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
    pub fn getArch(self: @This(), lists: *const ChunkLists) CompFlag.Set {
        const chunk = self.chunk orelse return .{};
        const header = chunk.getHeaderConst();
        return header.getArch(lists);
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
        /// The number of entities that can be stored in this chunk.
        capacity: u16,

        /// Returns this chunk's archetype.
        pub fn getArch(self: *const @This(), lists: *const ChunkLists) CompFlag.Set {
            return self.list.getArch(lists);
        }
    };

    /// Checks for self consistency.
    fn checkAssertions(
        self: *const @This(),
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

        const header = self.getHeaderConst();
        const list = header.list.getConst(&es.chunk_lists);
        const pool = &es.chunk_pool;

        // Validate next/prev
        if (header.next.getConst(pool)) |next_chunk| {
            assert(next_chunk.getHeaderConst().prev.getConst(pool) == self);
        }

        if (header.prev.getConst(pool)) |prev_chunk| {
            assert(prev_chunk.getHeaderConst().next.getConst(pool) == self);
        }

        if (self == list.head.getConst(pool)) assert(header.prev == .none);
        if (self == list.tail.getConst(pool)) assert(header.next == .none);

        if (header.len >= header.capacity) {
            // Validate full chunks
            assert(header.len == header.capacity);
            assert(header.next_avail == .none);
            assert(header.prev_avail == .none);
        } else {
            // Available chunks shouldn't be empty, since empty chunks are returned to the chunk
            // pool. `allow_empty` is set to true when checking a chunk that's about to be returned
            // to the chunk pool.
            assert(mode == .allow_empty or header.len > 0);

            // Validate next/prev available
            if (header.next_avail.getConst(pool)) |next_available_chunk| {
                assert(next_available_chunk.getHeaderConst().prev_avail.getConst(pool) == self);
            }

            if (header.prev_avail.getConst(pool)) |prev_available_chunk| {
                assert(prev_available_chunk.getHeaderConst().next_avail.getConst(pool) == self);
            }

            if (self == list.avail.getConst(pool)) {
                assert(header.prev_avail == .none);
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
        const list = header.list.get(&es.chunk_lists);

        // Validate this chunk
        self.checkAssertions(es, .allow_empty);

        // Remove this chunk from the chunk list head/tail
        if (list.head == index) list.head = header.next;
        if (list.tail == index) list.tail = header.prev;
        if (list.avail == index) list.avail = header.next_avail;

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
        list.checkAssertions(es);
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
            const list = header.list.get(&es.chunk_lists);
            if (list.avail.get(pool)) |head| {
                // Don't disturb the front of the available list if there is one, this decreases
                // fragmentation by guaranteeing that we fill one chunk at a time.
                self.getHeader().next_avail = head.getHeaderConst().next_avail;
                if (self.getHeader().next_avail.get(pool)) |next_avail| {
                    next_avail.getHeader().prev_avail = index;
                }
                self.getHeader().prev_avail = list.avail;
                head.getHeader().next_avail = index;
            } else {
                // If the available list is empty, set it to this chunk
                list.avail = index;
            }

            list.checkAssertions(es);
        }

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
    pub fn init(arch: CompFlag.Set) ChunkList {
        const sorted = sortCompsByAlignment(arch);

        _ = sorted;

        const index_buffer_offset = std.mem.alignForward(
            u16,
            @sizeOf(Chunk.Header),
            @alignOf(@FieldType(HandleTab.Key, "index")),
        );

        return .{
            .head = .none,
            .tail = .none,
            .avail = .none,
            .comp_buffer_offsets = .initUndefined(),
            .index_buffer_offset = index_buffer_offset,
        };
    }

    /// For internal use. Adds an entity to the chunk list.
    pub fn append(
        self: *@This(),
        es: *Entities,
        e: Entity,
    ) error{ ZcsChunkOverflow, ZcsChunkPoolOverflow }!EntityLoc {
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
        chunk.checkAssertions(es, .allow_empty);

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

        if (self.head.getConst(pool)) |head| {
            const header = head.getHeaderConst();
            head.checkAssertions(es, .default);
            self.tail.getConst(pool).?.checkAssertions(es, .default);
            assert(@intFromBool(header.next != .none) ^
                @intFromBool(head == self.tail.getConst(pool)) != 0);
            assert(self.tail != .none);
        } else {
            assert(self.tail == .none);
            assert(self.avail == .none);
        }

        if (self.avail.getConst(pool)) |avail| {
            const header = avail.getHeaderConst();
            avail.checkAssertions(es, .default);
            assert(header.prev_avail == .none);
        }
    }

    /// Returns an iterator over this chunk list's chunks.
    pub fn iterator(self: *const ChunkList, es: *const Entities) Iterator {
        self.checkAssertions(es);
        return .{ .chunk = self.head.getConst(&es.chunk_pool) };
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
            const header = chunk.getHeaderConst();
            self.chunk = header.next.getConst(&es.chunk_pool);
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

        /// Gets a chunk from the chunk ID.
        pub fn get(self: Index, pool: *ChunkPool) ?*Chunk {
            // Const cast is okay since it started out mutable.
            return @constCast(self.getConst(pool));
        }

        /// See `get`.
        pub fn getConst(self: Index, pool: *const ChunkPool) ?*const Chunk {
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
    ) error{ ZcsChunkPoolOverflow, ZcsChunkOverflow }!*Chunk {
        // Calculate the chunk's capacity
        const capacity = try Chunk.computeCapacity(self.size_align);

        // Get a free chunk. Try the free list first, then fall back to bump allocation from the
        // preallocated buffer.
        const chunk = if (self.free.get(self)) |free| b: {
            // Pop the next chunk from the free list
            self.free = free.getHeader().next;
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
        const header = chunk.getHeader();
        header.* = .{
            .list = list,
            .len = 0,
            .capacity = capacity,
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
        pub fn get(self: @This(), lists: *ChunkLists) *ChunkList {
            // This const cast is okay since it starts out mutable.
            return @constCast(self.getConst(lists));
        }

        /// See `get`.
        pub fn getConst(self: @This(), lists: *const ChunkLists) *const ChunkList {
            return &lists.arches.values()[@intFromEnum(self)];
        }

        /// Gets the archetype for a chunk list.
        pub fn getArch(self: Index, lists: *const ChunkLists) CompFlag.Set {
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
            gop.value_ptr.* = .init(arch);
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
