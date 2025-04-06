//! Tests for the `Node` extension.

const std = @import("std");
const zcs = @import("zcs");
const types = @import("../types.zig");

const Smith = @import("../Smith.zig");

const Model = types.Model;

const Entity = zcs.Entity;
const Entities = zcs.Entities;
const Any = zcs.Any;
const CompFlag = zcs.CompFlag;
const CmdBuf = zcs.CmdBuf;
const Node = zcs.ext.Node;
const SetParent = zcs.ext.Node.SetParent;
const Transform = zcs.ext.Transform2D;
const Vec2 = zcs.ext.geom.Vec2;
const Mat2x3 = zcs.ext.geom.Mat2x3;

const gpa = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualEntity = @import("../root.zig").expectEqualEntity;

const log = false;

const cmds_capacity = 100;
const max_entities = 100000;

// Smoke test to verify that the transform exec does actually call the node exec
test "exec" {
    defer CompFlag.unregisterAll();

    var es: Entities = try .init(gpa, .{
        .max_entities = 128,
        .max_archetypes = 8,
        .max_chunks = 8,
    });
    defer es.deinit(gpa);

    var cb: CmdBuf = try .init(gpa, &es, .{
        .cmds = 2,
        .data = .{ .bytes_per_cmd = @sizeOf(SetParent) },
    });
    defer cb.deinit(gpa, &es);

    const child: Entity = .reserve(&cb);
    const parent: Entity = .reserve(&cb);
    cb.ext(SetParent, .{ .child = child, .parent = parent.toOptional() });
    Transform.exec.immediate(&es, &cb);

    const child_node = child.get(&es, Node).?;
    try expectEqual(child_node.parent, parent.toOptional());
}

test "fuzz cb" {
    try std.testing.fuzz({}, fuzzTransformsCmdBuf, .{ .corpus = &.{} });
}

test "rand cb" {
    var xoshiro_256: std.Random.Xoshiro256 = .init(0);
    const rand = xoshiro_256.random();
    const input: []u8 = try gpa.alloc(u8, 262144);
    defer gpa.free(input);
    rand.bytes(input);
    try fuzzTransformsCmdBuf({}, input);
}

fn fuzzTransformsCmdBuf(_: void, input: []const u8) !void {
    defer CompFlag.unregisterAll();

    var smith: Smith = .init(input);

    var es: Entities = try .init(gpa, .{
        .max_entities = max_entities,
        .max_archetypes = 8,
        .max_chunks = 1024,
    });
    defer es.deinit(gpa);

    var cb: CmdBuf = try .init(gpa, &es, .{
        .cmds = cmds_capacity,
        .data = .{ .bytes_per_cmd = @sizeOf(Node) },
    });
    defer cb.deinit(gpa, &es);

    var all: std.ArrayListUnmanaged(Entity) = .{};
    defer all.deinit(gpa);

    const Mode = union(enum) {
        build,
        mutate: struct { steps: u8 },
    };
    var mode: Mode = .build;

    while (!smith.isEmpty()) {
        // Get a list of all the entities
        {
            all.clearRetainingCapacity();
            var iter = es.iterator(struct { e: Entity });
            while (iter.next(&es)) |vw| {
                try all.append(gpa, vw.e);
            }
        }

        switch (mode) {
            .build => {
                // Build a random tree with interesting topology
                if (log) std.debug.print("build phase ({}/{})\n", .{ smith.index, smith.input.len });
                for (0..smith.nextBetween(u8, 8, 16)) |_| {
                    if (smith.isEmpty()) break;

                    const child = Entity.reserve(&cb);
                    if (log) std.debug.print("  reserve {}\n", .{child});
                    child.add(&cb, Transform, .{
                        .pos = .{
                            .x = smith.nextBetween(f32, -100.0, 100.0),
                            .y = smith.nextBetween(f32, -100.0, 100.0),
                        },
                        .rot = .fromAngle(smith.next(f32)),
                        .relative = smith.next(u8) > 25 or true,
                    });
                    try all.append(gpa, child);
                    if (smith.next(u8) > 40) {
                        const parent: Entity.Optional = all.items[smith.nextLessThan(usize, all.items.len)].toOptional();
                        if (log) std.debug.print("  {}.parent = {}\n", .{ child, parent });
                        cb.ext(SetParent, .{ .child = child, .parent = parent });
                    }
                }
                mode = .{ .mutate = .{ .steps = 5 } };
            },
            .mutate => |mutate| {
                if (log) std.debug.print("mutate step {} ({}/{})\n", .{ mutate.steps, smith.index, smith.input.len });
                // Generate random commands
                for (0..smith.nextBetween(u8, 1, 10)) |_| {
                    switch (smith.next(enum { reserve, parent, remove, move })) {
                        .reserve => {
                            if (smith.next(bool)) {
                                const child = Entity.reserve(&cb);
                                if (log) std.debug.print("  reserve {}\n", .{child});
                                child.add(&cb, Transform, .{
                                    .pos = .{
                                        .x = smith.nextBetween(f32, -100.0, 100.0),
                                        .y = smith.nextBetween(f32, -100.0, 100.0),
                                    },
                                    .rot = .fromAngle(smith.next(f32)),
                                    .relative = smith.next(u8) > 25,
                                });
                                try all.append(gpa, child);
                                if (smith.next(u8) > 40) {
                                    const parent: Entity.Optional = all.items[smith.nextLessThan(usize, all.items.len)].toOptional();
                                    if (log) std.debug.print("  {}.parent = {}\n", .{ child, parent });
                                    cb.ext(SetParent, .{ .child = child, .parent = parent });
                                }
                            }
                        },
                        .parent => if (all.items.len > 0) {
                            const parent: Entity.Optional = if (smith.nextLessThan(u8, 100) > 10) b: {
                                break :b all.items[smith.nextLessThan(usize, all.items.len)].toOptional();
                            } else .none;
                            const child = all.items[smith.nextLessThan(usize, all.items.len)];
                            if (log) std.debug.print("  {}.parent = {}\n", .{ child, parent });
                            cb.ext(SetParent, .{ .child = child, .parent = parent });
                        },
                        .remove => {
                            // Sometimes destroy entities, but not too often
                            if (all.items.len == 0) continue;
                            const e = all.items[smith.nextLessThan(usize, all.items.len)];
                            switch (smith.next(enum { transform, node, entity })) {
                                .transform => {
                                    if (log) std.debug.print("  remove transform from {}\n", .{e});
                                    e.remove(&cb, Transform);
                                },
                                .node => {
                                    if (log) std.debug.print("  remove node from {}\n", .{e});
                                    e.remove(&cb, Node);
                                },
                                .entity => {
                                    if (log) std.debug.print("  destroy {}\n", .{e});
                                    e.destroy(&cb);
                                },
                            }
                        },
                        .move => {
                            if (all.items.len == 0) continue;
                            const e = all.items[smith.nextLessThan(usize, all.items.len)];
                            const transform = e.get(&es, Transform) orelse continue;
                            if (smith.next(bool)) {
                                transform.setPos(&es, .{
                                    .x = smith.nextBetween(f32, -100.0, 100.0),
                                    .y = smith.nextBetween(f32, -100.0, 100.0),
                                });
                            }
                            if (smith.next(bool)) {
                                if (smith.next(bool)) {
                                    transform.setRot(&es, .fromAngle(smith.next(f32)));
                                } else {
                                    // Mainly making sure it compiles
                                    transform.rotate(&es, .fromTo(.x_pos, .y_pos));
                                }
                                if (log) std.debug.print("  {} pos = {}, rot = {}\n", .{
                                    e,
                                    transform.getLocalPos(),
                                    transform.getLocalOrientation(),
                                });
                            }
                        },
                    }
                }
                if (mutate.steps == 0) {
                    mode = .build;
                } else {
                    mode = .{ .mutate = .{ .steps = mutate.steps - 1 } };
                }
            },
        }

        Transform.exec.immediate(&es, &cb);
        cb.clear(&es);
        try checkOracle(&es);
    }
}

fn checkOracle(es: *const Entities) !void {
    if (log) std.debug.print("check oracle\n", .{});

    var path: std.ArrayListUnmanaged(*const Transform) = .{};
    defer path.deinit(gpa);

    var iter = es.iterator(struct {
        node: ?*const Node,
        transform: *const Transform,
    });
    while (iter.next(es)) |vw| {
        // Get the path
        try path.append(gpa, vw.transform);
        if (vw.transform.relative) {
            if (vw.node) |node| {
                var ancestors = node.ancestorIterator();
                while (ancestors.next(es)) |ancestor| {
                    const transform = es.getComp(ancestor, Transform) orelse break;
                    try path.append(gpa, transform);
                    if (!transform.relative) break;
                }
            }
        }
        if (log) std.debug.print("  {} path len: {}\n", .{ Entity.from(es, vw.transform), path.items.len });

        // Iterate over the path in reverse order to get the ground truth world matrix
        var world_from_model: Mat2x3 = .identity;
        var sum: Vec2 = .zero;
        while (path.pop()) |ancestor| {
            const rotation: Mat2x3 = .rotation(ancestor.rot);
            const translation: Mat2x3 = .translation(ancestor.pos);
            world_from_model = rotation.applied(translation).applied(world_from_model);
            sum.add(ancestor.pos);
        }
        try expectMat2x3Equal(world_from_model, vw.transform.world_from_model);
        try expectEqual(world_from_model.getTranslation(), vw.transform.getWorldPos());
    }
}

fn expectMat2x3Equal(expected: Mat2x3, found: Mat2x3) !void {
    if (!expected.eql(found)) {
        std.debug.print("expected:\n{d} {d} {d}\n{d} {d} {d}\n", .{
            expected.r0.x,
            expected.r0.y,
            expected.r0.z,
            expected.r1.x,
            expected.r1.y,
            expected.r1.z,
        });
        std.debug.print("found:\n{d} {d} {d}\n{d} {d} {d}\n", .{
            found.r0.x,
            found.r0.y,
            found.r0.z,
            found.r1.x,
            found.r1.y,
            found.r1.z,
        });
        return error.TestExpectedMat2x3Equal;
    }
}
