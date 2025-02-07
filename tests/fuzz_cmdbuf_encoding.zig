//! Fuzz tests for the command buff encoding.

const std = @import("std");
const zcs = @import("zcs");

const gpa = std.testing.allocator;

const Entities = zcs.Entities;
const Comp = zcs.Comp;
const Entity = zcs.Entity;
const CmdBuf = zcs.CmdBuf;

const comps = @import("comps.zig");
const RigidBody = comps.RigidBody;
const Model = comps.Model;
const Tag = comps.Tag;

const Parser = @import("Parser.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const max_entities = 100000;
const comp_bytes = 100000;
const cmds_capacity = 4096;
const change_cap = 16;

test "fuzz cmdbuf encoding" {
    try std.testing.fuzz(fuzzCmdBufEncoding, .{ .corpus = &.{} });
}

test "rand cmdbuf encoding" {
    var xoshiro_256: std.Random.Xoshiro256 = .init(0);
    const rand = xoshiro_256.random();
    const input: []u8 = try gpa.alloc(u8, 8192);
    defer gpa.free(input);
    rand.bytes(input);
    try fuzzCmdBufEncoding(input);
}

const OracleCmd = union(enum) {
    destroy: Entity,
    change_arch: struct {
        const Op = union(enum) {
            add: Comp,
            remove: Comp.Id,
        };
        entity: Entity,
        ops: std.ArrayListUnmanaged(Op) = .empty,
    },

    fn deinit(self: *@This()) void {
        switch (self.*) {
            .destroy => {},
            .change_arch => |*change_arch| {
                for (change_arch.ops.items) |op| {
                    switch (op) {
                        .add => |comp| if (comp.as(RigidBody)) |rb| {
                            gpa.destroy(rb);
                        } else if (comp.as(Model)) |m| {
                            gpa.destroy(m);
                        } else if (comp.as(Tag)) |t| {
                            gpa.destroy(t);
                        } else {
                            @panic("unexpected component type");
                        },
                        .remove => {},
                    }
                }
                change_arch.ops.deinit(gpa);
            },
        }
        self.* = undefined;
    }
};

/// Pick a random entity from a small set.
fn randomEntity(parser: *Parser) Entity {
    return .{ .key = .{
        .index = parser.next(u8) % 10,
        .generation = @enumFromInt(parser.next(u8) % 3),
    } };
}

/// Randomize the given entity from a small set of entities, occasionally leaving it unchanged.
fn randomizeEntity(parser: *Parser, entity: *Entity) void {
    // Sometimes just use the last entity, this increases the chances that we test dedup logic
    if (parser.next(u8) < 50) return;

    // Most of the time, return a new entity, but pick from a small set to increase the chance of
    // catching dedup happening when it shouldn't
    entity.* = randomEntity(parser);
}

fn fuzzCmdBufEncoding(input: []const u8) !void {
    var parser: Parser = .init(input);

    var es: Entities = try .init(gpa, .{
        .max_entities = max_entities,
        .comp_bytes = comp_bytes,
    });
    defer es.deinit(gpa);

    var cmds: CmdBuf = try .init(gpa, &es, .{
        .cmds = cmds_capacity,
        .avg_comp_bytes = @sizeOf(RigidBody),
    });
    defer cmds.deinit(gpa, &es);

    var oracle: std.ArrayListUnmanaged(OracleCmd) = try .initCapacity(gpa, 1024);
    defer oracle.deinit(gpa);

    var e = randomEntity(&parser);
    while (!parser.isEmpty()) {
        defer {
            for (oracle.items) |*cmd| {
                cmd.deinit();
            }
            oracle.clearRetainingCapacity();
        }

        for (0..parser.next(u10)) |_| {
            switch (parser.next(enum {
                destroy,
                change_arch,
            })) {
                .destroy => {
                    randomizeEntity(&parser, &e);
                    e.destroyCmd(&cmds);
                    oracle.appendAssumeCapacity(.{ .destroy = e });
                },
                .change_arch => {
                    // Get a random entity
                    randomizeEntity(&parser, &e);

                    // Dedup with the last command if it's also a change arch on the same entity
                    const oracle_cmd = b: {
                        // See if we can just update the last command
                        if (oracle.items.len > 0) {
                            const prev = &oracle.items[oracle.items.len - 1];
                            switch (prev.*) {
                                .change_arch => |*change_arch| if (change_arch.entity == e) {
                                    break :b change_arch;
                                },
                                else => {},
                            }
                        }

                        // Generate a new command
                        const last_cmd = oracle.addOneAssumeCapacity();
                        last_cmd.* = .{ .change_arch = .{ .entity = e } };
                        break :b &last_cmd.change_arch;
                    };

                    for (0..parser.nextBetween(u8, 1, 5)) |_| {
                        switch (parser.next(enum {
                            add_val,
                            add_ptr,
                            commit,
                            remove,
                        })) {
                            .add_val => switch (parser.next(enum { rb, model, tag })) {
                                .rb => {
                                    const val = try gpa.create(RigidBody);
                                    val.* = parser.next(RigidBody);
                                    const comp: Comp = .init(RigidBody, val);
                                    e.addCompValCmd(&cmds, comp);
                                    try oracle_cmd.ops.append(gpa, .{ .add = comp });
                                },
                                .model => {
                                    const val = try gpa.create(Model);
                                    val.* = parser.next(Model);
                                    const comp: Comp = .init(Model, val);
                                    e.addCompValCmd(&cmds, comp);
                                    try oracle_cmd.ops.append(gpa, .{ .add = comp });
                                },
                                .tag => {
                                    const val = try gpa.create(Tag);
                                    val.* = parser.next(Tag);
                                    const comp: Comp = .init(Tag, val);
                                    e.addCompValCmd(&cmds, comp);
                                    try oracle_cmd.ops.append(gpa, .{ .add = comp });
                                },
                            },
                            .add_ptr => switch (parser.next(enum { rb, model, tag })) {
                                .rb => {
                                    const val = try gpa.create(RigidBody);
                                    val.* = RigidBody.interned[parser.nextLessThan(u8, RigidBody.interned.len)];
                                    const comp: Comp = .init(RigidBody, val);
                                    e.addCompPtrCmd(&cmds, comp);
                                    try oracle_cmd.ops.append(gpa, .{ .add = comp });
                                },
                                .model => {
                                    const val = try gpa.create(Model);
                                    val.* = Model.interned[parser.nextLessThan(u8, Model.interned.len)];
                                    const comp: Comp = .init(Model, val);
                                    e.addCompPtrCmd(&cmds, comp);
                                    try oracle_cmd.ops.append(gpa, .{ .add = comp });
                                },
                                .tag => {
                                    const val = try gpa.create(Tag);
                                    val.* = Tag.interned[parser.nextLessThan(u8, Tag.interned.len)];
                                    const comp: Comp = .init(Tag, val);
                                    e.addCompPtrCmd(&cmds, comp);
                                    try oracle_cmd.ops.append(gpa, .{ .add = comp });
                                },
                            },
                            .commit => {
                                e.commitCmd(&cmds);
                            },
                            .remove => switch (parser.next(enum { rb, model, tag })) {
                                .rb => {
                                    e.remCompCmd(&cmds, RigidBody);
                                    try oracle_cmd.ops.append(gpa, .{
                                        .remove = zcs.compId(RigidBody),
                                    });
                                },
                                .model => {
                                    e.remCompCmd(&cmds, Model);
                                    try oracle_cmd.ops.append(gpa, .{
                                        .remove = zcs.compId(Model),
                                    });
                                },
                                .tag => {
                                    e.remCompCmd(&cmds, Tag);
                                    try oracle_cmd.ops.append(gpa, .{
                                        .remove = zcs.compId(Tag),
                                    });
                                },
                            },
                        }
                    }

                    e.commitCmd(&cmds);
                },
            }
        }

        var iter = cmds.iterator();
        for (oracle.items) |expected| {
            switch (expected) {
                .destroy => |expected_entity| {
                    try expectEqual(expected_entity, iter.next().?.destroy);
                },
                .change_arch => |oracle_cmd| {
                    const cmd = iter.next().?.change_arch;
                    try expectEqual(oracle_cmd.entity, cmd.entity);
                    var ops = cmd.iterator();
                    for (oracle_cmd.ops.items) |oracle_op| {
                        switch (oracle_op) {
                            .add => |oracle_comp| {
                                const add = ops.next().?.add;
                                try expectEqual(oracle_comp.id, add.id);

                                if (oracle_comp.as(RigidBody)) |v| {
                                    try expectEqual(v.*, add.as(RigidBody).?.*);
                                } else if (oracle_comp.as(Model)) |v| {
                                    try expectEqual(v.*, add.as(Model).?.*);
                                } else if (oracle_comp.as(Tag)) |v| {
                                    try expectEqual(v.*, add.as(Tag).?.*);
                                } else {
                                    @panic("unexpected comp");
                                }
                            },
                            .remove => |oracle_id| try expectEqual(oracle_id, ops.next().?.remove),
                        }
                    }
                    try expectEqual(null, ops.next());
                },
            }
        }
        try expectEqual(null, iter.next());

        cmds.clear(&es);
    }
}
