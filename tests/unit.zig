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
const Any = zcs.Any;
const CompFlag = zcs.CompFlag;
const TypeInfo = zcs.TypeInfo;
const typeId = zcs.typeId;

const types = @import("types.zig");

const RigidBody = types.RigidBody;
const Model = types.Model;
const Tag = types.Tag;
const FooEv = types.FooEv;
const BarEv = types.BarEv;
const BazEv = types.BazEv;

const Components = struct {
    model: ?Model = null,
    rb: ?RigidBody = null,
    tag: ?Tag = null,
};

test "command buffer test execImmediate" {
    defer CompFlag.unregisterAll();

    var xoshiro_256: std.Random.Xoshiro256 = .init(0);
    const rand = xoshiro_256.random();

    var es = try Entities.init(gpa, .{ .max_entities = 100, .comp_bytes = 100 });
    defer es.deinit(gpa);

    // Check some entity equality stuff not tested elsewhere, OrErr more extensively in slot map
    try expect(Entity.Optional.none == Entity.Optional.none);
    try expectEqual(null, Entity.Optional.none.unwrap());

    var capacity: CmdBuf.GranularCapacity = .init(.{
        .cmds = 4,
        .avg_any_bytes = @sizeOf(RigidBody),
    });
    capacity.reserved = 0;
    var cmds = try CmdBuf.initGranularCapacity(gpa, &es, capacity);
    defer cmds.deinit(gpa, &es);

    try expectEqual(0, es.count());

    const e0 = Entity.reserveImmediate(&es);
    const e1 = Entity.reserveImmediate(&es);
    const e2 = Entity.reserveImmediate(&es);
    const e3 = Entity.reserveImmediate(&es);
    e0.commitCmd(&cmds);
    e1.commitCmd(&cmds);
    const rb = RigidBody.random(rand);
    const model = Model.random(rand);
    e3.destroyCmd(&cmds);
    e2.addCompCmd(&cmds, RigidBody, rb);
    try expectEqual(4, es.reserved());
    try expectEqual(0, es.count());
    cmds.execImmediate(&es);
    try expectEqual(0, es.reserved());
    try expectEqual(3, es.count());
    cmds.clear(&es);

    var iter = es.iterator(.{});

    try expect(iter.next().? == e0);
    try expectEqual(null, e0.getComp(&es, RigidBody));
    try expectEqual(null, e0.getComp(&es, Model));
    try expectEqual(null, e0.getComp(&es, Tag));

    try expect(e1 == iter.next().?);
    try expectEqual(null, e1.getComp(&es, RigidBody));
    try expectEqual(null, e1.getComp(&es, Model));
    try expectEqual(null, e1.getComp(&es, Tag));

    try expect(e2 == iter.next().?);
    try expectEqual(rb, e2.getComp(&es, RigidBody).?.*);
    try expectEqual(null, e2.getComp(&es, Model));
    try expectEqual(null, e2.getComp(&es, Tag));

    try expectEqual(null, iter.next());

    // We don't check eql anywhere else, quickly check it here. The details are tested more
    // extensively on slot map.
    try expect(e1 == e1);
    try expect(e1 != e2);
    try expect(e1.toOptional() != Entity.Optional.none);
    try expect(e1.toOptional().unwrap().? == e1);

    e0.remCompCmd(&cmds, RigidBody);
    e1.remCompCmd(&cmds, RigidBody);
    e2.addCompCmd(&cmds, Model, model);
    e2.remCompCmd(&cmds, RigidBody);
    cmds.execImmediate(&es);
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

fn isInAnyBytes(cmds: CmdBuf, data: anytype) bool {
    const bytes = std.mem.asBytes(data);
    const any_bytes = cmds.any_bytes.items;
    const start = @intFromPtr(any_bytes.ptr);
    const end = start + any_bytes.len;
    const addr_start = @intFromPtr(bytes.ptr);
    const addr_end = addr_start + bytes.len;
    return addr_start >= start and addr_end <= end;
}

// Verify that components are interned appropriately
test "command buffer interning" {
    defer CompFlag.unregisterAll();
    // Assumed by this test (affects cmds submission order.) If this fails, just adjust the types to
    // make it true and the rest of the test should pass.
    comptime assert(@alignOf(RigidBody) > @alignOf(Model));
    comptime assert(@alignOf(Model) > @alignOf(Tag));

    var xoshiro_256: std.Random.Xoshiro256 = .init(0);
    const rand = xoshiro_256.random();

    var es = try Entities.init(gpa, .{ .max_entities = 100, .comp_bytes = 4096 });
    defer es.deinit(gpa);

    var cmds = try CmdBuf.init(gpa, &es, .{ .cmds = 24, .avg_any_bytes = @sizeOf(RigidBody) });
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
    const foo_ev_interned: FooEv = .{
        .foo = .{ 3.3, 4.4, 5.5 },
    };
    const foo_ev_value = FooEv.random(rand);
    const bar_ev_interned: BarEv = .{
        .bar = 123,
    };
    const bar_ev_value = BarEv.random(rand);

    const e0: Entity = .reserveImmediate(&es);
    const e1: Entity = .reserveImmediate(&es);
    const e2: Entity = .reserveImmediate(&es);

    // Automatic interning
    e0.addCompCmd(&cmds, Model, model_value);
    e0.addCompCmd(&cmds, RigidBody, rb_interned);
    e0.eventCmd(&cmds, BarEv, bar_ev_value);
    e0.eventCmd(&cmds, FooEv, foo_ev_interned);

    e1.addCompCmd(&cmds, Model, model_interned);
    e1.addCompCmd(&cmds, RigidBody, rb_value);
    e1.eventCmd(&cmds, BarEv, bar_ev_interned);
    e1.eventCmd(&cmds, FooEv, foo_ev_value);

    // Explicit by value
    e0.addCompValCmd(&cmds, .init(Model, &model_value));
    e0.addCompValCmd(&cmds, .init(RigidBody, &rb_interned));
    e0.eventValCmd(&cmds, .init(BarEv, &bar_ev_value));
    e0.eventValCmd(&cmds, .init(FooEv, &foo_ev_interned));

    e1.addCompValCmd(&cmds, .init(Model, &model_interned));
    e1.addCompValCmd(&cmds, .init(RigidBody, &rb_value));
    e1.eventValCmd(&cmds, .init(BarEv, &bar_ev_interned));
    e1.eventValCmd(&cmds, .init(FooEv, &foo_ev_value));

    // Throw in a destroy for good measure, verify the components end up in the remove flags
    try expect(e2.changeArchImmediate(&es, .{
        .add = &.{ .init(RigidBody, &.{ .mass = 1.0 }), .init(Model, &.{ .vertex_start = 2 }) },
        .remove = .initEmpty(),
    }));
    e2.destroyCmd(&cmds);

    // Explicit interning
    e0.addCompPtrCmd(&cmds, .init(RigidBody, &rb_interned));
    e0.addCompPtrCmd(&cmds, .init(Model, &model_interned));
    e0.eventPtrCmd(&cmds, .init(BarEv, &bar_ev_interned));
    e0.eventPtrCmd(&cmds, .init(FooEv, &foo_ev_interned));

    // Zero sized types
    e1.addCompCmd(&cmds, Tag, .{});
    e1.addCompValCmd(&cmds, .init(Tag, &.{}));
    e1.addCompPtrCmd(&cmds, .init(Tag, &.{}));
    e1.eventCmd(&cmds, BazEv, .{});
    e1.eventValCmd(&cmds, .init(BazEv, &.{}));
    e1.eventPtrCmd(&cmds, .init(BazEv, &.{}));

    // Test the results
    var iter = cmds.iterator();

    {
        const cmd = iter.next().?;
        try expectEqual(e0, cmd.entity);
        const arch_change = cmd.getArchChangeImmediate(&es);
        try expectEqual(CompFlag.set(&.{
            CompFlag.registerImmediate(typeId(Model)),
            CompFlag.registerImmediate(typeId(RigidBody)),
        }), arch_change.add);
        try expectEqual(CompFlag.set(&.{}), arch_change.remove);
        try expect(!arch_change.destroy);
        var ops = cmd.iterator();
        const comp1 = ops.next().?.add_comp;
        try expect(isInAnyBytes(cmds, comp1.as(Model).?));
        try expectEqual(model_value, comp1.as(Model).?.*);
        const comp2 = ops.next().?.add_comp;
        try expect(!isInAnyBytes(cmds, comp2.as(RigidBody).?));
        try expectEqual(rb_interned, comp2.as(RigidBody).?.*);
        const ev1 = ops.next().?.event;
        try expect(isInAnyBytes(cmds, ev1.as(BarEv).?));
        try expectEqual(bar_ev_value, ev1.as(BarEv).?.*);
        const ev2 = ops.next().?.event;
        try expect(!isInAnyBytes(cmds, ev2.as(FooEv).?));
        try expectEqual(foo_ev_interned, ev2.as(FooEv).?.*);
        try expectEqual(null, ops.next());
    }
    {
        const cmd = iter.next().?;
        const arch_change = cmd.getArchChangeImmediate(&es);
        try expectEqual(CompFlag.set(&.{
            CompFlag.registerImmediate(typeId(Model)),
            CompFlag.registerImmediate(typeId(RigidBody)),
        }), arch_change.add);
        try expectEqual(CompFlag.set(&.{}), arch_change.remove);
        try expect(!arch_change.destroy);
        try expectEqual(e1, cmd.entity);
        var ops = cmd.iterator();
        const comp1 = ops.next().?.add_comp;
        try expect(isInAnyBytes(cmds, comp1.as(Model).?)); // By value because it's too small!
        try expectEqual(model_interned, comp1.as(Model).?.*);
        const comp2 = ops.next().?.add_comp;
        try expect(isInAnyBytes(cmds, comp2.as(RigidBody).?));
        try expectEqual(rb_value, comp2.as(RigidBody).?.*);
        const ev1 = ops.next().?.event;
        try expect(isInAnyBytes(cmds, ev1.as(BarEv).?)); // By value because it's too small!
        try expectEqual(bar_ev_interned, ev1.as(BarEv).?.*);
        const ev2 = ops.next().?.event;
        try expect(isInAnyBytes(cmds, ev2.as(FooEv).?));
        try expectEqual(foo_ev_value, ev2.as(FooEv).?.*);
        try expectEqual(null, ops.next());
    }
    {
        const cmd = iter.next().?;
        const arch_change = cmd.getArchChangeImmediate(&es);
        try expectEqual(CompFlag.set(&.{
            CompFlag.registerImmediate(typeId(Model)),
            CompFlag.registerImmediate(typeId(RigidBody)),
        }), arch_change.add);
        try expectEqual(CompFlag.set(&.{}), arch_change.remove);
        try expect(!arch_change.destroy);
        try expectEqual(e0, cmd.entity);
        var ops = cmd.iterator();
        const comp1 = ops.next().?.add_comp;
        try expect(isInAnyBytes(cmds, comp1.as(Model).?));
        try expectEqual(model_value, comp1.as(Model).?.*);
        const comp2 = ops.next().?.add_comp;
        try expect(isInAnyBytes(cmds, comp2.as(RigidBody).?));
        try expectEqual(rb_interned, comp2.as(RigidBody).?.*);
        const ev1 = ops.next().?.event;
        try expect(isInAnyBytes(cmds, ev1.as(BarEv).?));
        try expectEqual(bar_ev_value, ev1.as(BarEv).?.*);
        const ev2 = ops.next().?.event;
        try expect(isInAnyBytes(cmds, ev2.as(FooEv).?));
        try expectEqual(foo_ev_interned, ev2.as(FooEv).?.*);
        try expectEqual(null, ops.next());
    }
    {
        const cmd = iter.next().?;
        const arch_change = cmd.getArchChangeImmediate(&es);
        try expectEqual(CompFlag.set(&.{
            CompFlag.registerImmediate(typeId(Model)),
            CompFlag.registerImmediate(typeId(RigidBody)),
        }), arch_change.add);
        try expectEqual(CompFlag.set(&.{}), arch_change.remove);
        try expect(!arch_change.destroy);
        try expectEqual(e1, cmd.entity);
        var ops = cmd.iterator();
        const comp1 = ops.next().?.add_comp;
        try expect(isInAnyBytes(cmds, comp1.as(Model).?));
        try expectEqual(model_interned, comp1.as(Model).?.*);
        const comp2 = ops.next().?.add_comp;
        try expect(isInAnyBytes(cmds, comp2.as(RigidBody).?));
        try expectEqual(rb_value, comp2.as(RigidBody).?.*);
        const ev1 = ops.next().?.event;
        try expect(isInAnyBytes(cmds, ev1.as(BarEv).?));
        try expectEqual(bar_ev_interned, ev1.as(BarEv).?.*);
        const ev2 = ops.next().?.event;
        try expect(isInAnyBytes(cmds, ev2.as(FooEv).?));
        try expectEqual(foo_ev_value, ev2.as(FooEv).?.*);
        try expectEqual(null, ops.next());
    }
    {
        const cmd = iter.next().?;
        const arch_change = cmd.getArchChangeImmediate(&es);
        try expectEqual(e2, cmd.entity);
        try expectEqual(CompFlag.Set.initEmpty(), arch_change.add);
        try expectEqual(CompFlag.set(&.{
            CompFlag.registerImmediate(typeId(Model)),
            CompFlag.registerImmediate(typeId(RigidBody)),
        }), arch_change.remove);
        try expect(arch_change.destroy);
        var ops = cmd.iterator();
        try expectEqual(.destroy, ops.next());
        try expectEqual(null, ops.next());
    }
    {
        const cmd = iter.next().?;
        const arch_change = cmd.getArchChangeImmediate(&es);
        try expectEqual(CompFlag.set(&.{
            CompFlag.registerImmediate(typeId(Model)),
            CompFlag.registerImmediate(typeId(RigidBody)),
        }), arch_change.add);
        try expectEqual(CompFlag.set(&.{}), arch_change.remove);
        try expect(!arch_change.destroy);
        try expectEqual(e0, cmd.entity);
        var ops = cmd.iterator();
        const comp1 = ops.next().?.add_comp;
        try expect(!isInAnyBytes(cmds, comp1.as(RigidBody).?));
        try expectEqual(rb_interned, comp1.as(RigidBody).?.*);
        const comp2 = ops.next().?.add_comp;
        try expect(!isInAnyBytes(cmds, comp2.as(Model).?));
        try expectEqual(model_interned, comp2.as(Model).?.*);
        const ev1 = ops.next().?.event;
        try expect(!isInAnyBytes(cmds, ev1.as(BarEv).?));
        try expectEqual(bar_ev_interned, ev1.as(BarEv).?.*);
        const ev2 = ops.next().?.event;
        try expect(!isInAnyBytes(cmds, ev2.as(FooEv).?));
        try expectEqual(foo_ev_interned, ev2.as(FooEv).?.*);
        try expectEqual(null, ops.next());
    }
    {
        const cmd = iter.next().?;
        const arch_change = cmd.getArchChangeImmediate(&es);
        try expectEqual(CompFlag.set(&.{
            CompFlag.registerImmediate(typeId(Tag)),
        }), arch_change.add);
        try expectEqual(CompFlag.set(&.{}), arch_change.remove);
        try expect(!arch_change.destroy);
        try expectEqual(e1, cmd.entity);
        var ops = cmd.iterator();
        const comp1 = ops.next().?.add_comp;
        try expect(isInAnyBytes(cmds, comp1.as(Tag).?));
        try expectEqual(Tag{}, comp1.as(Tag).?.*);
        const comp2 = ops.next().?.add_comp;
        try expect(isInAnyBytes(cmds, comp2.as(Tag).?));
        try expectEqual(Tag{}, comp2.as(Tag).?.*);
        const comp3 = ops.next().?.add_comp;
        try expect(!isInAnyBytes(cmds, comp3.as(Tag).?));
        try expectEqual(Tag{}, comp3.as(Tag).?.*);
        const ev1 = ops.next().?.event;
        try expect(isInAnyBytes(cmds, ev1.as(BazEv).?));
        try expectEqual(BazEv{}, ev1.as(BazEv).?.*);
        const ev2 = ops.next().?.event;
        try expect(isInAnyBytes(cmds, ev2.as(BazEv).?));
        try expectEqual(BazEv{}, ev2.as(BazEv).?.*);
        const ev3 = ops.next().?.event;
        try expect(!isInAnyBytes(cmds, ev3.as(BazEv).?));
        try expectEqual(BazEv{}, ev3.as(BazEv).?.*);
        try expectEqual(null, ops.next());
    }

    try expectEqual(null, iter.next());
}

test "command buffer overflow" {
    defer CompFlag.unregisterAll();
    // Not very exhaustive, but checks that command buffers return the overflow error on failure to
    // append, and on submits that fail.

    var xoshiro_256: std.Random.Xoshiro256 = .init(0);
    const rand = xoshiro_256.random();

    var es = try Entities.init(gpa, .{ .max_entities = 100, .comp_bytes = 100 });
    defer es.deinit(gpa);

    // Tag overflow
    {
        var cmds = try CmdBuf.initGranularCapacity(gpa, &es, .{
            .tags = 0,
            .args = 100,
            .any_bytes = 100,
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

        var iter = cmds.iterator();
        try expectEqual(null, iter.next());
    }

    // Arg overflow
    {
        var cmds = try CmdBuf.initGranularCapacity(gpa, &es, .{
            .tags = 100,
            .args = 0,
            .any_bytes = 100,
            .reserved = 0,
        });
        defer cmds.deinit(gpa, &es);

        try expectError(
            error.ZcsCmdBufOverflow,
            Entity.reserveImmediate(&es).commitCmdOrErr(&cmds),
        );
        const e = Entity.reserveImmediate(&es);
        const tags = cmds.tags.items.len;
        const args = cmds.args.items.len;
        try expectError(error.ZcsCmdBufOverflow, e.destroyCmdOrErr(&cmds));
        try expectEqual(tags, cmds.tags.items.len);
        try expectEqual(args, cmds.args.items.len);

        try expectEqual(1.0, cmds.worstCaseUsage());

        var iter = cmds.iterator();
        try expectEqual(null, iter.next());
    }

    // Comp data overflow
    {
        var cmds = try CmdBuf.initGranularCapacity(gpa, &es, .{
            .tags = 100,
            .args = 100,
            .any_bytes = @sizeOf(RigidBody) * 2 - 1,
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

        var iter = cmds.iterator();

        {
            const cmd = iter.next().?;
            var ops = cmd.iterator();
            const create_rb = ops.next().?.add_comp;
            try expectEqual(typeId(RigidBody), create_rb.id);
            try expectEqual(rb, create_rb.as(RigidBody).?.*);
            try expectEqual(null, ops.next());
        }

        {
            const cmd = iter.next().?;
            const arch_change = cmd.getArchChangeImmediate(&es);
            try expectEqual(e, cmd.entity);
            try expectEqual(CompFlag.set(&.{}), arch_change.add);
            try expectEqual(CompFlag.set(&.{}), arch_change.remove);
            try expect(arch_change.destroy);
            var ops = cmd.iterator();
            try expectEqual(.destroy, ops.next());
            try expectEqual(null, ops.next());
        }

        try expectEqual(null, iter.next());
    }

    // Event data overflow
    {
        var cmds = try CmdBuf.initGranularCapacity(gpa, &es, .{
            .tags = 100,
            .args = 100,
            .any_bytes = @sizeOf(FooEv) * 2 - 1,
            .reserved = 0,
        });
        defer cmds.deinit(gpa, &es);

        const e: Entity = Entity.reserveImmediate(&es);
        const foo = FooEv.random(rand);

        _ = Entity.reserveImmediate(&es).eventCmd(&cmds, FooEv, foo);
        e.destroyCmd(&cmds);
        try expectError(error.ZcsCmdBufOverflow, e.eventCmdOrErr(
            &cmds,
            FooEv,
            FooEv.random(rand),
        ));

        try expectEqual(@as(f32, @sizeOf(FooEv)) / @as(f32, @sizeOf(FooEv) * 2 - 1), cmds.worstCaseUsage());

        var iter = cmds.iterator();

        {
            const cmd = iter.next().?;
            var ops = cmd.iterator();
            const create_foo = ops.next().?.event;
            try expectEqual(typeId(FooEv), create_foo.id);
            try expectEqual(foo, create_foo.as(FooEv).?.*);
            try expectEqual(null, ops.next());
        }

        {
            const cmd = iter.next().?;
            const arch_change = cmd.getArchChangeImmediate(&es);
            try expectEqual(e, cmd.entity);
            try expectEqual(CompFlag.set(&.{}), arch_change.add);
            try expectEqual(CompFlag.set(&.{}), arch_change.remove);
            try expect(arch_change.destroy);
            var ops = cmd.iterator();
            try expectEqual(.destroy, ops.next());
            try expectEqual(null, ops.next());
        }

        try expectEqual(null, iter.next());
    }

    // Reserved underflow
    {
        var cmds = try CmdBuf.initGranularCapacity(gpa, &es, .{
            .tags = 100,
            .args = 100,
            .any_bytes = @sizeOf(RigidBody) * 2 - 1,
            .reserved = 2,
        });
        defer cmds.deinit(gpa, &es);

        _ = try Entity.popReservedOrErr(&cmds);
        _ = try Entity.popReservedOrErr(&cmds);
        try expectError(error.ZcsReservedEntityUnderflow, Entity.popReservedOrErr(&cmds));
    }

    // Calling some things just to make sure they compile that we don't test elsewhere
    var cmds = try CmdBuf.initGranularCapacity(gpa, &es, .{
        .tags = 100,
        .args = 100,
        .any_bytes = @sizeOf(RigidBody) * 2 - 1,
        .reserved = 0,
    });
    defer cmds.deinit(gpa, &es);
    const e = Entity.reserveImmediate(&es);
    try expect(e.changeArchImmediate(&es, .{}));
    try e.addCompValCmdOrErr(&cmds, .init(RigidBody, &.{}));
    try e.addCompPtrCmdOrErr(&cmds, .init(RigidBody, &.{}));
    try expect(!e.hasComp(&es, Model));
    _ = Entity.reserveImmediate(&es);
    try expect(es.count() > 0);
    try expect(es.reserved() > 0);
    es.reset();
    try expectEqual(0, es.count());
    try expectEqual(0, es.reserved());
}

// Verify that command buffers don't overflow before their estimated capacity
test "command buffer worst case capacity" {
    defer CompFlag.unregisterAll();

    const cb_capacity = 600;

    var es = try Entities.init(gpa, .{
        .max_entities = cb_capacity * 10,
        .comp_bytes = cb_capacity * 10,
    });
    defer es.deinit(gpa);

    var cmds = try CmdBuf.init(gpa, &es, .{ .cmds = cb_capacity, .avg_any_bytes = 22 });
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
            e0.remCompCmd(&cmds, u0);
            e1.remCompCmd(&cmds, u8);
            e0.remCompCmd(&cmds, u16);
            e1.remCompCmd(&cmds, u32);
            e0.remCompCmd(&cmds, u64);
            e1.remCompCmd(&cmds, u128);
        }

        try expect(cmds.worstCaseUsage() < 1.0);
        cmds.clear(&es);

        for (0..cb_capacity / 6) |_| {
            e0.remCompCmd(&cmds, u0);
            e1.remCompCmd(&cmds, u8);
            e0.remCompCmd(&cmds, u16);
            e1.remCompCmd(&cmds, u32);
            e0.remCompCmd(&cmds, u64);
            e1.remCompCmd(&cmds, u128);
        }

        try expectEqual(1.0, cmds.worstCaseUsage());
        cmds.clear(&es);
    }

    // Events
    {
        // Event val
        const e0 = Entity.reserveImmediate(&es);
        const e1 = Entity.reserveImmediate(&es);

        for (0..cb_capacity / 12) |_| {
            e0.eventValCmd(&cmds, .init(u0, &0));
            e1.eventValCmd(&cmds, .init(u8, &0));
            e0.eventValCmd(&cmds, .init(u16, &0));
            e1.eventValCmd(&cmds, .init(u32, &0));
            e0.eventValCmd(&cmds, .init(u64, &0));
            e1.eventValCmd(&cmds, .init(u128, &0));
        }

        try expect(cmds.worstCaseUsage() < 1.0);
        cmds.clear(&es);

        for (0..cb_capacity / 6) |_| {
            e0.eventValCmd(&cmds, .init(u0, &0));
            e1.eventValCmd(&cmds, .init(u8, &0));
            e0.eventValCmd(&cmds, .init(u16, &0));
            e1.eventValCmd(&cmds, .init(u32, &0));
            e0.eventValCmd(&cmds, .init(u64, &0));
            e1.eventValCmd(&cmds, .init(u128, &0));
        }

        try expectEqual(1.0, cmds.worstCaseUsage());
        cmds.clear(&es);

        // Add ptr
        for (0..cb_capacity / 12) |_| {
            e0.eventPtrCmd(&cmds, .init(u0, &0));
            e1.eventPtrCmd(&cmds, .init(u8, &0));
            e0.eventPtrCmd(&cmds, .init(u16, &0));
            e1.eventPtrCmd(&cmds, .init(u32, &0));
            e0.eventPtrCmd(&cmds, .init(u64, &0));
            e1.eventPtrCmd(&cmds, .init(u128, &0));
        }

        try expect(cmds.worstCaseUsage() < 1.0);
        cmds.clear(&es);

        for (0..cb_capacity / 6) |_| {
            e0.eventPtrCmd(&cmds, .init(u0, &0));
            e1.eventPtrCmd(&cmds, .init(u8, &0));
            e0.eventPtrCmd(&cmds, .init(u16, &0));
            e1.eventPtrCmd(&cmds, .init(u32, &0));
            e0.eventPtrCmd(&cmds, .init(u64, &0));
            e1.eventPtrCmd(&cmds, .init(u128, &0));
        }

        try expectEqual(1.0, cmds.worstCaseUsage());
        cmds.clear(&es);
    }

    // Destroy
    {
        for (0..cb_capacity) |i| {
            const e: Entity = .{ .key = .{
                .index = @intCast(i),
                .generation = @enumFromInt(0),
            } };
            try e.destroyCmdOrErr(&cmds);
        }

        try expect(cmds.worstCaseUsage() == 1.0);
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

test "format entity" {
    try std.testing.expectFmt("0xa:0xb", "{}", Entity{ .key = .{
        .index = 10,
        .generation = @enumFromInt(11),
    } });
    try std.testing.expectFmt("0xa:0xb", "{}", (Entity{ .key = .{
        .index = 10,
        .generation = @enumFromInt(11),
    } }).toOptional());
    try std.testing.expectFmt(".none", "{}", Entity.Optional.none);
}

test "change arch immediate" {
    defer CompFlag.unregisterAll();
    var es = try Entities.init(gpa, .{ .max_entities = 100, .comp_bytes = 100 });
    defer es.deinit(gpa);

    {
        const e = Entity.reserveImmediate(&es);
        try expect(e.changeArchImmediate(&es, .{
            .add = &.{ .init(RigidBody, &.{ .mass = 1.0 }), .init(Model, &.{ .vertex_start = 2 }) },
            .remove = CompFlag.set(&.{CompFlag.registerImmediate(typeId(RigidBody))}),
        }));
        try expectEqual(Model{ .vertex_start = 2 }, e.getComp(&es, Model).?.*);
        try expectEqual(null, e.getComp(&es, RigidBody));
        try expectEqual(null, e.getComp(&es, Tag));
    }

    {
        const e = Entity.reserveImmediate(&es);
        try expect(e.changeArchImmediate(&es, .{
            .add = &.{
                .init(RigidBody, &.{ .mass = 0.5 }),
                .init(Model, &.{ .vertex_start = 20 }),
            },
            .remove = CompFlag.set(&.{CompFlag.registerImmediate(typeId(Tag))}),
        }));
        try expectEqual(RigidBody{ .mass = 0.5 }, e.getComp(&es, RigidBody).?.*);
        try expectEqual(Model{ .vertex_start = 20 }, e.getComp(&es, Model).?.*);
        try expectEqual(null, e.getComp(&es, Tag));
    }

    {
        const e = Entity.reserveImmediate(&es);
        try expect(e.destroyImmediate(&es));
        try expect(!e.changeArchImmediate(&es, .{
            .add = &.{
                .init(RigidBody, &.{ .mass = 0.5 }),
                .init(Model, &.{ .vertex_start = 20 }),
            },
            .remove = CompFlag.set(&.{CompFlag.registerImmediate(typeId(Tag))}),
        }));
        try expectEqual(null, e.getComp(&es, RigidBody));
        try expectEqual(null, e.getComp(&es, Model));
        try expectEqual(null, e.getComp(&es, Tag));

        try expect(!e.changeArchImmediate(&es, .{}));
        try expectEqual(null, e.getComp(&es, RigidBody));
        try expectEqual(null, e.getComp(&es, Model));
        try expectEqual(null, e.getComp(&es, Tag));

        try expect(!try e.changeArchUninitImmediateOrErr(&es, .{
            .add = .{},
            .remove = .{},
        }));
        try expectEqual(null, e.getComp(&es, RigidBody));
        try expectEqual(null, e.getComp(&es, Model));
        try expectEqual(null, e.getComp(&es, Tag));
    }
}

test "getAll" {
    defer CompFlag.unregisterAll();
    var es = try Entities.init(gpa, .{ .max_entities = 100, .comp_bytes = 100 });
    defer es.deinit(gpa);
    const e = Entity.reserveImmediate(&es);
    // Should register two types
    try expect(e.changeArchImmediate(&es, .{ .add = &.{
        Any.init(RigidBody, &.{}),
        Any.init(Model, &.{}),
    } }));
    // Should not result in a registration
    _ = typeId(i32);
    var cmds = try CmdBuf.init(gpa, &es, .{ .cmds = 24, .avg_any_bytes = @sizeOf(RigidBody) });
    defer cmds.deinit(gpa, &es);
    e.eventCmd(&cmds, BarEv, .{ .bar = 1 });
    cmds.execImmediate(&es);

    const registered = CompFlag.getAll();
    try std.testing.expectEqual(2, registered.len);
    for (registered, 0..) |id, i| {
        if (id == typeId(RigidBody)) {
            try expectEqual(id.*, TypeInfo{
                .name = @typeName(RigidBody),
                .size = @sizeOf(RigidBody),
                .alignment = @alignOf(RigidBody),
                .comp_flag = @enumFromInt(i),
            });
        } else if (id == typeId(Model)) {
            try expectEqual(id.*, TypeInfo{
                .name = @typeName(Model),
                .size = @sizeOf(Model),
                .alignment = @alignOf(Model),
                .comp_flag = @enumFromInt(i),
            });
        } else std.debug.panic("unexpected registration: {}", .{id.*});
    }
}

test "entity overflow" {
    defer CompFlag.unregisterAll();
    var es = try Entities.init(gpa, .{ .max_entities = 3, .comp_bytes = 4 });
    defer es.deinit(gpa);

    const e0 = Entity.reserveImmediate(&es);
    _ = Entity.reserveImmediate(&es);
    _ = Entity.reserveImmediate(&es);
    try expectError(error.ZcsEntityOverflow, Entity.reserveImmediateOrErr(&es));

    try expect(e0.changeArchImmediate(&es, .{ .add = &.{
        .init(u32, &0),
    } }));
    try expectError(error.ZcsCompOverflow, e0.changeArchImmediateOrErr(&es, .{ .add = &.{
        .init(u128, &0),
    } }));
}
