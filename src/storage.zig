//! For internal use. Handles entity storage.

const std = @import("std");
const zcs = @import("root.zig");
const slot_map = @import("slot_map");

const typeId = zcs.typeId;

const assert = std.debug.assert;
const math = std.math;

const Alignment = std.mem.Alignment;

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
    pub fn arch(self: @This(), lists: *const ChunkLists) CompFlag.Set {
        const chunk = self.chunk orelse return .{};
        const header = chunk.header();
        return header.arch(lists);
    }
};

/// An index into a chunk.
pub const IndexInChunk = enum(u16) { _ };

/// For internal use. A chunk of entities that all have the same archetype.
pub const Chunk = opaque {
    const EntityIndex = @FieldType(HandleTab.Key, "index");

    /// For internal use. The header information for a chunk.
    pub const Header = struct {
        /// The index of the chunk list.
        list: ChunkLists.Index,
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

        /// Returns this chunk's archetype.
        pub fn arch(self: *const @This(), lists: *const ChunkLists) CompFlag.Set {
            return self.list.arch(lists);
        }
    };

    /// Checks for self consistency.
    fn checkAssertions(
        self: *const Chunk,
        es: *const Entities,
        mode: enum {
            /// By default, chunks may not be empty since if they were they'd have been returned to
            /// the chunk pool.
            default,
            /// However if we're checking a just allocated chunk, or one we're about to clear, we
            /// can skip this check.
            allow_empty,
        },
    ) void {
        if (!std.debug.runtime_safety) return;

        const list = self.header().list.get(&es.chunk_lists);
        const pool = &es.chunk_pool;

        // Validate next/prev
        if (self.header().next.get(pool)) |next_chunk| {
            assert(next_chunk.header().prev.get(pool) == self);
        }

        if (self.header().prev.get(pool)) |prev_chunk| {
            assert(prev_chunk.header().next.get(pool) == self);
        }

        if (self == list.head.get(pool)) assert(self.header().prev == .none);
        if (self == list.tail.get(pool)) assert(self.header().next == .none);

        if (self.header().len >= list.chunk_capacity) {
            // Validate full chunks
            assert(self.header().len == list.chunk_capacity);
            assert(self.header().next_avail == .none);
            assert(self.header().prev_avail == .none);
        } else {
            // Available chunks shouldn't be empty, since empty chunks are returned to the chunk
            // pool. `allow_empty` is set to true when checking a chunk that's about to be returned
            // to the chunk pool.
            assert(mode == .allow_empty or self.header().len > 0);

            // Validate next/prev available
            if (self.header().next_avail.get(pool)) |next_available_chunk| {
                assert(next_available_chunk.header().prev_avail.get(pool) == self);
            }

            if (self.header().prev_avail.get(pool)) |prev_available_chunk| {
                assert(prev_available_chunk.header().next_avail.get(pool) == self);
            }

            if (self == list.avail.get(pool)) {
                assert(self.header().prev_avail == .none);
            }
        }
    }

    /// For internal use. Computes the capacity for a given chunk size.
    fn computeCapacity(size_align: Alignment) error{ZcsChunkOverflow}!u16 {
        const buf_start = std.mem.alignForward(
            u16,
            @sizeOf(Chunk.Header),
            @alignOf(EntityIndex),
        );
        const buf_end: u16 = @intCast(size_align.toByteUnits());
        const buf_len: u16 = std.math.sub(u16, buf_end, buf_start) catch |err| switch (err) {
            error.Overflow => return error.ZcsChunkOverflow,
        };
        const result: u16 = buf_len / @sizeOf(EntityIndex);
        if (result == 0) return error.ZcsChunkOverflow;
        return result;
    }

    /// For internal use. Returns a pointer to the chunk header.
    pub inline fn headerMut(self: *Chunk) *Header {
        // This const cast is okay since it starts out mutable.
        return @constCast(self.header());
    }

    /// For internal use. See `header`.
    pub inline fn header(self: *const Chunk) *const Header {
        return @alignCast(@ptrCast(self));
    }

    /// For internal use. Clears the chunk's entity data.
    pub fn clear(self: *Chunk, es: *Entities) void {
        // Get the header and chunk list
        const pool = &es.chunk_pool;
        const index = pool.indexOf(self);
        const list = self.header().list.getMut(&es.chunk_lists);

        // Validate this chunk
        self.checkAssertions(es, .allow_empty);

        // Remove this chunk from the chunk list head/tail
        if (list.head == index) list.head = self.header().next;
        if (list.tail == index) list.tail = self.header().prev;
        if (list.avail == index) list.avail = self.header().next_avail;

        // Remove this chunk from the chunk list normal and available linked lists
        if (self.header().prev.getMut(pool)) |prev| prev.headerMut().next = self.header().next;
        if (self.header().next.getMut(pool)) |next| next.headerMut().prev = self.header().prev;
        if (self.header().prev_avail.getMut(pool)) |prev| prev.headerMut().next_avail = self.header().next_avail;
        if (self.header().next_avail.getMut(pool)) |next| next.headerMut().prev_avail = self.header().prev_avail;

        // Reset this chunk, and add it to the pool's free list
        self.headerMut().* = undefined;
        self.headerMut().next = es.chunk_pool.free;
        es.chunk_pool.free = index;

        // Validate the chunk list
        list.checkAssertions(es);
    }

    /// For internal use. Gets the index buffer. This includes uninitialized indices.
    fn entityIndicesMut(self: *Chunk, es: *const Entities) []EntityIndex {
        // This const cast is okay since it starts out mutable.
        return @constCast(self.entityIndices(es));
    }

    /// For internal use. See `entityIndices`.
    pub fn entityIndices(self: *const Chunk, es: *const Entities) []const EntityIndex {
        const list = self.header().list.get(&es.chunk_lists);
        const ptr: [*]EntityIndex = @ptrFromInt(@intFromPtr(self) + list.index_buffer_offset);
        return ptr[0..self.header().len];
    }

    /// For internal use. Swap removes an entity from the chunk, updating the location of the moved
    /// entity.
    pub fn swapRemove(self: *@This(), es: *Entities, index_in_chunk: IndexInChunk) void {
        const pool = &es.chunk_pool;
        const index = pool.indexOf(self);
        const list = self.header().list.getMut(&es.chunk_lists);

        // Check if we were full before the remove
        const was_full = self.header().len >= list.chunk_capacity;

        // Pop the last entity
        const indices = self.entityIndicesMut(es);
        self.headerMut().len -= 1;
        const moved = indices[self.header().len];

        // Early out if we're popping the end of the list
        if (@intFromEnum(index_in_chunk) == self.header().len) {
            // If the chunk is now empty, return it to the chunk pool
            if (self.header().len == 0) self.clear(es);
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
            if (list.avail.getMut(pool)) |head| {
                // Don't disturb the front of the available list if there is one, this decreases
                // fragmentation by guaranteeing that we fill one chunk at a time.
                self.headerMut().next_avail = head.header().next_avail;
                if (self.header().next_avail.getMut(pool)) |next_avail| {
                    next_avail.headerMut().prev_avail = index;
                }
                self.headerMut().prev_avail = list.avail;
                head.headerMut().next_avail = index;
            } else {
                // If the available list is empty, set it to this chunk
                list.avail = index;
            }
        }

        list.checkAssertions(es);
        self.checkAssertions(es, .default);
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
                .list = @enumFromInt(
                    std.math.maxInt(@typeInfo(@FieldType(Header, "list")).@"enum".tag_type),
                ),
                .len = 0,
            }),
            .index_in_chunk = @enumFromInt(0),
        };

        chunk: *const Chunk,
        index_in_chunk: IndexInChunk,

        pub fn next(self: *@This(), es: *const Entities) ?Entity {
            if (@intFromEnum(self.index_in_chunk) >= self.chunk.header().len) return null;
            const indices = self.chunk.entityIndices(es);
            const entity_index = indices[@intFromEnum(self.index_in_chunk)];
            self.index_in_chunk = @enumFromInt(@intFromEnum(self.index_in_chunk) + 1);
            return .{ .key = .{
                .index = entity_index,
                .generation = es.handle_tab.generations[entity_index],
            } };
        }
    };
};

/// A linked list of chunks.
pub const ChunkList = struct {
    /// The chunks in this chunk list, connected via the `next` and `prev` fields.
    head: ChunkPool.Index,
    /// The final chunk in this chunk list.
    tail: ChunkPool.Index,
    /// The chunks in this chunk list that have space available, connected via the `next_avail`
    /// and `prev_avail` fields.
    avail: ChunkPool.Index,
    /// The offset to the entity index buffer.
    index_buffer_offset: u16,
    /// A map from component flags to the byte offset of their arrays. Components that aren't
    /// present or are zero sized have undefined offsets.
    comp_buffer_offsets: std.enums.EnumArray(CompFlag, u16),
    /// The number of entities that can be stored in a single chunk from this list.
    chunk_capacity: u16,

    fn alignmentGte(_: void, lhs: CompFlag, rhs: CompFlag) bool {
        const lhs_alignment = lhs.getId().alignment;
        const rhs_alignment = rhs.getId().alignment;
        return lhs_alignment >= rhs_alignment;
    }

    /// Returns a list of the components in this set sorted from greatest to least alignment. This
    /// is an optimization to reduce padding, but also necessary to get consistent cutoffs for how
    /// much data fits in a chunk regardless of registration order.
    inline fn sortCompsByAlignment(set: CompFlag.Set) std.BoundedArray(CompFlag, CompFlag.max) {
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
            var prev: usize = std.math.maxInt(usize);
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

    /// For internal use. Initializes a chunk list.
    pub fn init(pool: *const ChunkPool, arch: CompFlag.Set) error{ZcsChunkOverflow}!ChunkList {
        const sorted = sortCompsByAlignment(arch);

        const index_buffer_offset = std.mem.alignForward(
            u16,
            @sizeOf(Chunk.Header),
            @alignOf(@FieldType(HandleTab.Key, "index")),
        );

        const chunk_capacity = try Chunk.computeCapacity(pool.size_align);

        return .{
            .head = .none,
            .tail = .none,
            .avail = .none,
            .comp_buffer_offsets = .initUndefined(),
            .index_buffer_offset = index_buffer_offset,
            .chunk_capacity = chunk_capacity,
        };
    }

    /// For internal use. Adds an entity to the chunk list.
    pub fn append(
        self: *@This(),
        es: *Entities,
        e: Entity,
    ) error{ZcsChunkPoolOverflow}!EntityLoc {
        const pool = &es.chunk_pool;
        const lists = &es.chunk_lists;

        // Ensure there's a chunk with space available
        if (self.avail == .none) {
            // Allocate a new chunk
            const new = try pool.reserve(self.indexOf(lists));
            const new_index = pool.indexOf(new);

            // Point the available list to the new chunk
            self.avail = new_index;

            // Add the new chunk to the end of the chunk list
            if (self.tail.getMut(pool)) |tail| {
                new.headerMut().prev = self.tail;
                tail.headerMut().next = new_index;
                self.tail = new_index;
            } else {
                self.head = new_index;
                self.tail = new_index;
            }
        }

        // Get the next chunk with space available
        const chunk = self.avail.getMut(pool).?;
        const header = chunk.headerMut();
        assert(header.len < self.chunk_capacity);
        chunk.checkAssertions(es, .allow_empty);

        // Append the entity
        const index_in_chunk: IndexInChunk = @enumFromInt(header.len);
        header.len += 1;
        const index_buf = chunk.entityIndicesMut(es);
        index_buf[@intFromEnum(index_in_chunk)] = e.key.index;

        // If the chunk is now full, remove it from the available list
        if (header.len == self.chunk_capacity) {
            assert(self.avail.get(pool) == chunk);
            self.avail = chunk.header().next_avail;
            header.next_avail = .none;
            if (self.avail.getMut(pool)) |avail| {
                const available_header = avail.headerMut();
                assert(available_header.prev_avail.get(pool) == chunk);
                available_header.prev_avail = .none;
            }
        }

        self.checkAssertions(es);

        // Return the location we stored the entity
        return .{
            .chunk = chunk,
            .index_in_chunk = index_in_chunk,
        };
    }

    // Validates head and tail are self consistent.
    fn checkAssertions(self: *const ChunkList, es: *const Entities) void {
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
    pub fn iterator(self: *const ChunkList, es: *const Entities) Iterator {
        self.checkAssertions(es);
        return .{ .chunk = self.head.get(&es.chunk_pool) };
    }

    /// Gets the index of a chunk.
    pub fn indexOf(self: *const ChunkList, lists: *const ChunkLists) ChunkLists.Index {
        const vals = lists.arches.values();

        assert(@intFromPtr(self) >= @intFromPtr(vals.ptr));
        assert(@intFromPtr(self) < @intFromPtr(vals.ptr) + vals.len * @sizeOf(ChunkList));

        const offset = @intFromPtr(self) - @intFromPtr(vals.ptr);
        const index = offset / @sizeOf(ChunkList);
        return @enumFromInt(index);
    }

    /// An iterator over a chunk list's chunks.
    pub const Iterator = struct {
        pub const empty: @This() = .{ .chunk = null };

        chunk: ?*const Chunk,

        pub fn next(self: *@This(), es: *const Entities) ?*const Chunk {
            const chunk = self.chunk orelse return null;
            chunk.checkAssertions(es, .default);
            const header = chunk.header();
            self.chunk = header.next.get(&es.chunk_pool);
            return chunk;
        }
    };
};

/// For internal use. A pool of `Chunk`s.
pub const ChunkPool = struct {
    pub const Index = enum(u32) {
        /// The none index. The capacity is always less than this value, so there's no overlap.
        none = std.math.maxInt(u32),
        _,

        /// See `get`.
        pub fn getMut(self: Index, pool: *ChunkPool) ?*Chunk {
            // Const cast is okay since it started out mutable.
            return @constCast(self.get(pool));
        }

        /// Gets a chunk from the chunk ID.
        pub fn get(self: Index, pool: *const ChunkPool) ?*const Chunk {
            if (self == .none) return null;
            const byte_idx = @shlExact(
                @intFromEnum(self),
                @intCast(@intFromEnum(pool.size_align)),
            );
            const result: *const Chunk = @ptrCast(&pool.buf[byte_idx]);
            assert(@intFromEnum(self) < pool.reserved);
            assert(pool.indexOf(result) == self);
            return result;
        }
    };

    /// Memory reserved for chunks
    buf: []u8,
    /// The number of unique chunks that have ever reserved
    reserved: u32,
    /// The chunk size and alignment are both set to this value.
    size_align: Alignment,
    /// Freed chunks, connected by the `next` field. All other fields are undefined.
    free: Index = .none,

    /// Options for `init`.
    pub const Options = struct {
        /// The number of chunks to reserve. Supports the range `[0, std.math.maxInt(u32))`, max int
        /// is reserved for the none index.
        capacity: u32,
        /// The size of each chunk.
        chunk_size: u16,
    };

    /// For internal use. Allocates the chunk pool.
    pub fn init(gpa: Allocator, options: Options) Allocator.Error!ChunkPool {
        // The max size is reserved for invalid indices.
        assert(options.capacity < std.math.maxInt(u32));

        // Allocate the chunk data, aligned to the size of a chunk
        const alignment = Alignment.fromByteUnits(options.chunk_size);
        const len = @as(usize, options.chunk_size) * @as(usize, options.capacity);
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

    /// For internal use. Frees the chunk pool.
    pub fn deinit(self: *ChunkPool, gpa: Allocator) void {
        gpa.rawFree(self.buf, self.size_align, @returnAddress());
        self.* = undefined;
    }

    /// For internal use. Reserves a chunk from the chunk pool
    pub fn reserve(
        self: *ChunkPool,
        list: ChunkLists.Index,
    ) error{ZcsChunkPoolOverflow}!*Chunk {
        // Get a free chunk. Try the free list first, then fall back to bump allocation from the
        // preallocated buffer.
        const chunk = if (self.free.getMut(self)) |free| b: {
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
        const header = chunk.headerMut();
        header.* = .{
            .list = list,
            .len = 0,
        };
        return chunk;
    }

    /// Gets the index of a chunk.
    pub fn indexOf(self: *const ChunkPool, chunk: *const Chunk) Index {
        assert(@intFromPtr(chunk) >= @intFromPtr(self.buf.ptr));
        assert(@intFromPtr(chunk) < @intFromPtr(self.buf.ptr) + self.buf.len);
        const offset = @intFromPtr(chunk) - @intFromPtr(self.buf.ptr);
        assert(offset < self.buf.len);
        return @enumFromInt(@shrExact(offset, @intFromEnum(self.size_align)));
    }
};

/// A map from archetypes to their chunk lists.
pub const ChunkLists = struct {
    /// The index of a chunk list.
    pub const Index = enum(u32) {
        /// Gets a chunk list from a chunk list ID.
        pub fn get(self: @This(), lists: *const ChunkLists) *const ChunkList {
            return &lists.arches.values()[@intFromEnum(self)];
        }

        /// See `get`.
        pub fn getMut(self: @This(), lists: *ChunkLists) *ChunkList {
            // This const cast is okay since it starts out mutable.
            return @constCast(self.get(lists));
        }

        /// Gets the archetype for a chunk list.
        pub fn arch(self: Index, lists: *const ChunkLists) CompFlag.Set {
            return lists.arches.keys()[@intFromEnum(self)];
        }

        _,
    };

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
    pub fn getOrPut(
        self: *@This(),
        pool: *const ChunkPool,
        arch: CompFlag.Set,
    ) error{ ZcsChunkOverflow, ZcsArchOverflow }!*ChunkList {
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
            // We have to unlock pointers to do this, but we're just doing a swap remove so the
            // indices that we already store into the array won't change.
            self.arches.unlockPointers();
            assert(self.arches.swapRemove(arch));
            self.arches.lockPointers();
        };
        if (!gop.found_existing) {
            if (self.arches.count() >= self.capacity) return error.ZcsArchOverflow;
            gop.value_ptr.* = try .init(pool, arch);
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
