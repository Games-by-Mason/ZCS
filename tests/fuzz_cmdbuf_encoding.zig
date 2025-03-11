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
const FooExt = types.FooExt;
const BarExt = types.BarExt;
const BazExt = types.BazExt;

const Smith = @import("Smith.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const max_entities = 100000;
const comp_bytes = 100000;
const cmds_capacity = 4096;
const change_cap = 16;

test "fuzz encoding" {
    try std.testing.fuzz({}, fuzzCmdBufEncoding, .{ .corpus = &.{} });
}

test "rand encoding" {
    var xoshiro_256: std.Random.Xoshiro256 = .init(0);
    const rand = xoshiro_256.random();
    const input: []u8 = try gpa.alloc(u8, 131072);
    defer gpa.free(input);
    rand.bytes(input);
    try fuzzCmdBufEncoding({}, input);
}

const OracleBatch = struct {
    const Cmd = union(enum) {
        add: Any,
        remove: TypeId,
        ext: Any,
        destroy,
    };
    entity: Entity,
    cb: std.ArrayListUnmanaged(Cmd) = .empty,

    fn deinit(self: *@This()) void {
        for (self.cb.items) |cmd| {
            switch (cmd) {
                .add, .ext => |any| if (any.as(RigidBody)) |v| {
                    gpa.destroy(v);
                } else if (any.as(Model)) |v| {
                    gpa.destroy(v);
                } else if (any.as(Tag)) |v| {
                    gpa.destroy(v);
                } else if (any.as(FooExt)) |v| {
                    gpa.destroy(v);
                } else if (any.as(BarExt)) |v| {
                    gpa.destroy(v);
                } else if (any.as(BazExt)) |v| {
                    gpa.destroy(v);
                } else {
                    @panic("unexpected type");
                },
                .remove, .destroy => {},
            }
        }
        self.cb.deinit(gpa);
        self.* = undefined;
    }
};

/// Pick a random entity from a small set.
fn randomEntity(smith: *Smith) Entity {
    return .{ .key = .{
        .index = smith.next(u8) % 10,
        .generation = @enumFromInt(smith.next(u8) % 3),
    } };
}

/// Randomize the given entity from a small set of entities, occasionally leaving it unchanged.
fn randomizeEntity(smith: *Smith, entity: *Entity) void {
    // Sometimes just use the last entity, this increases the chances that we test dedup logic
    if (smith.next(u8) < 50) return;

    // Most of the time, return a new entity, but pick from a small set to increase the chance of
    // catching dedup happening when it shouldn't
    entity.* = randomEntity(smith);
}

fn fuzzCmdBufEncoding(_: void, input: []const u8) !void {
    var smith: Smith = .init(input);

    var es: Entities = try .init(gpa, .{
        .max_entities = max_entities,
        .comp_bytes = comp_bytes,
    });
    defer es.deinit(gpa);

    var cb: CmdBuf = try .init(gpa, &es, .{
        .cmds = cmds_capacity,
        .avg_cmd_bytes = @sizeOf(RigidBody),
    });
    defer cb.deinit(gpa, &es);

    var oracle: std.ArrayListUnmanaged(OracleBatch) = try .initCapacity(gpa, 1024);
    defer oracle.deinit(gpa);

    var e = randomEntity(&smith);
    while (!smith.isEmpty()) {
        defer {
            for (oracle.items) |*cmd| {
                cmd.deinit();
            }
            oracle.clearRetainingCapacity();
        }

        for (0..smith.next(u10)) |_| {
            // Get a random entity
            randomizeEntity(&smith, &e);

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

            for (0..smith.nextBetween(u8, 1, 5)) |_| {
                if (smith.next(bool)) {
                    e.destroy(&cb);
                    try oracle_batch.cb.append(gpa, .destroy);
                } else switch (smith.next(enum {
                    add_comp_val,
                    add_comp_ptr,
                    ext_val,
                    ext_ptr,
                    commit,
                    remove,
                })) {
                    .add_comp_val => switch (smith.next(enum { rb, model, tag })) {
                        .rb => {
                            const val = try gpa.create(RigidBody);
                            val.* = smith.next(RigidBody);
                            const comp: Any = .init(RigidBody, val);
                            try e.addAnyVal(&cb, comp);
                            try oracle_batch.cb.append(gpa, .{ .add = comp });
                        },
                        .model => {
                            const val = try gpa.create(Model);
                            val.* = smith.next(Model);
                            const comp: Any = .init(Model, val);
                            try e.addAnyVal(&cb, comp);
                            try oracle_batch.cb.append(gpa, .{ .add = comp });
                        },
                        .tag => {
                            const val = try gpa.create(Tag);
                            val.* = smith.next(Tag);
                            const comp: Any = .init(Tag, val);
                            try e.addAnyVal(&cb, comp);
                            try oracle_batch.cb.append(gpa, .{ .add = comp });
                        },
                    },
                    .add_comp_ptr => switch (smith.next(enum { rb, model, tag })) {
                        .rb => {
                            const val = try gpa.create(RigidBody);
                            val.* = RigidBody.interned[smith.nextLessThan(u8, RigidBody.interned.len)];
                            const comp: Any = .init(RigidBody, val);
                            try e.addAnyPtr(&cb, comp);
                            try oracle_batch.cb.append(gpa, .{ .add = comp });
                        },
                        .model => {
                            const val = try gpa.create(Model);
                            val.* = Model.interned[smith.nextLessThan(u8, Model.interned.len)];
                            const comp: Any = .init(Model, val);
                            try e.addAnyPtr(&cb, comp);
                            try oracle_batch.cb.append(gpa, .{ .add = comp });
                        },
                        .tag => {
                            const val = try gpa.create(Tag);
                            val.* = Tag.interned[smith.nextLessThan(u8, Tag.interned.len)];
                            const comp: Any = .init(Tag, val);
                            try e.addAnyPtr(&cb, comp);
                            try oracle_batch.cb.append(gpa, .{ .add = comp });
                        },
                    },
                    .ext_val => switch (smith.next(enum { foo, bar, baz })) {
                        .foo => {
                            const val = try gpa.create(FooExt);
                            val.* = smith.next(FooExt);
                            const ext: Any = .init(FooExt, val);
                            try e.cmdAnyVal(&cb, ext);
                            try oracle_batch.cb.append(gpa, .{ .ext = ext });
                        },
                        .bar => {
                            const val = try gpa.create(BarExt);
                            val.* = smith.next(BarExt);
                            const ext: Any = .init(BarExt, val);
                            try e.cmdAnyVal(&cb, ext);
                            try oracle_batch.cb.append(gpa, .{ .ext = ext });
                        },
                        .baz => {
                            const val = try gpa.create(BazExt);
                            val.* = smith.next(BazExt);
                            const ext: Any = .init(BazExt, val);
                            try e.cmdAnyVal(&cb, ext);
                            try oracle_batch.cb.append(gpa, .{ .ext = ext });
                        },
                    },
                    .ext_ptr => switch (smith.next(enum { foo, bar, baz })) {
                        .foo => {
                            const val = try gpa.create(FooExt);
                            val.* = FooExt.interned[smith.nextLessThan(u8, FooExt.interned.len)];
                            const comp: Any = .init(FooExt, val);
                            try e.cmdAnyPtr(&cb, comp);
                            try oracle_batch.cb.append(gpa, .{ .ext = comp });
                        },
                        .bar => {
                            const val = try gpa.create(BarExt);
                            val.* = BarExt.interned[smith.nextLessThan(u8, BarExt.interned.len)];
                            const comp: Any = .init(BarExt, val);
                            try e.cmdAnyPtr(&cb, comp);
                            try oracle_batch.cb.append(gpa, .{ .ext = comp });
                        },
                        .baz => {
                            const val = try gpa.create(BazExt);
                            val.* = BazExt.interned[smith.nextLessThan(u8, BazExt.interned.len)];
                            const comp: Any = .init(BazExt, val);
                            try e.cmdAnyPtr(&cb, comp);
                            try oracle_batch.cb.append(gpa, .{ .ext = comp });
                        },
                    },
                    .commit => {
                        e.commit(&cb);
                    },
                    .remove => switch (smith.next(enum { rb, model, tag })) {
                        .rb => {
                            e.remove(&cb, RigidBody);
                            try oracle_batch.cb.append(gpa, .{
                                .remove = zcs.typeId(RigidBody),
                            });
                        },
                        .model => {
                            e.remove(&cb, Model);
                            try oracle_batch.cb.append(gpa, .{
                                .remove = zcs.typeId(Model),
                            });
                        },
                        .tag => {
                            e.remove(&cb, Tag);
                            try oracle_batch.cb.append(gpa, .{
                                .remove = zcs.typeId(Tag),
                            });
                        },
                    },
                }
            }

            e.commit(&cb);
        }

        var iter = cb.iterator();
        for (oracle.items) |oracle_batch| {
            const batch = iter.next().?;
            try expectEqual(oracle_batch.entity, batch.entity);
            var batch_iter = batch.iterator();
            for (oracle_batch.cb.items) |oracle_op| {
                switch (oracle_op) {
                    .add => |oracle_comp| {
                        const add = batch_iter.next().?.add;
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
                    .remove => |oracle_id| {
                        try expectEqual(oracle_id, batch_iter.next().?.remove);
                    },
                    .ext => |oracle_ext| {
                        const ext = batch_iter.next().?.ext;
                        try expectEqual(oracle_ext.id, ext.id);

                        if (oracle_ext.as(FooExt)) |v| {
                            try expectEqual(v.*, ext.as(FooExt).?.*);
                        } else if (oracle_ext.as(BarExt)) |v| {
                            try expectEqual(v.*, ext.as(BarExt).?.*);
                        } else if (oracle_ext.as(BazExt)) |v| {
                            try expectEqual(v.*, ext.as(BazExt).?.*);
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

        cb.clear(&es);
    }
}
