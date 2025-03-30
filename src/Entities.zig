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
    var chunk_lists_iter = self.chunk_lists.iterator(self, arch);
    while (chunk_lists_iter.next(self)) |chunk_list| {
        var chunk_list_iter = chunk_list.iterator(self);
        while (chunk_list_iter.next(self)) |chunk| {
            var chunk_iter = chunk.iterator(self);
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
///
/// Note that the implementation only relies on ZCS's public interface. If you have a use case that
/// isn't served well by `forEach`, you can fork it into your code base and modify it as needed.
pub fn forEach(
    self: *@This(),
    updateEntity: anytype,
    ctx: view.params(@TypeOf(updateEntity))[0],
) void {
    const params = view.params(@TypeOf(updateEntity));
    const View = view.Tuple(params[1..]);
    var iter = self.iterator(View);
    while (iter.next(self)) |vw| {
        @call(.auto, updateEntity, .{ctx} ++ vw);
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
    const required_comps = view.comps(view.Tuple(params[1..]), .slice) orelse return;
    var chunks = self.chunkIterator(required_comps);
    while (chunks.next(self)) |chunk| {
        const chunk_view = chunk.view(self, view.Tuple(params[1..])).?;
        @call(.auto, updateChunk, .{ctx} ++ chunk_view);
    }
}

/// Returns an iterator over all the chunks with at least the components in `required_comps` in
/// an implementation defined order.
///
/// Invalidating pointers while iterating results in safety checked illegal behavior.
pub fn chunkIterator(
    self: *const @This(),
    required_comps: CompFlag.Set,
) ChunkIterator {
    var lists = self.chunk_lists.iterator(self, required_comps);
    const chunks: ChunkList.Iterator = if (lists.next(self)) |l| l.iterator(self) else .empty(self);
    var result: ChunkIterator = .{
        .lists = lists,
        .chunks = chunks,
    };
    result.catchUp(self);
    return result;
}

/// See `chunkIterator`.
pub const ChunkIterator = struct {
    lists: ChunkLists.Iterator,
    chunks: ChunkList.Iterator,

    /// Returns the pointer lock.
    pub fn pointerLock(self: *const ChunkIterator) PointerLock {
        return self.lists.pointer_lock;
    }

    /// Returns an empty iterator.
    pub fn empty(es: *const Entities) @This() {
        return .{
            .lists = .empty(es),
            .chunks = .empty(es),
        };
    }

    /// Advance the internal state so that `peek` is in sync.
    fn catchUp(self: *@This(), es: *const Entities) void {
        while (self.chunks.chunk == null) {
            if (self.lists.next(es)) |chunk_list| {
                self.chunks = chunk_list.iterator(es);
            } else {
                break;
            }
        }
    }

    /// Returns the current chunk without advancing.
    pub fn peek(self: *const @This(), es: *const Entities) ?*Chunk {
        return self.chunks.peek(es);
    }

    /// Advances the iterator, returning the next entity.
    pub fn next(self: *@This(), es: *const Entities) ?*Chunk {
        self.pointerLock().check(es.pointer_generation);

        // We need to loop here because while chunks can't be empty, chunk lists can
        const chunk = while (true) {
            // Get the next chunk in this list
            if (self.chunks.next(es)) |chunk| break chunk;

            // If that fails, get the next list and try again
            if (self.lists.next(es)) |chunk_list| {
                self.chunks = chunk_list.iterator(es);
                continue;
            }

            // If that fails, return null
            return null;
        };

        // Catch up the peek state.
        self.catchUp(es);

        return chunk;
    }
};

/// Returns an iterator over all entities that have at least the components in `required_comps` in
/// an implementation defined order. The results are of type `View` which is a struct where each
/// field is either a pointer to a component, an optional pointer to a component, or `Entity`.
///
/// Invalidating pointers while iterating results in safety checked illegal behavior.
pub fn iterator(self: *const @This(), View: type) Iterator(View) {
    const required_comps: CompFlag.Set = view.comps(View, .one) orelse
        return .empty(self);
    const chunks = self.chunkIterator(required_comps);
    const slices = if (chunks.peek(self)) |c| c.view(self, view.Slice(View)).? else undefined;
    return .{
        .chunks = chunks,
        .slices = slices,
        .index_in_chunk = 0,
    };
}

/// See `Entities.iterator`.
pub fn Iterator(View: type) type {
    return struct {
        const Slices = view.Slice(View);

        chunks: ChunkIterator,
        slices: Slices,
        index_in_chunk: u16,

        /// Returns an empty iterator.
        pub fn empty(es: *const Entities) @This() {
            return .{
                .chunks = .empty(es),
                .slices = undefined,
                .index_in_chunk = 0,
            };
        }

        /// Advances the iterator, returning the next view.
        pub fn next(self: *@This(), es: *const Entities) ?View {
            // Check for pointer invalidation
            self.chunks.pointerLock().check(es.pointer_generation);

            // Get the current chunk
            var chunk = self.chunks.peek(es) orelse return null;
            assert(chunk.header().len > 0); // Free chunks are returned to the chunk pool

            // If we're done with the current chunk, advance to the next one
            if (self.index_in_chunk >= chunk.header().len) {
                _ = self.chunks.next(es).?;
                chunk = self.chunks.peek(es) orelse return null;
                self.index_in_chunk = 0;
                assert(chunk.header().len > 0); // Free chunks are returned to the chunk pool
                self.slices = chunk.view(es, Slices).?;
            }

            // Get the entity and advance the index, this can't overflow the counter since we can't
            // have as many entities as bytes in a chunk since the space would be used up by the
            // entity indices
            const result = view.index(View, es, self.slices, self.index_in_chunk);
            self.index_in_chunk += 1;
            return result;
        }
    };
}
