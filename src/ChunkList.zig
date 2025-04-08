//! A list of all chunks with a given archetype.

const std = @import("std");
const zcs = @import("root.zig");
const tracy = @import("tracy");

const ChunkPool = zcs.ChunkPool;
const CompFlag = zcs.CompFlag;
const Chunk = zcs.Chunk;
const Entities = zcs.Entities;
const PointerLock = zcs.PointerLock;
const Arches = zcs.Arches;
const Entity = zcs.Entity;

const Zone = tracy.Zone;

const typeId = zcs.typeId;

const assert = std.debug.assert;
const alignForward = std.mem.alignForward;
const math = std.math;

const ChunkList = @This();

/// The chunks in this chunk list, connected via the `next` and `prev` fields.
head: Chunk.Index,
/// The final chunk in this chunk list.
tail: Chunk.Index,
/// The chunks in this chunk list that have space available, connected via the `next_avail`
/// and `prev_avail` fields.
avail: Chunk.Index,
/// The offset to the entity index buffer.
index_buf_offset: u32,
/// A map from component flags to the byte offset of their arrays. Components that aren't
/// present or are zero sized have undefined offsets. It's generally faster to read this from
/// the chunk instead of the chunk list to avoid the extra cache miss.
comp_buf_offsets_cold: std.enums.EnumArray(CompFlag, u32),
/// The number of entities that can be stored in a single chunk from this list.
chunk_capacity: u32,

/// The index of a `ChunkList` in the `Arches` that owns it.
pub const Index = enum(u32) {
    /// Gets a chunk list from a chunk list ID.
    pub fn get(self: @This(), arches: *const Arches) *ChunkList {
        return &arches.map.values()[@intFromEnum(self)];
    }

    /// Gets the archetype for a chunk list.
    pub fn arch(self: Index, arches: *const Arches) CompFlag.Set {
        return arches.map.keys()[@intFromEnum(self)];
    }

    _,
};

/// Initializes a chunk list.
pub fn init(pool: *const ChunkPool, arch: CompFlag.Set) error{ZcsChunkOverflow}!@This() {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();

    // Sort the components from greatest to least alignment.
    const sorted = sortCompsByAlignment(arch);

    // Get the max alignment required by any component or entity index
    var max_align: u32 = @alignOf(Entity.Index);
    if (sorted.len > 0) max_align = @max(max_align, sorted.get(0).getId().alignment);

    // Initialize the offset to the start of the data
    const data_offset: u32 = alignForward(u32, @sizeOf(Chunk.Header), max_align);

    // Calculate how many bytes of data there are
    const bytes = math.sub(
        u32,
        @intCast(pool.size_align.toByteUnits()),
        data_offset,
    ) catch return error.ZcsChunkOverflow;

    // Calculate how much space one entity takes
    var entity_size: u32 = @sizeOf(Entity.Index);
    for (sorted.constSlice()) |comp| {
        const comp_size = math.cast(u32, comp.getId().size) orelse
            return error.ZcsChunkOverflow;
        entity_size = math.add(u32, entity_size, comp_size) catch
            return error.ZcsChunkOverflow;
    }

    // Calculate the capacity in entities
    const chunk_capacity: u32 = bytes / entity_size;

    // Check that we have enough space for at least one entity
    if (chunk_capacity <= 0) return error.ZcsChunkOverflow;

    // Calculate the offsets for each component
    var offset: u32 = data_offset;
    var comp_buf_offsets: std.enums.EnumArray(CompFlag, u32) = .initFill(0);
    var index_buf_offset: u32 = 0;
    for (sorted.constSlice()) |comp| {
        const id = comp.getId();

        // If we haven't found a place for the index buffer, check if it can go here
        if (index_buf_offset == 0 and id.alignment <= @alignOf(Entity.Index)) {
            assert(offset % @alignOf(Entity.Index) == 0);
            index_buf_offset = offset;
            const buf_size = math.mul(u32, @sizeOf(Entity.Index), chunk_capacity) catch
                return error.ZcsChunkOverflow;
            offset = math.add(u32, offset, buf_size) catch
                return error.ZcsChunkOverflow;
        }

        // Store the offset to this component type
        assert(offset % id.alignment == 0);
        comp_buf_offsets.set(comp, offset);
        const comp_size = math.cast(u32, id.size) orelse
            return error.ZcsChunkOverflow;
        const buf_size = math.mul(u32, comp_size, chunk_capacity) catch
            return error.ZcsChunkOverflow;
        offset = math.add(u32, offset, buf_size) catch
            return error.ZcsChunkOverflow;
    }

    // If we haven't found a place for the index buffer, place it at the end
    if (index_buf_offset == 0) {
        index_buf_offset = offset;
        const buf_size = math.mul(u32, @sizeOf(Entity.Index), chunk_capacity) catch
            return error.ZcsChunkOverflow;
        offset = math.add(u32, offset, buf_size) catch
            return error.ZcsChunkOverflow;
    }

    assert(offset <= pool.size_align.toByteUnits());

    return .{
        .head = .none,
        .tail = .none,
        .avail = .none,
        .comp_buf_offsets_cold = comp_buf_offsets,
        .index_buf_offset = index_buf_offset,
        .chunk_capacity = chunk_capacity,
    };
}

/// Adds an entity to the chunk list.
pub fn append(
    self: *@This(),
    es: *Entities,
    e: Entity,
) error{ZcsChunkPoolOverflow}!Entity.Location {
    const pool = &es.chunk_pool;
    const arches = &es.arches;

    // Ensure there's a chunk with space available
    if (self.avail == .none) {
        // Allocate a new chunk
        const new = try pool.reserve(es, arches.indexOf(self));
        const new_index = pool.indexOf(new);

        // Point the available list to the new chunk
        self.avail = new_index;

        // Add the new chunk to the end of the chunk list
        if (self.tail.get(pool)) |tail| {
            new.header().prev = self.tail;
            tail.header().next = new_index;
            self.tail = new_index;
        } else {
            self.head = new_index;
            self.tail = new_index;
        }
    }

    // Get the next chunk with space available
    const chunk = self.avail.get(pool).?;
    const header = chunk.header();
    assert(header.len < self.chunk_capacity);
    chunk.checkAssertions(es, .allow_empty);

    // Append the entity. This const cast is okay since the chunk was originally mutable, we
    // just don't expose mutable pointers to the index buf publicly.
    const index_in_chunk: Entity.Location.IndexInChunk = @enumFromInt(header.len);
    header.len += 1;
    const index_buf = @constCast(chunk.view(es, struct {
        indices: []const Entity.Index,
    }).?.indices);
    index_buf[@intFromEnum(index_in_chunk)] = @enumFromInt(e.key.index);

    // If the chunk is now full, remove it from the available list
    if (header.len == self.chunk_capacity) {
        @branchHint(.unlikely);
        assert(self.avail.get(pool) == chunk);
        self.avail = chunk.header().next_avail;
        header.next_avail = .none;
        if (self.avail.get(pool)) |avail| {
            const available_header = avail.header();
            assert(available_header.prev_avail.get(pool) == chunk);
            available_header.prev_avail = .none;
        }
    }

    self.checkAssertions(es);

    // Return the location we stored the entity
    return .{
        .chunk = es.chunk_pool.indexOf(chunk),
        .index_in_chunk = index_in_chunk,
    };
}

// Checks internal consistency.
pub fn checkAssertions(self: *const @This(), es: *const Entities) void {
    if (!std.debug.runtime_safety) return;

    const pool = &es.chunk_pool;

    if (self.head.get(pool)) |head| {
        const header = head.header();
        head.checkAssertions(es, .default);
        self.tail.get(pool).?.checkAssertions(es, .default);
        assert(@intFromBool(header.next != .none) ^
            @intFromBool(head == self.tail.get(pool)) != 0);
        assert(self.tail != .none);
    } else {
        assert(self.tail == .none);
        assert(self.avail == .none);
    }

    if (self.avail.get(pool)) |avail| {
        const header = avail.header();
        avail.checkAssertions(es, .default);
        assert(header.prev_avail == .none);
    }
}

/// Returns an iterator over this chunk list's chunks.
///
/// Invalidating pointers while iterating results in safety checked illegal behavior.
pub fn iterator(self: *const @This(), es: *const Entities) Iterator {
    self.checkAssertions(es);
    return .{
        .chunk = self.head.get(&es.chunk_pool),
        .pointer_lock = es.pointer_generation.lock(),
    };
}

/// An iterator over a chunk list's chunks.
pub const Iterator = struct {
    /// Returns an empty iterator.
    pub fn empty(es: *const Entities) @This() {
        return .{
            .chunk = null,
            .pointer_lock = es.pointer_generation.lock(),
        };
    }

    chunk: ?*Chunk,
    pointer_lock: PointerLock,

    /// Returns the next chunk and advances.
    pub fn next(self: *@This(), es: *const Entities) ?*Chunk {
        self.pointer_lock.check(es.pointer_generation);
        const chunk = self.chunk orelse {
            @branchHint(.unlikely);
            return null;
        };
        chunk.checkAssertions(es, .default);
        const header = chunk.header();
        self.chunk = header.next.get(&es.chunk_pool);
        return chunk;
    }

    /// Peeks at the next chunk.
    pub fn peek(self: @This(), es: *const Entities) ?*Chunk {
        self.pointer_lock.check(es.pointer_generation);
        return self.chunk;
    }
};

/// Compares the alignment of two component types.
fn alignmentGte(_: void, lhs: CompFlag, rhs: CompFlag) bool {
    const lhs_alignment = lhs.getId().alignment;
    const rhs_alignment = rhs.getId().alignment;
    return lhs_alignment >= rhs_alignment;
}

/// Returns a list of the components in this set sorted from greatest to least alignment. This
/// is an optimization to reduce padding, but also necessary to get consistent cutoffs for how
/// much data fits in a chunk regardless of registration order.
inline fn sortCompsByAlignment(set: CompFlag.Set) std.BoundedArray(CompFlag, CompFlag.max) {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();
    var comps: std.BoundedArray(CompFlag, CompFlag.max) = .{};
    var iter = set.iterator();
    while (iter.next()) |flag| comps.appendAssumeCapacity(flag);
    std.sort.pdq(CompFlag, comps.slice(), {}, alignmentGte);
    return comps;
}

test sortCompsByAlignment {
    defer CompFlag.unregisterAll();

    // Register various components with different alignments in an arbitrary order
    const a_1 = CompFlag.registerImmediate(typeId(struct { x: u8 align(1) }));
    const e_2 = CompFlag.registerImmediate(typeId(struct { x: u8 align(16) }));
    const d_2 = CompFlag.registerImmediate(typeId(struct { x: u8 align(8) }));
    const e_0 = CompFlag.registerImmediate(typeId(struct { x: u8 align(16) }));
    const b_2 = CompFlag.registerImmediate(typeId(struct { x: u8 align(2) }));
    const d_0 = CompFlag.registerImmediate(typeId(struct { x: u8 align(8) }));
    const a_2 = CompFlag.registerImmediate(typeId(struct { x: u8 align(1) }));
    const e_1 = CompFlag.registerImmediate(typeId(struct { x: u8 align(16) }));
    const c_0 = CompFlag.registerImmediate(typeId(struct { x: u8 align(4) }));
    const b_0 = CompFlag.registerImmediate(typeId(struct { x: u8 align(2) }));
    const b_1 = CompFlag.registerImmediate(typeId(struct { x: u8 align(2) }));
    const a_0 = CompFlag.registerImmediate(typeId(struct { x: u8 align(1) }));
    const c_2 = CompFlag.registerImmediate(typeId(struct { x: u8 align(4) }));
    const c_1 = CompFlag.registerImmediate(typeId(struct { x: u8 align(4) }));
    const d_1 = CompFlag.registerImmediate(typeId(struct { x: u8 align(8) }));

    // Test sorting all of them
    {
        // Sort them
        const sorted = sortCompsByAlignment(.initMany(&.{
            e_0,
            c_1,
            d_0,
            e_1,
            a_1,
            b_1,
            b_0,
            a_0,
            d_1,
            c_0,
            c_2,
            e_2,
            a_2,
            b_2,
            d_2,
        }));
        try std.testing.expectEqual(15, sorted.len);
        var prev: usize = math.maxInt(usize);
        for (sorted.constSlice()) |flag| {
            const curr = flag.getId().alignment;
            try std.testing.expect(curr <= prev);
            prev = curr;
        }
    }

    // Test sorting a subset of them
    {
        // Sort them
        const sorted = sortCompsByAlignment(.initMany(&.{
            e_0,
            d_0,
            c_0,
            a_0,
            b_0,
        }));
        try std.testing.expectEqual(5, sorted.len);
        try std.testing.expectEqual(e_0, sorted.get(0));
        try std.testing.expectEqual(d_0, sorted.get(1));
        try std.testing.expectEqual(c_0, sorted.get(2));
        try std.testing.expectEqual(b_0, sorted.get(3));
        try std.testing.expectEqual(a_0, sorted.get(4));
    }
}
