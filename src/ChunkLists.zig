//! A map from archetypes to their chunk lists.

// XXX: remove unused imports
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
const Chunk = zcs.Chunk;
const ChunkList = zcs.ChunkList;
const ChunkPool = zcs.ChunkPool;

const SlotMap = slot_map.SlotMap;

const Allocator = std.mem.Allocator;

pub const ChunkLists = @This();

// XXX: move onto chunk list?
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
