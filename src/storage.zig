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
pub const HandleTable = SlotMap(HandleTableValue, .{});

/// For internal use. Points to an entity's storage. The indirection allows entities to be relocated
/// without invalidating their handles.
const HandleTableValue = struct {
    arch_list: ?*ArchChunks,

    /// For internal use. Returns the archetype for this entity, or the empty archetype if it hasn't
    /// been committed.
    pub fn getArch(self: @This()) CompFlag.Set {
        const arch_list = self.arch_list orelse return .{};
        return arch_list.arch;
    }
};

/// For internal use. A chunk of entities that all have the same archetype.
pub const Chunk = struct {
    const EntityKey = HandleTable.Key;
    const EntityIndex = @FieldType(EntityKey, "index");
    const EntityIndices = std.BoundedArray(EntityIndex, 1024);

    indices: EntityIndices,
    next: ?*Chunk = null,
};

/// A linked list of chunks that all have the same archetype.
pub const ArchChunks = struct {
    arch: CompFlag.Set,
    head: *Chunk,

    /// For internal use. Adds an entity to the archetype list.
    pub fn add(self: *@This(), p: *ChunkPool, e: Entity) error{ZcsChunkOverflow}!void {
        var curr = self.head;
        while (true) {
            if (curr.indices.len < @typeInfo(@TypeOf(curr.indices.buffer)).array.len) {
                curr.indices.appendAssumeCapacity(e.key.index);
                return;
            }

            curr = if (curr.next) |next| next else b: {
                const next = try p.reserve();
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

    /// For internal use. Reserves a chunk from the chunk pool.
    pub fn reserve(self: *ChunkPool) error{ZcsChunkOverflow}!*Chunk {
        if (self.all.items.len >= self.all.capacity) {
            return error.ZcsChunkOverflow;
        }
        const chunk = self.all.addOneAssumeCapacity();
        chunk.* = .{
            .indices = .{},
        };
        return chunk;
    }
};

/// A map from archetypes to their chunk lists.
pub const Arches = struct {
    capacity: u32,
    map: std.AutoArrayHashMapUnmanaged(CompFlag.Set, ArchChunks),

    /// For internal use. Initializes the archetype map.
    pub fn init(gpa: Allocator, capacity: u16) Allocator.Error!@This() {
        var map: std.AutoArrayHashMapUnmanaged(CompFlag.Set, ArchChunks) = .{};
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
    ) error{ ZcsChunkOverflow, ZcsArchOverflow }!*ArchChunks {
        const gop = self.map.getOrPutAssumeCapacity(arch);
        if (!gop.found_existing) {
            // This is a bit awkward, but works around there not being a get or put variation
            // that fails when allocation is needed.
            //
            // In practice this code path will only be executed when we're about to fail in a likely
            // fatal way, so the mild amount of extra work isn't worth creating a whole new gop
            // variant over.
            //
            // Note that we reserve space for the requested capacity + 1 in `init` to make this
            // work.
            if (self.map.count() >= self.capacity) {
                self.map.unlockPointers();
                assert(self.map.swapRemove(arch));
                self.map.lockPointers();
                return error.ZcsArchOverflow;
            }
            gop.value_ptr.* = .{
                .arch = arch,
                .head = try p.reserve(),
            };
        }
        return gop.value_ptr;
    }
};
