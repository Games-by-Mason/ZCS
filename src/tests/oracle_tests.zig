//! Oracle based tests.

const std = @import("std");
const zcs = @import("../root.zig");
const oracle = @import("oracle.zig");
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

const Oracle = oracle.Oracle(&.{
    RigidBody,
    Model,
    Tag,
});
const Entities = Oracle.Entities;
const Entity = Oracle.Entity;
const ComponentFlags = Oracle.ComponentFlags;
const OptionalComponent = Oracle.OptionalComponent;

test "random and clear" {
    var xoshiro_256: std.Random.Xoshiro256 = .init(0);
    const rand = xoshiro_256.random();

    const capacity = 10000;
    var es = try Entities.init(capacity);
    defer es.deinit();

    try doRandomOperations(rand, &es, capacity, 0.05);
    try es.reset();
    try doRandomOperations(rand, &es, capacity, 0.05);
}

test "saturate generations" {
    var xoshiro_256: std.Random.Xoshiro256 = .init(1);
    const rand = xoshiro_256.random();

    const capacity = 10000;
    var es = try Entities.init(capacity);
    defer es.deinit();

    try doRandomOperations(rand, &es, 10000, 0.01);
    {
        var i: usize = 0;
        while (i < es.expected_live.keys().len) : (i += 1) {
            const entity = es.expected_live.keys()[i];
            try entity.destroy(&es);
            const Generation = @TypeOf(es.actual.slots.generations[entity.actual.key.index]);
            const GenerationTag = @typeInfo(Generation).@"enum".tag_type;
            es.actual.slots.generations[entity.actual.key.index] = @enumFromInt(std.math.maxInt(GenerationTag) - 1);
        }
    }
    try expectEqual(0, es.actual.slots.saturated_generations);
    try doRandomOperations(rand, &es, 500, 0.01);
    const saturated = es.actual.slots.saturated_generations;
    try expect(es.actual.slots.saturated_generations > 0);
    try doRandomOperations(rand, &es, 10000, 0.01);
    try expect(es.actual.slots.saturated_generations > saturated);

    // Destroy all via iteration
    try es.checkViewIterator(rand, struct { entity: zcs.Entity, model: *Model, rb: *RigidBody }, 1.0);
    try expect(try es.count() > 0);
    try es.checkViewIterator(rand, struct { entity: zcs.Entity }, 1.0);
    try expectEqual(0, es.count());

    try es.fullCheck(rand);
}

test "overflow" {
    var xoshiro_256: std.Random.Xoshiro256 = .init(0);
    const rand = xoshiro_256.random();

    const capacity = 10;
    var es = try Entities.init(capacity);
    defer es.deinit();

    for (0..capacity) |_| {
        _ = try Entity.create(&es, .{});
    }

    try expectError(error.Overflow, Entity.create(&es, .{}));
    try expectError(error.Overflow, Entity.create(&es, .{}));
    try es.expected_live.keys()[0].destroy(&es);
    _ = try Entity.create(&es, .{});
    try expectError(error.Overflow, Entity.create(&es, .{}));
    try expectError(error.Overflow, Entity.create(&es, .{}));
    try es.reset();
    for (0..capacity) |_| {
        _ = try Entity.create(&es, .{});
    }
    try expectError(error.Overflow, Entity.create(&es, .{}));

    try es.fullCheck(rand);
}

pub fn doRandomOperations(
    rand: std.Random,
    es: *Entities,
    iterations: usize,
    destroy_while_iter_chance: f32,
) !void {
    for (0..iterations) |_| {
        switch (rand.enumValue(enum {
            create,
            destroy,
            modify,
            change_archetype,
            iterate,
            full_check,
            access_destroyed,
            reserve,
        })) {
            .create => {
                if (rand.boolean()) {
                    var comps: RandomComponents = .{};
                    comps.randomize(es, rand);
                    _ = try Entity.createFromComponents(es, comps.buf.constSlice());
                } else {
                    // Typed
                    if (rand.boolean()) {
                        // Without null components
                        if (rand.float(f32) < 0.1) {
                            // Interned
                            _ = switch (rand.enumValue(enum {
                                model,
                                rb,
                                tag,
                                model_rb,
                                model_tag,
                                rb_tag,
                                model_rb_tag,
                            })) {
                                .model => try Entity.create(es, .{Model{}}),
                                .rb => try Entity.create(es, .{RigidBody{}}),
                                .tag => try Entity.create(es, .{Tag{}}),
                                .model_rb => try Entity.create(es, .{ Model{}, RigidBody{} }),
                                .model_tag => try Entity.create(es, .{ Model{}, Tag{} }),
                                .rb_tag => try Entity.create(es, .{ RigidBody{}, Tag{} }),
                                .model_rb_tag => try Entity.create(es, .{ RigidBody{}, Model{}, Tag{} }),
                            };
                        } else {
                            // Non interned
                            _ = switch (rand.enumValue(enum {
                                empty,
                                model,
                                rb,
                                tag,
                                model_rb,
                                model_tag,
                                rb_tag,
                                model_rb_tag,
                            })) {
                                .empty => try Entity.create(es, .{}),
                                .model => try Entity.create(es, .{Model.random(rand)}),
                                .rb => try Entity.create(es, .{RigidBody.random(rand)}),
                                .tag => try Entity.create(es, .{Tag.random(rand)}),
                                .model_rb => try Entity.create(es, .{ Model.random(rand), RigidBody.random(rand) }),
                                .model_tag => try Entity.create(es, .{ Model.random(rand), Tag.random(rand) }),
                                .rb_tag => try Entity.create(es, .{ RigidBody.random(rand), Tag.random(rand) }),
                                .model_rb_tag => try Entity.create(es, .{ RigidBody.random(rand), Model.random(rand), Tag.random(rand) }),
                            };
                        }
                    } else {
                        // With null components
                        if (rand.float(f32) < 0.1) {
                            // Interned
                            _ = switch (rand.enumValue(enum {
                                model,
                                rb,
                                tag,
                                model_rb,
                                model_tag,
                                rb_tag,
                                model_rb_tag,
                            })) {
                                .model => try Entity.create(es, .{@as(?Model, .{})}),
                                .rb => try Entity.create(es, .{@as(?RigidBody, .{})}),
                                .tag => try Entity.create(es, .{@as(?Tag, Tag{})}),
                                .model_rb => try Entity.create(es, .{ @as(?Model, null), @as(?RigidBody, .{}) }),
                                .model_tag => try Entity.create(es, .{ @as(?Model, .{}), @as(?Tag, null) }),
                                .rb_tag => try Entity.create(es, .{ @as(?RigidBody, .{}), @as(?Tag, .{}) }),
                                .model_rb_tag => try Entity.create(es, .{ @as(?RigidBody, null), @as(?Model, .{}), @as(?Tag, null) }),
                            };
                        } else {
                            // Non interned
                            _ = switch (rand.enumValue(enum {
                                empty,
                                model,
                                rb,
                                tag,
                                model_rb,
                                model_tag,
                                rb_tag,
                                model_rb_tag,
                            })) {
                                .empty => try Entity.create(es, .{}),
                                .model => try Entity.create(es, .{Model.randomOrNull(rand)}),
                                .rb => try Entity.create(es, .{RigidBody.randomOrNull(rand)}),
                                .tag => try Entity.create(es, .{Tag.randomOrNull(rand)}),
                                .model_rb => try Entity.create(es, .{ Model.randomOrNull(rand), RigidBody.randomOrNull(rand) }),
                                .model_tag => try Entity.create(es, .{ Model.randomOrNull(rand), Tag.randomOrNull(rand) }),
                                .rb_tag => try Entity.create(es, .{ RigidBody.randomOrNull(rand), Tag.randomOrNull(rand) }),
                                .model_rb_tag => try Entity.create(es, .{ RigidBody.randomOrNull(rand), Model.randomOrNull(rand), Tag.randomOrNull(rand) }),
                            };
                        }
                    }
                }
            },
            .destroy => {
                // If we're at less than half capacity, give a slight bias against destroying
                // entities so that we don't just hover near zero entities for the whole test
                if (try es.count() < es.capacity / 2 and rand.float(f32) < 0.3) {
                    continue;
                }

                // Destroy a random entity
                if (Entity.random(es, rand)) |entity| {
                    try entity.destroy(es);
                }
            },
            .modify => {
                if (Entity.random(es, rand)) |entity| {
                    if (try entity.getComponent(es, Model)) |model| {
                        const new = Model.random(rand);
                        model.expected.* = new;
                        model.actual.* = new;
                    }

                    if (try entity.getComponent(es, RigidBody)) |rb| {
                        const new = RigidBody.random(rand);
                        rb.expected.* = new;
                        rb.actual.* = new;
                    }
                }
            },
            .change_archetype => {
                if (Entity.random(es, rand)) |entity| {
                    if (rand.boolean()) {
                        // From IDs
                        var remove: ComponentFlags = .{};
                        inline for (@typeInfo(ComponentFlags).@"struct".fields) |field| {
                            @field(remove, field.name) = rand.boolean();
                        }
                        var comps: RandomComponents = .{};
                        comps.randomize(es, rand);
                        try entity.changeArchetypeFromComponents(es, remove, comps.buf.constSlice());
                    } else {
                        // From types
                        var remove: ComponentFlags = .{};
                        inline for (@typeInfo(ComponentFlags).@"struct".fields) |field| {
                            @field(remove, field.name) = rand.boolean();
                        }
                        if (rand.boolean()) {
                            // Without null components
                            if (rand.float(f32) < 0.1) {
                                // Interned
                                _ = switch (rand.enumValue(enum {
                                    model,
                                    rb,
                                    tag,
                                    model_rb,
                                    model_tag,
                                    rb_tag,
                                    model_rb_tag,
                                })) {
                                    .model => try entity.changeArchetype(es, remove, .{Model{}}),
                                    .rb => try entity.changeArchetype(es, remove, .{RigidBody{}}),
                                    .tag => try entity.changeArchetype(es, remove, .{Tag{}}),
                                    .model_rb => try entity.changeArchetype(es, remove, .{ Model{}, RigidBody{} }),
                                    .model_tag => try entity.changeArchetype(es, remove, .{ Model{}, Tag{} }),
                                    .rb_tag => try entity.changeArchetype(es, remove, .{ RigidBody{}, Tag{} }),
                                    .model_rb_tag => try entity.changeArchetype(es, remove, .{ RigidBody{}, Model{}, Tag{} }),
                                };
                            } else {
                                _ = switch (rand.enumValue(enum {
                                    empty,
                                    model,
                                    rb,
                                    tag,
                                    model_rb,
                                    model_tag,
                                    rb_tag,
                                    model_rb_tag,
                                })) {
                                    .empty => try entity.changeArchetype(es, remove, .{}),
                                    .model => try entity.changeArchetype(es, remove, .{Model.random(rand)}),
                                    .rb => try entity.changeArchetype(es, remove, .{RigidBody.random(rand)}),
                                    .tag => try entity.changeArchetype(es, remove, .{Tag.random(rand)}),
                                    .model_rb => try entity.changeArchetype(es, remove, .{ Model.random(rand), RigidBody.random(rand) }),
                                    .model_tag => try entity.changeArchetype(es, remove, .{ Model.random(rand), Tag.random(rand) }),
                                    .rb_tag => try entity.changeArchetype(es, remove, .{ RigidBody.random(rand), Tag.random(rand) }),
                                    .model_rb_tag => try entity.changeArchetype(es, remove, .{ RigidBody.random(rand), Model.random(rand), Tag.random(rand) }),
                                };
                            }
                        } else {
                            if (rand.float(f32) < 0.1) {
                                // Interned optional
                                _ = switch (rand.enumValue(enum {
                                    model,
                                    rb,
                                    tag,
                                    model_rb,
                                    model_tag,
                                    rb_tag,
                                    model_rb_tag,
                                })) {
                                    .model => try entity.changeArchetype(es, remove, .{@as(?Model, .{})}),
                                    .rb => try entity.changeArchetype(es, remove, .{@as(?RigidBody, null)}),
                                    .tag => try entity.changeArchetype(es, remove, .{@as(?Tag, .{})}),
                                    .model_rb => try entity.changeArchetype(es, remove, .{ @as(?Model, null), @as(?RigidBody, .{}) }),
                                    .model_tag => try entity.changeArchetype(es, remove, .{ @as(?Model, .{}), @as(?Tag, null) }),
                                    .rb_tag => try entity.changeArchetype(es, remove, .{ @as(?RigidBody, .{}), @as(?Tag, .{}) }),
                                    .model_rb_tag => try entity.changeArchetype(es, remove, .{ @as(?RigidBody, .{}), @as(?Model, null), @as(?Tag, .{}) }),
                                };
                            } else {
                                // With null components
                                _ = switch (rand.enumValue(enum {
                                    empty,
                                    model,
                                    rb,
                                    tag,
                                    model_rb,
                                    model_tag,
                                    rb_tag,
                                    model_rb_tag,
                                })) {
                                    .empty => try entity.changeArchetype(es, remove, .{}),
                                    .model => try entity.changeArchetype(es, remove, .{Model.randomOrNull(rand)}),
                                    .rb => try entity.changeArchetype(es, remove, .{RigidBody.randomOrNull(rand)}),
                                    .tag => try entity.changeArchetype(es, remove, .{Tag.randomOrNull(rand)}),
                                    .model_rb => try entity.changeArchetype(es, remove, .{ Model.randomOrNull(rand), RigidBody.randomOrNull(rand) }),
                                    .model_tag => try entity.changeArchetype(es, remove, .{ Model.randomOrNull(rand), Tag.randomOrNull(rand) }),
                                    .rb_tag => try entity.changeArchetype(es, remove, .{ RigidBody.randomOrNull(rand), Tag.randomOrNull(rand) }),
                                    .model_rb_tag => try entity.changeArchetype(es, remove, .{ RigidBody.randomOrNull(rand), Model.randomOrNull(rand), Tag.randomOrNull(rand) }),
                                };
                            }
                        }
                    }
                }
            },
            .iterate => {
                if (rand.boolean()) {
                    // No optional components
                    switch (rand.enumValue(enum {
                        empty,
                        model,
                        rb,
                        tag,
                        model_rb,
                        model_tag,
                        rb_tag,
                        model_rb_tag,
                    })) {
                        .empty => try es.checkViewIterator(rand, struct { entity: zcs.Entity }, destroy_while_iter_chance),
                        .model => try es.checkViewIterator(rand, struct { entity: zcs.Entity, model: *Model }, destroy_while_iter_chance),
                        .rb => try es.checkViewIterator(rand, struct { entity: zcs.Entity, rb: *RigidBody }, destroy_while_iter_chance),
                        .tag => try es.checkViewIterator(rand, struct { entity: zcs.Entity, tag: *Tag }, destroy_while_iter_chance),
                        .model_rb => try es.checkViewIterator(rand, struct { entity: zcs.Entity, model: *Model, rb: *RigidBody }, destroy_while_iter_chance),
                        .model_tag => try es.checkViewIterator(rand, struct { entity: zcs.Entity, model: *Model, tag: *Tag }, destroy_while_iter_chance),
                        .rb_tag => try es.checkViewIterator(rand, struct { entity: zcs.Entity, rb: *RigidBody, tag: *Tag }, destroy_while_iter_chance),
                        .model_rb_tag => try es.checkViewIterator(rand, struct { entity: zcs.Entity, model: *Model, rb: *RigidBody, tag: *Tag }, destroy_while_iter_chance),
                    }
                } else {
                    // Some components are marked as optional
                    switch (rand.enumValue(enum {
                        empty,
                        model,
                        rb,
                        tag,
                        model_rb,
                        model_tag,
                        rb_tag,
                        model_rb_tag,
                    })) {
                        .empty => try es.checkViewIterator(rand, struct { entity: zcs.Entity }, destroy_while_iter_chance),
                        .model => try es.checkViewIterator(rand, struct { entity: zcs.Entity, model: ?*Model }, destroy_while_iter_chance),
                        .rb => try es.checkViewIterator(rand, struct { entity: zcs.Entity, rb: ?*RigidBody }, destroy_while_iter_chance),
                        .tag => try es.checkViewIterator(rand, struct { entity: zcs.Entity, tag: ?*Tag }, destroy_while_iter_chance),
                        .model_rb => switch (rand.uintLessThan(u8, 3)) {
                            0 => try es.checkViewIterator(rand, struct { entity: zcs.Entity, model: ?*Model, rb: *RigidBody }, destroy_while_iter_chance),
                            1 => try es.checkViewIterator(rand, struct { entity: zcs.Entity, model: *Model, rb: ?*RigidBody }, destroy_while_iter_chance),
                            2 => try es.checkViewIterator(rand, struct { entity: zcs.Entity, model: ?*Model, rb: ?*RigidBody }, destroy_while_iter_chance),
                            else => unreachable,
                        },
                        .model_tag => switch (rand.uintLessThan(u8, 3)) {
                            0 => try es.checkViewIterator(rand, struct { entity: zcs.Entity, model: ?*Model, tag: *Tag }, destroy_while_iter_chance),
                            1 => try es.checkViewIterator(rand, struct { entity: zcs.Entity, model: *Model, tag: ?*Tag }, destroy_while_iter_chance),
                            2 => try es.checkViewIterator(rand, struct { entity: zcs.Entity, model: ?*Model, tag: ?*Tag }, destroy_while_iter_chance),
                            else => unreachable,
                        },
                        .rb_tag => switch (rand.uintLessThan(u8, 3)) {
                            0 => try es.checkViewIterator(rand, struct { entity: zcs.Entity, rb: ?*RigidBody, tag: *Tag }, destroy_while_iter_chance),
                            1 => try es.checkViewIterator(rand, struct { entity: zcs.Entity, rb: *RigidBody, tag: ?*Tag }, destroy_while_iter_chance),
                            2 => try es.checkViewIterator(rand, struct { entity: zcs.Entity, rb: ?*RigidBody, tag: ?*Tag }, destroy_while_iter_chance),
                            else => unreachable,
                        },
                        .model_rb_tag => switch (rand.uintLessThan(u8, 8)) {
                            0 => try es.checkViewIterator(rand, struct { entity: zcs.Entity, model: ?*Model, rb: *RigidBody, tag: *Tag }, destroy_while_iter_chance),
                            1 => try es.checkViewIterator(rand, struct { entity: zcs.Entity, model: *Model, rb: ?*RigidBody, tag: *Tag }, destroy_while_iter_chance),
                            2 => try es.checkViewIterator(rand, struct { entity: zcs.Entity, model: *Model, rb: *RigidBody, tag: ?*Tag }, destroy_while_iter_chance),
                            3 => try es.checkViewIterator(rand, struct { entity: zcs.Entity, model: ?*Model, rb: ?*RigidBody, tag: *Tag }, destroy_while_iter_chance),
                            4 => try es.checkViewIterator(rand, struct { entity: zcs.Entity, model: ?*Model, rb: *RigidBody, tag: ?*Tag }, destroy_while_iter_chance),
                            5 => try es.checkViewIterator(rand, struct { entity: zcs.Entity, model: *Model, rb: ?*RigidBody, tag: ?*Tag }, destroy_while_iter_chance),
                            6 => try es.checkViewIterator(rand, struct { entity: zcs.Entity, model: *Model, rb: ?*RigidBody, tag: ?*Tag }, destroy_while_iter_chance),
                            7 => try es.checkViewIterator(rand, struct { entity: zcs.Entity, model: ?*Model, rb: ?*RigidBody, tag: ?*Tag }, destroy_while_iter_chance),
                            else => unreachable,
                        },
                    }
                }
            },
            .full_check => {
                try es.fullCheck(rand);
            },
            .access_destroyed => {
                if (Entity.randomDestroyed(es, rand)) |entity| {
                    _ = try entity.exists(es);

                    _ = try entity.hasComponent(es, RigidBody);
                    _ = try entity.hasComponent(es, Model);
                    _ = try entity.hasComponent(es, Tag);

                    _ = try entity.getComponent(es, RigidBody);
                    _ = try entity.getComponent(es, Model);
                    _ = try entity.getComponent(es, Tag);

                    var remove: ComponentFlags = .{};
                    inline for (@typeInfo(ComponentFlags).@"struct".fields) |field| {
                        @field(remove, field.name) = rand.boolean();
                    }
                    try entity.changeArchetype(es, remove, .{ RigidBody.randomOrNull(rand), Model.randomOrNull(rand), Tag.randomOrNull(rand) });
                    try entity.changeArchetype(es, remove, .{ RigidBody.randomOrNull(rand), Tag.randomOrNull(rand) });
                    try entity.changeArchetype(es, remove, .{ RigidBody.randomOrNull(rand), Model.randomOrNull(rand) });

                    try entity.destroy(es);
                }
            },
            .reserve => {
                const count = try es.count();
                const reserved = try es.reserved();
                _ = try Entity.reserve(es);
                try expectEqual(count, try es.count());
                try expectEqual(reserved + 1, try es.reserved());
            },
        }
    }

    try es.fullCheck(rand);
}

const RandomComponents = struct {
    const cap = 8;
    models: std.BoundedArray(Model, cap) = .{},
    rbs: std.BoundedArray(RigidBody, cap) = .{},
    tags: std.BoundedArray(Tag, cap) = .{},
    buf: std.BoundedArray(OptionalComponent, cap) = .{},

    pub fn randomize(self: *@This(), es: *const Entities, rand: std.Random) void {
        for (0..rand.uintAtMost(usize, cap)) |_| {
            if (rand.float(f32) < 0.2) {
                self.buf.appendAssumeCapacity(.none);
            } else {
                self.buf.appendAssumeCapacity(switch (rand.enumValue(enum {
                    model,
                    rb,
                    tag,
                })) {
                    .model => b: {
                        if (rand.float(f32) < 0.1) {
                            break :b .{
                                .actual = .initInterned(&es.actual, &Model{}),
                                .expected_name = Model.name,
                            };
                        } else {
                            const model = self.models.addOneAssumeCapacity();
                            model.* = Model.random(rand);
                            break :b .{
                                .actual = .init(&es.actual, model),
                                .expected_name = Model.name,
                            };
                        }
                    },
                    .rb => b: {
                        if (rand.float(f32) < 0.1) {
                            break :b .{
                                .actual = .initInterned(&es.actual, &RigidBody{}),
                                .expected_name = RigidBody.name,
                            };
                        } else {
                            const rb = self.rbs.addOneAssumeCapacity();
                            rb.* = RigidBody.random(rand);
                            break :b .{
                                .actual = .init(&es.actual, rb),
                                .expected_name = RigidBody.name,
                            };
                        }
                    },
                    .tag => b: {
                        if (rand.float(f32) < 0.1) {
                            break :b .{
                                .actual = .initInterned(&es.actual, &Tag{}),
                                .expected_name = Tag.name,
                            };
                        } else {
                            const tag = self.tags.addOneAssumeCapacity();
                            tag.* = Tag.random(rand);
                            break :b .{
                                .actual = .init(&es.actual, tag),
                                .expected_name = Tag.name,
                            };
                        }
                    },
                });
            }
        }
    }
};
