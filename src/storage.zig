//! For internal use. Handles entity storage.

const std = @import("std");
const zcs = @import("root.zig");
const slot_map = @import("slot_map");

const assert = std.debug.assert;

const Entity = zcs.Entity;
const Entities = zcs.Entities;
const CompFlag = zcs.CompFlag;

const SlotMap = slot_map.SlotMap;

const Allocator = std.mem.Allocator;

/// For internal use. A handle table that associates persistent entity keys with values that point
/// to their storage.
pub const HandleTable = SlotMap(EntityLoc, .{});

/// For internal use. Points to an entity's storage, the indirection allows entities to be relocated
/// without invalidating their handles.
pub const EntityLoc = struct {
    /// A handle that's been reserved but not committed.
    pub const reserved: @This() = .{
        .chunk = null,
        .index_in_chunk = if (std.debug.runtime_safety)
            @enumFromInt(std.math.maxInt(@typeInfo(IndexInChunk).@"enum".tag_type))
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
        return chunk.arch;
    }
};

/// An index into a chunk.
const IndexInChunkTag = u16;
pub const IndexInChunk = enum(IndexInChunkTag) { _ };

/// For internal use. A chunk of entities that all have the same archetype.
pub const Chunk = struct {
    const EntityKey = HandleTable.Key;
    const EntityIndex = @FieldType(EntityKey, "index");
    const EntityIndices = std.BoundedArray(EntityIndex, 1024);

    arch: CompFlag.Set,
    indices: EntityIndices,
    next: ?*Chunk = null,
};

/// A linked list of chunks.
pub const ChunkList = struct {
    head: *Chunk,

    /// For internal use. Adds an entity to the archetype list.
    pub fn append(
        self: *@This(),
        p: *ChunkPool,
        e: Entity,
        arch: CompFlag.Set,
    ) error{ZcsChunkOverflow}!EntityLoc {
        var curr = self.head;
        while (true) {
            const index_in_chunk = curr.indices.len;
            if (index_in_chunk < @typeInfo(@TypeOf(curr.indices.buffer)).array.len) {
                // Add the entity to the chunk
                curr.indices.appendAssumeCapacity(e.key.index);

                // Comptime assert that casting the index to the enum index is safe. We make sure
                // there's one extra index so that in safe builds the fact that we use max int as an
                // invalid index is fine.
                const Indices = @FieldType(Chunk, "indices");
                const IndicesBuf = @FieldType(Indices, "buffer");
                const chunk_cap = @typeInfo(IndicesBuf).array.len;
                const TagType = @typeInfo(IndexInChunk).@"enum".tag_type;
                comptime assert(chunk_cap < std.math.maxInt(TagType));

                // Return the location we stored the entity
                return .{
                    .chunk = curr,
                    .index_in_chunk = @enumFromInt(index_in_chunk),
                };
            }

            curr = if (curr.next) |next| next else b: {
                const next = try p.reserve(arch);
                curr.next = next;
                break :b next;
            };
        }
    }
};

/// For internal use. A pool of `Chunk`s.
pub const ChunkPool = struct {
    all: std.ArrayListUnmanaged(Chunk),

    /// For internal use. Allocates the chunk pool.
    pub fn init(gpa: Allocator, capacity: usize) Allocator.Error!ChunkPool {
        return .{
            .all = try .initCapacity(gpa, capacity),
        };
    }

    /// For internal use. Frees the chunk pool.
    pub fn deinit(self: *ChunkPool, gpa: Allocator) void {
        self.all.deinit(gpa);
        self.* = undefined;
    }

    /// For internal use. Reserves a chunk from the chunk pool
    pub fn reserve(self: *ChunkPool, arch: CompFlag.Set) error{ZcsChunkOverflow}!*Chunk {
        if (self.all.items.len >= self.all.capacity) {
            return error.ZcsChunkOverflow;
        }
        const chunk = self.all.addOneAssumeCapacity();
        chunk.* = .{
            .arch = arch,
            .indices = .{},
        };
        return chunk;
    }
};

/// A map from archetypes to their chunk lists.
pub const ChunkLists = struct {
    capacity: u32,
    map: std.AutoArrayHashMapUnmanaged(CompFlag.Set, ChunkList),

    /// For internal use. Initializes the archetype map.
    pub fn init(gpa: Allocator, capacity: u16) Allocator.Error!@This() {
        var map: std.AutoArrayHashMapUnmanaged(CompFlag.Set, ChunkList) = .{};
        errdefer map.deinit(gpa);
        // We reserve one extra to work around a slightly the slightly awkward get or put API.
        try map.ensureTotalCapacity(gpa, @as(u32, capacity) + 1);
        map.lockPointers();
        return .{
            .capacity = capacity,
            .map = map,
        };
    }

    /// For internal use. Frees the map.
    pub fn deinit(self: *@This(), gpa: Allocator) void {
        self.map.unlockPointers();
        self.map.deinit(gpa);
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
        const gop = self.map.getOrPutAssumeCapacity(arch);
        errdefer if (!gop.found_existing) {
            self.map.unlockPointers();
            assert(self.map.swapRemove(arch));
            self.map.lockPointers();
        };
        if (!gop.found_existing) {
            if (self.map.count() >= self.capacity) return error.ZcsArchOverflow;
            gop.value_ptr.* = .{ .head = try p.reserve(arch) };
        }
        return gop.value_ptr;
    }
};
