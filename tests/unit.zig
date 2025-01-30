//! Normal unit tests.

const std = @import("std");
const zcs = @import("zcs");
const assert = std.debug.assert;
const gpa = std.testing.allocator;
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;
const expectError = std.testing.expectError;

const Entities = zcs.Entities;
const Entity = zcs.Entity;
const CmdBuf = zcs.CmdBuf;
const Comp = zcs.Comp;
const compId = zcs.compId;

const RigidBody = struct {
    position: [2]f32 = .{ 1.0, 2.0 },
    velocity: [2]f32 = .{ 3.0, 4.0 },
    mass: f32 = 5.0,

    pub fn random(rand: std.Random) @This() {
        return .{
            .position = .{ rand.float(f32), rand.float(f32) },
            .velocity = .{ rand.float(f32), rand.float(f32) },
            .mass = rand.float(f32),
        };
    }

    pub fn randomOrNull(rand: std.Random) ?@This() {
        if (rand.boolean()) return null;
        return @This().random(rand);
    }
};

const Model = struct {
    vertex_start: u16 = 6,
    vertex_count: u16 = 7,

    pub fn random(rand: std.Random) @This() {
        return .{
            .vertex_start = rand.int(u16),
            .vertex_count = rand.int(u16),
        };
    }

    pub fn randomOrNull(rand: std.Random) ?@This() {
        if (rand.boolean()) return null;
        return @This().random(rand);
    }
};

/// A zero sized component type
pub const Tag = struct {
    pub fn random(rand: std.Random) @This() {
        _ = rand;
        return .{};
    }

    pub fn randomOrNull(rand: std.Random) ?@This() {
        if (rand.boolean()) return null;
        return @This().random(rand);
    }
};

const Components = struct {
    model: ?Model = null,
    rb: ?RigidBody = null,
    tag: ?Tag = null,
};

test "command buffer some test decode" {
    defer Comp.unregisterAll();

    var xoshiro_256: std.Random.Xoshiro256 = .init(0);
    const rand = xoshiro_256.random();

    var es = try Entities.init(gpa, 100);
    defer es.deinit(gpa);

    // Check some entity equality stuff not tested elsewhere, OrErr more extensively in slot map
    try expect(Entity.none.eql(.none));
    try expect(!Entity.none.exists(&es));

    var capacity: CmdBuf.GranularCapacity = .init(.{
        .cmds = 4,
        .comp_bytes = @sizeOf(RigidBody),
    });
    capacity.reserved = 0;
    var cmds = try CmdBuf.initGranularCapacity(gpa, &es, capacity);
    defer cmds.deinit(gpa, &es);

    try expectEqual(0, es.count());

    const e0 = Entity.reserveImmediate(&es);
    const e1 = Entity.reserveImmediate(&es);
    const e2 = Entity.reserveImmediate(&es);
    e0.commitCmd(&cmds);
    e1.commitCmd(&cmds);
    const rb = RigidBody.random(rand);
    const model = Model.random(rand);
    e2.addCompCmd(&cmds, RigidBody, rb);
    try expectEqual(3, es.reserved());
    try expectEqual(0, es.count());
    cmds.execute(&es);
    try expectEqual(0, es.reserved());
    try expectEqual(3, es.count());
    cmds.clear(&es);

    var iter = es.iterator(.{});

    try expect(iter.next().?.eql(e0));
    try expectEqual(null, e0.getComp(&es, RigidBody));
    try expectEqual(null, e0.getComp(&es, Model));
    try expectEqual(null, e0.getComp(&es, Tag));

    try expect(e1.eql(iter.next().?));
    try expectEqual(null, e1.getComp(&es, RigidBody));
    try expectEqual(null, e1.getComp(&es, Model));
    try expectEqual(null, e1.getComp(&es, Tag));

    try expect(e2.eql(iter.next().?));
    try expectEqual(rb, e2.getComp(&es, RigidBody).?.*);
    try expectEqual(null, e2.getComp(&es, Model));
    try expectEqual(null, e2.getComp(&es, Tag));

    try expectEqual(null, iter.next());

    // We don't check eql anywhere else, quickly check it here. The details are tested more
    // extensively on slot map.
    try expect(e1.eql(e1));
    try expect(!e1.eql(e2));
    try expect(!e1.eql(.none));

    e0.removeCompCmd(&cmds, RigidBody);
    e1.removeCompCmd(&cmds, RigidBody);
    e2.addCompCmd(&cmds, Model, model);
    e2.removeCompCmd(&cmds, RigidBody);
    cmds.execute(&es);
    cmds.clear(&es);

    try expectEqual(3, es.count());

    try expectEqual(null, e0.getComp(&es, RigidBody));
    try expectEqual(null, e0.getComp(&es, Model));
    try expectEqual(null, e0.getComp(&es, Tag));

    try expectEqual(null, e1.getComp(&es, RigidBody));
    try expectEqual(null, e1.getComp(&es, Model));
    try expectEqual(null, e1.getComp(&es, Tag));

    try expectEqual(null, e2.getComp(&es, RigidBody));
    try expectEqual(model, e2.getComp(&es, Model).?.*);
    try expectEqual(null, e2.getComp(&es, Tag));
}

fn isInCompBytes(cmds: CmdBuf, ptr: *const anyopaque) bool {
    const comp_bytes = cmds.arch_changes.comp_bytes.items;
    const start = @intFromPtr(comp_bytes.ptr);
    const end = start + comp_bytes.len;
    const addr = @intFromPtr(ptr);
    return addr >= start and addr < end;
}

// Verify that components are interned appropriately
test "command buffer interning" {
    defer Comp.unregisterAll();
    // Assumed by this test (affects cmds submission order.) If this fails, just adjust the types to
    // make it true and the rest of the test should pass.
    comptime assert(@alignOf(RigidBody) > @alignOf(Model));
    comptime assert(@alignOf(Model) > @alignOf(Tag));

    var xoshiro_256: std.Random.Xoshiro256 = .init(0);
    const rand = xoshiro_256.random();

    var es = try Entities.init(gpa, 100);
    defer es.deinit(gpa);

    var cmds = try CmdBuf.init(gpa, &es, .{ .cmds = 24, .comp_bytes = @sizeOf(RigidBody) });
    defer cmds.deinit(gpa, &es);

    const rb_interned: RigidBody = .{
        .position = .{ 0.5, 1.5 },
        .velocity = .{ 2.5, 3.5 },
        .mass = 4.5,
    };
    const rb_value = RigidBody.random(rand);
    const model_interned: Model = .{
        .vertex_start = 1,
        .vertex_count = 2,
    };
    const model_value = Model.random(rand);

    const e0: Entity = .reserveImmediate(&es);
    const e1: Entity = .reserveImmediate(&es);

    // Automatic interning
    e0.addCompCmd(&cmds, Model, model_value);
    e0.addCompCmd(&cmds, RigidBody, rb_interned);

    e1.addCompCmd(&cmds, Model, model_interned);
    e1.addCompCmd(&cmds, RigidBody, rb_value);

    // Explicit by value
    e0.addCompValCmd(&cmds, .init(Model, &model_value));
    e0.addCompValCmd(&cmds, .init(RigidBody, &rb_interned));

    e1.addCompValCmd(&cmds, .init(Model, &model_interned));
    e1.addCompValCmd(&cmds, .init(RigidBody, &rb_value));

    // Explicit interning
    e0.addCompPtrCmd(&cmds, .init(RigidBody, &rb_interned));
    e0.addCompPtrCmd(&cmds, .init(Model, &model_interned));

    // Test the results
    var iter = cmds.arch_changes.iterator();

    {
        const cmd = iter.next().?;
        try expectEqual(e0, cmd.entity);
        var ops = cmd.iterator();
        const comp1 = ops.next().?.add;
        try expect(isInCompBytes(cmds, comp1.as(Model).?));
        try expectEqual(model_value, comp1.as(Model).?.*);
        const comp2 = ops.next().?.add;
        try expect(!isInCompBytes(cmds, comp2.as(RigidBody).?));
        try expectEqual(rb_interned, comp2.as(RigidBody).?.*);
    }
    {
        const cmd = iter.next().?;
        try expectEqual(e1, cmd.entity);
        var ops = cmd.iterator();
        const comp1 = ops.next().?.add;
        try expect(isInCompBytes(cmds, comp1.as(Model).?)); // By value because it's too small!
        try expectEqual(model_interned, comp1.as(Model).?.*);
        const comp2 = ops.next().?.add;
        try expect(isInCompBytes(cmds, comp2.as(RigidBody).?));
        try expectEqual(rb_value, comp2.as(RigidBody).?.*);
        try expectEqual(null, ops.next());
    }
    {
        const cmd = iter.next().?;
        try expectEqual(e0, cmd.entity);
        var ops = cmd.iterator();
        const comp1 = ops.next().?.add;
        try expect(isInCompBytes(cmds, comp1.as(Model).?));
        try expectEqual(model_value, comp1.as(Model).?.*);
        const comp2 = ops.next().?.add;
        try expect(isInCompBytes(cmds, comp2.as(RigidBody).?));
        try expectEqual(rb_interned, comp2.as(RigidBody).?.*);
        try expectEqual(null, ops.next());
    }
    {
        const cmd = iter.next().?;
        try expectEqual(e1, cmd.entity);
        var ops = cmd.iterator();
        const comp1 = ops.next().?.add;
        try expect(isInCompBytes(cmds, comp1.as(Model).?));
        try expectEqual(model_interned, comp1.as(Model).?.*);
        const comp2 = ops.next().?.add;
        try expect(isInCompBytes(cmds, comp2.as(RigidBody).?));
        try expectEqual(rb_value, comp2.as(RigidBody).?.*);
        try expectEqual(null, ops.next());
    }
    {
        const cmd = iter.next().?;
        try expectEqual(e0, cmd.entity);
        var ops = cmd.iterator();
        const comp1 = ops.next().?.add;
        try expect(!isInCompBytes(cmds, comp1.as(RigidBody).?));
        try expectEqual(rb_interned, comp1.as(RigidBody).?.*);
        const comp2 = ops.next().?.add;
        try expect(!isInCompBytes(cmds, comp2.as(Model).?));
        try expectEqual(model_interned, comp2.as(Model).?.*);
        try expectEqual(null, ops.next());
    }

    try expectEqual(null, iter.next());
}

test "command buffer overflow" {
    defer Comp.unregisterAll();
    // Not very exhaustive, but checks that command buffers return the overflow error on failure to
    // append, and on submits that fail.

    var xoshiro_256: std.Random.Xoshiro256 = .init(0);
    const rand = xoshiro_256.random();

    var es = try Entities.init(gpa, 100);
    defer es.deinit(gpa);

    // Tag/destroy overflow
    {
        var cmds = try CmdBuf.initGranularCapacity(gpa, &es, .{
            .tags = 0,
            .args = 100,
            .comp_bytes = 100,
            .destroy = 0,
            .reserved = 0,
        });
        defer cmds.deinit(gpa, &es);

        try expectError(
            error.ZcsCmdBufOverflow,
            Entity.reserveImmediate(&es).commitCmdOrErr(&cmds),
        );
        try expectError(
            error.ZcsCmdBufOverflow,
            Entity.reserveImmediate(&es).destroyCmdOrErr(&cmds),
        );

        try expectEqual(1.0, cmds.worstCaseUsage());

        var iter = cmds.arch_changes.iterator();
        try expectEqual(null, iter.next());
    }

    // Arg overflow
    {
        var cmds = try CmdBuf.initGranularCapacity(gpa, &es, .{
            .tags = 100,
            .args = 0,
            .comp_bytes = 100,
            .destroy = 100,
            .reserved = 0,
        });
        defer cmds.deinit(gpa, &es);

        try expectError(
            error.ZcsCmdBufOverflow,
            Entity.reserveImmediate(&es).commitCmdOrErr(&cmds),
        );
        const e = Entity.reserveImmediate(&es);
        e.destroyCmd(&cmds);

        try expectEqual(1.0, cmds.worstCaseUsage());

        try expectEqual(1, cmds.destroy.items.len);
        try expectEqual(e, cmds.destroy.items[0]);
        var iter = cmds.arch_changes.iterator();
        try expectEqual(null, iter.next());
    }

    // Comp data overflow
    {
        var cmds = try CmdBuf.initGranularCapacity(gpa, &es, .{
            .tags = 100,
            .args = 100,
            .comp_bytes = @sizeOf(RigidBody) * 2 - 1,
            .destroy = 100,
            .reserved = 0,
        });
        defer cmds.deinit(gpa, &es);

        const e: Entity = Entity.reserveImmediate(&es);
        const rb = RigidBody.random(rand);

        _ = Entity.reserveImmediate(&es).addCompCmd(&cmds, RigidBody, rb);
        e.destroyCmd(&cmds);
        try expectError(error.ZcsCmdBufOverflow, e.addCompCmdOrErr(
            &cmds,
            RigidBody,
            RigidBody.random(rand),
        ));

        try expectEqual(@as(f32, @sizeOf(RigidBody)) / @as(f32, @sizeOf(RigidBody) * 2 - 1), cmds.worstCaseUsage());

        try expectEqual(1, cmds.destroy.items.len);
        try expectEqual(e, cmds.destroy.items[0]);
        var iter = cmds.arch_changes.iterator();
        const arch_change = iter.next().?;
        var ops = arch_change.iterator();
        const create_rb = ops.next().?.add;
        try expectEqual(compId(RigidBody), create_rb.id);
        try expectEqual(rb, create_rb.as(RigidBody).?.*);
        try expectEqual(null, ops.next());
        try expectEqual(null, iter.next());
    }
}

// Verify that command buffers don't overflow before their estimated capacity
test "command buffer worst case capacity" {
    defer Comp.unregisterAll();

    const cb_capacity = 600;

    var es = try Entities.init(gpa, cb_capacity * 10);
    defer es.deinit(gpa);

    var cmds = try CmdBuf.init(gpa, &es, .{ .cmds = cb_capacity, .comp_bytes = 22 });
    defer cmds.deinit(gpa, &es);

    // Change archetype
    {
        // Add val
        const e0 = Entity.reserveImmediate(&es);
        const e1 = Entity.reserveImmediate(&es);

        for (0..cb_capacity / 12) |_| {
            e0.addCompValCmd(&cmds, .init(u0, &0));
            e1.addCompValCmd(&cmds, .init(u8, &0));
            e0.addCompValCmd(&cmds, .init(u16, &0));
            e1.addCompValCmd(&cmds, .init(u32, &0));
            e0.addCompValCmd(&cmds, .init(u64, &0));
            e1.addCompValCmd(&cmds, .init(u128, &0));
        }

        try expect(cmds.worstCaseUsage() < 1.0);
        cmds.clear(&es);

        for (0..cb_capacity / 6) |_| {
            e0.addCompValCmd(&cmds, .init(u0, &0));
            e1.addCompValCmd(&cmds, .init(u8, &0));
            e0.addCompValCmd(&cmds, .init(u16, &0));
            e1.addCompValCmd(&cmds, .init(u32, &0));
            e0.addCompValCmd(&cmds, .init(u64, &0));
            e1.addCompValCmd(&cmds, .init(u128, &0));
        }

        try expectEqual(1.0, cmds.worstCaseUsage());
        cmds.clear(&es);

        // Add ptr
        for (0..cb_capacity / 12) |_| {
            e0.addCompPtrCmd(&cmds, .init(u0, &0));
            e1.addCompPtrCmd(&cmds, .init(u8, &0));
            e0.addCompPtrCmd(&cmds, .init(u16, &0));
            e1.addCompPtrCmd(&cmds, .init(u32, &0));
            e0.addCompPtrCmd(&cmds, .init(u64, &0));
            e1.addCompPtrCmd(&cmds, .init(u128, &0));
        }

        try expect(cmds.worstCaseUsage() < 1.0);
        cmds.clear(&es);

        for (0..cb_capacity / 6) |_| {
            e0.addCompPtrCmd(&cmds, .init(u0, &0));
            e1.addCompPtrCmd(&cmds, .init(u8, &0));
            e0.addCompPtrCmd(&cmds, .init(u16, &0));
            e1.addCompPtrCmd(&cmds, .init(u32, &0));
            e0.addCompPtrCmd(&cmds, .init(u64, &0));
            e1.addCompPtrCmd(&cmds, .init(u128, &0));
        }

        try expectEqual(1.0, cmds.worstCaseUsage());
        cmds.clear(&es);

        // Remove
        for (0..cb_capacity / 12) |_| {
            e0.removeCompCmd(&cmds, u0);
            e1.removeCompCmd(&cmds, u8);
            e0.removeCompCmd(&cmds, u16);
            e1.removeCompCmd(&cmds, u32);
            e0.removeCompCmd(&cmds, u64);
            e1.removeCompCmd(&cmds, u128);
        }

        try expect(cmds.worstCaseUsage() < 1.0);
        cmds.clear(&es);

        for (0..cb_capacity / 6) |_| {
            e0.removeCompCmd(&cmds, u0);
            e1.removeCompCmd(&cmds, u8);
            e0.removeCompCmd(&cmds, u16);
            e1.removeCompCmd(&cmds, u32);
            e0.removeCompCmd(&cmds, u64);
            e1.removeCompCmd(&cmds, u128);
        }

        try expectEqual(1.0, cmds.worstCaseUsage());
        cmds.clear(&es);
    }

    // Destroy
    {
        for (0..cb_capacity / 2) |i| {
            const e: Entity = .{ .key = .{
                .index = @intCast(i),
                .generation = @enumFromInt(0),
            } };
            try e.destroyCmdOrErr(&cmds);
        }

        try expect(cmds.worstCaseUsage() < 1.0);
        cmds.clear(&es);

        for (0..cb_capacity) |i| {
            const e: Entity = .{ .key = .{
                .index = @intCast(i),
                .generation = @enumFromInt(0),
            } };
            try e.destroyCmdOrErr(&cmds);
        }

        try expectEqual(1.0, cmds.worstCaseUsage());
        cmds.clear(&es);
    }

    // Destroy
    {
        for (0..cb_capacity) |_| {
            _ = try Entity.popReservedOrErr(&cmds);
        }

        try expectEqual(1.0, cmds.worstCaseUsage());
        cmds.clear(&es);
    }
}
