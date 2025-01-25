//! Normal unit tests.

const std = @import("std");
const assert = std.debug.assert;
const zcs = @import("../root.zig");
const gpa = std.testing.allocator;
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;
const expectError = std.testing.expectError;

const RigidBody = struct {
    pub const name = "RigidBody";
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
    pub const name = "Model";
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
    pub const name = "Tag";

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

test "command buffers" {
    // Initialize
    var xoshiro_256: std.Random.Xoshiro256 = .init(0);
    const rand = xoshiro_256.random();

    const capacity = 100000;

    const comps: []const type = &.{ RigidBody, Model, Tag };

    var expected: std.AutoArrayHashMapUnmanaged(zcs.Entity, Components) = .{};
    defer expected.deinit(gpa);

    var actual = try zcs.Entities.init(gpa, capacity, comps);
    defer actual.deinit(gpa);

    // We do two passes, so that the second pass has a chance to read results from the first
    try checkRandomCmdBuf(rand, &expected, &actual);
    try checkRandomCmdBuf(rand, &expected, &actual);
    // Make sure we're not accidentally destroying so many entities that the test is not executing
    // many interesting paths
    try expect(actual.count() > 1000);
}

// The normal command buffer tests have a "key" component on every entity to simplify the tests,
// so here we just run a few tests to make sure that empty entities don't cause issues since
// they get no coverage there.
test "command buffer create empty" {
    var xoshiro_256: std.Random.Xoshiro256 = .init(0);
    const rand = xoshiro_256.random();

    var es = try zcs.Entities.init(gpa, 100, &.{ RigidBody, Model, Tag });
    defer es.deinit(gpa);

    // Check some entity equality stuff not tested elsewhere, checked more extensively in slot map
    try expect(zcs.Entity.none.eql(.none));
    try expect(!zcs.Entity.none.exists(&es));

    // Make sure we exercise the `toOptional` API and such
    const comp: zcs.Component = .init(&es, &Tag{});
    const comp_interned: zcs.Component = .init(&es, &Tag{});
    const comp_optional = comp.toOptional();
    const comp_optional_interned = comp.toOptional();
    try expect(!comp.interned);
    try expect(!comp_interned.interned);
    try expectEqual(comp, comp_optional.unwrap().?);
    try expectEqual(comp, comp_optional_interned.unwrap().?);

    var cb = try zcs.CmdBuf.initNoReserve(gpa, &es, 4);
    defer cb.deinit(gpa, &es);

    try expectEqual(0, es.count());

    const e0 = zcs.Entity.reserveImmediately(&es);
    const e1 = zcs.Entity.reserveImmediately(&es);
    const e2 = zcs.Entity.reserveImmediately(&es);
    e0.changeArchetypeCmd(&es, &cb, .{}, .{});
    e1.changeArchetypeCmdFromComponents(&es, &cb, .{}, &.{});
    const rb = RigidBody.random(rand);
    const model = Model.random(rand);
    e2.changeArchetypeCmd(&es, &cb, .{}, .{rb});
    try expectEqual(3, es.reserved());
    try expectEqual(0, es.count());
    cb.execute(&es);
    try expectEqual(0, es.reserved());
    try expectEqual(3, es.count());
    cb.clearWithoutRefill();

    var iter = es.iterator(.{});

    try expect(iter.next().?.eql(e0));
    try expectEqual(null, e0.getComponent(&es, RigidBody));
    try expectEqual(null, e0.getComponent(&es, Model));
    try expectEqual(null, e0.getComponent(&es, Tag));

    try expect(e1.eql(iter.next().?));
    try expectEqual(null, e1.getComponent(&es, RigidBody));
    try expectEqual(null, e1.getComponent(&es, Model));
    try expectEqual(null, e1.getComponent(&es, Tag));

    try expect(e2.eql(iter.next().?));
    try expectEqual(rb, e2.getComponent(&es, RigidBody).?.*);
    try expectEqual(null, e2.getComponent(&es, Model));
    try expectEqual(null, e2.getComponent(&es, Tag));

    try expectEqual(null, iter.next());

    // We don't check eql anywhere else, quickly check it here. The details are tested more
    // extensively on slot map.
    try expect(e1.eql(e1));
    try expect(!e1.eql(e2));
    try expect(!e1.eql(.none));

    e0.changeArchetypeCmd(&es, &cb, zcs.Component.flags(&es, &.{RigidBody}), .{});
    e1.changeArchetypeCmdFromComponents(&es, &cb, zcs.Component.flags(&es, &.{RigidBody}), &.{});
    e2.changeArchetypeCmd(&es, &cb, zcs.Component.flags(&es, &.{RigidBody}), .{model});
    cb.execute(&es);
    cb.clearWithoutRefill();

    try expectEqual(3, es.count());

    try expectEqual(null, e0.getComponent(&es, RigidBody));
    try expectEqual(null, e0.getComponent(&es, Model));
    try expectEqual(null, e0.getComponent(&es, Tag));

    try expectEqual(null, e1.getComponent(&es, RigidBody));
    try expectEqual(null, e1.getComponent(&es, Model));
    try expectEqual(null, e1.getComponent(&es, Tag));

    try expectEqual(null, e2.getComponent(&es, RigidBody));
    try expectEqual(model, e2.getComponent(&es, Model).?.*);
    try expectEqual(null, e2.getComponent(&es, Tag));
}

// Verify that fromComponents methods don't pass duplicate component data, this allows us to make
// our capacity guarantees
test "command buffer skip dups" {
    var es = try zcs.Entities.init(gpa, 100, &.{ RigidBody, Model, Tag });
    defer es.deinit(gpa);

    var cb = try zcs.CmdBuf.initNoReserve(gpa, &es, 24);
    defer cb.deinit(gpa, &es);

    const model1: Model = .{
        .vertex_start = 1,
        .vertex_count = 2,
    };
    const model2: Model = .{
        .vertex_start = 3,
        .vertex_count = 4,
    };

    const e0: zcs.Entity = .{ .key = .{ .index = 1, .generation = @enumFromInt(2) } };

    {
        defer cb.clearWithoutRefill();
        e0.changeArchetypeCmdFromComponents(
            &es,
            &cb,
            zcs.Component.flags(&es, &.{}),
            &.{
                .init(&es, &model1),
                .init(&es, &RigidBody{}),
                .init(&es, &model2),
                .none,
            },
        );
        var iter = cb.iterator(&es);
        const change_archetype = iter.next().?.change_archetype;
        try expectEqual(
            zcs.Component.Flags{},
            change_archetype.remove,
        );
        var comps = change_archetype.componentIterator();
        const comp1 = comps.next().?;
        try expect(!comp1.interned);
        try expectEqual(model2, comp1.as(&es, Model).?.*);
        const comp2 = comps.next().?;
        try expect(!comp2.interned);
        try expectEqual(RigidBody{}, comp2.as(&es, RigidBody).?.*);
    }
}

// Verify that components are interned appropriately
test "command buffer interning" {
    // Assumed by this test (affects cb submission order.) If this fails, just adjust the types to
    // make it true and the rest of the test should pass.
    comptime assert(@alignOf(RigidBody) > @alignOf(Model));
    comptime assert(@alignOf(Model) > @alignOf(Tag));

    var xoshiro_256: std.Random.Xoshiro256 = .init(0);
    const rand = xoshiro_256.random();

    var es = try zcs.Entities.init(gpa, 100, &.{ RigidBody, Model, Tag });
    defer es.deinit(gpa);

    var cb = try zcs.CmdBuf.initNoReserve(gpa, &es, 24);
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

    const rb_interned_optional: ?RigidBody = rb_interned;
    const rb_value_optional: ?RigidBody = rb_value;
    const model_interned_optional: ?Model = model_interned;
    const model_value_optional: ?Model = model_value;

    const rb_interned_null: ?RigidBody = null;
    const rb_value_null: ?RigidBody = null;
    const model_interned_null: ?Model = null;
    const model_value_null: ?Model = null;

    const e0: zcs.Entity = .{ .key = .{ .index = 1, .generation = @enumFromInt(2) } };
    const e1: zcs.Entity = .{ .key = .{ .index = 1, .generation = @enumFromInt(2) } };

    // Change archetype non optional
    e0.changeArchetypeCmd(
        &es,
        &cb,
        zcs.Component.flags(&es, &.{Tag}),
        .{ model_value, rb_interned },
    );
    e1.changeArchetypeCmd(
        &es,
        &cb,
        zcs.Component.flags(&es, &.{Tag}),
        .{ model_interned, rb_value },
    );
    e0.changeArchetypeCmdFromComponents(&es, &cb, zcs.Component.flags(&es, &.{Tag}), &.{
        .init(&es, &model_value),
        .initInterned(&es, &rb_interned),
    });
    e1.changeArchetypeCmdFromComponents(&es, &cb, zcs.Component.flags(&es, &.{Tag}), &.{
        .initInterned(&es, &model_interned),
        .init(&es, &rb_value),
    });

    // Change archetype optional
    e0.changeArchetypeCmd(
        &es,
        &cb,
        zcs.Component.flags(&es, &.{Tag}),
        .{ model_value_optional, rb_interned_optional },
    );
    e1.changeArchetypeCmd(
        &es,
        &cb,
        zcs.Component.flags(&es, &.{Tag}),
        .{ model_interned_optional, rb_value_optional },
    );
    e0.changeArchetypeCmdFromComponents(&es, &cb, zcs.Component.flags(&es, &.{Tag}), &.{
        .init(&es, &model_value_optional),
        .initInterned(&es, &rb_interned_optional),
    });
    e1.changeArchetypeCmdFromComponents(&es, &cb, zcs.Component.flags(&es, &.{Tag}), &.{
        .initInterned(&es, &model_interned_optional),
        .init(&es, &rb_value_optional),
    });

    // Change archetype null
    e0.changeArchetypeCmd(
        &es,
        &cb,
        zcs.Component.flags(&es, &.{Tag}),
        .{ model_value_null, rb_interned_null },
    );
    e1.changeArchetypeCmd(
        &es,
        &cb,
        zcs.Component.flags(&es, &.{Tag}),
        .{ model_interned_null, rb_value_null },
    );
    e0.changeArchetypeCmdFromComponents(&es, &cb, zcs.Component.flags(&es, &.{Tag}), &.{
        .init(&es, &model_value_null),
        .initInterned(&es, &rb_interned_null),
    });
    e1.changeArchetypeCmdFromComponents(&es, &cb, zcs.Component.flags(&es, &.{Tag}), &.{
        .initInterned(&es, &model_interned_null),
        .init(&es, &rb_value_null),
    });

    // Test the results
    {
        var iter = cb.iterator(&es);

        // Change archetype non optional
        {
            const cmd = iter.next().?.change_archetype;
            try expectEqual(e0, cmd.entity);
            try expectEqual(
                zcs.Component.flags(&es, &.{Tag}),
                cmd.remove,
            );
            // Components reordered due to alignment
            var comps = cmd.componentIterator();
            const comp1 = comps.next().?;
            try expect(comp1.interned);
            try expectEqual(rb_interned, comp1.as(&es, RigidBody).?.*);
            const comp2 = comps.next().?;
            try expect(!comp2.interned);
            try expectEqual(model_value, comp2.as(&es, Model).?.*);
            try expectEqual(null, comps.next());
        }
        {
            const cmd = iter.next().?.change_archetype;
            try expectEqual(e1, cmd.entity);
            try expectEqual(
                zcs.Component.flags(&es, &.{Tag}),
                cmd.remove,
            );
            // Components reordered due to alignment
            var comps = cmd.componentIterator();
            const comp1 = comps.next().?;
            try expect(!comp1.interned);
            try expectEqual(rb_value, comp1.as(&es, RigidBody).?.*);
            const comp2 = comps.next().?;
            try expect(!comp2.interned); // Not interned because it's too small!
            try expectEqual(model_interned, comp2.as(&es, Model).?.*);
            try expectEqual(null, comps.next());
        }
        {
            const cmd = iter.next().?.change_archetype;
            try expectEqual(e0, cmd.entity);
            try expectEqual(
                zcs.Component.flags(&es, &.{Tag}),
                cmd.remove,
            );
            // Comps are encoded in reverse order by *fromComponents methods
            var comps = cmd.componentIterator();
            const comp1 = comps.next().?;
            try expect(comp1.interned);
            try expectEqual(rb_interned, comp1.as(&es, RigidBody).?.*);
            const comp2 = comps.next().?;
            try expect(!comp2.interned);
            try expectEqual(model_value, comp2.as(&es, Model).?.*);
            try expectEqual(null, comps.next());
        }
        {
            const cmd = iter.next().?.change_archetype;
            try expectEqual(e1, cmd.entity);
            try expectEqual(
                zcs.Component.flags(&es, &.{Tag}),
                cmd.remove,
            );
            // Comps are encoded in reverse order by *fromComponents methods
            var comps = cmd.componentIterator();
            const comp1 = comps.next().?;
            try expect(!comp1.interned);
            try expectEqual(rb_value, comp1.as(&es, RigidBody).?.*);
            const comp2 = comps.next().?;
            // Low level API respects request regardless of size
            try expect(comp2.interned);
            try expectEqual(model_interned, comp2.as(&es, Model).?.*);
            try expectEqual(null, comps.next());
        }

        // Change archetype optional
        {
            const cmd = iter.next().?.change_archetype;
            try expectEqual(e0, cmd.entity);
            try expectEqual(
                zcs.Component.flags(&es, &.{Tag}),
                cmd.remove,
            );
            // Components reordered due to alignment
            var comps = cmd.componentIterator();
            const comp1 = comps.next().?;
            try expect(comp1.interned);
            try expectEqual(rb_interned, comp1.as(&es, RigidBody).?.*);
            const comp2 = comps.next().?;
            try expect(!comp2.interned);
            try expectEqual(model_value, comp2.as(&es, Model).?.*);
            try expectEqual(null, comps.next());
        }
        {
            const cmd = iter.next().?.change_archetype;
            try expectEqual(e1, cmd.entity);
            try expectEqual(
                zcs.Component.flags(&es, &.{Tag}),
                cmd.remove,
            );
            // Components reordered due to alignment
            var comps = cmd.componentIterator();
            const comp1 = comps.next().?;
            try expect(!comp1.interned);
            try expectEqual(rb_value, comp1.as(&es, RigidBody).?.*);
            const comp2 = comps.next().?;
            try expect(!comp2.interned); // Not interned because it's too small!
            try expectEqual(model_interned, comp2.as(&es, Model).?.*);
            try expectEqual(null, comps.next());
        }
        {
            const cmd = iter.next().?.change_archetype;
            try expectEqual(e0, cmd.entity);
            try expectEqual(
                zcs.Component.flags(&es, &.{Tag}),
                cmd.remove,
            );
            // Comps are encoded in reverse order by *fromComponents methods
            var comps = cmd.componentIterator();
            const comp1 = comps.next().?;
            try expect(comp1.interned);
            try expectEqual(rb_interned, comp1.as(&es, RigidBody).?.*);
            const comp2 = comps.next().?;
            try expect(!comp2.interned);
            try expectEqual(model_value, comp2.as(&es, Model).?.*);
            try expectEqual(null, comps.next());
        }
        {
            const cmd = iter.next().?.change_archetype;
            try expectEqual(e1, cmd.entity);
            try expectEqual(
                zcs.Component.flags(&es, &.{Tag}),
                cmd.remove,
            );
            // Comps are encoded in reverse order by *fromComponents methods
            var comps = cmd.componentIterator();
            const comp1 = comps.next().?;
            try expect(!comp1.interned);
            try expectEqual(rb_value, comp1.as(&es, RigidBody).?.*);
            const comp2 = comps.next().?;
            // Low level API respects request regardless of size
            try expect(comp2.interned);
            try expectEqual(model_interned, comp2.as(&es, Model).?.*);
            try expectEqual(null, comps.next());
        }

        // Change archetype null
        {
            const cmd = iter.next().?.change_archetype;
            try expectEqual(e0, cmd.entity);
            try expectEqual(
                zcs.Component.flags(&es, &.{Tag}),
                cmd.remove,
            );
            var comps = cmd.componentIterator();
            try expectEqual(null, comps.next());
        }
        {
            const cmd = iter.next().?.change_archetype;
            try expectEqual(e1, cmd.entity);
            try expectEqual(
                zcs.Component.flags(&es, &.{Tag}),
                cmd.remove,
            );
            var comps = cmd.componentIterator();
            try expectEqual(null, comps.next());
        }
        {
            const cmd = iter.next().?.change_archetype;
            try expectEqual(e0, cmd.entity);
            try expectEqual(
                zcs.Component.flags(&es, &.{Tag}),
                cmd.remove,
            );
            var comps = cmd.componentIterator();
            try expectEqual(null, comps.next());
        }
        {
            const cmd = iter.next().?.change_archetype;
            try expectEqual(e1, cmd.entity);
            try expectEqual(
                zcs.Component.flags(&es, &.{Tag}),
                cmd.remove,
            );
            var comps = cmd.componentIterator();
            try expectEqual(null, comps.next());
        }

        // Done
        try expectEqual(null, iter.next());
    }
}

test "command buffer overflow" {
    // Not very exhaustive, but checks that command buffers return the overflow error on failure to
    // append, and on submits that fail.

    var xoshiro_256: std.Random.Xoshiro256 = .init(0);
    const rand = xoshiro_256.random();

    var es = try zcs.Entities.init(gpa, 100, &.{ RigidBody, Model, Tag });
    defer es.deinit(gpa);

    // Tag/destroy overflow
    {
        var cb = try zcs.CmdBuf.initSeparateCapacities(gpa, &es, .{
            .tags = 0,
            .args = 100,
            .comp_bytes = 100,
            .destroy = 0,
            .reserved = 0,
        });
        defer cb.deinit(gpa, &es);

        try expectError(error.ZcsCmdBufOverflow, zcs.Entity.reserveImmediately(&es).changeArchetypeCmdChecked(&es, &cb, .{}, .{}));
        try expectError(error.ZcsCmdBufOverflow, @as(zcs.Entity, undefined).destroyCmdChecked(&cb));

        try expectEqual(1.0, cb.worstCaseUsage());

        var iter = cb.iterator(&es);
        try expectEqual(null, iter.next());
    }

    // Arg overflow
    {
        var cb = try zcs.CmdBuf.initSeparateCapacities(gpa, &es, .{
            .tags = 100,
            .args = 0,
            .comp_bytes = 100,
            .destroy = 100,
            .reserved = 0,
        });
        defer cb.deinit(gpa, &es);

        try expectError(error.ZcsCmdBufOverflow, @as(zcs.Entity, undefined).changeArchetypeCmdChecked(
            &es,
            &cb,
            .{},
            .{},
        ));
        const e: zcs.Entity = .{ .key = .{ .index = 1, .generation = @enumFromInt(2) } };
        e.destroyCmd(&cb);

        try expectEqual(1.0, cb.worstCaseUsage());

        var iter = cb.iterator(&es);
        try expectEqual(zcs.CmdBuf.Cmd{ .destroy = e }, iter.next());
        try expectEqual(null, iter.next());
    }

    // Component data overflow
    {
        var cb = try zcs.CmdBuf.initSeparateCapacities(gpa, &es, .{
            .tags = 100,
            .args = 100,
            .comp_bytes = @sizeOf(RigidBody) * 2 - 1,
            .destroy = 100,
            .reserved = 0,
        });
        defer cb.deinit(gpa, &es);

        const e: zcs.Entity = .{ .key = .{ .index = 1, .generation = @enumFromInt(2) } };
        const rb = RigidBody.random(rand);

        _ = zcs.Entity.reserveImmediately(&es).changeArchetypeCmd(&es, &cb, .{}, .{rb});
        e.destroyCmd(&cb);
        try expectError(error.ZcsCmdBufOverflow, e.changeArchetypeCmdChecked(
            &es,
            &cb,
            .{},
            .{RigidBody.random(rand)},
        ));

        try expectEqual(@as(f32, @sizeOf(RigidBody)) / @as(f32, @sizeOf(RigidBody) * 2 - 1), cb.worstCaseUsage());

        var iter = cb.iterator(&es);
        try expectEqual(zcs.CmdBuf.Cmd{ .destroy = e }, iter.next());
        const change_archetype = iter.next().?.change_archetype;
        var add_comps = change_archetype.componentIterator();
        const create_rb = add_comps.next().?;
        try expectEqual(es.getComponentId(RigidBody), create_rb.id);
        try expectEqual(rb, create_rb.as(&es, RigidBody).?.*);
        try expectEqual(null, add_comps.next());
        try expectEqual(null, iter.next());
    }
}

test "command buffer worst case capacity" {
    const cb_capacity = 100;

    const comps: []const type = &.{ u0, u8, u16, u32, u64, u128 };

    var es = try zcs.Entities.init(gpa, cb_capacity * 10, comps);
    defer es.deinit(gpa);

    var cb = try zcs.CmdBuf.initNoReserve(gpa, &es, cb_capacity);
    defer cb.deinit(gpa, &es);

    // Change archetype
    {
        // Non interned
        for (0..cb_capacity) |_| {
            _ = try zcs.Entity.reserveImmediately(&es).changeArchetypeCmdFromComponentsChecked(
                &es,
                &cb,
                .{},
                &.{
                    .init(&es, &@as(u0, 0)),
                    .init(&es, &@as(u8, 0)),
                    .init(&es, &@as(u16, 0)),
                    .init(&es, &@as(u32, 0)),
                    .init(&es, &@as(u64, 0)),
                    .init(&es, &@as(u128, 0)),
                },
            );
        }

        try expect(cb.worstCaseUsage() > 0.8);
        cb.clearWithoutRefill();

        // Interned
        for (0..cb_capacity) |_| {
            _ = try zcs.Entity.reserveImmediately(&es).changeArchetypeCmdFromComponentsChecked(
                &es,
                &cb,
                .{},
                &.{
                    .initInterned(&es, &@as(u0, 0)),
                    .initInterned(&es, &@as(u8, 0)),
                    .initInterned(&es, &@as(u16, 0)),
                    .initInterned(&es, &@as(u32, 0)),
                    .initInterned(&es, &@as(u64, 0)),
                    .initInterned(&es, &@as(u128, 0)),
                },
            );
        }

        try expect(cb.worstCaseUsage() > 0.8);
        cb.clearWithoutRefill();

        // Duplicates don't take up extra space
        var dups: std.BoundedArray(zcs.Component.Optional, cb_capacity * 4) = .{};
        for (0..dups.buffer.len) |i| {
            dups.appendAssumeCapacity(.init(&es, &@as(u128, i)));
        }
        _ = try zcs.Entity.reserveImmediately(&es).changeArchetypeCmdFromComponentsChecked(
            &es,
            &cb,
            .{},
            dups.constSlice(),
        );
        cb.clearWithoutRefill();
    }

    // Destroy
    {
        for (0..cb_capacity) |i| {
            const e: zcs.Entity = .{ .key = .{
                .index = @intCast(i),
                .generation = @enumFromInt(0),
            } };
            try e.destroyCmdChecked(&cb);
        }

        try expect(cb.worstCaseUsage() == 1.0);
        cb.clearWithoutRefill();
    }
}

fn checkRandomCmdBuf(
    rand: std.Random,
    expected: *std.AutoArrayHashMapUnmanaged(zcs.Entity, Components),
    actual: *zcs.Entities,
) !void {
    // Queue random commands, apply them directly to the expected data and submit the command buffer
    // at the end.
    const cb_capacity = 20000;
    var cb = try zcs.CmdBuf.initNoReserve(gpa, actual, cb_capacity);
    defer cb.deinit(gpa, actual);
    for (0..cb_capacity) |_| {
        switch (rand.enumValue(@typeInfo(zcs.CmdBuf.Cmd).@"union".tag_type.?)) {
            .destroy => {
                // If we're at less than half capacity, give a slight bias against destroying
                // entities so that we don't just hover near zero entities for the whole test
                if (expected.count() < actual.slots.capacity / 2 and rand.float(f32) < 0.3) {
                    continue;
                }

                const count = expected.count();
                if (count > 0) {
                    const index = rand.uintLessThan(usize, count);
                    const entity = expected.keys()[index];
                    try expect(expected.swapRemove(entity));
                    entity.destroyCmd(&cb);
                }
            },
            .change_archetype => {
                // Typed
                const entity = if (actual.count() > 0 and rand.boolean()) b: {
                    break :b expected.keys()[rand.uintLessThan(usize, expected.count())];
                } else b: {
                    const e = zcs.Entity.reserveImmediately(actual);
                    try expected.putNoClobber(gpa, e, .{});
                    break :b e;
                };

                const expected_comps = expected.getPtr(entity).?;
                var remove: zcs.Component.Flags = .{};
                if (rand.boolean()) {
                    remove.insert(actual.getComponentId(Model));
                    expected_comps.model = null;
                }
                if (rand.boolean()) {
                    remove.insert(actual.getComponentId(RigidBody));
                    expected_comps.rb = null;
                }
                if (rand.boolean()) {
                    remove.insert(actual.getComponentId(Tag));
                    expected_comps.tag = null;
                }

                if (rand.boolean()) {
                    // Typed
                    if (rand.boolean()) {
                        // Optional
                        const tag = Tag.randomOrNull(rand);
                        const model = Model.randomOrNull(rand);
                        const rb = RigidBody.randomOrNull(rand);
                        if (tag) |v| expected_comps.tag = v;
                        if (model) |v| expected_comps.model = v;
                        if (rb) |v| expected_comps.rb = v;
                        entity.changeArchetypeCmd(actual, &cb, remove, .{ tag, model, rb });
                    } else {
                        // Not optional
                        switch (rand.enumValue(enum {
                            empty,
                            rb,
                            model,
                            tag,
                            rb_model,
                            rb_tag,
                            rb_model_tag,
                        })) {
                            .empty => entity.changeArchetypeCmd(actual, &cb, remove, .{}),
                            .rb => {
                                const rb = RigidBody.random(rand);
                                expected_comps.rb = rb;
                                entity.changeArchetypeCmd(actual, &cb, remove, .{rb});
                            },
                            .model => {
                                const model = Model.random(rand);
                                expected_comps.model = model;
                                entity.changeArchetypeCmd(actual, &cb, remove, .{model});
                            },
                            .tag => {
                                const tag = Tag.random(rand);
                                expected_comps.tag = tag;
                                entity.changeArchetypeCmd(actual, &cb, remove, .{tag});
                            },
                            .rb_model => {
                                const rb = RigidBody.random(rand);
                                const model = Model.random(rand);
                                expected_comps.rb = rb;
                                expected_comps.model = model;
                                entity.changeArchetypeCmd(actual, &cb, remove, .{ rb, model });
                            },
                            .rb_tag => {
                                const rb = RigidBody.random(rand);
                                const tag = Tag.random(rand);
                                expected_comps.rb = rb;
                                expected_comps.tag = tag;
                                entity.changeArchetypeCmd(actual, &cb, remove, .{ rb, tag });
                            },
                            .rb_model_tag => {
                                const rb = RigidBody.random(rand);
                                const model = Model.random(rand);
                                const tag = Tag.random(rand);
                                expected_comps.rb = rb;
                                expected_comps.model = model;
                                expected_comps.tag = tag;
                                entity.changeArchetypeCmd(actual, &cb, remove, .{ rb, model, tag });
                            },
                        }
                    }
                } else {
                    // Untyped
                    const model = Model.randomOrNull(rand);
                    const rb = RigidBody.randomOrNull(rand);
                    const tag = Tag.randomOrNull(rand);
                    const add: [3]zcs.Component.Optional = .{
                        .init(actual, &rb),
                        .init(actual, &model),
                        .init(actual, &tag),
                    };
                    if (model) |v| expected_comps.model = v;
                    if (rb) |v| expected_comps.rb = v;
                    if (tag) |v| expected_comps.tag = v;
                    entity.changeArchetypeCmdFromComponents(actual, &cb, remove, &add);
                }
            },
        }
    }
    cb.execute(actual);
    try expect(cb.worstCaseUsage() < 0.5);
    cb.clearWithoutRefill();
    try expect(cb.worstCaseUsage() == 0.0);
    try expect(actual.reserved() == 0.0);

    // Compare the maps
    try expectEqual(expected.count(), actual.count());
    var iter = expected.iterator();
    while (iter.next()) |entry| {
        const e = entry.key_ptr.*;
        const expected_comps = entry.value_ptr;
        try expectEqual(expected_comps.rb, if (e.getComponent(actual, RigidBody)) |v| v.* else null);
        try expectEqual(expected_comps.model, if (e.getComponent(actual, Model)) |v| v.* else null);
        try expectEqual(expected_comps.tag, if (e.getComponent(actual, Tag)) |v| v.* else null);
    }

    // Double check the count via iterating
    var results_iter = actual.iterator(.{});
    var iter_count: usize = 0;
    while (results_iter.next()) |item| {
        try expect(expected.contains(item));
        iter_count += 1;
    }
    try expectEqual(expected.count(), iter_count);
}
