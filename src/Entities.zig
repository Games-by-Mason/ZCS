//! Storage for entities.
//!
//! See `SlotMap` for how handle safety works. Note that you may want to check
//! `saturated` every now and then and warn if it's nonzero.
//!
//! See `README.md` for more information.

const std = @import("std");
const assert = std.debug.assert;

const Allocator = std.mem.Allocator;

const zcs = @import("root.zig");
const typeId = zcs.typeId;
const Any = zcs.Any;
const CompFlag = zcs.CompFlag;
const Entity = zcs.Entity;
const PointerLock = zcs.PointerLock;
const ChunkList = zcs.storage.ChunkList;
const ChunkPool = zcs.storage.ChunkPool;
const Chunk = zcs.storage.Chunk;
const HandleTab = zcs.storage.HandleTab;
const ChunkLists = zcs.storage.ChunkLists;
const EntityIndex = zcs.storage.EntityIndex;
const view = zcs.view;

const Entities = @This();

handle_tab: HandleTab,
chunk_lists: ChunkLists,
pointer_generation: PointerLock.Generation = .init,
reserved_entities: usize = 0,
chunk_pool: ChunkPool,

/// Options for `init`.
pub const Options = struct {
    /// The max number of entities.
    max_entities: u32,
    /// The number of bytes per component type array.
    comp_bytes: usize,
    /// The max number of archetypes.
    max_archetypes: u16,
    /// The number of chunks to allocate.
    max_chunks: u32,
    /// The size of each chunk.
    chunk_size: u16 = 16 << 10,
};

/// Initializes the entity storage with the given capacity.
pub fn init(gpa: Allocator, options: Options) Allocator.Error!@This() {
    var handle_tab: HandleTab = try .init(gpa, options.max_entities);
    errdefer handle_tab.deinit(gpa);

    var chunk_pool: ChunkPool = try .init(gpa, .{
        .capacity = options.max_chunks,
        .chunk_size = options.chunk_size,
    });
    errdefer chunk_pool.deinit(gpa);

    var chunk_lists: ChunkLists = try .init(gpa, options.max_archetypes);
    errdefer chunk_lists.deinit(gpa);

    return .{
        .handle_tab = handle_tab,
        .chunk_lists = chunk_lists,
        .chunk_pool = chunk_pool,
    };
}

/// Destroys the entity storage.
pub fn deinit(self: *@This(), gpa: Allocator) void {
    self.chunk_lists.deinit(gpa);
    self.chunk_pool.deinit(gpa);
    self.handle_tab.deinit(gpa);
    self.* = undefined;
}

/// Recycles all entities compatible with the given archetype.
///
/// Invalidates pointers.
pub fn recycleArchImmediate(self: *@This(), arch: CompFlag.Set) void {
    self.pointer_generation.increment();
    var chunk_lists_iter = self.chunk_lists.iterator(arch);
    while (chunk_lists_iter.next()) |chunk_list| {
        var chunk_list_iter = chunk_list.iterator(self);
        while (chunk_list_iter.next(self)) |chunk| {
            var chunk_iter = chunk.iterator();
            while (chunk_iter.next(self)) |entity| {
                self.handle_tab.recycle(entity.key);
            }
            // We have a mutable reference to entities, so it's fine to cast the const away here
            @constCast(chunk).clear(self);
        }
    }
}

/// Recycles all entities.
///
/// Invalidates pointers.
pub fn recycleImmediate(self: *@This()) void {
    self.pointer_generation.increment();
    self.handle_tab.recycleAll();
    self.reserved_entities = 0;
}

/// Returns the current number of entities.
pub fn count(self: *const @This()) usize {
    return self.handle_tab.count() - self.reserved_entities;
}

/// Returns the number of reserved but not committed entities that currently exist.
pub fn reserved(self: *const @This()) usize {
    return self.reserved_entities;
}

/// Calls `updateEntity` on each compatible entity in an implementation defined order.
/// See also `forEachChunk`.
///
/// `updateEntity` should take `ctx` as an argument, followed by any number of component pointers,
/// optional component pointers, or `Entity`s.
///
/// Invalidating pointers from the update function results in safety checked illegal behavior.
pub fn forEach(
    self: *@This(),
    updateEntity: anytype,
    ctx: view.params(@TypeOf(updateEntity))[0],
) void {
    const params = view.params(@TypeOf(updateEntity));
    var chunks = self.chunkIterator(view.requiredComps(params[1..]) orelse return);
    while (chunks.next()) |chunk| {
        const chunk_view = chunk.view(self, view.Slices(params[1..])).?;
        for (0..chunk.header().len) |i| {
            const entity_view = zcs.view.index(self, chunk_view, @intCast(i));
            @call(.auto, updateEntity, .{ctx} ++ entity_view);
        }
    }
}

/// Prefer `forEach`. Calls `updateChunk` on each compatible chunk in an implementation
/// defined order, may be useful for batch optimizations.
///
/// `updateChunk` should take `ctx` as an argument, followed by any number of component slices,
/// optional component slices, or const slices of `EntityIndex`.
///
/// Invalidating pointers from the update function results in safety checked illegal behavior.
pub fn forEachChunk(
    self: *@This(),
    updateChunk: anytype,
    ctx: view.params(@TypeOf(updateChunk))[0],
) void {
    const params = view.params(@TypeOf(updateChunk));
    var chunks = self.chunkIterator(view.requiredComps(params[1..]) orelse return);
    while (chunks.next()) |chunk| {
        const chunk_view = chunk.view(self, view.Tuple(params[1..])).?;
        @call(.auto, updateChunk, .{ctx} ++ chunk_view);
    }
}

/// Returns an iterator over all the chunks with at least the components in `required_comps` in
/// an implementation defined order.
///
/// Invalidating pointers while iterating results in safety checked illegal behavior.
pub fn chunkIterator(
    self: *@This(),
    required_comps: CompFlag.Set,
) ChunkIterator {
    var lists = self.chunk_lists.iterator(required_comps);
    const chunks: ChunkList.Iterator = if (lists.next()) |list| list.iterator(self) else .empty;
    return .{
        .es = self,
        .lists = lists,
        .chunks = chunks,
        .pointer_lock = self.pointer_generation.lock(),
    };
}

/// See `chunkIterator`.
pub const ChunkIterator = struct {
    es: *const Entities,
    lists: ChunkLists.Iterator,
    chunks: ChunkList.Iterator,
    pointer_lock: PointerLock,

    /// Advances the iterator, returning the next entity.
    pub fn next(self: *@This()) ?*Chunk {
        self.pointer_lock.check(self.es.pointer_generation);

        while (true) {
            // Get the next chunk in this list
            if (self.chunks.next(self.es)) |chunk| {
                return chunk;
            }

            // If that fails, get the next list
            if (self.lists.next()) |chunk_list| {
                self.chunks = chunk_list.iterator(self.es);
                continue;
            }

            // If that fails, return null
            return null;
        }
    }
};

/// Returns an iterator over all entities that have at least the components in `required_comps` in
/// an implementation defined order.
///
/// Invalidating pointers while iterating results in safety checked illegal behavior.
pub fn iterator(
    self: *@This(),
    required_comps: CompFlag.Set,
) Iterator {
    var arch_iter = self.chunk_lists.iterator(required_comps);
    var chunk_list_iter: ChunkList.Iterator = if (arch_iter.next()) |chunk_list|
        chunk_list.iterator(self)
    else
        .empty;
    const chunk_iter: Chunk.Iterator = if (chunk_list_iter.next(self)) |chunk|
        chunk.iterator()
    else
        .empty;
    return .{
        .es = self,
        .pointer_lock = self.pointer_generation.lock(),
        .arch_iter = arch_iter,
        .chunk_list_iter = chunk_list_iter,
        .chunk_iter = chunk_iter,
    };
}

/// See `iterator`.
pub const Iterator = struct {
    es: *const Entities,
    arch_iter: ChunkLists.Iterator,
    chunk_list_iter: ChunkList.Iterator,
    chunk_iter: Chunk.Iterator,
    pointer_lock: PointerLock,

    /// Advances the iterator, returning the next entity.
    pub fn next(self: *@This()) ?Entity {
        self.pointer_lock.check(self.es.pointer_generation);

        while (true) {
            // Get the next entity in this chunk
            if (self.chunk_iter.next(self.es)) |entity| {
                return entity;
            }

            // If that fails, get the next chunk in this chunk list
            if (self.chunk_list_iter.next(self.es)) |chunk| {
                self.chunk_iter = chunk.iterator();
                continue;
            }

            // If that fails, get the next chunk list in this archetype
            if (self.arch_iter.next()) |chunk_list| {
                self.chunk_list_iter = chunk_list.iterator(self.es);
                continue;
            }

            // If that fails, return null
            return null;
        }
    }
};

/// Similar to `iterator`, but returns a `view` with pointers to the requested components.
///
/// Invalidating pointers while iterating results in safety checked illegal behavior.
pub fn viewIterator(self: *const @This(), View: type) ViewIterator(View) {
    var required_comps: CompFlag.Set = .{};
    inline for (@typeInfo(view.Comps(View)).@"struct".fields) |field| {
        const T = view.UnwrapField(field.type, .one);
        if (@typeInfo(field.type) != .optional) {
            if (typeId(T).comp_flag) |flag| {
                required_comps.insert(flag);
            } else {
                return .empty(self);
            }
        }
    }

    var arch_iter = self.chunk_lists.iterator(required_comps);
    var chunk_list_iter: ChunkList.Iterator = if (arch_iter.next()) |chunk_list|
        chunk_list.iterator(self)
    else
        .empty;
    const chunk_iter: Chunk.Iterator = if (chunk_list_iter.next(self)) |chunk|
        chunk.iterator()
    else
        .empty;
    return .{
        .entity_iter = .{
            .es = self,
            .pointer_lock = self.pointer_generation.lock(),
            .arch_iter = arch_iter,
            .chunk_list_iter = chunk_list_iter,
            .chunk_iter = chunk_iter,
        },
    };
}

/// See `Entities.viewIterator`.
pub fn ViewIterator(View: type) type {
    return struct {
        entity_iter: Iterator,

        pub fn empty(es: *const Entities) @This() {
            return .{
                .entity_iter = .{
                    .es = es,
                    .arch_iter = .empty,
                    .chunk_list_iter = .empty,
                    .chunk_iter = .empty,
                    .pointer_lock = es.pointer_generation.lock(),
                },
            };
        }

        /// Advances the iterator, returning the next view.
        pub fn next(self: *@This()) ?View {
            while (self.entity_iter.next()) |entity| {
                var result: View = undefined;
                inline for (@typeInfo(View).@"struct".fields) |field| {
                    if (field.type == Entity) {
                        @field(result, field.name) = entity;
                    } else {
                        const T = view.UnwrapField(field.type, .one);
                        const comp = entity.get(self.entity_iter.es, T);
                        const is_opt = @typeInfo(field.type) == .optional;
                        @field(result, field.name) = if (is_opt) comp else comp.?;
                    }
                }
                return result;
            }

            return null;
        }
    };
}
