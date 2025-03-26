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
const ChunkList = zcs.storage.ChunkList;
const ChunkPool = zcs.storage.ChunkPool;
const Chunk = zcs.storage.Chunk;
const HandleTab = zcs.storage.HandleTab;
const ChunkLists = zcs.storage.ChunkLists;
const view = zcs.view;

const Entities = @This();

const IteratorGeneration = if (std.debug.runtime_safety) u64 else u0;

const max_align = zcs.TypeInfo.max_align;

handle_tab: HandleTab,
comps: *[CompFlag.max][]align(max_align) u8,
max_archetypes: u16,
chunk_lists: ChunkLists,
iterator_generation: IteratorGeneration = 0,
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

    const comps = try gpa.create([CompFlag.max][]align(max_align) u8);
    errdefer gpa.destroy(comps);

    comptime var comps_init = 0;
    errdefer for (0..comps_init) |i| gpa.free(comps[i]);
    inline for (comps) |*comp| {
        comp.* = try gpa.alignedAlloc(u8, max_align, options.comp_bytes);
        comps_init += 1;
    }

    var chunk_pool: ChunkPool = try .init(gpa, .{
        .capacity = options.max_chunks,
        .chunk_size = options.chunk_size,
    });
    errdefer chunk_pool.deinit(gpa);

    var chunk_lists: ChunkLists = try .init(gpa, options.max_archetypes);
    errdefer chunk_lists.deinit(gpa);

    return .{
        .handle_tab = handle_tab,
        .max_archetypes = options.max_archetypes,
        .chunk_lists = chunk_lists,
        .comps = comps,
        .chunk_pool = chunk_pool,
    };
}

/// Destroys the entity storage.
pub fn deinit(self: *@This(), gpa: Allocator) void {
    self.chunk_lists.deinit(gpa);
    self.chunk_pool.deinit(gpa);
    for (self.comps) |comp| {
        gpa.free(comp);
    }
    gpa.destroy(self.comps);
    self.handle_tab.deinit(gpa);
    self.* = undefined;
}

/// Recycles all entities compatible with the given archetype.
pub fn recycleArchImmediate(self: *@This(), arch: CompFlag.Set) void {
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
pub fn recycleImmediate(self: *@This()) void {
    self.handle_tab.recycleAll();
    self.reserved_entities = 0;
}

/// Returns the current number of entities.
pub fn count(self: @This()) usize {
    return self.handle_tab.count() - self.reserved_entities;
}

/// Returns the number of reserved but not committed entities that currently exist.
pub fn reserved(self: @This()) usize {
    return self.reserved_entities;
}

/// Returns an iterator over all entities that have at least the components in `required_comps` in
/// an implementation defined order.
pub fn iterator(
    self: *const @This(),
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
        .generation = self.iterator_generation,
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
    generation: IteratorGeneration,

    /// Advances the iterator, returning the next entity.
    pub fn next(self: *@This()) ?Entity {
        if (self.generation != self.es.iterator_generation) {
            @panic("called next after iterator was invalidated");
        }

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

            // If that fails, return null;
            return null;
        }
    }
};

/// Similar to `iterator`, but returns a `view` with pointers to the requested components.
pub fn viewIterator(self: *const @This(), View: type) ViewIterator(View) {
    var base: view.Comps(View) = undefined;
    var required_comps: CompFlag.Set = .{};
    inline for (@typeInfo(view.Comps(View)).@"struct".fields) |field| {
        const T = view.UnwrapField(field.type);
        if (@typeInfo(field.type) != .optional) {
            if (typeId(T).comp_flag) |flag| {
                required_comps.insert(flag);
            } else {
                return .empty(self);
            }
        }

        if (typeId(T).comp_flag) |flag| {
            @field(base, field.name) = @ptrCast(self.comps[@intFromEnum(flag)]);
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
            .generation = self.iterator_generation,
            .arch_iter = arch_iter,
            .chunk_list_iter = chunk_list_iter,
            .chunk_iter = chunk_iter,
        },
        .base = base,
    };
}

/// See `Entities.viewIterator`.
pub fn ViewIterator(View: type) type {
    return struct {
        entity_iter: Iterator,
        base: view.Comps(View),

        pub fn empty(es: *const Entities) @This() {
            return .{
                .entity_iter = .{
                    .es = es,
                    .arch_iter = .empty,
                    .chunk_list_iter = .empty,
                    .chunk_iter = .empty,
                    .generation = es.iterator_generation,
                },
                .base = undefined,
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
                        const T = view.UnwrapField(field.type);
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
