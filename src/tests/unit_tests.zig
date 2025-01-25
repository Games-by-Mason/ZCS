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

/// Used to track equivalence across ECSs.
const Key = struct {
    n: u64,
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

    const comps: []const type = &.{ Key, RigidBody, Model, Tag };

    var expected = try zcs.Entities.init(gpa, capacity, comps);
    defer expected.deinit(gpa);

    var actual = try zcs.Entities.init(gpa, capacity, comps);
    defer actual.deinit(gpa);

    var next_key: Key = .{ .n = 0 };
    // The first pass will only create entities, since there are not yet any entities to destroy or
    // modify
    try checkRandomCommandBuffer(&next_key, rand, &expected, &actual);
    // The second pass will create, destroy, and change the archetype of the entities
    try checkRandomCommandBuffer(&next_key, rand, &expected, &actual);
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

    var cb = try zcs.CommandBuffer.init(gpa, &es, 4);
    defer cb.deinit(gpa, &es);

    try expectEqual(0, es.count());

    const e0_expected = cb.peekCreate(0);
    const e0 = cb.create(&es, .{});
    const e1_expected = cb.peekCreate(0);
    const e2_expected = cb.peekCreate(1);
    const e1 = cb.createFromComponents(&es, &.{});
    const rb = RigidBody.random(rand);
    const model = Model.random(rand);
    const e2 = cb.create(&es, .{rb});
    try expect(e0_expected.eql(e0));
    try expect(e1_expected.eql(e1));
    try expect(e2_expected.eql(e2));
    _ = try cb.peekCreateChecked(0);
    try expectError(error.Overflow, cb.peekCreateChecked(1));
    cb.submit(&es);
    cb.clear();

    try expectEqual(3, es.count());

    // Entities are currently used in reverse order from how they're reserved
    var iter = es.iterator(.{});

    try expect(e2.eql(iter.next().?));
    try expectEqual(rb, e2.getComponent(&es, RigidBody).?.*);
    try expectEqual(null, e2.getComponent(&es, Model));
    try expectEqual(null, e2.getComponent(&es, Tag));

    try expect(e1.eql(iter.next().?));
    try expectEqual(null, e1.getComponent(&es, RigidBody));
    try expectEqual(null, e1.getComponent(&es, Model));
    try expectEqual(null, e1.getComponent(&es, Tag));

    try expect(iter.next().?.eql(e0));
    try expectEqual(null, e0.getComponent(&es, RigidBody));
    try expectEqual(null, e0.getComponent(&es, Model));
    try expectEqual(null, e0.getComponent(&es, Tag));

    try expectEqual(null, iter.next());

    // We don't check eql anywhere else, quickly check it here. The details are tested more
    // extensively on slot map.
    try expect(e1.eql(e1));
    try expect(!e1.eql(e2));
    try expect(!e1.eql(.none));

    cb.changeArchetype(&es, e0, zcs.Component.flags(&es, &.{RigidBody}), .{});
    cb.changeArchetypeFromComponents(&es, e1, zcs.Component.flags(&es, &.{RigidBody}), &.{});
    cb.changeArchetype(&es, e2, zcs.Component.flags(&es, &.{RigidBody}), .{model});
    cb.submit(&es);
    cb.clear();

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

    var cb = try zcs.CommandBuffer.init(gpa, &es, 24);
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
        defer cb.clear();
        _ = cb.createFromComponents(&es, &.{
            .init(&es, &model1),
            .init(&es, &RigidBody{}),
            .init(&es, &model2),
            .none,
        });
        var iter = cb.iterator(&es);
        const create = iter.next().?.create;
        try std.testing.expectEqual(
            zcs.Component.flags(&es, &.{ RigidBody, Model }),
            create.archetype,
        );
        var comps = create.componentIterator();
        const comp1 = comps.next().?;
        try expect(!comp1.interned);
        try expectEqual(model2, comp1.as(&es, Model).?.*);
        const comp2 = comps.next().?;
        try expect(!comp2.interned);
        try expectEqual(RigidBody{}, comp2.as(&es, RigidBody).?.*);
    }

    {
        defer cb.clear();
        cb.changeArchetypeFromComponents(
            &es,
            e0,
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
        try std.testing.expectEqual(
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

    var cb = try zcs.CommandBuffer.init(gpa, &es, 24);
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

    // Create non optional
    _ = cb.create(&es, .{ rb_interned, model_value });
    _ = cb.create(&es, .{ rb_value, model_interned });
    _ = cb.createFromComponents(&es, &.{
        .initInterned(&es, &rb_interned),
        .init(&es, &model_value),
    });
    _ = cb.createFromComponents(&es, &.{
        .init(&es, &rb_value),
        .initInterned(&es, &model_interned),
    });

    // Create optional
    _ = cb.create(&es, .{ rb_interned_optional, model_value_optional });
    _ = cb.create(&es, .{ rb_value_optional, model_interned_optional });
    _ = cb.createFromComponents(&es, &.{
        .initInterned(&es, &rb_interned_optional),
        .init(&es, &model_value_optional),
    });
    _ = cb.createFromComponents(&es, &.{
        .init(&es, &rb_value_optional),
        .initInterned(&es, &model_interned_optional),
    });

    // Create null
    _ = cb.create(&es, .{ rb_interned_null, model_value_null });
    _ = cb.create(&es, .{ rb_value_null, model_interned_null });
    _ = cb.createFromComponents(&es, &.{
        .init(&es, &model_value_null),
        .initInterned(&es, &rb_interned_null),
    });
    _ = cb.createFromComponents(&es, &.{
        .initInterned(&es, &model_interned_null),
        .init(&es, &rb_value_null),
    });

    // Change archetype non optional
    cb.changeArchetype(
        &es,
        e0,
        zcs.Component.flags(&es, &.{Tag}),
        .{ model_value, rb_interned },
    );
    cb.changeArchetype(
        &es,
        e1,
        zcs.Component.flags(&es, &.{Tag}),
        .{ model_interned, rb_value },
    );
    cb.changeArchetypeFromComponents(&es, e0, zcs.Component.flags(&es, &.{Tag}), &.{
        .init(&es, &model_value),
        .initInterned(&es, &rb_interned),
    });
    cb.changeArchetypeFromComponents(&es, e1, zcs.Component.flags(&es, &.{Tag}), &.{
        .initInterned(&es, &model_interned),
        .init(&es, &rb_value),
    });

    // Change archetype optional
    cb.changeArchetype(
        &es,
        e0,
        zcs.Component.flags(&es, &.{Tag}),
        .{ model_value_optional, rb_interned_optional },
    );
    cb.changeArchetype(
        &es,
        e1,
        zcs.Component.flags(&es, &.{Tag}),
        .{ model_interned_optional, rb_value_optional },
    );
    cb.changeArchetypeFromComponents(&es, e0, zcs.Component.flags(&es, &.{Tag}), &.{
        .init(&es, &model_value_optional),
        .initInterned(&es, &rb_interned_optional),
    });
    cb.changeArchetypeFromComponents(&es, e1, zcs.Component.flags(&es, &.{Tag}), &.{
        .initInterned(&es, &model_interned_optional),
        .init(&es, &rb_value_optional),
    });

    // Change archetype null
    cb.changeArchetype(
        &es,
        e0,
        zcs.Component.flags(&es, &.{Tag}),
        .{ model_value_null, rb_interned_null },
    );
    cb.changeArchetype(
        &es,
        e1,
        zcs.Component.flags(&es, &.{Tag}),
        .{ model_interned_null, rb_value_null },
    );
    cb.changeArchetypeFromComponents(&es, e0, zcs.Component.flags(&es, &.{Tag}), &.{
        .init(&es, &model_value_null),
        .initInterned(&es, &rb_interned_null),
    });
    cb.changeArchetypeFromComponents(&es, e1, zcs.Component.flags(&es, &.{Tag}), &.{
        .initInterned(&es, &model_interned_null),
        .init(&es, &rb_value_null),
    });

    // Test the results
    {
        var iter = cb.iterator(&es);

        // Create non optional
        {
            const cmd = iter.next().?.create;
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
            const cmd = iter.next().?.create;
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
            const cmd = iter.next().?.create;
            // Comps are encoded in reverse order by *fromComponents methods
            var comps = cmd.componentIterator();
            const comp1 = comps.next().?;
            try expect(!comp1.interned);
            try expectEqual(model_value, comp1.as(&es, Model).?.*);
            const comp2 = comps.next().?;
            try expect(comp2.interned);
            try expectEqual(rb_interned, comp2.as(&es, RigidBody).?.*);
            try expectEqual(null, comps.next());
        }
        {
            const cmd = iter.next().?.create;
            // Comps are encoded in reverse order by *fromComponents methods
            var comps = cmd.componentIterator();
            const comp1 = comps.next().?;
            // Low level API respects request regardless of size
            try expect(comp1.interned);
            try expectEqual(model_interned, comp1.as(&es, Model).?.*);
            const comp2 = comps.next().?;
            try expect(!comp2.interned);
            try expectEqual(rb_value, comp2.as(&es, RigidBody).?.*);
            try expectEqual(null, comps.next());
        }

        // Create optional
        {
            const cmd = iter.next().?.create;
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
            const cmd = iter.next().?.create;
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
            const cmd = iter.next().?.create;
            // Comps are encoded in reverse order by *fromComponents methods
            var comps = cmd.componentIterator();
            const comp1 = comps.next().?;
            try expect(!comp1.interned);
            try expectEqual(model_value, comp1.as(&es, Model).?.*);
            const comp2 = comps.next().?;
            try expect(comp2.interned);
            try expectEqual(rb_interned, comp2.as(&es, RigidBody).?.*);
            try expectEqual(null, comps.next());
        }
        {
            const cmd = iter.next().?.create;
            // Comps are encoded in reverse order by *fromComponents methods
            var comps = cmd.componentIterator();
            const comp1 = comps.next().?;
            // Low level API respects request regardless of size
            try expect(comp1.interned);
            try expectEqual(model_interned, comp1.as(&es, Model).?.*);
            const comp2 = comps.next().?;
            try expect(!comp2.interned);
            try expectEqual(rb_value, comp2.as(&es, RigidBody).?.*);
            try expectEqual(null, comps.next());
        }

        // Create null
        {
            const cmd = iter.next().?.create;
            var comps = cmd.componentIterator();
            try expectEqual(null, comps.next());
        }
        {
            const cmd = iter.next().?.create;
            var comps = cmd.componentIterator();
            try expectEqual(null, comps.next());
        }
        {
            const cmd = iter.next().?.create;
            var comps = cmd.componentIterator();
            try expectEqual(null, comps.next());
        }
        {
            const cmd = iter.next().?.create;
            var comps = cmd.componentIterator();
            try expectEqual(null, comps.next());
        }

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

    var es = try zcs.Entities.init(gpa, 200, &.{ RigidBody, Model, Tag });
    defer es.deinit(gpa);

    // Tag/destroy overflow
    {
        var cb = try zcs.CommandBuffer.initSeparateCapacities(gpa, &es, .{
            .tags = 0,
            .args = 100,
            .comp_buf = 100,
            .destroy = 0,
            .reserved = 100,
        });
        defer cb.deinit(gpa, &es);

        try expectError(error.Overflow, cb.createChecked(&es, .{}));
        try expectError(error.Overflow, cb.changeArchetypeChecked(
            &es,
            undefined,
            .{},
            .{},
        ));
        try expectError(error.Overflow, cb.destroyChecked(undefined));

        try expectEqual(1.0, cb.worstCaseUsage());

        var iter = cb.iterator(&es);
        try expectEqual(null, iter.next());
    }

    // Arg overflow
    {
        var cb = try zcs.CommandBuffer.initSeparateCapacities(gpa, &es, .{
            .tags = 100,
            .args = 0,
            .comp_buf = 100,
            .destroy = 100,
            .reserved = 100,
        });
        defer cb.deinit(gpa, &es);

        _ = cb.create(&es, .{});
        try expectError(error.Overflow, cb.createChecked(&es, .{RigidBody.random(rand)}));
        try expectError(error.Overflow, cb.changeArchetypeChecked(
            &es,
            undefined,
            .{},
            .{},
        ));
        const e: zcs.Entity = .{ .key = .{ .index = 1, .generation = @enumFromInt(2) } };
        cb.destroy(e);

        try expectEqual(1.0, cb.worstCaseUsage());

        var iter = cb.iterator(&es);
        try expectEqual(zcs.CommandBuffer.Cmd{ .destroy = e }, iter.next());
        const create = iter.next().?.create;
        var create_comps = create.componentIterator();
        try expectEqual(null, create_comps.next());
        try expectEqual(null, iter.next());
    }

    // Component data overflow
    {
        var cb = try zcs.CommandBuffer.initSeparateCapacities(gpa, &es, .{
            .tags = 100,
            .args = 100,
            .comp_buf = @sizeOf(RigidBody) * 2 - 1,
            .destroy = 100,
            .reserved = 100,
        });
        defer cb.deinit(gpa, &es);

        const e: zcs.Entity = .{ .key = .{ .index = 1, .generation = @enumFromInt(2) } };
        const rb = RigidBody.random(rand);

        _ = cb.create(&es, .{rb});
        cb.destroy(e);
        try expectError(error.Overflow, cb.createChecked(&es, .{RigidBody.random(rand)}));
        try expectError(error.Overflow, cb.changeArchetypeChecked(
            &es,
            e,
            .{},
            .{RigidBody.random(rand)},
        ));

        try expectEqual(@as(f32, @sizeOf(RigidBody)) / @as(f32, @sizeOf(RigidBody) * 2 - 1), cb.worstCaseUsage());

        var iter = cb.iterator(&es);
        try expectEqual(zcs.CommandBuffer.Cmd{ .destroy = e }, iter.next());
        const create = iter.next().?.create;
        var create_comps = create.componentIterator();
        const create_rb = create_comps.next().?;
        try expectEqual(es.getComponentId(RigidBody), create_rb.id);
        try expectEqual(rb, create_rb.as(&es, RigidBody).?.*);
        try expectEqual(null, create_comps.next());
        try expectEqual(null, iter.next());
    }
}

test "command buffer worst case capacity" {
    const capacity = 100;

    const comps: []const type = &.{ u0, u8, u16, u32, u64, u128 };

    var es = try zcs.Entities.init(gpa, capacity, comps);
    defer es.deinit(gpa);

    var cb = try zcs.CommandBuffer.init(gpa, &es, capacity);
    defer cb.deinit(gpa, &es);

    // Create
    {
        // Non interned
        for (0..capacity) |_| {
            _ = try cb.createFromComponentsChecked(
                &es,
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

        try std.testing.expect(cb.worstCaseUsage() > 0.8);
        cb.clear();

        // Interned
        for (0..capacity) |_| {
            _ = try cb.createFromComponentsChecked(
                &es,
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

        try std.testing.expect(cb.worstCaseUsage() > 0.8);
        cb.clear();

        // Duplicates don't take up extra space
        var dups: std.BoundedArray(zcs.Component.Optional, capacity * 4) = .{};
        for (0..dups.buffer.len) |i| {
            dups.appendAssumeCapacity(.init(&es, &@as(u128, i)));
        }
        _ = try cb.createFromComponentsChecked(
            &es,
            dups.constSlice(),
        );
        cb.clear();
    }

    // Change archetype
    {
        for (0..capacity) |i| {
            try cb.changeArchetypeFromComponentsChecked(
                &es,
                .{ .key = .{ .index = @intCast(i), .generation = @enumFromInt(0) } },
                zcs.Component.flags(&es, &.{u0}),
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

        try std.testing.expect(cb.worstCaseUsage() > 0.8);
        cb.clear();

        // Elide u0 from the component data so that the remove can't be optimized out
        for (0..capacity) |i| {
            try cb.changeArchetypeFromComponentsChecked(
                &es,
                .{ .key = .{ .index = @intCast(i), .generation = @enumFromInt(0) } },
                zcs.Component.flags(&es, &.{u0}),
                &.{
                    .init(&es, &@as(u8, 0)),
                    .init(&es, &@as(u16, 0)),
                    .init(&es, &@as(u32, 0)),
                    .init(&es, &@as(u64, 0)),
                    .init(&es, &@as(u128, 0)),
                },
            );
        }

        try std.testing.expect(cb.worstCaseUsage() > 0.8);
        cb.clear();

        // Duplicates don't take up extra space
        var dups: std.BoundedArray(zcs.Component.Optional, capacity * 4) = .{};
        for (0..dups.buffer.len) |i| {
            dups.appendAssumeCapacity(.init(&es, &@as(u128, i)));
        }
        try cb.changeArchetypeFromComponentsChecked(
            &es,
            .{ .key = .{ .index = @intCast(0), .generation = @enumFromInt(0) } },
            .{},
            dups.constSlice(),
        );
        cb.clear();
    }

    // Destroy
    {
        for (0..capacity) |i| {
            const e: zcs.Entity = .{ .key = .{
                .index = @intCast(i),
                .generation = @enumFromInt(0),
            } };
            try cb.destroyChecked(e);
        }

        try std.testing.expect(cb.worstCaseUsage() == 1.0);
        cb.clear();
    }
}

fn checkRandomCommandBuffer(
    next_key: *Key,
    rand: std.Random,
    expected: *zcs.Entities,
    actual: *zcs.Entities,
) !void {
    // Accumulate the current entities in a way we can random access
    var key_to_actual_es = try keysToEntities(actual);
    defer key_to_actual_es.deinit(gpa);
    var key_to_expected_es = try keysToEntities(expected);
    defer key_to_expected_es.deinit(gpa);
    try expectEqual(key_to_actual_es.count(), key_to_expected_es.count());

    // Queue random commands, apply them directly to the expected data and submit the command buffer
    // at the end. Gives each entity an incrementing key to track equivalence across ECSs since
    // commands are allowed to be reordered.
    const cb_capacity = 10000;
    var cb = try zcs.CommandBuffer.init(gpa, actual, cb_capacity);
    defer cb.deinit(gpa, actual);
    for (0..cb_capacity) |_| {
        switch (rand.enumValue(@typeInfo(zcs.CommandBuffer.Cmd).@"union".tag_type.?)) {
            .create => {
                if (rand.boolean()) {
                    // Typed
                    if (rand.boolean()) {
                        // Optional
                        const comps = .{
                            next_key.*,
                            RigidBody.randomOrNull(rand),
                            Model.randomOrNull(rand),
                            Tag.randomOrNull(rand),
                        };
                        _ = zcs.Entity.create(expected, comps);
                        _ = cb.create(actual, comps);
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
                            .empty => {
                                const comps = .{
                                    next_key.*,
                                };
                                _ = zcs.Entity.create(expected, comps);
                                _ = cb.create(actual, comps);
                            },
                            .rb => {
                                const comps = .{
                                    next_key.*,
                                    RigidBody.random(rand),
                                };
                                _ = zcs.Entity.create(expected, comps);
                                _ = cb.create(actual, comps);
                            },
                            .model => {
                                const comps = .{
                                    next_key.*,
                                    Model.random(rand),
                                };
                                _ = zcs.Entity.create(expected, comps);
                                _ = cb.create(actual, comps);
                            },
                            .tag => {
                                const comps = .{
                                    next_key.*,
                                    Tag.random(rand),
                                };
                                _ = zcs.Entity.create(expected, comps);
                                _ = cb.create(actual, comps);
                            },
                            .rb_model => {
                                const comps = .{
                                    next_key.*,
                                    RigidBody.random(rand),
                                    Model.random(rand),
                                };
                                _ = zcs.Entity.create(expected, comps);
                                _ = cb.create(actual, comps);
                            },
                            .rb_tag => {
                                const comps = .{
                                    next_key.*,
                                    RigidBody.random(rand),
                                    Tag.random(rand),
                                };
                                _ = zcs.Entity.create(expected, comps);
                                _ = cb.create(actual, comps);
                            },
                            .rb_model_tag => {
                                const comps = .{
                                    next_key.*,
                                    RigidBody.random(rand),
                                    Model.random(rand),
                                    Tag.random(rand),
                                };
                                _ = zcs.Entity.create(expected, comps);
                                _ = cb.create(actual, comps);
                            },
                        }
                    }
                } else {
                    // Untyped
                    const model = Model.randomOrNull(rand);
                    const rb = RigidBody.randomOrNull(rand);
                    const tag = Tag.randomOrNull(rand);
                    const key = next_key.*;
                    const comps: [4]zcs.Component.Optional = .{
                        .init(expected, &rb),
                        .init(expected, &model),
                        .init(expected, &key),
                        .init(expected, &tag),
                    };
                    _ = zcs.Entity.createFromComponents(expected, &comps);
                    _ = cb.createFromComponents(actual, &comps);
                }
                next_key.n += 1;
            },
            .destroy => {
                // If we're at less than half capacity, give a slight bias against destroying
                // entities so that we don't just hover near zero entities for the whole test
                if (expected.count() < expected.slots.capacity / 2 and rand.float(f32) < 0.3) {
                    continue;
                }

                const count = key_to_actual_es.count();
                if (count > 0) {
                    const index = rand.uintLessThan(usize, count);
                    const expected_entity = key_to_expected_es.values()[index];
                    const actual_entity = key_to_actual_es.values()[index];
                    expected_entity.destroy(expected);
                    cb.destroy(actual_entity);
                }
            },
            .change_archetype => {
                const count = key_to_actual_es.count();
                if (count > 0) {
                    // Typed
                    const index = rand.uintLessThan(usize, count);
                    const expected_entity = key_to_expected_es.values()[index];
                    const actual_entity = key_to_actual_es.values()[index];

                    var remove: zcs.Component.Flags = .{};
                    if (rand.boolean()) remove.insert(actual.getComponentId(Model));
                    if (rand.boolean()) remove.insert(actual.getComponentId(RigidBody));
                    if (rand.boolean()) remove.insert(actual.getComponentId(Tag));

                    if (rand.boolean()) {
                        // Typed
                        if (rand.boolean()) {
                            // Optional
                            const add = .{
                                next_key.*,
                                Tag.randomOrNull(rand),
                                Model.randomOrNull(rand),
                                RigidBody.randomOrNull(rand),
                            };

                            expected_entity.changeArchetype(expected, remove, add);
                            cb.changeArchetype(actual, actual_entity, remove, add);
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
                                .empty => {
                                    const add = .{};
                                    expected_entity.changeArchetype(expected, remove, add);
                                    cb.changeArchetype(actual, expected_entity, remove, add);
                                },
                                .rb => {
                                    const add = .{
                                        RigidBody.random(rand),
                                    };
                                    expected_entity.changeArchetype(expected, remove, add);
                                    cb.changeArchetype(actual, expected_entity, remove, add);
                                },
                                .model => {
                                    const add = .{
                                        Model.random(rand),
                                    };
                                    expected_entity.changeArchetype(expected, remove, add);
                                    cb.changeArchetype(actual, expected_entity, remove, add);
                                },
                                .tag => {
                                    const add = .{
                                        Tag.random(rand),
                                    };
                                    expected_entity.changeArchetype(expected, remove, add);
                                    cb.changeArchetype(actual, expected_entity, remove, add);
                                },
                                .rb_model => {
                                    const add = .{
                                        RigidBody.random(rand),
                                        Model.random(rand),
                                    };
                                    expected_entity.changeArchetype(expected, remove, add);
                                    cb.changeArchetype(actual, expected_entity, remove, add);
                                },
                                .rb_tag => {
                                    const add = .{
                                        RigidBody.random(rand),
                                        Tag.random(rand),
                                    };
                                    expected_entity.changeArchetype(expected, remove, add);
                                    cb.changeArchetype(actual, expected_entity, remove, add);
                                },
                                .rb_model_tag => {
                                    const add = .{
                                        RigidBody.random(rand),
                                        Model.random(rand),
                                        Tag.random(rand),
                                    };
                                    expected_entity.changeArchetype(expected, remove, add);
                                    cb.changeArchetype(actual, expected_entity, remove, add);
                                },
                            }
                        }
                    } else {
                        // Untyped
                        const model = Model.randomOrNull(rand);
                        const rb = RigidBody.randomOrNull(rand);
                        const tag = Tag.randomOrNull(rand);
                        const add: [3]zcs.Component.Optional = .{
                            .init(expected, &rb),
                            .init(expected, &model),
                            .init(expected, &tag),
                        };
                        expected_entity.changeArchetypeFromComponents(expected, remove, &add);
                        cb.changeArchetypeFromComponents(actual, actual_entity, remove, &add);
                    }
                }
            },
        }
    }
    cb.submit(actual);
    try expect(cb.worstCaseUsage() < 0.5);
    cb.clear();
    try expect(cb.worstCaseUsage() == 0.0);

    // Build maps of the expected and actual results
    var expected_es = try entitiesToKeyMap(expected);
    defer expected_es.deinit(gpa);
    var actual_es = try entitiesToKeyMap(actual);
    defer actual_es.deinit(gpa);

    // Compare the maps
    try expectEqual(expected_es.count(), actual_es.count());
    var results_iter = expected_es.iterator();
    while (results_iter.next()) |item| {
        const expected_storage: Components = item.value_ptr.*;
        const actual_storage: Components = expected_es.get(item.key_ptr.*).?;
        try expectEqual(expected_storage, actual_storage);
    }
}

fn keysToEntities(es: *const zcs.Entities) !std.AutoArrayHashMapUnmanaged(Key, zcs.Entity) {
    var keys: std.AutoArrayHashMapUnmanaged(Key, zcs.Entity) = .empty;
    errdefer keys.deinit(gpa);
    var iter = es.iterator(.{});
    while (iter.next()) |entity| {
        const key = entity.getComponent(es, Key).?;
        try keys.put(gpa, key.*, entity);
    }
    return keys;
}

fn entitiesToKeyMap(
    es: *const zcs.Entities,
) !std.AutoArrayHashMapUnmanaged(Key, Components) {
    var map: std.AutoArrayHashMapUnmanaged(Key, Components) = .empty;
    errdefer map.deinit(gpa);
    var iter = es.iterator(.{});
    while (iter.next()) |entity| {
        var comps: Components = .{};
        if (entity.getComponent(es, Model)) |model| comps.model = model.*;
        if (entity.getComponent(es, RigidBody)) |rb| comps.rb = rb.*;
        if (entity.getComponent(es, Tag)) |tag| comps.tag = tag.*;
        const key = entity.getComponent(es, Key).?;
        try map.put(gpa, key.*, comps);
    }
    return map;
}
