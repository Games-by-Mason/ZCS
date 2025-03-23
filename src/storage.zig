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
        return chunk.constHeader().arch;
    }
};

/// An index into a chunk.
const IndexInChunkTag = u16;
pub const IndexInChunk = enum(IndexInChunkTag) { _ };

/// For internal use. A chunk of entities that all have the same archetype.
pub const Chunk = opaque {
    const EntityKey = HandleTab.Key;
    const EntityIndex = @FieldType(EntityKey, "index");
    const EntityIndices = std.BoundedArray(EntityIndex, 512);

    /// For internal use. The header information for a chunk.
    pub const Header = struct {
        arch: CompFlag.Set,
        indices: EntityIndices,
        next: ?*Chunk = null,
    };

    /// For internal use. Returns a pointer to the chunk header.
    pub inline fn header(self: *Chunk) *Header {
        return @alignCast(@ptrCast(self));
    }

    /// For internal use. Returns a const pointer to the chunk header.
    pub inline fn constHeader(self: *const Chunk) *const Header {
        return @alignCast(@ptrCast(self));
    }

    /// For internal use. Swap removes an entity from the chunk, updating the location of the moved
    /// entity.
    pub fn swapRemove(self: *@This(), ht: *HandleTab, index_in_chunk: IndexInChunk) void {
        // Pop the last entity
        const moved = self.header().indices.pop().?;

        // If we're removing the last entity, we're done!
        if (@intFromEnum(index_in_chunk) == self.constHeader().indices.len) return;

        // Otherwise, overwrite the removed entity the popped entity, and then update the location
        // of the moved entity in the handle table
        self.header().indices.set(@intFromEnum(index_in_chunk), moved);
        const moved_loc = &ht.values[moved];
        assert(moved_loc.chunk.? == self);
        moved_loc.index_in_chunk = index_in_chunk;
    }

    /// Returns an iterator over this chunk's entities.
    pub fn iterator(self: *const @This()) Iterator {
        return .{
            .chunk = self,
            .index = 0,
        };
    }

    /// An iterator over a chunk's entities.
    pub const Iterator = struct {
        pub const empty: @This() = .{
            .chunk = @ptrCast(&Header{
                .arch = .{},
                .indices = .{},
            }),
            .index = 0,
        };

        chunk: *const Chunk,
        index: u16,

        pub fn next(self: *@This(), handle_tab: *const HandleTab) ?Entity {
            comptime assert(math.maxInt(@TypeOf(self.index)) >=
                @typeInfo(@FieldType(EntityIndices, "buffer")).array.len);
            if (self.index >= self.chunk.constHeader().indices.len) return null;
            const entity_index = self.chunk.constHeader().indices.get(self.index);
            self.index += 1;
            return .{ .key = .{
                .index = entity_index,
                .generation = handle_tab.generations[entity_index],
            } };
        }
    };
};

/// A linked list of chunks.
pub const ChunkList = struct {
    head: *Chunk,

    /// For internal use. Adds an entity to the chunk list.
    pub fn append(
        self: *@This(),
        p: *ChunkPool,
        e: Entity,
        arch: CompFlag.Set,
    ) error{ZcsChunkOverflow}!EntityLoc {
        var curr = self.head;
        while (true) {
            const index_in_chunk = curr.constHeader().indices.len;
            if (index_in_chunk < @typeInfo(@TypeOf(curr.constHeader().indices.buffer)).array.len) {
                // Add the entity to the chunk
                curr.header().indices.appendAssumeCapacity(e.key.index);

                // Comptime assert that casting the index to the enum index is safe. We make sure
                // there's one extra index so that in safe builds the fact that we use max int as an
                // invalid index is fine.
                const Indices = @FieldType(Chunk.Header, "indices");
                const IndicesBuf = @FieldType(Indices, "buffer");
                const chunk_cap = @typeInfo(IndicesBuf).array.len;
                const TagType = @typeInfo(IndexInChunk).@"enum".tag_type;
                comptime assert(chunk_cap < math.maxInt(TagType));

                // Return the location we stored the entity
                return .{
                    .chunk = curr,
                    .index_in_chunk = @enumFromInt(index_in_chunk),
                };
            }

            curr = if (curr.constHeader().next) |next| next else b: {
                const next = try p.reserve(arch);
                curr.header().next = next;
                break :b next;
            };
        }
    }

    /// Returns an iterator over this chunk list's chunks.
    pub fn iterator(self: *const ChunkList) Iterator {
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
            self.chunk = chunk.constHeader().next;
            return chunk;
        }
    };
};

/// The maximum chunk size.
pub const min_chunk_size = math.ceilPowerOfTwo(usize, @sizeOf(Chunk.Header) + 1) catch unreachable;

/// The minimum chunk size.
pub const max_chunk_size = std.heap.page_size_max;

/// For internal use. A pool of `Chunk`s.
pub const ChunkPool = struct {
    buf: []align(max_chunk_size) u8,
    reserved: u32,
    chunk_size: u32,

    /// Options for `init`.
    pub const Options = struct {
        /// The number of chunks to reserve.
        capacity: u32,
        /// The size of each chunk. When left `null`, defaults to `std.heap.pageSize()`. Must be a
        /// power of two in the range `[min_chunk_size, max_chunk_size]`.
        chunk_size: ?u32 = null,
    };

    /// For internal use. Allocates the chunk pool.
    pub fn init(gpa: Allocator, options: Options) Allocator.Error!ChunkPool {
        const chunk_size: u32 = @intCast(options.chunk_size orelse std.heap.pageSize());
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
        // Return an error if all chunks are reserved
        if (self.reserved >= self.buf.len / self.chunk_size) return error.ZcsChunkOverflow;

        // Get the next chunk, and assert that it has the correct alignment
        const chunk: *Chunk = @ptrCast(&self.buf[self.reserved * self.chunk_size]);
        assert(@intFromPtr(chunk) % self.chunk_size == 0);

        // Increment the number of reserved chunks
        self.reserved = self.reserved + 1;

        // Initialize the chunk and return it
        chunk.header().* = .{
            .arch = arch,
            .indices = .{},
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
            gop.value_ptr.* = .{ .head = try p.reserve(arch) };
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
