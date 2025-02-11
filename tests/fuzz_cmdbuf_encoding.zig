//! Fuzz tests for the command buff encoding.

const std = @import("std");
const zcs = @import("zcs");

const gpa = std.testing.allocator;

const Entities = zcs.Entities;
const Any = zcs.Any;
const CompFlag = zcs.CompFlag;
const TypeId = zcs.TypeId;
const Entity = zcs.Entity;
const CmdBuf = zcs.CmdBuf;

const types = @import("types.zig");
const RigidBody = types.RigidBody;
const Model = types.Model;
const Tag = types.Tag;
const FooEv = types.FooEv;
const BarEv = types.BarEv;
const BazEv = types.BazEv;

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

const OracleBatch = struct {
    const Cmd = union(enum) {
        add_comp: Any,
        remove_comp: TypeId,
        event: Any,
        destroy,
    };
    entity: Entity,
    cmds: std.ArrayListUnmanaged(Cmd) = .empty,

    fn deinit(self: *@This()) void {
        for (self.cmds.items) |cmd| {
            switch (cmd) {
                .add_comp, .event => |any| if (any.as(RigidBody)) |v| {
                    gpa.destroy(v);
                } else if (any.as(Model)) |v| {
                    gpa.destroy(v);
                } else if (any.as(Tag)) |v| {
                    gpa.destroy(v);
                } else if (any.as(FooEv)) |v| {
                    gpa.destroy(v);
                } else if (any.as(BarEv)) |v| {
                    gpa.destroy(v);
                } else if (any.as(BazEv)) |v| {
                    gpa.destroy(v);
                } else {
                    @panic("unexpected type");
                },
                .remove_comp, .destroy => {},
            }
        }
        self.cmds.deinit(gpa);
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
        .avg_any_bytes = @sizeOf(RigidBody),
    });
    defer cmds.deinit(gpa, &es);

    var oracle: std.ArrayListUnmanaged(OracleBatch) = try .initCapacity(gpa, 1024);
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
            // Get a random entity
            randomizeEntity(&parser, &e);

            // Dedup with the last command if it's also a change arch on the same entity
            const oracle_batch = b: {
                // See if we can just update the last command
                if (oracle.items.len > 0) {
                    const prev = &oracle.items[oracle.items.len - 1];
                    if (prev.entity == e) break :b prev;
                }

                // Generate a new command
                const last_cmd = oracle.addOneAssumeCapacity();
                last_cmd.* = .{ .entity = e };
                break :b last_cmd;
            };

            for (0..parser.nextBetween(u8, 1, 5)) |_| {
                if (parser.next(bool)) {
                    e.destroyCmd(&cmds);
                    try oracle_batch.cmds.append(gpa, .destroy);
                } else switch (parser.next(enum {
                    add_comp_val,
                    add_comp_ptr,
                    event_val,
                    event_ptr,
                    commit,
                    remove,
                })) {
                    .add_comp_val => switch (parser.next(enum { rb, model, tag })) {
                        .rb => {
                            const val = try gpa.create(RigidBody);
                            val.* = parser.next(RigidBody);
                            const comp: Any = .init(RigidBody, val);
                            e.addCompValCmd(&cmds, comp);
                            try oracle_batch.cmds.append(gpa, .{ .add_comp = comp });
                        },
                        .model => {
                            const val = try gpa.create(Model);
                            val.* = parser.next(Model);
                            const comp: Any = .init(Model, val);
                            e.addCompValCmd(&cmds, comp);
                            try oracle_batch.cmds.append(gpa, .{ .add_comp = comp });
                        },
                        .tag => {
                            const val = try gpa.create(Tag);
                            val.* = parser.next(Tag);
                            const comp: Any = .init(Tag, val);
                            e.addCompValCmd(&cmds, comp);
                            try oracle_batch.cmds.append(gpa, .{ .add_comp = comp });
                        },
                    },
                    .add_comp_ptr => switch (parser.next(enum { rb, model, tag })) {
                        .rb => {
                            const val = try gpa.create(RigidBody);
                            val.* = RigidBody.interned[parser.nextLessThan(u8, RigidBody.interned.len)];
                            const comp: Any = .init(RigidBody, val);
                            e.addCompPtrCmd(&cmds, comp);
                            try oracle_batch.cmds.append(gpa, .{ .add_comp = comp });
                        },
                        .model => {
                            const val = try gpa.create(Model);
                            val.* = Model.interned[parser.nextLessThan(u8, Model.interned.len)];
                            const comp: Any = .init(Model, val);
                            e.addCompPtrCmd(&cmds, comp);
                            try oracle_batch.cmds.append(gpa, .{ .add_comp = comp });
                        },
                        .tag => {
                            const val = try gpa.create(Tag);
                            val.* = Tag.interned[parser.nextLessThan(u8, Tag.interned.len)];
                            const comp: Any = .init(Tag, val);
                            e.addCompPtrCmd(&cmds, comp);
                            try oracle_batch.cmds.append(gpa, .{ .add_comp = comp });
                        },
                    },
                    .event_val => switch (parser.next(enum { foo, bar, baz })) {
                        .foo => {
                            const val = try gpa.create(FooEv);
                            val.* = parser.next(FooEv);
                            const event: Any = .init(FooEv, val);
                            e.eventValCmd(&cmds, event);
                            try oracle_batch.cmds.append(gpa, .{ .event = event });
                        },
                        .bar => {
                            const val = try gpa.create(BarEv);
                            val.* = parser.next(BarEv);
                            const event: Any = .init(BarEv, val);
                            e.eventValCmd(&cmds, event);
                            try oracle_batch.cmds.append(gpa, .{ .event = event });
                        },
                        .baz => {
                            const val = try gpa.create(BazEv);
                            val.* = parser.next(BazEv);
                            const event: Any = .init(BazEv, val);
                            e.eventValCmd(&cmds, event);
                            try oracle_batch.cmds.append(gpa, .{ .event = event });
                        },
                    },
                    .event_ptr => switch (parser.next(enum { foo, bar, baz })) {
                        .foo => {
                            const val = try gpa.create(FooEv);
                            val.* = FooEv.interned[parser.nextLessThan(u8, FooEv.interned.len)];
                            const comp: Any = .init(FooEv, val);
                            e.eventPtrCmd(&cmds, comp);
                            try oracle_batch.cmds.append(gpa, .{ .event = comp });
                        },
                        .bar => {
                            const val = try gpa.create(BarEv);
                            val.* = BarEv.interned[parser.nextLessThan(u8, BarEv.interned.len)];
                            const comp: Any = .init(BarEv, val);
                            e.eventPtrCmd(&cmds, comp);
                            try oracle_batch.cmds.append(gpa, .{ .event = comp });
                        },
                        .baz => {
                            const val = try gpa.create(BazEv);
                            val.* = BazEv.interned[parser.nextLessThan(u8, BazEv.interned.len)];
                            const comp: Any = .init(BazEv, val);
                            e.eventPtrCmd(&cmds, comp);
                            try oracle_batch.cmds.append(gpa, .{ .event = comp });
                        },
                    },
                    .commit => {
                        e.commitCmd(&cmds);
                    },
                    .remove => switch (parser.next(enum { rb, model, tag })) {
                        .rb => {
                            e.remCompCmd(&cmds, RigidBody);
                            try oracle_batch.cmds.append(gpa, .{
                                .remove_comp = zcs.typeId(RigidBody),
                            });
                        },
                        .model => {
                            e.remCompCmd(&cmds, Model);
                            try oracle_batch.cmds.append(gpa, .{
                                .remove_comp = zcs.typeId(Model),
                            });
                        },
                        .tag => {
                            e.remCompCmd(&cmds, Tag);
                            try oracle_batch.cmds.append(gpa, .{
                                .remove_comp = zcs.typeId(Tag),
                            });
                        },
                    },
                }
            }

            e.commitCmd(&cmds);
        }

        var iter = cmds.iterator();
        for (oracle.items) |oracle_batch| {
            const batch = iter.next().?;
            try expectEqual(oracle_batch.entity, batch.entity);
            var batch_iter = batch.iterator();
            for (oracle_batch.cmds.items) |oracle_op| {
                switch (oracle_op) {
                    .add_comp => |oracle_comp| {
                        const add = batch_iter.next().?.add_comp;
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
                    .remove_comp => |oracle_id| {
                        try expectEqual(oracle_id, batch_iter.next().?.remove_comp);
                    },
                    .event => |oracle_event| {
                        const event = batch_iter.next().?.event;
                        try expectEqual(oracle_event.id, event.id);

                        if (oracle_event.as(FooEv)) |v| {
                            try expectEqual(v.*, event.as(FooEv).?.*);
                        } else if (oracle_event.as(BarEv)) |v| {
                            try expectEqual(v.*, event.as(BarEv).?.*);
                        } else if (oracle_event.as(BazEv)) |v| {
                            try expectEqual(v.*, event.as(BazEv).?.*);
                        } else {
                            @panic("unexpected comp");
                        }
                    },
                    .destroy => try expectEqual(.destroy, batch_iter.next().?),
                }
            }
            try expectEqual(null, batch_iter.next());
        }
        try expectEqual(null, iter.next());

        cmds.clear(&es);
    }
}
