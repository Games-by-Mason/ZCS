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
const FooExt = types.FooExt;
const BarExt = types.BarExt;
const BazExt = types.BazExt;

const Components = struct {
    model: ?Model = null,
    rb: ?RigidBody = null,
    tag: ?Tag = null,
};

test "cb execImmediate" {
    defer CompFlag.unregisterAll();

    var xoshiro_256: std.Random.Xoshiro256 = .init(0);
    const rand = xoshiro_256.random();

    var es = try Entities.init(gpa, .{
        .max_entities = 100,
        .comp_bytes = 100,
        .max_archetypes = 8,
    });
    defer es.deinit(gpa);

    // Check some entity equality stuff not tested elsewhere, OrErr more extensively in slot map
    try expect(Entity.Optional.none == Entity.Optional.none);
    try expectEqual(null, Entity.Optional.none.unwrap());

    var capacity: CmdBuf.GranularCapacity = .init(.{
        .cmds = 4,
        .avg_cmd_bytes = @sizeOf(RigidBody),
    });
    capacity.reserved = 0;
    var cb = try CmdBuf.initGranularCapacity(gpa, &es, capacity);
    defer cb.deinit(gpa, &es);

    try expectEqual(0, es.count());

    const e0 = Entity.reserveImmediate(&es);
    const e1 = Entity.reserveImmediate(&es);
    const e2 = Entity.reserveImmediate(&es);
    const e3 = Entity.reserveImmediate(&es);
    e0.commit(&cb);
    e1.commit(&cb);
    const rb = RigidBody.random(rand);
    const model = Model.random(rand);
    e3.destroy(&cb);
    e2.add(&cb, RigidBody, rb);
    try expectEqual(4, es.reserved());
    try expectEqual(0, es.count());
    cb.execImmediate(&es);
    try expectEqual(0, es.reserved());
    try expectEqual(3, es.count());
    cb.clear(&es);

    var iter = es.iterator(.{});

    try expect(iter.next().? == e0);
    try expectEqual(null, e0.get(&es, RigidBody));
    try expectEqual(null, e0.get(&es, Model));
    try expectEqual(null, e0.get(&es, Tag));

    try expect(e1 == iter.next().?);
    try expectEqual(null, e1.get(&es, RigidBody));
    try expectEqual(null, e1.get(&es, Model));
    try expectEqual(null, e1.get(&es, Tag));

    try expect(e2 == iter.next().?);
    try expectEqual(rb, e2.get(&es, RigidBody).?.*);
    try expectEqual(null, e2.get(&es, Model));
    try expectEqual(null, e2.get(&es, Tag));

    try expectEqual(null, iter.next());

    // We don't check eql anywhere else, quickly check it here. The details are tested more
    // extensively on slot map.
    try expect(e1 == e1);
    try expect(e1 != e2);
    try expect(e1.toOptional() != Entity.Optional.none);
    try expect(e1.toOptional().unwrap().? == e1);

    e0.remove(&cb, RigidBody);
    e1.remove(&cb, RigidBody);
    e2.add(&cb, Model, model);
    e2.remove(&cb, RigidBody);
    cb.execImmediate(&es);
    cb.clear(&es);

    try expectEqual(3, es.count());

    try expectEqual(null, e0.get(&es, RigidBody));
    try expectEqual(null, e0.get(&es, Model));
    try expectEqual(null, e0.get(&es, Tag));

    try expectEqual(null, e1.get(&es, RigidBody));
    try expectEqual(null, e1.get(&es, Model));
    try expectEqual(null, e1.get(&es, Tag));

    try expectEqual(null, e2.get(&es, RigidBody));
    try expectEqual(model, e2.get(&es, Model).?.*);
    try expectEqual(null, e2.get(&es, Tag));
}

fn isInAnyBytes(cb: CmdBuf, data: anytype) bool {
    const bytes = std.mem.asBytes(data);
    const any_bytes = cb.any_bytes.items;
    const start = @intFromPtr(any_bytes.ptr);
    const end = start + any_bytes.len;
    const addr_start = @intFromPtr(bytes.ptr);
    const addr_end = addr_start + bytes.len;
    return addr_start >= start and addr_end <= end;
}

// Verify that components are interned appropriately
test "cb interning" {
    defer CompFlag.unregisterAll();
    // Assumed by this test (affects cb submission order.) If this fails, just adjust the types to
    // make it true and the rest of the test should pass.
    comptime assert(@alignOf(RigidBody) > @alignOf(Model));
    comptime assert(@alignOf(Model) > @alignOf(Tag));

    var xoshiro_256: std.Random.Xoshiro256 = .init(0);
    const rand = xoshiro_256.random();

    var es = try Entities.init(gpa, .{
        .max_entities = 100,
        .comp_bytes = 4096,
        .max_archetypes = 8,
    });
    defer es.deinit(gpa);

    var cb = try CmdBuf.init(gpa, &es, .{ .cmds = 24, .avg_cmd_bytes = @sizeOf(RigidBody) });
    defer cb.deinit(gpa, &es);

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
    const foo_ev_interned: FooExt = .{
        .foo = .{ 3.3, 4.4, 5.5 },
    };
    const foo_ev_value = FooExt.random(rand);
    const bar_ev_interned: BarExt = .{
        .bar = 123,
    };
    const bar_ev_value = BarExt.random(rand);

    const e0: Entity = .reserveImmediate(&es);
    const e1: Entity = .reserveImmediate(&es);
    const e2: Entity = .reserveImmediate(&es);

    // Automatic interning
    e0.add(&cb, Model, model_value);
    e0.add(&cb, RigidBody, rb_interned);
    e0.cmd(&cb, BarExt, bar_ev_value);
    e0.cmd(&cb, FooExt, foo_ev_interned);

    e1.add(&cb, Model, model_interned);
    e1.add(&cb, RigidBody, rb_value);
    e1.cmd(&cb, BarExt, bar_ev_interned);
    e1.cmd(&cb, FooExt, foo_ev_value);

    // Explicit by value
    try e0.addAnyVal(&cb, .init(Model, &model_value));
    try e0.addAnyVal(&cb, .init(RigidBody, &rb_interned));
    try e0.cmdAnyVal(&cb, .init(BarExt, &bar_ev_value));
    try e0.cmdAnyVal(&cb, .init(FooExt, &foo_ev_interned));

    try e1.addAnyVal(&cb, .init(Model, &model_interned));
    try e1.addAnyVal(&cb, .init(RigidBody, &rb_value));
    try e1.cmdAnyVal(&cb, .init(BarExt, &bar_ev_interned));
    try e1.cmdAnyVal(&cb, .init(FooExt, &foo_ev_value));

    // Throw in a destroy for good measure, verify the components end up in the remove flags
    try expect(e2.changeArchImmediate(&es, .{
        .add = &.{ .init(RigidBody, &.{ .mass = 1.0 }), .init(Model, &.{ .vertex_start = 2 }) },
        .remove = .initEmpty(),
    }));
    e2.destroy(&cb);

    // Explicit interning
    try e0.addAnyPtr(&cb, .init(RigidBody, &rb_interned));
    try e0.addAnyPtr(&cb, .init(Model, &model_interned));
    try e0.cmdAnyPtr(&cb, .init(BarExt, &bar_ev_interned));
    try e0.cmdAnyPtr(&cb, .init(FooExt, &foo_ev_interned));

    // Zero sized types
    e1.add(&cb, Tag, .{});
    try e1.addAnyVal(&cb, .init(Tag, &.{}));
    try e1.addAnyPtr(&cb, .init(Tag, &.{}));
    e1.cmd(&cb, BazExt, .{});
    try e1.cmdAnyVal(&cb, .init(BazExt, &.{}));
    try e1.cmdAnyPtr(&cb, .init(BazExt, &.{}));

    // Test the results
    var iter = cb.iterator();

    {
        const cmd = iter.next().?;
        try expectEqual(e0, cmd.entity);
        const arch_change = cmd.getArchChangeImmediate(&es);
        try expectEqual(CompFlag.Set.initMany(&.{
            CompFlag.registerImmediate(typeId(Model)),
            CompFlag.registerImmediate(typeId(RigidBody)),
        }), arch_change.add);
        try expectEqual(CompFlag.Set.initMany(&.{}), arch_change.remove);
        try expect(!arch_change.destroy);
        var batches = cmd.iterator();
        const comp1 = batches.next().?.add;
        try expect(isInAnyBytes(cb, comp1.as(Model).?));
        try expectEqual(model_value, comp1.as(Model).?.*);
        const comp2 = batches.next().?.add;
        try expect(!isInAnyBytes(cb, comp2.as(RigidBody).?));
        try expectEqual(rb_interned, comp2.as(RigidBody).?.*);
        const ev1 = batches.next().?.ext;
        try expect(isInAnyBytes(cb, ev1.as(BarExt).?));
        try expectEqual(bar_ev_value, ev1.as(BarExt).?.*);
        const ev2 = batches.next().?.ext;
        try expect(!isInAnyBytes(cb, ev2.as(FooExt).?));
        try expectEqual(foo_ev_interned, ev2.as(FooExt).?.*);
        try expectEqual(null, batches.next());
    }
    {
        const cmd = iter.next().?;
        const arch_change = cmd.getArchChangeImmediate(&es);
        try expectEqual(CompFlag.Set.initMany(&.{
            CompFlag.registerImmediate(typeId(Model)),
            CompFlag.registerImmediate(typeId(RigidBody)),
        }), arch_change.add);
        try expectEqual(CompFlag.Set.initMany(&.{}), arch_change.remove);
        try expect(!arch_change.destroy);
        try expectEqual(e1, cmd.entity);
        var batches = cmd.iterator();
        const comp1 = batches.next().?.add;
        try expect(isInAnyBytes(cb, comp1.as(Model).?)); // By value because it's too small!
        try expectEqual(model_interned, comp1.as(Model).?.*);
        const comp2 = batches.next().?.add;
        try expect(isInAnyBytes(cb, comp2.as(RigidBody).?));
        try expectEqual(rb_value, comp2.as(RigidBody).?.*);
        const ev1 = batches.next().?.ext;
        try expect(isInAnyBytes(cb, ev1.as(BarExt).?)); // By value because it's too small!
        try expectEqual(bar_ev_interned, ev1.as(BarExt).?.*);
        const ev2 = batches.next().?.ext;
        try expect(isInAnyBytes(cb, ev2.as(FooExt).?));
        try expectEqual(foo_ev_value, ev2.as(FooExt).?.*);
        try expectEqual(null, batches.next());
    }
    {
        const cmd = iter.next().?;
        const arch_change = cmd.getArchChangeImmediate(&es);
        try expectEqual(CompFlag.Set.initMany(&.{
            CompFlag.registerImmediate(typeId(Model)),
            CompFlag.registerImmediate(typeId(RigidBody)),
        }), arch_change.add);
        try expectEqual(CompFlag.Set.initMany(&.{}), arch_change.remove);
        try expect(!arch_change.destroy);
        try expectEqual(e0, cmd.entity);
        var batches = cmd.iterator();
        const comp1 = batches.next().?.add;
        try expect(isInAnyBytes(cb, comp1.as(Model).?));
        try expectEqual(model_value, comp1.as(Model).?.*);
        const comp2 = batches.next().?.add;
        try expect(isInAnyBytes(cb, comp2.as(RigidBody).?));
        try expectEqual(rb_interned, comp2.as(RigidBody).?.*);
        const ev1 = batches.next().?.ext;
        try expect(isInAnyBytes(cb, ev1.as(BarExt).?));
        try expectEqual(bar_ev_value, ev1.as(BarExt).?.*);
        const ev2 = batches.next().?.ext;
        try expect(isInAnyBytes(cb, ev2.as(FooExt).?));
        try expectEqual(foo_ev_interned, ev2.as(FooExt).?.*);
        try expectEqual(null, batches.next());
    }
    {
        const cmd = iter.next().?;
        const arch_change = cmd.getArchChangeImmediate(&es);
        try expectEqual(CompFlag.Set.initMany(&.{
            CompFlag.registerImmediate(typeId(Model)),
            CompFlag.registerImmediate(typeId(RigidBody)),
        }), arch_change.add);
        try expectEqual(CompFlag.Set.initMany(&.{}), arch_change.remove);
        try expect(!arch_change.destroy);
        try expectEqual(e1, cmd.entity);
        var batches = cmd.iterator();
        const comp1 = batches.next().?.add;
        try expect(isInAnyBytes(cb, comp1.as(Model).?));
        try expectEqual(model_interned, comp1.as(Model).?.*);
        const comp2 = batches.next().?.add;
        try expect(isInAnyBytes(cb, comp2.as(RigidBody).?));
        try expectEqual(rb_value, comp2.as(RigidBody).?.*);
        const ev1 = batches.next().?.ext;
        try expect(isInAnyBytes(cb, ev1.as(BarExt).?));
        try expectEqual(bar_ev_interned, ev1.as(BarExt).?.*);
        const ev2 = batches.next().?.ext;
        try expect(isInAnyBytes(cb, ev2.as(FooExt).?));
        try expectEqual(foo_ev_value, ev2.as(FooExt).?.*);
        try expectEqual(null, batches.next());
    }
    {
        const cmd = iter.next().?;
        const arch_change = cmd.getArchChangeImmediate(&es);
        try expectEqual(e2, cmd.entity);
        try expectEqual(CompFlag.Set.initEmpty(), arch_change.add);
        try expectEqual(CompFlag.Set.initMany(&.{
            CompFlag.registerImmediate(typeId(Model)),
            CompFlag.registerImmediate(typeId(RigidBody)),
        }), arch_change.remove);
        try expect(arch_change.destroy);
        var batches = cmd.iterator();
        try expectEqual(.destroy, batches.next());
        try expectEqual(null, batches.next());
    }
    {
        const cmd = iter.next().?;
        const arch_change = cmd.getArchChangeImmediate(&es);
        try expectEqual(CompFlag.Set.initMany(&.{
            CompFlag.registerImmediate(typeId(Model)),
            CompFlag.registerImmediate(typeId(RigidBody)),
        }), arch_change.add);
        try expectEqual(CompFlag.Set.initMany(&.{}), arch_change.remove);
        try expect(!arch_change.destroy);
        try expectEqual(e0, cmd.entity);
        var batches = cmd.iterator();
        const comp1 = batches.next().?.add;
        try expect(!isInAnyBytes(cb, comp1.as(RigidBody).?));
        try expectEqual(rb_interned, comp1.as(RigidBody).?.*);
        const comp2 = batches.next().?.add;
        try expect(!isInAnyBytes(cb, comp2.as(Model).?));
        try expectEqual(model_interned, comp2.as(Model).?.*);
        const ev1 = batches.next().?.ext;
        try expect(!isInAnyBytes(cb, ev1.as(BarExt).?));
        try expectEqual(bar_ev_interned, ev1.as(BarExt).?.*);
        const ev2 = batches.next().?.ext;
        try expect(!isInAnyBytes(cb, ev2.as(FooExt).?));
        try expectEqual(foo_ev_interned, ev2.as(FooExt).?.*);
        try expectEqual(null, batches.next());
    }
    {
        const cmd = iter.next().?;
        const arch_change = cmd.getArchChangeImmediate(&es);
        try expectEqual(CompFlag.Set.initMany(&.{
            CompFlag.registerImmediate(typeId(Tag)),
        }), arch_change.add);
        try expectEqual(CompFlag.Set.initMany(&.{}), arch_change.remove);
        try expect(!arch_change.destroy);
        try expectEqual(e1, cmd.entity);
        var batches = cmd.iterator();
        const comp1 = batches.next().?.add;
        try expect(isInAnyBytes(cb, comp1.as(Tag).?));
        try expectEqual(Tag{}, comp1.as(Tag).?.*);
        const comp2 = batches.next().?.add;
        try expect(isInAnyBytes(cb, comp2.as(Tag).?));
        try expectEqual(Tag{}, comp2.as(Tag).?.*);
        const comp3 = batches.next().?.add;
        try expect(!isInAnyBytes(cb, comp3.as(Tag).?));
        try expectEqual(Tag{}, comp3.as(Tag).?.*);
        const ev1 = batches.next().?.ext;
        try expect(isInAnyBytes(cb, ev1.as(BazExt).?));
        try expectEqual(BazExt{}, ev1.as(BazExt).?.*);
        const ev2 = batches.next().?.ext;
        try expect(isInAnyBytes(cb, ev2.as(BazExt).?));
        try expectEqual(BazExt{}, ev2.as(BazExt).?.*);
        const ev3 = batches.next().?.ext;
        try expect(!isInAnyBytes(cb, ev3.as(BazExt).?));
        try expectEqual(BazExt{}, ev3.as(BazExt).?.*);
        try expectEqual(null, batches.next());
    }

    try expectEqual(null, iter.next());
}

test "cb overflow" {
    defer CompFlag.unregisterAll();
    // Not very exhaustive, but checks that command buffers return the overflow error on failure to
    // append, and on submits that fail.

    var xoshiro_256: std.Random.Xoshiro256 = .init(0);
    const rand = xoshiro_256.random();

    var es = try Entities.init(gpa, .{
        .max_entities = 100,
        .comp_bytes = 100,
        .max_archetypes = 8,
    });
    defer es.deinit(gpa);

    // Tag overflow
    {
        var cb = try CmdBuf.initGranularCapacity(gpa, &es, .{
            .tags = 0,
            .args = 100,
            .any_bytes = 100,
            .reserved = 0,
        });
        defer cb.deinit(gpa, &es);

        try expectError(
            error.ZcsCmdBufOverflow,
            Entity.reserveImmediate(&es).commitOrErr(&cb),
        );
        try expectError(
            error.ZcsCmdBufOverflow,
            Entity.reserveImmediate(&es).destroyOrErr(&cb),
        );

        try expectEqual(1.0, cb.worstCaseUsage());

        var iter = cb.iterator();
        try expectEqual(null, iter.next());
    }

    // Arg overflow
    {
        var cb = try CmdBuf.initGranularCapacity(gpa, &es, .{
            .tags = 100,
            .args = 0,
            .any_bytes = 100,
            .reserved = 0,
        });
        defer cb.deinit(gpa, &es);

        try expectError(
            error.ZcsCmdBufOverflow,
            Entity.reserveImmediate(&es).commitOrErr(&cb),
        );
        const e = Entity.reserveImmediate(&es);
        const tags = cb.tags.items.len;
        const args = cb.args.items.len;
        try expectError(error.ZcsCmdBufOverflow, e.destroyOrErr(&cb));
        try expectEqual(tags, cb.tags.items.len);
        try expectEqual(args, cb.args.items.len);

        try expectEqual(1.0, cb.worstCaseUsage());

        var iter = cb.iterator();
        try expectEqual(null, iter.next());
    }

    // Comp data overflow
    {
        var cb = try CmdBuf.initGranularCapacity(gpa, &es, .{
            .tags = 100,
            .args = 100,
            .any_bytes = @sizeOf(RigidBody) * 2 - 1,
            .reserved = 0,
        });
        defer cb.deinit(gpa, &es);

        const e: Entity = Entity.reserveImmediate(&es);
        const rb = RigidBody.random(rand);

        _ = Entity.reserveImmediate(&es).add(&cb, RigidBody, rb);
        e.destroy(&cb);
        try expectError(error.ZcsCmdBufOverflow, e.addOrErr(
            &cb,
            RigidBody,
            RigidBody.random(rand),
        ));

        try expectEqual(
            @as(f32, @sizeOf(RigidBody)) / @as(f32, @sizeOf(RigidBody) * 2 - 1),
            cb.worstCaseUsage(),
        );

        var iter = cb.iterator();

        {
            const cmd = iter.next().?;
            var batches = cmd.iterator();
            const create_rb = batches.next().?.add;
            try expectEqual(typeId(RigidBody), create_rb.id);
            try expectEqual(rb, create_rb.as(RigidBody).?.*);
            try expectEqual(null, batches.next());
        }

        {
            const cmd = iter.next().?;
            const arch_change = cmd.getArchChangeImmediate(&es);
            try expectEqual(e, cmd.entity);
            try expectEqual(CompFlag.Set.initMany(&.{}), arch_change.add);
            try expectEqual(CompFlag.Set.initMany(&.{}), arch_change.remove);
            try expect(arch_change.destroy);
            var batches = cmd.iterator();
            try expectEqual(.destroy, batches.next());
            try expectEqual(null, batches.next());
        }

        try expectEqual(null, iter.next());
    }

    // Extension data overflow
    {
        var cb = try CmdBuf.initGranularCapacity(gpa, &es, .{
            .tags = 100,
            .args = 100,
            .any_bytes = @sizeOf(FooExt) * 2 - 1,
            .reserved = 0,
        });
        defer cb.deinit(gpa, &es);

        const e: Entity = Entity.reserveImmediate(&es);
        const foo = FooExt.random(rand);

        _ = Entity.reserveImmediate(&es).cmd(&cb, FooExt, foo);
        e.destroy(&cb);
        try expectError(error.ZcsCmdBufOverflow, e.cmdOrErr(
            &cb,
            FooExt,
            FooExt.random(rand),
        ));

        try expectEqual(@as(f32, @sizeOf(FooExt)) / @as(f32, @sizeOf(FooExt) * 2 - 1), cb.worstCaseUsage());

        var iter = cb.iterator();

        {
            const cmd = iter.next().?;
            var batches = cmd.iterator();
            const create_foo = batches.next().?.ext;
            try expectEqual(typeId(FooExt), create_foo.id);
            try expectEqual(foo, create_foo.as(FooExt).?.*);
            try expectEqual(null, batches.next());
        }

        {
            const cmd = iter.next().?;
            const arch_change = cmd.getArchChangeImmediate(&es);
            try expectEqual(e, cmd.entity);
            try expectEqual(CompFlag.Set.initMany(&.{}), arch_change.add);
            try expectEqual(CompFlag.Set.initMany(&.{}), arch_change.remove);
            try expect(arch_change.destroy);
            var batches = cmd.iterator();
            try expectEqual(.destroy, batches.next());
            try expectEqual(null, batches.next());
        }

        try expectEqual(null, iter.next());
    }

    // Reserved underflow
    {
        var cb = try CmdBuf.initGranularCapacity(gpa, &es, .{
            .tags = 100,
            .args = 100,
            .any_bytes = @sizeOf(RigidBody) * 2 - 1,
            .reserved = 2,
        });
        defer cb.deinit(gpa, &es);

        _ = try Entity.reserveOrErr(&cb);
        _ = try Entity.reserveOrErr(&cb);
        try expectError(error.ZcsReservedEntityUnderflow, Entity.reserveOrErr(&cb));
    }

    // Calling some things just to make sure they compile that we don't test elsewhere
    var cb = try CmdBuf.initGranularCapacity(gpa, &es, .{
        .tags = 100,
        .args = 100,
        .any_bytes = @sizeOf(RigidBody) * 2 - 1,
        .reserved = 0,
    });
    defer cb.deinit(gpa, &es);
    const e = Entity.reserveImmediate(&es);
    try expect(e.changeArchImmediate(&es, .{}));
    try e.addAnyVal(&cb, .init(RigidBody, &.{}));
    try e.addAnyPtr(&cb, .init(RigidBody, &.{}));
    try expect(!e.has(&es, Model));
    _ = Entity.reserveImmediate(&es);
    try expect(es.count() > 0);
    try expect(es.reserved() > 0);
    es.recycleImmediate();
    try expectEqual(0, es.count());
    try expectEqual(0, es.reserved());
}

// Verify that command buffers don't overflow before their estimated capacity
test "cb capacity" {
    defer CompFlag.unregisterAll();

    const cb_capacity = 600;

    var es = try Entities.init(gpa, .{
        .max_entities = cb_capacity * 10,
        .comp_bytes = cb_capacity * 10,
        .max_archetypes = 8,
    });
    defer es.deinit(gpa);

    var cb = try CmdBuf.init(gpa, &es, .{ .cmds = cb_capacity, .avg_cmd_bytes = 22 });
    defer cb.deinit(gpa, &es);

    // Change archetype
    {
        // Add val
        const e0 = Entity.reserveImmediate(&es);
        const e1 = Entity.reserveImmediate(&es);

        for (0..cb_capacity / 12) |_| {
            try e0.addAnyVal(&cb, .init(u0, &0));
            try e1.addAnyVal(&cb, .init(u8, &0));
            try e0.addAnyVal(&cb, .init(u16, &0));
            try e1.addAnyVal(&cb, .init(u32, &0));
            try e0.addAnyVal(&cb, .init(u64, &0));
            try e1.addAnyVal(&cb, .init(u128, &0));
        }

        try expect(cb.worstCaseUsage() < 1.0);
        cb.clear(&es);

        for (0..cb_capacity / 6) |_| {
            try e0.addAnyVal(&cb, .init(u0, &0));
            try e1.addAnyVal(&cb, .init(u8, &0));
            try e0.addAnyVal(&cb, .init(u16, &0));
            try e1.addAnyVal(&cb, .init(u32, &0));
            try e0.addAnyVal(&cb, .init(u64, &0));
            try e1.addAnyVal(&cb, .init(u128, &0));
        }

        try expectEqual(1.0, cb.worstCaseUsage());
        cb.clear(&es);

        // Add ptr
        for (0..cb_capacity / 12) |_| {
            try e0.addAnyPtr(&cb, .init(u0, &0));
            try e1.addAnyPtr(&cb, .init(u8, &0));
            try e0.addAnyPtr(&cb, .init(u16, &0));
            try e1.addAnyPtr(&cb, .init(u32, &0));
            try e0.addAnyPtr(&cb, .init(u64, &0));
            try e1.addAnyPtr(&cb, .init(u128, &0));
        }

        try expect(cb.worstCaseUsage() < 1.0);
        cb.clear(&es);

        for (0..cb_capacity / 6) |_| {
            try e0.addAnyPtr(&cb, .init(u0, &0));
            try e1.addAnyPtr(&cb, .init(u8, &0));
            try e0.addAnyPtr(&cb, .init(u16, &0));
            try e1.addAnyPtr(&cb, .init(u32, &0));
            try e0.addAnyPtr(&cb, .init(u64, &0));
            try e1.addAnyPtr(&cb, .init(u128, &0));
        }

        try expectEqual(1.0, cb.worstCaseUsage());
        cb.clear(&es);

        // Remove
        for (0..cb_capacity / 12) |_| {
            e0.remove(&cb, u0);
            e1.remove(&cb, u8);
            e0.remove(&cb, u16);
            e1.remove(&cb, u32);
            e0.remove(&cb, u64);
            e1.remove(&cb, u128);
        }

        try expect(cb.worstCaseUsage() < 1.0);
        cb.clear(&es);

        for (0..cb_capacity / 6) |_| {
            e0.remove(&cb, u0);
            e1.remove(&cb, u8);
            e0.remove(&cb, u16);
            e1.remove(&cb, u32);
            e0.remove(&cb, u64);
            e1.remove(&cb, u128);
        }

        try expectEqual(1.0, cb.worstCaseUsage());
        cb.clear(&es);
    }

    // Extensions
    {
        // Extension val
        const e0 = Entity.reserveImmediate(&es);
        const e1 = Entity.reserveImmediate(&es);

        for (0..cb_capacity / 12) |_| {
            try e0.cmdAnyVal(&cb, .init(u0, &0));
            try e1.cmdAnyVal(&cb, .init(u8, &0));
            try e0.cmdAnyVal(&cb, .init(u16, &0));
            try e1.cmdAnyVal(&cb, .init(u32, &0));
            try e0.cmdAnyVal(&cb, .init(u64, &0));
            try e1.cmdAnyVal(&cb, .init(u128, &0));
        }

        try expect(cb.worstCaseUsage() < 1.0);
        cb.clear(&es);

        for (0..cb_capacity / 6) |_| {
            try e0.cmdAnyVal(&cb, .init(u0, &0));
            try e1.cmdAnyVal(&cb, .init(u8, &0));
            try e0.cmdAnyVal(&cb, .init(u16, &0));
            try e1.cmdAnyVal(&cb, .init(u32, &0));
            try e0.cmdAnyVal(&cb, .init(u64, &0));
            try e1.cmdAnyVal(&cb, .init(u128, &0));
        }

        try expectEqual(1.0, cb.worstCaseUsage());
        cb.clear(&es);

        // Extension ptr
        for (0..cb_capacity / 12) |_| {
            try e0.cmdAnyPtr(&cb, .init(u0, &0));
            try e1.cmdAnyPtr(&cb, .init(u8, &0));
            try e0.cmdAnyPtr(&cb, .init(u16, &0));
            try e1.cmdAnyPtr(&cb, .init(u32, &0));
            try e0.cmdAnyPtr(&cb, .init(u64, &0));
            try e1.cmdAnyPtr(&cb, .init(u128, &0));
        }

        try expect(cb.worstCaseUsage() < 1.0);
        cb.clear(&es);

        for (0..cb_capacity / 6) |_| {
            try e0.cmdAnyPtr(&cb, .init(u0, &0));
            try e1.cmdAnyPtr(&cb, .init(u8, &0));
            try e0.cmdAnyPtr(&cb, .init(u16, &0));
            try e1.cmdAnyPtr(&cb, .init(u32, &0));
            try e0.cmdAnyPtr(&cb, .init(u64, &0));
            try e1.cmdAnyPtr(&cb, .init(u128, &0));
        }

        try expectEqual(1.0, cb.worstCaseUsage());
        cb.clear(&es);
    }

    // Destroy
    {
        for (0..cb_capacity) |i| {
            const e: Entity = .{ .key = .{
                .index = @intCast(i),
                .generation = @enumFromInt(1),
            } };
            try e.destroyOrErr(&cb);
        }

        try expect(cb.worstCaseUsage() == 1.0);
        cb.clear(&es);

        for (0..cb_capacity) |i| {
            const e: Entity = .{ .key = .{
                .index = @intCast(i),
                .generation = @enumFromInt(1),
            } };
            try e.destroyOrErr(&cb);
        }

        try expectEqual(1.0, cb.worstCaseUsage());
        cb.clear(&es);
    }

    // Destroy
    {
        for (0..cb_capacity) |_| {
            _ = try Entity.reserveOrErr(&cb);
        }

        try expectEqual(1.0, cb.worstCaseUsage());
        cb.clear(&es);
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
    var es = try Entities.init(gpa, .{
        .max_entities = 100,
        .comp_bytes = 100,
        .max_archetypes = 8,
    });
    defer es.deinit(gpa);

    {
        const e = Entity.reserveImmediate(&es);
        try expect(e.changeArchImmediate(&es, .{
            .add = &.{ .init(RigidBody, &.{ .mass = 1.0 }), .init(Model, &.{ .vertex_start = 2 }) },
            .remove = CompFlag.Set.initMany(&.{CompFlag.registerImmediate(typeId(RigidBody))}),
        }));
        try expectEqual(Model{ .vertex_start = 2 }, e.get(&es, Model).?.*);
        try expectEqual(null, e.get(&es, RigidBody));
        try expectEqual(null, e.get(&es, Tag));
    }

    {
        const e = Entity.reserveImmediate(&es);
        try expect(e.changeArchImmediate(&es, .{
            .add = &.{
                .init(RigidBody, &.{ .mass = 0.5 }),
                .init(Model, &.{ .vertex_start = 20 }),
            },
            .remove = CompFlag.Set.initMany(&.{CompFlag.registerImmediate(typeId(Tag))}),
        }));
        try expectEqual(RigidBody{ .mass = 0.5 }, e.get(&es, RigidBody).?.*);
        try expectEqual(Model{ .vertex_start = 20 }, e.get(&es, Model).?.*);
        try expectEqual(null, e.get(&es, Tag));
    }

    {
        const e = Entity.reserveImmediate(&es);
        try expect(e.destroyImmediate(&es));
        try expect(!e.changeArchImmediate(&es, .{
            .add = &.{
                .init(RigidBody, &.{ .mass = 0.5 }),
                .init(Model, &.{ .vertex_start = 20 }),
            },
            .remove = CompFlag.Set.initMany(&.{CompFlag.registerImmediate(typeId(Tag))}),
        }));
        try expectEqual(null, e.get(&es, RigidBody));
        try expectEqual(null, e.get(&es, Model));
        try expectEqual(null, e.get(&es, Tag));

        try expect(!e.changeArchImmediate(&es, .{}));
        try expectEqual(null, e.get(&es, RigidBody));
        try expectEqual(null, e.get(&es, Model));
        try expectEqual(null, e.get(&es, Tag));

        try expect(!try e.changeArchUninitImmediateOrErr(&es, .{
            .add = .{},
            .remove = .{},
        }));
        try expectEqual(null, e.get(&es, RigidBody));
        try expectEqual(null, e.get(&es, Model));
        try expectEqual(null, e.get(&es, Tag));
    }
}

test "getAll" {
    defer CompFlag.unregisterAll();
    var es = try Entities.init(gpa, .{
        .max_entities = 100,
        .comp_bytes = 100,
        .max_archetypes = 8,
    });
    defer es.deinit(gpa);
    const e = Entity.reserveImmediate(&es);
    // Should register two types
    try expect(e.changeArchImmediate(&es, .{ .add = &.{
        Any.init(RigidBody, &.{}),
        Any.init(Model, &.{}),
    } }));
    // Should not result in a registration
    _ = typeId(i32);
    var cb = try CmdBuf.init(gpa, &es, .{ .cmds = 24, .avg_cmd_bytes = @sizeOf(RigidBody) });
    defer cb.deinit(gpa, &es);
    e.cmd(&cb, BarExt, .{ .bar = 1 });
    cb.execImmediate(&es);

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
    var es = try Entities.init(gpa, .{
        .max_entities = 3,
        .comp_bytes = 4,
        .max_archetypes = 8,
    });
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

test "archetype overflow" {
    defer CompFlag.unregisterAll();
    var es = try Entities.init(gpa, .{
        .max_entities = 3,
        .comp_bytes = 4,
        .max_archetypes = 3,
    });
    defer es.deinit(gpa);

    const e0 = Entity.reserveImmediate(&es);
    try expectEqual(0, es.archetype_lists.count());

    // Create three archetypes
    try expect(try e0.changeArchImmediateOrErr(&es, .{ .add = &.{
        .init(u1, &0),
    } }));
    try expectEqual(1, es.archetype_lists.count());

    try expect(try e0.changeArchImmediateOrErr(&es, .{ .add = &.{
        .init(u2, &0),
    } }));
    try expectEqual(2, es.archetype_lists.count());

    // Test that trying to create additional archetypes causes it to overflow
    try expectError(error.ZcsArchetypeOverflow, e0.changeArchImmediateOrErr(&es, .{ .add = &.{
        .init(u3, &0),
    } }));
    try expectError(error.ZcsArchetypeOverflow, e0.changeArchImmediateOrErr(&es, .{ .add = &.{
        .init(u3, &0),
    } }));
    try expectError(error.ZcsArchetypeOverflow, e0.changeArchImmediateOrErr(&es, .{ .add = &.{
        .init(u4, &0),
    } }));
    try expectEqual(2, es.archetype_lists.count());

    // Trying to create an archetype that already exists should be fine
    try expect(try e0.changeArchImmediateOrErr(&es, .{
        .remove = .initMany(&.{typeId(u2).comp_flag.?}),
    }));
    try expectEqual(2, es.archetype_lists.count());
    try expect(try e0.changeArchImmediateOrErr(&es, .{ .add = &.{
        .init(u2, &0),
    } }));
    try expectEqual(2, es.archetype_lists.count());
}

// This is a regression test. We do something a little tricky with zero sized types--we "allocate"
// them at the entity ID to make it possible to retrieve the entity again later
// (see `Entity.fromAny`). We had a bug in our first pass at this where a valid entity ID could have
// both an index and generation of zero, which would result in this pointer being null despite not
// being optional.
//
// This has since been fixed 0 is used as the invalid generation now, so all valid entity IDs are
// nonzero. This test just verifies the previously failing code path works since it wasn't exercised
// anywhere else.
test "zero sized Entity.from" {
    defer CompFlag.unregisterAll();
    var es = try Entities.init(gpa, .{
        .max_entities = 3,
        .comp_bytes = 4,
        .max_archetypes = 3,
    });
    defer es.deinit(gpa);

    const e0 = Entity.reserveImmediate(&es);
    try expectEqual(0, es.archetype_lists.count());

    try expect(e0.changeArchImmediate(&es, .{ .add = &.{
        .init(u0, &0),
    } }));

    try expectEqual(e0, Entity.from(&es, e0.get(&es, u0).?));
}
