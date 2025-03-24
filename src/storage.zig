//! For internal use. Handles entity storage.

const std = @import("std");
const zcs = @import("root.zig");
const slot_map = @import("slot_map");

const assert = std.debug.assert;
const math = std.math;

const Entity = zcs.Entity;
const Entities = zcs.Entities;
const CompFlag = zcs.CompFlag;

const SlotMap = slot_map.SlotMap;

const Allocator = std.mem.Allocator;

/// For internal use. A handle table that associates persistent entity keys with values that point
/// to their storage.
pub const HandleTab = SlotMap(EntityLoc, .{});

/// For internal use. Points to an entity's storage, the indirection allows entities to be relocated
/// without invalidating their handles.
pub const EntityLoc = struct {
    /// A handle that's been reserved but not committed.
    pub const reserved: @This() = .{
        .chunk = null,
        .index_in_chunk = if (std.debug.runtime_safety)
            @enumFromInt(math.maxInt(@typeInfo(IndexInChunk).@"enum".tag_type))
        else
            undefined,
    };

    /// The chunk where this entity is stored, or `null` if it hasn't been committed.
    chunk: ?*Chunk,
    /// The entity's index in the chunk, value is unspecified if not committed.
    index_in_chunk: IndexInChunk,

    /// For internal use. Returns the archetype for this entity, or the empty archetype if it hasn't
    /// been committed.
    pub fn getArch(self: @This()) CompFlag.Set {
        const chunk = self.chunk orelse return .{};
        const header = chunk.getHeaderConst();
        return header.getArch();
    }
};

/// An index into a chunk.
pub const IndexInChunk = enum(u16) { _ };

/// For internal use. A chunk of entities that all have the same archetype.
pub const Chunk = opaque {
    const EntityIndex = @FieldType(HandleTab.Key, "index");

    /// For internal use. The header information for a chunk.
    pub const Header = extern struct {
        /// See `getArch`.
        arch_mask: u64,
        /// The next chunk.
        next: ChunkPool.Index = .none,
        /// The previous chunk.
        prev: ChunkPool.Index = .none,
        /// The next chunk with available space.
        next_avail: ChunkPool.Index = .none,
        /// The previous chunk with available space.
        prev_avail: ChunkPool.Index = .none,
        /// The number of entities in this chunk.
        len: u16,
        /// The number of entities that can be stored in this chunk.
        capacity: u16,

        /// Returns this chunk's archetype.
        pub fn getArch(self: *const @This()) CompFlag.Set {
            return .{ .bits = .{ .mask = self.arch_mask } };
        }
    };

    /// Options for `checkAssertions`.
    const CheckAssertionsOptions = struct {
        pool: *const ChunkPool,
        cl: ?*const ChunkList,
        allow_empty: bool = false,
    };

    /// Checks for self consistency.
    fn checkAssertions(self: *const @This(), options: CheckAssertionsOptions) void {
        const header = self.getHeaderConst();
        const pool = options.pool;

        // Validate next/prev
        if (header.next.getConst(pool)) |next_chunk| {
            assert(next_chunk.getHeaderConst().prev.getConst(pool) == self);
        }

        if (header.prev.getConst(pool)) |prev_chunk| {
            assert(prev_chunk.getHeaderConst().next.getConst(pool) == self);
        }

        if (options.cl) |cl| {
            if (self == cl.head.getConst(options.pool)) assert(header.prev == .none);
            if (self == cl.tail.getConst(options.pool)) assert(header.next == .none);
        }

        if (header.len >= header.capacity) {
            // Validate full chunks
            assert(header.len == header.capacity);
            assert(header.next_avail == .none);
            assert(header.prev_avail == .none);
        } else {
            // Available chunks shouldn't be empty, since empty chunks are returned to the chunk
            // pool. `allow_empty` is set to true when checking a chunk that's about to be returned
            // to the chunk pool.
            assert(options.allow_empty or header.len > 0);

            // Validate next/prev available
            if (header.next_avail.getConst(pool)) |next_available_chunk| {
                assert(next_available_chunk.getHeaderConst().prev_avail.getConst(pool) == self);
            }

            if (header.prev_avail.getConst(pool)) |prev_available_chunk| {
                assert(prev_available_chunk.getHeaderConst().next_avail.getConst(pool) == self);
            }

            if (options.cl) |cl| {
                if (self == cl.avail.getConst(options.pool)) {
                    assert(header.prev_avail == .none);
                }
            }
        }
    }

    /// For internal use. Computes the capacity for a given chunk size.
    fn computeCapacity(chunk_size: u16) u16 {
        const buf_start = std.mem.alignForward(u16, @sizeOf(Chunk.Header), @alignOf(EntityIndex));
        const buf_end = chunk_size;
        const buf_len = buf_end - buf_start;
        return buf_len / @sizeOf(EntityIndex);
    }

    /// For internal use. Returns a pointer to the chunk header.
    pub inline fn getHeader(self: *Chunk) *Header {
        // This const cast is okay since it starts out mutable.
        return @constCast(self.getHeaderConst());
    }

    /// For internal use. See `getHeader`.
    pub inline fn getHeaderConst(self: *const Chunk) *const Header {
        return @alignCast(@ptrCast(self));
    }

    /// For internal use. Clears the chunk's entity data.
    pub fn clear(self: *Chunk, es: *Entities) void {
        // Get the header and chunk list
        const header = self.getHeader();
        const pool = &es.chunk_pool;
        const index = pool.indexOf(self);
        const cl: *ChunkList = es.chunk_lists.arches.getPtr(header.getArch()).?;

        // Validate this chunk
        self.checkAssertions(.{ .cl = cl, .allow_empty = true, .pool = pool });

        // Remove this chunk from the chunk list head/tail
        if (cl.head == index) cl.head = header.next;
        if (cl.tail == index) cl.tail = header.prev;
        if (cl.avail == index) cl.avail = header.next_avail;

        // Remove this chunk from the chunk list normal and available linked lists
        if (header.prev.get(pool)) |prev| prev.getHeader().next = header.next;
        if (header.next.get(pool)) |next| next.getHeader().prev = header.prev;
        if (header.prev_avail.get(pool)) |prev| prev.getHeader().next_avail = header.next_avail;
        if (header.next_avail.get(pool)) |next| next.getHeader().prev_avail = header.prev_avail;

        // Reset this chunk, and add it to the pool's free list
        header.* = undefined;
        header.next = es.chunk_pool.free;
        es.chunk_pool.free = index;

        // Validate the chunk list
        cl.checkAssertions(pool);
    }

    /// For internal use. Gets the index buffer. This includes uninitialized indices.
    fn getIndexBuf(self: *Chunk) []EntityIndex {
        // This const cast is okay since it starts out mutable.
        return @constCast(self.getIndexBufConst());
    }

    /// For internal use. See `getIndexBuf`.
    fn getIndexBufConst(self: *const Chunk) []const EntityIndex {
        const header = self.getHeaderConst();
        const ptr: [*]EntityIndex = @ptrFromInt(std.mem.alignForward(
            usize,
            @intFromPtr(self) + @sizeOf(Header),
            @alignOf(EntityIndex),
        ));
        return ptr[0..header.capacity];
    }

    /// For internal use. Swap removes an entity from the chunk, updating the location of the moved
    /// entity.
    pub fn swapRemove(self: *@This(), es: *Entities, index_in_chunk: IndexInChunk) void {
        const pool = &es.chunk_pool;
        const header = self.getHeader();
        const index = pool.indexOf(self);

        // Check if we were full before the remove
        const was_full = header.len >= header.capacity;

        // Pop the last entity
        const indices = self.getIndexBuf();
        header.len -= 1;
        const moved = indices[header.len];

        // Early out if we're popping the end of the list
        if (@intFromEnum(index_in_chunk) == header.len) {
            // If the chunk is now empty, return it to the chunk pool
            if (header.len == 0) self.clear(es);
            // Either way, early out
            return;
        }

        // Otherwise, overwrite the removed entity the popped entity, and then update the location
        // of the moved entity in the handle table
        indices[@intFromEnum(index_in_chunk)] = moved;
        const moved_loc = &es.handle_tab.values[moved];
        assert(moved_loc.chunk.? == self);
        moved_loc.index_in_chunk = index_in_chunk;

        // If this chunk was previously full, add it to this chunk list's available list
        if (was_full) {
            const cl: *ChunkList = es.chunk_lists.arches.getPtr(header.getArch()).?;
            if (cl.avail.get(pool)) |head| {
                // Don't disturb the front of the available list if there is one, this decreases
                // fragmentation by guaranteeing that we fill one chunk at a time.
                self.getHeader().next_avail = head.getHeaderConst().next_avail;
                if (self.getHeader().next_avail.get(pool)) |next_avail| {
                    next_avail.getHeader().prev_avail = index;
                }
                self.getHeader().prev_avail = cl.avail;
                head.getHeader().next_avail = index;
            } else {
                // If the available list is empty, set it to this chunk
                cl.avail = index;
            }

            cl.checkAssertions(pool);
            self.checkAssertions(.{ .cl = cl, .pool = pool });
        } else {
            const cl: *ChunkList = es.chunk_lists.arches.getPtr(header.getArch()).?;
            self.checkAssertions(.{ .cl = cl, .pool = pool });
        }
    }

    /// Returns an iterator over this chunk's entities.
    pub fn iterator(self: *const @This()) Iterator {
        return .{
            .chunk = self,
            .index_in_chunk = @enumFromInt(0),
        };
    }

    /// An iterator over a chunk's entities.
    pub const Iterator = struct {
        pub const empty: @This() = .{
            .chunk = @ptrCast(&Header{
                .arch_mask = 0,
                .len = 0,
                .capacity = 0,
            }),
            .index_in_chunk = @enumFromInt(0),
        };

        chunk: *const Chunk,
        index_in_chunk: IndexInChunk,

        pub fn next(self: *@This(), handle_tab: *const HandleTab) ?Entity {
            const header = self.chunk.getHeaderConst();
            if (@intFromEnum(self.index_in_chunk) >= header.len) return null;
            const indices = self.chunk.getIndexBufConst();
            const entity_index = indices[@intFromEnum(self.index_in_chunk)];
            self.index_in_chunk = @enumFromInt(@intFromEnum(self.index_in_chunk) + 1);
            return .{ .key = .{
                .index = entity_index,
                .generation = handle_tab.generations[entity_index],
            } };
        }
    };
};

/// A linked list of chunks.
pub const ChunkList = struct {
    /// The chunks in this chunk list, connected via the `next` and `prev` fields.
    head: ChunkPool.Index = .none,
    /// The final chunk in this chunk list.
    tail: ChunkPool.Index = .none,
    /// The chunks in this chunk list that have space available, connected via the `next_avail`
    /// and `prev_avail` fields.
    avail: ChunkPool.Index = .none,

    /// For internal use. Adds an entity to the chunk list.
    pub fn append(
        self: *@This(),
        pool: *ChunkPool,
        e: Entity,
        arch: CompFlag.Set,
    ) error{ZcsChunkPoolOverflow}!EntityLoc {
        // Ensure there's a chunk with space available
        if (self.avail == .none) {
            // Allocate a new chunk
            const new = try pool.reserve(arch);
            const new_index = pool.indexOf(new);

            // Point the available list to the new chunk
            self.avail = new_index;

            // Add the new chunk to the end of the chunk list
            if (self.tail.get(pool)) |tail| {
                new.getHeader().prev = self.tail;
                tail.getHeader().next = new_index;
                self.tail = new_index;
            } else {
                self.head = new_index;
                self.tail = new_index;
            }
        }

        // Get the next chunk with space available
        const chunk = self.avail.get(pool).?;
        const header = chunk.getHeader();
        assert(header.len < header.capacity);
        chunk.checkAssertions(.{ .cl = self, .allow_empty = true, .pool = pool });

        // Append the entity
        const index_in_chunk: IndexInChunk = @enumFromInt(header.len);
        const index_buf = chunk.getIndexBuf();
        index_buf[@intFromEnum(index_in_chunk)] = e.key.index;
        header.len += 1;

        // If the chunk is now full, remove it from the available list
        if (header.len == header.capacity) {
            assert(self.avail.getConst(pool) == chunk);
            self.avail = chunk.getHeaderConst().next_avail;
            header.next_avail = .none;
            if (self.avail.get(pool)) |avail| {
                const available_header = avail.getHeader();
                assert(available_header.prev_avail.get(pool) == chunk);
                available_header.prev_avail = .none;
            }
        }

        self.checkAssertions(pool);

        // Return the location we stored the entity
        return .{
            .chunk = chunk,
            .index_in_chunk = index_in_chunk,
        };
    }

    // Validates head and tail are self consistent.
    fn checkAssertions(self: *const ChunkList, pool: *const ChunkPool) void {
        if (self.head.getConst(pool)) |head| {
            const header = head.getHeaderConst();
            head.checkAssertions(.{ .cl = self, .pool = pool });
            self.tail.getConst(pool).?.checkAssertions(.{ .cl = self, .pool = pool });
            assert(@intFromBool(header.next != .none) ^
                @intFromBool(head == self.tail.getConst(pool)) != 0);
            assert(self.tail != .none);
        } else {
            assert(self.tail == .none);
            assert(self.avail == .none);
        }

        if (self.avail.getConst(pool)) |avail| {
            const header = avail.getHeaderConst();
            avail.checkAssertions(.{ .cl = self, .pool = pool });
            assert(header.prev_avail == .none);
        }
    }

    /// Returns an iterator over this chunk list's chunks.
    pub fn iterator(self: *const ChunkList, es: *const Entities) Iterator {
        const pool = &es.chunk_pool;
        self.checkAssertions(pool);
        return .{ .chunk = self.head.getConst(pool) };
    }

    /// An iterator over a chunk list's chunks.
    pub const Iterator = struct {
        pub const empty: @This() = .{ .chunk = null };

        chunk: ?*const Chunk,

        pub fn next(self: *@This(), es: *const Entities) ?*const Chunk {
            const chunk = self.chunk orelse return null;
            chunk.checkAssertions(.{ .cl = null, .pool = &es.chunk_pool });
            const header = chunk.getHeaderConst();
            self.chunk = header.next.getConst(&es.chunk_pool);
            return chunk;
        }
    };
};

/// The maximum chunk size.
pub const min_chunk_size: u16 = math.ceilPowerOfTwoAssert(usize, @sizeOf(Chunk.Header) + 1);

/// The minimum chunk size.
pub const max_chunk_size: u16 = std.heap.page_size_max;

/// For internal use. A pool of `Chunk`s.
pub const ChunkPool = struct {
    pub const Index = enum(u32) {
        /// The none index. The capacity is always less than this value, so there's no overlap.
        none = std.math.maxInt(u32),
        _,

        /// Gets a chunk from the chunk ID.
        pub fn get(self: Index, pool: *ChunkPool) ?*Chunk {
            // Const cast is okay since it started out mutable.
            return @constCast(self.getConst(pool));
        }

        /// See `get`.
        pub fn getConst(self: Index, pool: *const ChunkPool) ?*const Chunk {
            if (self == .none) return null;
            const result: *const Chunk = @ptrCast(&pool.buf[@intFromEnum(self) * pool.chunk_size]);
            assert(@intFromEnum(self) < pool.reserved);
            assert(pool.indexOf(result) == self);
            return result;
        }
    };

    /// Memory reserved for chunks
    buf: []align(max_chunk_size) u8,
    /// The number of unique chunks that have ever reserved
    reserved: u32,
    /// The size of a chunk
    chunk_size: u16,
    /// Freed chunks, connected by the `next` field. All other fields are undefined.
    free: Index = .none,

    /// Options for `init`.
    pub const Options = struct {
        /// The number of chunks to reserve. Supports the range `[0, std.math.maxInt(u32))`, max int
        /// is reserved for the none index.
        capacity: u32,
        /// The size of each chunk. When left `null`, defaults to `std.heap.pageSize()`. Must be a
        /// power of two in the range `[min_chunk_size, max_chunk_size]`.
        chunk_size: ?u16 = null,
    };

    /// For internal use. Allocates the chunk pool.
    pub fn init(gpa: Allocator, options: Options) Allocator.Error!ChunkPool {
        assert(options.capacity < std.math.maxInt(u32));
        const chunk_size: u16 = @intCast(options.chunk_size orelse std.heap.pageSize());
        // Check our sizes, the rest of the pool logic is allowed to depend on these invariants
        // holding true
        comptime assert(math.isPowerOfTwo(max_chunk_size));
        assert(math.isPowerOfTwo(chunk_size));
        assert(chunk_size >= min_chunk_size);
        assert(chunk_size <= max_chunk_size);

        const buf = try gpa.alignedAlloc(u8, max_chunk_size, chunk_size * options.capacity);
        errdefer comptime unreachable;

        return .{
            .buf = buf,
            .reserved = 0,
            .chunk_size = chunk_size,
        };
    }

    /// For internal use. Frees the chunk pool.
    pub fn deinit(self: *ChunkPool, gpa: Allocator) void {
        gpa.free(self.buf);
        self.* = undefined;
    }

    /// For internal use. Reserves a chunk from the chunk pool
    pub fn reserve(self: *ChunkPool, arch: CompFlag.Set) error{ZcsChunkPoolOverflow}!*Chunk {
        // Get a free chunk. Try the free list first, then fall back to bump allocation from the
        // preallocated buffer.
        const chunk = if (self.free.get(self)) |free| b: {
            // Pop the next chunk from the free list
            self.free = free.getHeader().next;
            break :b free;
        } else b: {
            // Pop the next chunk from the preallocated buffer
            if (self.reserved >= self.buf.len / self.chunk_size) return error.ZcsChunkPoolOverflow;
            const chunk: *Chunk = @ptrCast(&self.buf[self.reserved * self.chunk_size]);
            self.reserved = self.reserved + 1;
            break :b chunk;
        };
        errdefer comptime unreachable; // Already modified the free list!

        // Check the alignment
        assert(@intFromPtr(chunk) % self.chunk_size == 0);

        // Initialize the chunk and return it
        const header = chunk.getHeader();
        header.* = .{
            .arch_mask = arch.bits.mask,
            .len = 0,
            .capacity = Chunk.computeCapacity(self.chunk_size),
        };
        return chunk;
    }

    /// Gets the index of a chunk.
    pub fn indexOf(self: *const ChunkPool, chunk: *const Chunk) Index {
        assert(@intFromPtr(chunk) >= @intFromPtr(self.buf.ptr));
        assert(@intFromPtr(chunk) < @intFromPtr(self.buf.ptr) + self.buf.len);
        const offset = @intFromPtr(chunk) - @intFromPtr(self.buf.ptr);
        assert(offset < self.buf.len);
        return @enumFromInt(@divExact(offset, self.chunk_size));
    }
};

/// A map from archetypes to their chunk lists.
pub const ChunkLists = struct {
    capacity: u32,
    arches: std.AutoArrayHashMapUnmanaged(CompFlag.Set, ChunkList),

    /// For internal use. Initializes the archetype map.
    pub fn init(gpa: Allocator, capacity: u16) Allocator.Error!@This() {
        var arches: std.AutoArrayHashMapUnmanaged(CompFlag.Set, ChunkList) = .{};
        errdefer arches.deinit(gpa);
        // We reserve one extra to work around a slightly the slightly awkward get or put API.
        try arches.ensureTotalCapacity(gpa, @as(u32, capacity) + 1);
        arches.lockPointers();
        return .{
            .capacity = capacity,
            .arches = arches,
        };
    }

    /// For internal use. Frees the map.
    pub fn deinit(self: *@This(), gpa: Allocator) void {
        self.arches.unlockPointers();
        self.arches.deinit(gpa);
        self.* = undefined;
    }

    /// For internal use. Gets the chunk list for the given archetype, initializing it if it doesn't
    /// exist.
    pub fn getOrPut(self: *@This(), arch: CompFlag.Set) error{ZcsArchOverflow}!*ChunkList {
        // This is a bit awkward, but works around there not being a get or put variation
        // that fails when allocation is needed.
        //
        // In practice this code path will only be executed when we're about to fail in a likely
        // fatal way, so the mild amount of extra work isn't worth creating a whole new gop
        // variant over.
        //
        // Note that we reserve space for the requested capacity + 1 in `init` to make this
        // work.
        const gop = self.arches.getOrPutAssumeCapacity(arch);
        errdefer if (!gop.found_existing) {
            self.arches.unlockPointers();
            assert(self.arches.swapRemove(arch));
            self.arches.lockPointers();
        };
        if (!gop.found_existing) {
            if (self.arches.count() >= self.capacity) return error.ZcsArchOverflow;
            gop.value_ptr.* = .{};
        }
        return gop.value_ptr;
    }

    /// Returns an iterator over the chunk lists that have the given components.
    pub fn iterator(self: @This(), required_comps: CompFlag.Set) Iterator {
        return .{
            .required_comps = required_comps,
            .all = self.arches.iterator(),
        };
    }

    /// An iterator over chunk lists that have the given components.
    pub const Iterator = struct {
        required_comps: CompFlag.Set,
        all: @FieldType(ChunkLists, "arches").Iterator,

        pub const empty: @This() = .{
            .required_comps = .{},
            .all = b: {
                const map: std.AutoArrayHashMapUnmanaged(CompFlag.Set, ChunkList) = .{};
                break :b map.iterator();
            },
        };

        pub fn next(self: *@This()) ?*const ChunkList {
            while (self.all.next()) |item| {
                if (item.key_ptr.*.supersetOf(self.required_comps)) {
                    return item.value_ptr;
                }
            }
            return null;
        }
    };
};
