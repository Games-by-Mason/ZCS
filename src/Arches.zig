//! A map from archetypes to their chunk lists.

const std = @import("std");
const zcs = @import("root.zig");
const tracy = @import("tracy");

const Zone = tracy.Zone;

const assert = std.debug.assert;

const Entities = zcs.Entities;
const CompFlag = zcs.CompFlag;
const PointerLock = zcs.PointerLock;
const ChunkList = zcs.ChunkList;
const ChunkPool = zcs.ChunkPool;

const Allocator = std.mem.Allocator;

pub const Arches = @This();

capacity: u32,
map: std.ArrayHashMapUnmanaged(
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

/// Initializes the chunk lists.
pub fn init(gpa: Allocator, capacity: u32) Allocator.Error!@This() {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();

    var map: @FieldType(@This(), "map") = .{};
    errdefer map.deinit(gpa);
    // We reserve one extra to work around a slightly the slightly awkward get or put API.
    try map.ensureTotalCapacity(gpa, @as(u32, capacity) + 1);
    map.lockPointers();
    return .{
        .capacity = capacity,
        .map = map,
    };
}

/// Frees the chunk lists.
pub fn deinit(self: *@This(), gpa: Allocator) void {
    self.map.unlockPointers();
    self.map.deinit(gpa);
    self.* = undefined;
}

/// Resets arches back to its initial state.
pub fn clear(self: *@This()) void {
    self.map.unlockPointers();
    self.map.clearRetainingCapacity();
    self.map.lockPointers();
}

/// Gets the chunk list for the given archetype, initializing it if it doesn't exist.
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
    const gop = self.map.getOrPutAssumeCapacity(arch);
    errdefer if (!gop.found_existing) {
        @branchHint(.cold);
        // We have to unlock pointers to do this, but we're just doing a swap remove so the
        // indices that we already store into the array won't change.
        self.map.unlockPointers();
        assert(self.map.swapRemove(arch));
        self.map.lockPointers();
    };
    if (!gop.found_existing) {
        @branchHint(.unlikely);
        if (self.map.count() > self.capacity) return error.ZcsArchOverflow;
        gop.value_ptr.* = try .init(pool, arch);
    }
    return gop.value_ptr;
}

/// Gets the index of a chunk list.
pub fn indexOf(lists: *const @This(), self: *const ChunkList) ChunkList.Index {
    const vals = lists.map.values();

    assert(@intFromPtr(self) >= @intFromPtr(vals.ptr));
    assert(@intFromPtr(self) < @intFromPtr(vals.ptr) + vals.len * @sizeOf(ChunkList));

    const offset = @intFromPtr(self) - @intFromPtr(vals.ptr);
    const index = offset / @sizeOf(ChunkList);
    return @enumFromInt(index);
}

/// Returns an iterator over the chunk lists that have the given components.
///
/// Invalidating pointers while iterating results in safety checked illegal behavior.
pub fn iterator(self: @This(), es: *const Entities, required_comps: CompFlag.Set) Iterator {
    return .{
        .required_comps = required_comps,
        .all = self.map.iterator(),
        .pointer_lock = es.pointer_generation.lock(),
    };
}

/// An iterator over chunk lists that have the given components.
pub const Iterator = struct {
    required_comps: CompFlag.Set,
    all: @FieldType(Arches, "map").Iterator,
    pointer_lock: PointerLock,

    /// Returns an empty iterator.
    pub fn empty(es: *const Entities) @This() {
        return .{
            .required_comps = .{},
            .all = b: {
                const map: @FieldType(Arches, "map") = .{};
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
