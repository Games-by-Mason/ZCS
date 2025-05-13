//! A pool of `Chunk`s.

const std = @import("std");
const zcs = @import("root.zig");
const tracy = @import("tracy");

const Chunk = zcs.Chunk;
const Entities = zcs.Entities;
const ChunkList = zcs.ChunkList;
const Entity = zcs.Entity;

const assert = std.debug.assert;
const math = std.math;

const Alignment = std.mem.Alignment;
const Allocator = std.mem.Allocator;

const Zone = tracy.Zone;

const ChunkPool = @This();

/// Memory reserved for chunks
buf: []u8,
/// The number of unique chunks that have ever been reserved.
reserved: u32,
/// The chunk size and alignment are both set to this value. This is done for a couple reasons:
/// 1. It makes `Entity.from` slightly cheaper
/// 2. It reduces false sharing
/// 3. We need to be aligned by more than `TypeInfo.max_align` so that the place our allocation
///    ends up doesn't change how much stuff can fit in it.
///
/// If this becomes an issue, we stop doing this by giving up 1 as long as we set the alignment
/// to at least a cache line and assert 3. However seeing as it only adds padding before the
/// first chunk, this is unlikely to ever matter.
size_align: Alignment,
/// Freed chunks, connected by the `next` field. All other fields are undefined.
free: Chunk.Index = .none,

/// The pool's capcity.
pub const Capacity = struct {
    /// The number of chunks to reserve. Supports the range `[0, math.maxInt(u32))`, max int
    /// is reserved for the none index.
    chunks: u16,
    /// The size of each chunk.
    chunk: u32,
};

/// Allocates a chunk pool.
pub fn init(gpa: Allocator, cap: Capacity) Allocator.Error!@This() {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();

    // The max size is reserved for invalid indices.
    assert(cap.chunks < math.maxInt(u32));
    assert(cap.chunk >= zcs.TypeInfo.max_align.toByteUnits());

    // Allocate the chunk data, aligned to the size of a chunk
    const alignment = Alignment.fromByteUnits(cap.chunk);
    const len = @as(usize, cap.chunk) * @as(usize, cap.chunks);
    const buf = (gpa.rawAlloc(
        len,
        alignment,
        @returnAddress(),
    ) orelse return error.OutOfMemory)[0..len];
    errdefer comptime unreachable;

    return .{
        .buf = buf,
        .reserved = 0,
        .size_align = alignment,
    };
}

/// Frees a chunk pool.
pub fn deinit(self: *@This(), gpa: Allocator) void {
    gpa.rawFree(self.buf, self.size_align, @returnAddress());
    self.* = undefined;
}

/// Reserves a chunk from the chunk pool
pub fn reserve(
    self: *@This(),
    es: *const Entities,
    list: ChunkList.Index,
) error{ZcsChunkPoolOverflow}!*Chunk {
    // Get a free chunk. Try the free list first, then fall back to bump allocation from the
    // preallocated buffer.
    const chunk = if (self.free.get(self)) |free| b: {
        // Pop the next chunk from the free list
        self.free = free.header().next;
        break :b free;
    } else b: {
        // Pop the next chunk from the preallocated buffer
        const byte_idx = @shlExact(self.reserved, @intCast(@intFromEnum(self.size_align)));
        if (byte_idx >= self.buf.len) return error.ZcsChunkPoolOverflow;
        const chunk: *Chunk = @ptrCast(&self.buf[byte_idx]);
        self.reserved = self.reserved + 1;
        break :b chunk;
    };
    errdefer comptime unreachable; // Already modified the free list!

    // Check the alignment
    assert(self.size_align.check(@intFromPtr(chunk)));

    // Initialize the chunk and return it
    const header = chunk.header();
    header.* = .{
        .comp_buf_offsets = list.get(&es.arches).comp_buf_offsets_cold,
        .list = list,
        .len = 0,
    };
    return chunk;
}

/// Gets the index of a chunk.
pub fn indexOf(self: *const @This(), chunk: *const Chunk) Chunk.Index {
    assert(@intFromPtr(chunk) >= @intFromPtr(self.buf.ptr));
    assert(@intFromPtr(chunk) < @intFromPtr(self.buf.ptr) + self.buf.len);
    const offset = @intFromPtr(chunk) - @intFromPtr(self.buf.ptr);
    assert(offset < self.buf.len);
    return @enumFromInt(@shrExact(offset, @intFromEnum(self.size_align)));
}
