const std = @import("std");
const zcs = @import("root.zig");

const assert = std.debug.assert;

const typeId = zcs.typeId;

const Entity = zcs.Entity;
const Entities = zcs.Entities;
const PointerLock = zcs.PointerLock;
const TypeId = zcs.TypeId;
const CompFlag = zcs.CompFlag;
const ChunkList = zcs.ChunkList;
const Arches = zcs.Arches;
const ChunkPool = zcs.ChunkPool;

/// A chunk of entity data where each entity has the same archetype. This type is mostly used
/// internally, you should prefer the higher level API in most cases.
pub const Chunk = opaque {
    /// A chunk's index in its `ChunkPool`.
    pub const Index = enum(u32) {
        /// The none index. The capacity is always less than this value, so there's no overlap.
        none = std.math.maxInt(u32),
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

    /// Meta information for a chunk.
    pub const Header = struct {
        /// The offsets to each component, or 0 for each that is missing.
        ///
        /// This is also stored on the chunk list, but duplicating this state to the chunk
        /// measurably improves benchmarks, likely due to reducing cache misses.
        comp_buf_offsets: std.enums.EnumArray(CompFlag, u32),
        /// The chunk list this chunk is part of, if any.
        list: ChunkList.Index,
        /// The next chunk, if any.
        next: Index = .none,
        /// The previous chunk, if any.
        prev: Index = .none,
        /// The next chunk with available space, if any.
        next_avail: Index = .none,
        /// The previous chunk with available space, if any.
        prev_avail: Index = .none,
        /// The number of entities in this chunk.
        len: u32,

        /// Returns this chunk's archetype. When checking for individual components, prefer checking
        /// `comp_buf_offsets`. This value larger but nearer in memory.
        pub fn arch(self: *const @This(), lists: *const Arches) CompFlag.Set {
            return self.list.arch(lists);
        }
    };

    /// An offset from the start of a chunk to a component buffer.
    pub const CompBufOffset = enum(u32) {
        none = 0,
        _,

        pub inline fn unwrap(self: @This()) ?u32 {
            const result = @intFromEnum(self);
            if (result == 0) return null;
            return result;
        }
    };

    /// Checks for self consistency.
    pub fn checkAssertions(
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
        if (!std.debug.runtime_safety) return;

        const list = self.header().list.get(&es.arches);
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

    /// Returns a pointer to the chunk header.
    pub inline fn header(self: *Chunk) *Header {
        return @alignCast(@ptrCast(self));
    }

    /// Clears the chunk's entity data.
    pub fn clear(self: *Chunk, es: *Entities) void {
        // Get the header and chunk list
        const pool = &es.chunk_pool;
        const index = pool.indexOf(self);
        const list = self.header().list.get(&es.arches);

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

    /// Returns an entity slice view of type `View` into this chunk. See `zcs.view`.
    pub fn view(self: *@This(), es: *const Entities, View: type) ?View {
        const list = self.header().list.get(&es.arches);

        const view_arch = zcs.view.comps(View, .{ .size = .slice }) orelse return null;
        const chunk_arch = self.header().arch(&es.arches);
        if (!chunk_arch.supersetOf(view_arch)) return null;

        var result: View = undefined;
        inline for (@typeInfo(View).@"struct".fields) |field| {
            const As = zcs.view.UnwrapField(field.type, .{ .size = .slice });
            if (As == Entity.Index) {
                const unsized: [*]As = @ptrFromInt(@intFromPtr(self) + list.index_buf_offset);
                const sized = unsized[0..self.header().len];
                @field(result, field.name) = sized;
            } else {
                // https://github.com/Games-by-Mason/ZCS/issues/24
                const offset = if (typeId(As).comp_flag) |flag|
                    self.header().comp_buf_offsets.values[@intFromEnum(flag)]
                else
                    0;
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

    /// Similar to `view`, but only gets a single component slice and doesn't require comptime
    /// types.
    pub fn compsFromId(self: *Chunk, id: TypeId) ?[]u8 {
        const flag = id.comp_flag orelse return null;
        // https://github.com/Games-by-Mason/ZCS/issues/24
        const offset = self.header().comp_buf_offsets.values[@intFromEnum(flag)];
        if (offset == 0) return null;
        const ptr: [*]u8 = @ptrFromInt(@intFromPtr(self) + offset);
        return ptr[0 .. self.header().len * id.size];
    }

    /// Swap removes an entity from the chunk, updating the location of the moved entity. This is
    /// typically used internally, for external uses you're likely looking for
    /// `Entity.destroy` or `Entity.destroyImmediate`.
    pub fn swapRemove(
        self: *@This(),
        es: *Entities,
        index_in_chunk: Entity.Location.IndexInChunk,
    ) void {
        const pool = &es.chunk_pool;
        const index = pool.indexOf(self);
        const list = self.header().list.get(&es.arches);
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
                var it = self.header().arch(&es.arches).iterator();
                while (it.next()) |flag| {
                    const id = flag.getId();
                    const comp_buffer = self.compsFromId(id).?;
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
            var move = self.header().arch(&es.arches).iterator();
            while (move.next()) |flag| {
                const id = flag.getId();

                const comp_buffer = self.compsFromId(id).?;
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
