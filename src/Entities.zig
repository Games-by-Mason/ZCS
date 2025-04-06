//! Storage for entities.
//!
//! See `SlotMap` for how handle safety works. Note that you may want to check
//! `saturated` every now and then and warn if it's nonzero.
//!
//! See `README.md` for more information.

const std = @import("std");
const assert = std.debug.assert;
const tracy = @import("tracy");

const Allocator = std.mem.Allocator;

const Zone = tracy.Zone;

const zcs = @import("root.zig");
const typeId = zcs.typeId;
const Any = zcs.Any;
const CompFlag = zcs.CompFlag;
const Entity = zcs.Entity;
const PointerLock = zcs.PointerLock;
const TypeId = zcs.TypeId;
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
pointer_generation: PointerLock.Generation = .{},
reserved_entities: usize = 0,
chunk_pool: ChunkPool,

/// Options for `init`.
pub const Options = struct {
    /// The max number of entities.
    max_entities: u32 = 1000000,
    /// The max number of archetypes.
    max_archetypes: u32 = 64,
    /// The number of chunks to allocate.
    max_chunks: u16 = 4096,
    /// The size of each chunk.
    chunk_size: u32 = 65536,
};

/// Initializes the entity storage with the given capacity.
pub fn init(gpa: Allocator, options: Options) Allocator.Error!@This() {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();

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

/// Given a pointer to a non zero sized component, returns the corresponding entity.
pub fn getEntity(es: *const Entities, from_comp: anytype) Entity {
    const T = @typeInfo(@TypeOf(from_comp)).pointer.child;

    // We could technically pack the entity into the pointer value since both are typically 64
    // bits. However, this would break support for getting a slice of zero sized components from
    // a chunk since all would have the same address.
    //
    // I've chosen to support the slice use case and not this one as it's simpler and seems
    // slightly more likely to come up in generic code. I don't expect either to come up
    // particularly often, this decision can be reversed in the future if one or the other turns
    // out to be desirable. If we do this, make sure to have an assertion/test that valid
    // entities are never fully zero since non optional pointers can't be zero unless explicitly
    // annotated as such.
    comptime assert(@sizeOf(T) != 0);

    return getEntityFromAny(es, .init(T, from_comp));
}

/// Similar to `getEntity`, but does not require compile time types. Assumes a valid pointer to a
/// non zero sized component.
pub fn getEntityFromAny(es: *const Entities, from_comp: Any) Entity {
    // Get the entity index from the chunk
    const loc = getLoc(es, from_comp);
    const indices = loc.chunk.view(es, struct { indices: []const Entity.Index }).?.indices;
    const entity_index = indices[@intFromEnum(loc.index_in_chunk)];

    // Get the entity handle
    assert(@intFromEnum(entity_index) < es.handle_tab.next_index);
    const entity = entity_index.toEntity(es);

    // Assert that the entity has been committed and return it
    assert(entity.committed(es));
    return entity;
}

/// Given a valid pointer to a non zero sized component `from`, returns the corresponding
/// component `Result`, or `null` if there isn't one attached to the same entity. See also
/// `Entity.get`.
pub fn getComp(es: *const Entities, from: anytype, Result: type) ?*Result {
    const T = @typeInfo(@TypeOf(from)).pointer.child;
    // See `from` for why this isn't allowed.
    comptime assert(@sizeOf(T) != 0);
    const slice = getCompFromAny(es, .init(T, from), typeId(Result));
    return @ptrCast(@alignCast(slice));
}

/// Similar to `getComp`, but does not require compile time types.
pub fn getCompFromAny(self: *const Entities, from_comp: Any, get_comp_id: TypeId) ?[]u8 {
    // Check assertions
    if (std.debug.runtime_safety) {
        _ = self.getEntityFromAny(from_comp);
    }

    // Get the component
    const flag = get_comp_id.comp_flag orelse return null;
    const loc = self.getLoc(from_comp);
    // https://github.com/Games-by-Mason/ZCS/issues/24
    const comp_buf_offset = loc.chunk.header().comp_buf_offsets.values[@intFromEnum(flag)];
    if (comp_buf_offset == 0) return null;
    const unsized: [*]u8 = @ptrFromInt(@intFromPtr(loc.chunk) +
        comp_buf_offset +
        get_comp_id.size * @intFromEnum(loc.index_in_chunk));
    return unsized[0..get_comp_id.size];
}

/// Looks up the location of an entity from a component.
fn getLoc(self: *const Entities, from_comp: Any) struct {
    chunk: *Chunk,
    index_in_chunk: Entity.Location.IndexInChunk,
} {
    // See `from` for why this isn't allowed
    assert(from_comp.id.size != 0);

    const pool = &self.chunk_pool;
    const flag = from_comp.id.comp_flag.?;

    // Make sure this component is actually in the chunk pool
    assert(@intFromPtr(from_comp.ptr) >= @intFromPtr(pool.buf.ptr));
    assert(@intFromPtr(from_comp.ptr) <= @intFromPtr(&pool.buf[pool.buf.len - 1]));

    // Get the corresponding chunk by rounding down to the chunk alignment. This works as chunks
    // are aligned to their size, in part to support this operation.
    const chunk: *Chunk = @ptrFromInt(pool.size_align.backward(@intFromPtr(from_comp.ptr)));

    // Calculate the index in this chunk that this component is at
    assert(chunk.header().arch(&self.chunk_lists).contains(flag));
    const comp_offset = @intFromPtr(from_comp.ptr) - @intFromPtr(chunk);
    assert(comp_offset != 0); // Zero when missing
    // https://github.com/Games-by-Mason/ZCS/issues/24
    const comp_buf_offset = chunk.header().comp_buf_offsets.values[@intFromEnum(flag)];
    const index_in_chunk = @divExact(comp_offset - comp_buf_offset, from_comp.id.size);

    return .{
        .chunk = chunk,
        .index_in_chunk = @enumFromInt(index_in_chunk),
    };
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
                @branchHint(.likely);
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
        index_in_chunk: u32,

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
            var chunk = self.chunks.peek(es) orelse {
                @branchHint(.unlikely);
                return null;
            };
            assert(chunk.header().len > 0); // Free chunks are returned to the chunk pool

            // If we're done with the current chunk, advance to the next one
            if (self.index_in_chunk >= chunk.header().len) {
                _ = self.chunks.next(es).?;
                chunk = self.chunks.peek(es) orelse {
                    @branchHint(.unlikely);
                    return null;
                };
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
