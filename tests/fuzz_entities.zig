//! Fuzz tests for `Entities`.

const std = @import("std");
const zcs = @import("zcs");

const gpa = std.testing.allocator;

const Fuzzer = @import("EntitiesFuzzer.zig");
const Any = zcs.Any;
const CompFlag = zcs.CompFlag;
const Entity = zcs.Entity;
const Entities = zcs.Entities;
const CmdBuf = zcs.CmdBuf;

const comps = @import("comps.zig");
const RigidBody = comps.RigidBody;
const Model = comps.Model;
const Tag = comps.Tag;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const cmds_capacity = 1000;
const change_cap = 16;

test "fuzz cmdbuf" {
    try std.testing.fuzz(fuzzCmdBuf, .{ .corpus = &.{} });
}

test "fuzz cmdbuf saturated" {
    try std.testing.fuzz(fuzzCmdBufSaturated, .{ .corpus = &.{} });
}

test "rand cmdbuf" {
    var xoshiro_256: std.Random.Xoshiro256 = .init(0);
    const rand = xoshiro_256.random();
    const input: []u8 = try gpa.alloc(u8, 8192);
    defer gpa.free(input);
    rand.bytes(input);
    try fuzzCmdBuf(input);
}

test "rand cmdbuf saturated" {
    var xoshiro_256: std.Random.Xoshiro256 = .init(0);
    const rand = xoshiro_256.random();
    const input: []u8 = try gpa.alloc(u8, 8192);
    defer gpa.free(input);
    rand.bytes(input);
    try fuzzCmdBufSaturated(input);
}

fn fuzzCmdBuf(input: []const u8) !void {
    try run(input, false);
}

fn fuzzCmdBufSaturated(input: []const u8) !void {
    try run(input, true);
}

fn run(input: []const u8, saturated: bool) !void {
    defer CompFlag.unregisterAll();

    var fz: Fuzzer = try .init(input);
    defer fz.deinit();

    var cmds: CmdBuf = try .init(gpa, &fz.es, .{
        .cmds = cmds_capacity,
        .avg_any_bytes = @sizeOf(RigidBody),
    });
    defer cmds.deinit(gpa, &fz.es);

    const saturated_count = if (saturated) fz.parser.nextLessThan(u16, 10000) else 0;

    for (0..saturated_count) |_| {
        const e = Entity.reserveImmediate(&fz.es);
        try expect(e.destroyImmediate(&fz.es));
        const Key = @FieldType(Entities, "slots").Key;
        const Generation = @FieldType(Key, "generation");
        const invalid = @intFromEnum(Generation.invalid);
        fz.es.slots.generations[e.key.index] = @enumFromInt(invalid - 1);
        const e2 = Entity.reserveImmediate(&fz.es);
        try expect(e2.destroyImmediate(&fz.es));
        try expect(!e.exists(&fz.es));
        try expect(!e2.exists(&fz.es));
        try expect(!e.committed(&fz.es));
        try expect(!e2.committed(&fz.es));
    }
    try expectEqual(saturated_count, fz.es.slots.saturated_generations);

    while (!fz.parser.isEmpty()) {
        // Modify the entities via a command buffer
        for (0..fz.parser.nextLessThan(u16, cmds_capacity)) |_| {
            if (fz.parser.isEmpty()) break;
            switch (fz.parser.next(enum {
                reserve,
                destroy,
                change_arch,
            })) {
                .reserve => try reserve(&fz, &cmds),
                .destroy => try destroy(&fz, &cmds),
                .change_arch => try changeArch(&fz, &cmds),
            }
        }

        cmds.execImmediate(&fz.es);
        cmds.clear(&fz.es);
        try checkOracle(&fz, &cmds);

        // Modify the entities directly. We do this later since interspersing it with the
        // command buffer will get incorrect results since the oracle applies everything
        // instantly. We only do a few iterations because this test is easily exhausted.
        for (0..fz.parser.nextLessThan(u16, 100)) |_| {
            if (fz.parser.isEmpty()) break;
            try fz.modifyImmediate();
        }
        try checkOracle(&fz, &cmds);
    }

    try expect(fz.es.slots.saturated_generations >= saturated_count);
    for (0..saturated_count) |i| {
        try expectEqual(.invalid, fz.es.slots.generations[i + cmds.reserved.capacity]);
    }
}

fn checkOracle(fz: *Fuzzer, cmds: *const CmdBuf) !void {
    // Check the total number of entities
    try expectEqual(
        fz.reserved.count() + cmds.reserved.items.len,
        fz.es.reserved(),
    );
    try expectEqual(fz.committed.count(), fz.es.count());

    // Check the reserved entities
    for (fz.reserved.keys()) |e| {
        try expect(e.exists(&fz.es));
        try expect(!e.committed(&fz.es));
    }

    // Check the committed entities
    var commited_iter = fz.committed.iterator();
    while (commited_iter.next()) |entry| {
        const entity = entry.key_ptr.*;
        const expected = entry.value_ptr;
        try expect(entity.exists(&fz.es));
        try expect(entity.committed(&fz.es));
        try expectEqual(expected.rb, if (entity.getComp(&fz.es, RigidBody)) |v| v.* else null);
        try expectEqual(expected.model, if (entity.getComp(&fz.es, Model)) |v| v.* else null);
        try expectEqual(expected.tag, if (entity.getComp(&fz.es, Tag)) |v| v.* else null);
    }

    // Check the tracked deleted entities
    var destroyed_iter = fz.destroyed.iterator();
    while (destroyed_iter.next()) |entry| {
        const entity = entry.key_ptr.*;
        try expect(!entity.exists(&fz.es));
        try expect(!entity.committed(&fz.es));
        try expectEqual(null, if (entity.getComp(&fz.es, RigidBody)) |v| v.* else null);
        try expectEqual(null, if (entity.getComp(&fz.es, Model)) |v| v.* else null);
        try expectEqual(null, if (entity.getComp(&fz.es, Tag)) |v| v.* else null);
    }

    // Check the iterators
    try fz.checkIterators();
}

fn reserve(fz: *Fuzzer, cmds: *CmdBuf) !void {
    // Skip reserve if we already have a lot of entities to avoid overflowing
    if (fz.es.count() + fz.es.reserved() > fz.es.slots.capacity / 2) {
        return;
    }

    // Reserve an entity and update the oracle
    const entity = Entity.popReserved(cmds);
    try fz.reserved.putNoClobber(gpa, entity, {});
}

fn destroy(fz: *Fuzzer, cmds: *CmdBuf) !void {
    if (fz.shouldSkipDestroy()) return;

    // Destroy a random entity
    const entity = fz.randomEntity().unwrap() orelse return;
    entity.destroyCmd(cmds);

    // Destroy the entity in the oracle as well, displacing an existing
    // destroyed entity if there are already too many to prevent the destroyed
    // list from growing indefinitely.
    while (fz.destroyed.count() > 1000) {
        const index = fz.parser.nextLessThan(usize, fz.destroyed.count());
        fz.destroyed.swapRemoveAt(index);
    }
    _ = fz.reserved.swapRemove(entity);
    _ = fz.committed.swapRemove(entity);
    try fz.destroyed.put(gpa, entity, {});
}

fn changeArch(fz: *Fuzzer, cmds: *CmdBuf) !void {
    // Get a random entity
    const entity = fz.randomEntity().unwrap() orelse return;

    // Get the oracle if any, committing it if needed
    if (fz.reserved.swapRemove(entity)) {
        try fz.committed.putNoClobber(gpa, entity, .{});
    }
    const expected = fz.committed.getPtr(entity);

    // Issue commands to add/remove N random components, updating the oracle along the way
    for (0..@intCast(fz.parser.nextBetween(u8, 1, change_cap))) |_| {
        if (fz.parser.next(bool)) {
            switch (fz.parser.next(enum {
                rb,
                model,
                tag,
            })) {
                .rb => {
                    const rb = addRandomComp(fz, cmds, entity, RigidBody);
                    if (expected) |e| e.rb = rb;
                },
                .model => {
                    const model = addRandomComp(fz, cmds, entity, Model);
                    if (expected) |e| e.model = model;
                },
                .tag => {
                    const tag = addRandomComp(fz, cmds, entity, Tag);
                    if (expected) |e| e.tag = tag;
                },
            }
        } else {
            switch (fz.parser.next(enum {
                rb,
                model,
                tag,
                commit,
            })) {
                .rb => {
                    entity.remCompCmd(cmds, RigidBody);
                    if (expected) |e| e.rb = null;
                },
                .model => {
                    entity.remCompCmd(cmds, Model);
                    if (expected) |e| e.model = null;
                },
                .tag => {
                    entity.remCompCmd(cmds, Tag);
                    if (expected) |e| e.tag = null;
                },
                .commit => {
                    entity.commitCmd(cmds);
                },
            }
        }
    }
}

/// Adds a random value for the given component by value, or a random value from it's interned
/// list by pointer. Returns the value.
fn addRandomComp(fz: *Fuzzer, cmds: *CmdBuf, e: Entity, T: type) T {
    const i = fz.parser.next(u8);
    const by_ptr = i < 40;
    if (by_ptr) {
        switch (i % T.interned.len) {
            inline 0...(T.interned.len - 1) => |n| {
                const val = T.interned[n];
                e.addCompPtrCmd(cmds, .init(T, &val));
                return val;
            },
            else => unreachable,
        }
    } else {
        const val = fz.parser.next(T);
        e.addCompCmd(cmds, T, val);
        return val;
    }
}
