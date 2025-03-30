//! For internal use. Handles entity storage.

const std = @import("std");
const zcs = @import("root.zig");
const slot_map = @import("slot_map");
const tracy = @import("tracy");

const Zone = tracy.Zone;

const typeId = zcs.typeId;

const assert = std.debug.assert;
const math = std.math;
const runtime_safety = std.debug.runtime_safety;

const alignForward = std.mem.alignForward;

const Alignment = std.mem.Alignment;

const Entity = zcs.Entity;
const Entities = zcs.Entities;
const CompFlag = zcs.CompFlag;
const TypeId = zcs.TypeId;
const PointerLock = zcs.PointerLock;

const SlotMap = slot_map.SlotMap;

const Allocator = std.mem.Allocator;

/// For internal use. A handle table that associates persistent entity keys with values that point
/// to their storage.
pub const HandleTab = SlotMap(Entity.Location, .{});

/// For internal use. A chunk of entities that all have the same archetype.
pub const Chunk = opaque {
    /// For internal use. The header information for a chunk.
    pub const Header = struct {
        /// The offsets to each component, or 0 for each that is missing.
        ///
        /// This is also stored on the chunk list, but duplicating this state to the chunk
        /// measurably improves benchmarks, likely due to reducing cache misses.
        comp_buf_offsets: std.enums.EnumArray(CompFlag, u32),
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
        len: u32,

        /// Returns this chunk's archetype.
        pub fn arch(self: *const @This(), lists: *const ChunkLists) CompFlag.Set {
            return self.list.arch(lists);
        }
    };

    /// Checks for self consistency.
    fn checkAssertions(
        self: *Chunk,
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
        if (!runtime_safety) return;

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

    /// For internal use. Returns a pointer to the chunk header.
    pub inline fn header(self: *Chunk) *Header {
        return @alignCast(@ptrCast(self));
    }

    /// For internal use. Clears the chunk's entity data.
    pub fn clear(self: *Chunk, es: *Entities) void {
        // Get the header and chunk list
        const pool = &es.chunk_pool;
        const index = pool.indexOf(self);
        const list = self.header().list.get(&es.chunk_lists);

        // Validate this chunk
        self.checkAssertions(es, .allow_empty);

        // Remove this chunk from the chunk list head/tail
        if (list.head == index) list.head = self.header().next;
        if (list.tail == index) list.tail = self.header().prev;
        if (list.avail == index) list.avail = self.header().next_avail;

        // Remove this chunk from the chunk list normal and available linked lists
        if (self.header().prev.get(pool)) |prev| prev.header().next = self.header().next;
        if (self.header().next.get(pool)) |next| next.header().prev = self.header().prev;
        if (self.header().prev_avail.get(pool)) |prev| prev.header().next_avail = self.header().next_avail;
        if (self.header().next_avail.get(pool)) |next| next.header().prev_avail = self.header().prev_avail;

        // Reset this chunk, and add it to the pool's free list
        self.header().* = undefined;
        self.header().next = es.chunk_pool.free;
        es.chunk_pool.free = index;

        // Validate the chunk list
        list.checkAssertions(es);
    }

    /// Similar to `view`, but only gets a single component slice and doesn't require comptime
    /// types.
    pub fn compsFromId(self: *Chunk, es: *const Entities, id: TypeId) ?[]u8 {
        const flag = id.comp_flag orelse return null;
        const list = self.header().list.get(&es.chunk_lists);
        // https://github.com/Games-by-Mason/ZCS/issues/24
        const offset = list.comp_buf_offsets.values[@intFromEnum(flag)];
        if (offset == 0) return null;
        const ptr: [*]u8 = @ptrFromInt(@intFromPtr(self) + offset);
        return ptr[0 .. self.header().len * id.size];
    }

    /// Returns an entity slice view of type `View` into this chunk. See `zcs.view`.
    pub fn view(self: *@This(), es: *const Entities, View: type) ?View {
        const list = self.header().list.get(&es.chunk_lists);

        const view_arch = zcs.view.comps(View, .slice) orelse return null;
        const chunk_arch = self.header().arch(&es.chunk_lists);
        if (!chunk_arch.supersetOf(view_arch)) return null;

        var result: View = undefined;
        inline for (@typeInfo(View).@"struct".fields) |field| {
            const As = zcs.view.UnwrapField(field.type, .slice);
            if (As == Entity.Index) {
                const unsized: [*]As = @ptrFromInt(@intFromPtr(self) + list.index_buf_offset);
                const sized = unsized[0..self.header().len];
                @field(result, field.name) = sized;
            } else {
                const flag = typeId(As).comp_flag.?; // Arch checked above
                // https://github.com/Games-by-Mason/ZCS/issues/24
                const offset = list.comp_buf_offsets.values[@intFromEnum(flag)];
                if (@typeInfo(field.type) == .optional and offset == 0) {
                    @field(result, field.name) = null;
                } else {
                    assert(offset != 0); // Arch checked above
                    const unsized: [*]As = @ptrFromInt(@intFromPtr(self) + offset);
                    const sized = unsized[0..self.header().len];
                    @field(result, field.name) = sized;
                }
            }
        }
        return result;
    }

    /// For internal use. Swap removes an entity from the chunk, updating the location of the moved
    /// entity.
    pub fn swapRemove(
        self: *@This(),
        es: *Entities,
        index_in_chunk: Entity.Location.IndexInChunk,
    ) void {
        const pool = &es.chunk_pool;
        const index = pool.indexOf(self);
        const list = self.header().list.get(&es.chunk_lists);
        const was_full = self.header().len >= list.chunk_capacity;

        // Get the last entity
        const indices = @constCast(self.view(es, struct {
            indices: []const Entity.Index,
        }).?.indices);
        const new_len = self.header().len - 1;
        const moved = indices[new_len];

        // Early out if we're popping the end of the list
        if (@intFromEnum(index_in_chunk) == new_len) {
            // Clear the previous entity data
            if (std.debug.runtime_safety) {
                indices[@intFromEnum(index_in_chunk)] = undefined;
                var it = self.header().arch(&es.chunk_lists).iterator();
                while (it.next()) |flag| {
                    const id = flag.getId();
                    const comp_buffer = self.compsFromId(es, id).?;
                    const comp_offset = new_len * id.size;
                    const comp = comp_buffer[comp_offset..][0..id.size];
                    @memset(comp, undefined);
                }
            }

            // Update the chunk's length, possibly returning it to the chunk pool
            if (new_len == 0) {
                self.clear(es);
            } else {
                self.header().len = new_len;
            }

            // Early out
            return;
        }

        // Overwrite the removed entity index with the popped entity index
        indices[@intFromEnum(index_in_chunk)] = moved;

        // Move the moved entity's components
        {
            var move = self.header().arch(&es.chunk_lists).iterator();
            while (move.next()) |flag| {
                const id = flag.getId();

                const comp_buffer = self.compsFromId(es, id).?;
                const new_comp_offset = @intFromEnum(index_in_chunk) * id.size;
                const new_comp = comp_buffer[new_comp_offset..][0..id.size];

                const prev_comp_offset = new_len * id.size;
                const prev_comp = comp_buffer[prev_comp_offset..][0..id.size];

                @memcpy(new_comp, prev_comp);
                @memset(prev_comp, undefined);
            }
        }

        // Pop the last entity
        self.header().len = new_len;

        // Update the location of the moved entity in the handle table
        const moved_loc = &es.handle_tab.slots[@intFromEnum(moved)].value;
        assert(moved_loc.chunk.get(&es.chunk_pool) == self);
        moved_loc.index_in_chunk = index_in_chunk;

        // If this chunk was previously full, add it to this chunk list's available list
        if (was_full) {
            if (list.avail.get(pool)) |head| {
                // Don't disturb the front of the available list if there is one, this decreases
                // fragmentation by guaranteeing that we fill one chunk at a time.
                self.header().next_avail = head.header().next_avail;
                if (self.header().next_avail.get(pool)) |next_avail| {
                    next_avail.header().prev_avail = index;
                }
                self.header().prev_avail = list.avail;
                head.header().next_avail = index;
            } else {
                // If the available list is empty, set it to this chunk
                list.avail = index;
            }
        }

        list.checkAssertions(es);
        self.checkAssertions(es, .default);
    }

    /// Returns an iterator over this chunk's entities.
    ///
    /// Invalidating pointers while iterating results in safety checked illegal behavior.
    pub fn iterator(self: *@This(), es: *const Entities) Iterator {
        return .{
            .chunk = self,
            .index_in_chunk = @enumFromInt(0),
            .pointer_lock = es.pointer_generation.lock(),
        };
    }

    /// An iterator over a chunk's entities.
    pub const Iterator = struct {
        chunk: *Chunk,
        index_in_chunk: Entity.Location.IndexInChunk,
        pointer_lock: PointerLock,

        pub fn next(self: *@This(), es: *const Entities) ?Entity {
            self.pointer_lock.check(es.pointer_generation);
            if (@intFromEnum(self.index_in_chunk) >= self.chunk.header().len) {
                @branchHint(.unlikely);
                return null;
            }
            const indices = self.chunk.view(es, struct { indices: []const Entity.Index }).?.indices;
            const entity_index = indices[@intFromEnum(self.index_in_chunk)];
            self.index_in_chunk = @enumFromInt(@intFromEnum(self.index_in_chunk) + 1);
            return entity_index.toEntity(es);
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
    index_buf_offset: u32,
    /// A map from component flags to the byte offset of their arrays. Components that aren't
    /// present or are zero sized have undefined offsets. It's generally faster to read this from
    /// the chunk instead of the chunk list to avoid the extra cache miss.
    comp_buf_offsets: std.enums.EnumArray(CompFlag, u32),
    /// The number of entities that can be stored in a single chunk from this list.
    chunk_capacity: u32,

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

    /// For internal use. Initializes a chunk list.
    pub fn init(pool: *const ChunkPool, arch: CompFlag.Set) error{ZcsChunkOverflow}!ChunkList {
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
            .comp_buf_offsets = comp_buf_offsets,
            .index_buf_offset = index_buf_offset,
            .chunk_capacity = chunk_capacity,
        };
    }

    /// For internal use. Adds an entity to the chunk list.
    pub fn append(
        self: *@This(),
        es: *Entities,
        e: Entity,
    ) error{ZcsChunkPoolOverflow}!Entity.Location {
        const pool = &es.chunk_pool;
        const lists = &es.chunk_lists;

        // Ensure there's a chunk with space available
        if (self.avail == .none) {
            // Allocate a new chunk
            const new = try pool.reserve(es, self.indexOf(lists));
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

    // Validates head and tail are self consistent.
    fn checkAssertions(self: *const ChunkList, es: *const Entities) void {
        if (!runtime_safety) return;

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
    pub fn iterator(self: *const ChunkList, es: *const Entities) Iterator {
        self.checkAssertions(es);
        return .{
            .chunk = self.head.get(&es.chunk_pool),
            .pointer_lock = es.pointer_generation.lock(),
        };
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
        /// Returns an empty iterator.
        pub fn empty(es: *const Entities) @This() {
            return .{
                .chunk = null,
                .pointer_lock = es.pointer_generation.lock(),
            };
        }

        chunk: ?*Chunk,
        pointer_lock: PointerLock,

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

        pub fn peek(self: @This(), es: *const Entities) ?*Chunk {
            self.pointer_lock.check(es.pointer_generation);
            return self.chunk;
        }
    };
};

/// For internal use. A pool of `Chunk`s.
pub const ChunkPool = struct {
    pub const Index = enum(u32) {
        /// The none index. The capacity is always less than this value, so there's no overlap.
        none = math.maxInt(u32),
        _,

        /// Gets a chunk from the chunk ID.
        pub fn get(self: Index, pool: *const ChunkPool) ?*Chunk {
            if (self == .none) return null;
            const byte_idx = @shlExact(
                @intFromEnum(self),
                @intCast(@intFromEnum(pool.size_align)),
            );
            const result: *Chunk = @ptrCast(&pool.buf[byte_idx]);
            assert(@intFromEnum(self) < pool.reserved);
            assert(pool.indexOf(result) == self);
            return result;
        }
    };

    /// Memory reserved for chunks
    buf: []u8,
    /// The number of unique chunks that have ever reserved
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
    free: Index = .none,

    /// Options for `init`.
    pub const Options = struct {
        /// The number of chunks to reserve. Supports the range `[0, math.maxInt(u32))`, max int
        /// is reserved for the none index.
        capacity: u16,
        /// The size of each chunk.
        chunk_size: u32,
    };

    /// For internal use. Allocates the chunk pool.
    pub fn init(gpa: Allocator, options: Options) Allocator.Error!ChunkPool {
        const zone = Zone.begin(.{ .src = @src() });
        defer zone.end();

        // The max size is reserved for invalid indices.
        assert(options.capacity < math.maxInt(u32));
        assert(options.chunk_size >= zcs.TypeInfo.max_align);

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
        es: *const Entities,
        list: ChunkLists.Index,
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
            .comp_buf_offsets = list.get(&es.chunk_lists).comp_buf_offsets,
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
        pub fn get(self: @This(), lists: *const ChunkLists) *ChunkList {
            return &lists.arches.values()[@intFromEnum(self)];
        }

        /// Gets the archetype for a chunk list.
        pub fn arch(self: Index, lists: *const ChunkLists) CompFlag.Set {
            return lists.arches.keys()[@intFromEnum(self)];
        }

        _,
    };

    capacity: u32,
    arches: std.ArrayHashMapUnmanaged(
        CompFlag.Set,
        ChunkList,
        struct {
            pub fn eql(_: @This(), lhs: CompFlag.Set, rhs: CompFlag.Set, _: usize) bool {
                return lhs.eql(rhs);
            }
            pub fn hash(_: @This(), key: CompFlag.Set) u32 {
                return @truncate(std.hash.int(key.bits.mask));
            }
        },
        false,
    ),

    /// For internal use. Initializes the archetype map.
    pub fn init(gpa: Allocator, capacity: u32) Allocator.Error!@This() {
        const zone = Zone.begin(.{ .src = @src() });
        defer zone.end();

        var arches: @FieldType(@This(), "arches") = .{};
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
            @branchHint(.cold);
            // We have to unlock pointers to do this, but we're just doing a swap remove so the
            // indices that we already store into the array won't change.
            self.arches.unlockPointers();
            assert(self.arches.swapRemove(arch));
            self.arches.lockPointers();
        };
        if (!gop.found_existing) {
            @branchHint(.unlikely);
            if (self.arches.count() > self.capacity) return error.ZcsArchOverflow;
            gop.value_ptr.* = try .init(pool, arch);
        }
        return gop.value_ptr;
    }

    /// Returns an iterator over the chunk lists that have the given components.
    ///
    /// Invalidating pointers while iterating results in safety checked illegal behavior.
    pub fn iterator(self: @This(), es: *const Entities, required_comps: CompFlag.Set) Iterator {
        return .{
            .required_comps = required_comps,
            .all = self.arches.iterator(),
            .pointer_lock = es.pointer_generation.lock(),
        };
    }

    /// An iterator over chunk lists that have the given components.
    pub const Iterator = struct {
        required_comps: CompFlag.Set,
        all: @FieldType(ChunkLists, "arches").Iterator,
        pointer_lock: PointerLock,

        /// Returns an empty iterator.
        pub fn empty(es: *const Entities) @This() {
            return .{
                .required_comps = .{},
                .all = b: {
                    const map: @FieldType(ChunkLists, "arches") = .{};
                    break :b map.iterator();
                },
                .pointer_lock = es.pointer_generation.lock(),
            };
        }

        pub fn next(self: *@This(), es: *const Entities) ?*const ChunkList {
            self.pointer_lock.check(es.pointer_generation);
            while (self.all.next()) |item| {
                if (item.key_ptr.*.supersetOf(self.required_comps)) {
                    return item.value_ptr;
                }
            }
            return null;
        }
    };
};
