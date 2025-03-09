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
const comp_bytes = 100000;

test "fuzz transforms cmdbuf" {
    try std.testing.fuzz({}, fuzzTransformsCmdBuf, .{ .corpus = &.{} });
}

test "rand transforms cmdbuf" {
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
        .comp_bytes = comp_bytes,
    });
    defer es.deinit(gpa);

    var cb: CmdBuf = try .init(gpa, &es, .{
        .cmds = cmds_capacity,
        .avg_cmd_bytes = @sizeOf(Node),
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
            var iter = es.iterator(.{});
            while (iter.next()) |e| {
                try all.append(gpa, e);
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
                    child.add(&cb, Transform, .initLocal(.{
                        .pos = .{
                            .x = smith.nextBetween(f32, -100.0, 100.0),
                            .y = smith.nextBetween(f32, -100.0, 100.0),
                        },
                        .orientation = .fromAngle(smith.next(f32)),
                    }));
                    try all.append(gpa, child);
                    if (smith.next(u8) > 40) {
                        const parent: Entity.Optional = all.items[smith.nextLessThan(usize, all.items.len)].toOptional();
                        if (log) std.debug.print("  {}.parent = {}\n", .{ child, parent });
                        child.cmd(&cb, SetParent, .{parent});
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
                                child.add(&cb, Transform, .initLocal(.{
                                    .pos = .{
                                        .x = smith.nextBetween(f32, -100.0, 100.0),
                                        .y = smith.nextBetween(f32, -100.0, 100.0),
                                    },
                                    .orientation = .fromAngle(smith.next(f32)),
                                }));
                                try all.append(gpa, child);
                                if (smith.next(u8) > 40) {
                                    const parent: Entity.Optional = all.items[smith.nextLessThan(usize, all.items.len)].toOptional();
                                    if (log) std.debug.print("  {}.parent = {}\n", .{ child, parent });
                                    child.cmd(&cb, SetParent, .{parent});
                                }
                            }
                        },
                        .parent => {
                            const parent: Entity.Optional = if (smith.nextLessThan(u8, 100) > 10) b: {
                                break :b all.items[smith.nextLessThan(usize, all.items.len)].toOptional();
                            } else .none;
                            const child = all.items[smith.nextLessThan(usize, all.items.len)];
                            if (log) std.debug.print("  {}.parent = {}\n", .{ child, parent });
                            child.cmd(&cb, SetParent, .{parent});
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
                                transform.setLocalPos(&es, &cb, .{
                                    .x = smith.nextBetween(f32, -100.0, 100.0),
                                    .y = smith.nextBetween(f32, -100.0, 100.0),
                                });
                            }
                            if (smith.next(bool)) {
                                transform.setLocalOrientation(&es, &cb, .fromAngle(smith.next(f32)));
                                if (log) std.debug.print("  {} local_pos = {}, local_orientation = {}\n", .{
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

        exec(&es, &cb);
        Transform.syncAllImmediate(&es);
        try checkOracle(&es);
    }
}

pub fn exec(es: *Entities, cb: *CmdBuf) void {
    var batches = cb.iterator();
    while (batches.next()) |batch| {
        var node_exec: Node.Exec = .{};

        var arch_change = batch.getArchChangeImmediate(es);
        {
            var iter = batch.iterator();
            while (iter.next()) |cmd| {
                node_exec.beforeCmdImmediate(es, batch, &arch_change, cmd);
            }
        }

        _ = batch.execImmediate(es, arch_change);

        {
            var iter = batch.iterator();
            while (iter.next()) |cmd| {
                node_exec.afterCmdImmediate(es, batch, arch_change, cmd) catch |err|
                    @panic(@errorName(err));
                Transform.Exec.afterCmdImmediate(es, batch, cmd);
            }
        }
    }

    cb.clear(es);
}

fn checkOracle(es: *const Entities) !void {
    if (log) std.debug.print("check oracle\n", .{});

    // All dirty events should have been cleared by now
    var dirty_events = es.viewIterator(struct { dirty: *const Transform.Dirty });
    try std.testing.expectEqual(null, dirty_events.next());

    var path: std.ArrayListUnmanaged(*const Transform) = .{};
    defer path.deinit(gpa);

    var iter = es.viewIterator(struct {
        node: ?*const Node,
        transform: *const Transform,
    });
    while (iter.next()) |vw| {
        // The cache should be clean
        try std.testing.expect(vw.transform.cache == .clean);

        // Get the path
        try path.append(gpa, vw.transform);
        if (vw.node) |node| {
            var ancestors = node.ancestorIterator();
            while (ancestors.next(es)) |ancestor| {
                const transform = ancestor.get(es, Transform) orelse break;
                try path.append(gpa, transform);
            }
        }
        if (log) std.debug.print("  {} path len: {}\n", .{ Entity.from(es, vw.transform), path.items.len });

        // Iterate over the path in reverse order to get the ground truth world matrix
        var world_from_model: Mat2x3 = .identity;
        var sum: Vec2 = .zero;
        while (path.pop()) |ancestor| {
            const rotation: Mat2x3 = .rotation(ancestor.getLocalOrientation());
            const translation: Mat2x3 = .translation(ancestor.getLocalPos());
            world_from_model = rotation.applied(translation).applied(world_from_model);
            sum.add(ancestor.getLocalPos());
        }
        try expectMat2x3Equal(world_from_model, vw.transform.getWorldFromModel());
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
