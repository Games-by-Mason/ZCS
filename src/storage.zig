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
        arch_mask: u64,
        next: ?*Chunk = null,
        prev: ?*Chunk = null,
        next_available: ?*Chunk = null,
        prev_available: ?*Chunk = null,
        len: u16,
        capacity: u16,

        /// Returns this chunk's archetype.
        pub fn getArch(self: *const @This()) CompFlag.Set {
            return .{ .bits = .{ .mask = self.arch_mask } };
        }
    };

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
    pub fn clear(self: *Chunk) void {
        const header = self.getHeader();
        header.len = 0;
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
        const header = self.getHeader();

        // Check if we were full before the remove
        const was_full = header.len >= header.capacity;

        // Pop the last entity
        const indices = self.getIndexBuf();
        header.len -= 1;
        const moved = indices[header.len];

        // Early out if we're popping the end of the list
        if (@intFromEnum(index_in_chunk) == header.len) {
            // If the chunk is now empty, return it to the chunk pool
            if (header.len == 0) {
                // Remove this chunk from the chunk list head/tail
                const cl: *ChunkList = es.chunk_lists.arches.getPtr(header.getArch()).?;
                if (cl.head == self) cl.head = header.next;
                if (cl.tail == self) cl.tail = header.prev;
                if (cl.available == self) cl.available = header.next_available;

                // Remove this chunk from the chunk list normal and available linked lists
                if (header.prev) |prev| prev.getHeader().next = header.next;
                if (header.next) |next| next.getHeader().prev = header.prev;
                if (header.prev_available) |prev| prev.getHeader().next_available = header.next_available;
                if (header.next_available) |next| next.getHeader().prev_available = header.prev_available;

                // Reset this chunk, and add it to the pool's free list
                header.* = undefined;
                header.next = es.chunk_pool.free;
                es.chunk_pool.free = self;
            }

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
            assert(header.next_available == null);
            assert(header.prev_available == null);
            const cl: *ChunkList = es.chunk_lists.arches.getPtr(header.getArch()).?;
            if (cl.available) |head| {
                // Don't disturb the front of the available list if there is one, this decreases
                // fragmentation by guaranteeing that we fill one chunk at a time.
                self.getHeader().next_available = head.getHeaderConst().next_available;
                self.getHeader().prev_available = head;
                head.getHeader().next_available = self;
            } else {
                // If the available list is empty, set it to this chunk
                cl.available = self;
            }
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
    head: ?*Chunk,
    /// The final chunk in this chunk list.
    tail: ?*Chunk,
    /// The chunks in this chunk list that have space available, connected via the `next_available`
    /// and `prev_available` fields.
    available: ?*Chunk,

    /// For internal use. Adds an entity to the chunk list.
    pub fn append(
        self: *@This(),
        p: *ChunkPool,
        e: Entity,
        arch: CompFlag.Set,
    ) error{ZcsChunkOverflow}!EntityLoc {
        // Ensure there's a chunk with space available
        if (self.available == null) {
            // Allocate a new chunk
            const new = try p.reserve(arch);

            // Point the available list to the new chunk
            self.available = new;

            // Add the new chunk to the end of the chunk list
            if (self.tail) |tail| {
                new.getHeader().prev = tail;
                tail.getHeader().next = new;
                self.tail = new;
            } else {
                self.head = new;
                self.tail = new;
            }
        }

        // Get a chunk with space available
        const chunk = self.available.?;

        // Add the entity to the chunk
        {
            // Get the header and index buf
            const header = chunk.getHeader();
            const index_buf = chunk.getIndexBuf();

            // Append the entity
            assert(header.len < header.capacity);
            const index_in_chunk: IndexInChunk = @enumFromInt(header.len);
            index_buf[@intFromEnum(index_in_chunk)] = e.key.index;
            header.len += 1;

            // If the chunk is now full, remove it from the available list
            if (header.len >= header.capacity) {
                assert(self.available == chunk);
                self.available = self.available.?.getHeaderConst().next_available;
                header.next_available = null;
                header.prev_available = null;
            }

            // Return the location we stored the entity
            return .{
                .chunk = chunk,
                .index_in_chunk = index_in_chunk,
            };
        }
    }

    /// Returns an iterator over this chunk list's chunks.
    pub fn iterator(self: *const ChunkList) Iterator {
        if (self.head) |head| assert(head.getHeaderConst().prev == null);
        return .{
            .chunk = self.head,
        };
    }

    /// An iterator over a chunk list's chunks.
    pub const Iterator = struct {
        pub const empty: @This() = .{ .chunk = null };

        chunk: ?*const Chunk,

        pub fn next(self: *@This()) ?*const Chunk {
            const chunk = self.chunk orelse return null;
            const header = chunk.getHeaderConst();
            if (header.next) |n| assert(n.getHeaderConst().prev == chunk);
            self.chunk = header.next;
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
    /// Memory reserved for chunks
    buf: []align(max_chunk_size) u8,
    /// The number of chunks reserved
    reserved: u32,
    /// The size of a chunk
    chunk_size: u16,
    /// Freed chunks, connected by the `next` field. All other fields are undefined.
    free: ?*Chunk = null,

    /// Options for `init`.
    pub const Options = struct {
        /// The number of chunks to reserve.
        capacity: u32,
        /// The size of each chunk. When left `null`, defaults to `std.heap.pageSize()`. Must be a
        /// power of two in the range `[min_chunk_size, max_chunk_size]`.
        chunk_size: ?u16 = null,
    };

    /// For internal use. Allocates the chunk pool.
    pub fn init(gpa: Allocator, options: Options) Allocator.Error!ChunkPool {
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
    pub fn reserve(self: *ChunkPool, arch: CompFlag.Set) error{ZcsChunkOverflow}!*Chunk {
        // Get a free chunk. Try the free list first, then fall back to bump allocation from the
        // preallocated buffer.
        const chunk = if (self.free) |free| b: {
            // Pop the next chunk from the free list
            self.free = free.getHeader().next;
            break :b free;
        } else b: {
            // Pop the next chunk from the preallocated buffer
            if (self.reserved >= self.buf.len / self.chunk_size) return error.ZcsChunkOverflow;
            const chunk: *Chunk = @ptrCast(&self.buf[self.reserved * self.chunk_size]);
            break :b chunk;
        };
        errdefer comptime unreachable; // Already modified the free list!

        // Check the alignment
        assert(@intFromPtr(chunk) % self.chunk_size == 0);

        // Increment the number of reserved chunks
        self.reserved = self.reserved + 1;

        // Initialize the chunk and return it
        const header = chunk.getHeader();
        header.* = .{
            .arch_mask = arch.bits.mask,
            .len = 0,
            .capacity = Chunk.computeCapacity(self.chunk_size),
        };
        return chunk;
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
    pub fn getOrPut(
        self: *@This(),
        p: *ChunkPool,
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
            self.arches.unlockPointers();
            assert(self.arches.swapRemove(arch));
            self.arches.lockPointers();
        };
        if (!gop.found_existing) {
            if (self.arches.count() >= self.capacity) return error.ZcsArchOverflow;
            const chunk = try p.reserve(arch);
            errdefer comptime unreachable;
            gop.value_ptr.* = .{
                .head = chunk,
                .tail = chunk,
                .available = chunk,
            };
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
