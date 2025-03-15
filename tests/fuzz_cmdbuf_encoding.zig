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

const assert = std.debug.assert;

const max_entities = 100000;
const comp_bytes = 100000;
const cmds_capacity = 4096;
const change_cap = 16;

const log = false;

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

const OracleBatch = union(enum) {
    arch_change: ArchChange,
    ext: Any,

    const ArchChange = struct {
        const Cmd = union(enum) {
            add: Any,
            remove: TypeId,
            destroy,
        };
        entity: Entity,
        cb: std.ArrayListUnmanaged(Cmd) = .empty,

        fn deinit(self: *@This()) void {
            for (self.cb.items) |cmd| {
                switch (cmd) {
                    .add => |any| if (any.as(RigidBody)) |v| {
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

    fn deinit(self: *@This()) void {
        switch (self.*) {
            .arch_change => |*arch_change| arch_change.deinit(),
            .ext => |any| if (any.as(RigidBody)) |v| {
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
        }
        self.* = undefined;
    }
};

/// Pick a random entity from a small set.
fn randomEntity(smith: *Smith) Entity {
    const Key = @FieldType(Entity, "key");
    const Generation = @FieldType(Key, "generation");
    comptime assert(@intFromEnum(Generation.invalid) == 0);
    return .{
        .key = .{
            .index = smith.next(u8) % 10,
            // We add one to avoid the invalid generation which is zero, asserted above
            .generation = @enumFromInt(@as(u32, smith.next(u8) % 3) + 1),
        },
    };
}

/// Randomize the given entity from a small set of entities, occasionally leaving it unchanged.
fn randomizeEntity(smith: *Smith, entity: *Entity) void {
    // Sometimes just use the last entity, this increases the chances that we test dedup logic
    if (smith.next(u8) < 50) return;

    // Most of the time, return a new entity, but pick from a small set to increase the chance of
    // catching dedup happening when it shouldn't
    entity.* = randomEntity(smith);
}

const Oracle = std.ArrayListUnmanaged(OracleBatch);

fn appendArchChange(oracle: *Oracle, e: Entity) *OracleBatch.ArchChange {
    // See if we can just update the last command
    if (oracle.items.len > 0) {
        switch (oracle.items[oracle.items.len - 1]) {
            .arch_change => |*arch_change| if (arch_change.entity == e) {
                return arch_change;
            },
            .ext => {},
        }
    }

    // Generate a new command
    const batch = oracle.addOneAssumeCapacity();
    batch.* = .{ .arch_change = .{ .entity = e } };
    return &batch.arch_change;
}

fn fuzzCmdBufEncoding(_: void, input: []const u8) !void {
    var smith: Smith = .init(input);

    var es: Entities = try .init(gpa, .{
        .max_entities = max_entities,
        .comp_bytes = comp_bytes,
        .max_archetypes = 8,
        .max_chunks = 8,
    });
    defer es.deinit(gpa);

    var cb: CmdBuf = try .init(gpa, &es, .{
        .cmds = cmds_capacity,
        .avg_cmd_bytes = @sizeOf(RigidBody),
    });
    defer cb.deinit(gpa, &es);

    var oracle: Oracle = try .initCapacity(gpa, 4096);
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

            for (0..smith.nextBetween(u8, 1, 5)) |_| {
                if (smith.next(bool)) {
                    if (log) std.debug.print("{}: destroy\n", .{e});
                    const ac = appendArchChange(&oracle, e);
                    e.destroy(&cb);
                    try ac.cb.append(gpa, .destroy);
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
                            if (log) std.debug.print("{}: add val rb val\n", .{e});
                            const ac = appendArchChange(&oracle, e);
                            const val = try gpa.create(RigidBody);
                            val.* = smith.next(RigidBody);
                            const comp: Any = .init(RigidBody, val);
                            try e.addAnyVal(&cb, comp);
                            try ac.cb.append(gpa, .{ .add = comp });
                        },
                        .model => {
                            if (log) std.debug.print("{}: add val model val\n", .{e});
                            const ac = appendArchChange(&oracle, e);
                            const val = try gpa.create(Model);
                            val.* = smith.next(Model);
                            const comp: Any = .init(Model, val);
                            try e.addAnyVal(&cb, comp);
                            try ac.cb.append(gpa, .{ .add = comp });
                        },
                        .tag => {
                            if (log) std.debug.print("{}: add val tag val\n", .{e});
                            const ac = appendArchChange(&oracle, e);
                            const val = try gpa.create(Tag);
                            val.* = smith.next(Tag);
                            const comp: Any = .init(Tag, val);
                            try e.addAnyVal(&cb, comp);
                            try ac.cb.append(gpa, .{ .add = comp });
                        },
                    },
                    .add_comp_ptr => switch (smith.next(enum { rb, model, tag })) {
                        .rb => {
                            if (log) std.debug.print("{}: add rb ptr\n", .{e});
                            const ac = appendArchChange(&oracle, e);
                            const val = try gpa.create(RigidBody);
                            val.* = RigidBody.interned[smith.nextLessThan(u8, RigidBody.interned.len)];
                            const comp: Any = .init(RigidBody, val);
                            try e.addAnyPtr(&cb, comp);
                            try ac.cb.append(gpa, .{ .add = comp });
                        },
                        .model => {
                            if (log) std.debug.print("{}: add model ptr\n", .{e});
                            const ac = appendArchChange(&oracle, e);
                            const val = try gpa.create(Model);
                            val.* = Model.interned[smith.nextLessThan(u8, Model.interned.len)];
                            const comp: Any = .init(Model, val);
                            try e.addAnyPtr(&cb, comp);
                            try ac.cb.append(gpa, .{ .add = comp });
                        },
                        .tag => {
                            if (log) std.debug.print("{}: add tag ptr\n", .{e});
                            const ac = appendArchChange(&oracle, e);
                            const val = try gpa.create(Tag);
                            val.* = Tag.interned[smith.nextLessThan(u8, Tag.interned.len)];
                            const comp: Any = .init(Tag, val);
                            try e.addAnyPtr(&cb, comp);
                            try ac.cb.append(gpa, .{ .add = comp });
                        },
                    },
                    .commit => {
                        if (log) std.debug.print("{}: commit\n", .{e});
                        e.commit(&cb);
                        _ = appendArchChange(&oracle, e);
                    },
                    .remove => switch (smith.next(enum { rb, model, tag })) {
                        .rb => {
                            if (log) std.debug.print("{}: remove rb\n", .{e});
                            const ac = appendArchChange(&oracle, e);
                            e.remove(&cb, RigidBody);
                            try ac.cb.append(gpa, .{
                                .remove = zcs.typeId(RigidBody),
                            });
                        },
                        .model => {
                            if (log) std.debug.print("{}: remove model\n", .{e});
                            const ac = appendArchChange(&oracle, e);
                            e.remove(&cb, Model);
                            try ac.cb.append(gpa, .{
                                .remove = zcs.typeId(Model),
                            });
                        },
                        .tag => {
                            if (log) std.debug.print("{}: remove tag\n", .{e});
                            const ac = appendArchChange(&oracle, e);
                            e.remove(&cb, Tag);
                            try ac.cb.append(gpa, .{
                                .remove = zcs.typeId(Tag),
                            });
                        },
                    },
                    .ext_val => switch (smith.next(enum { foo, bar, baz })) {
                        .foo => {
                            if (log) std.debug.print("ext val foo\n", .{});
                            const val = try gpa.create(FooExt);
                            val.* = smith.next(FooExt);
                            const ext: Any = .init(FooExt, val);
                            try cb.extAnyVal(ext);
                            oracle.appendAssumeCapacity(.{ .ext = ext });
                        },
                        .bar => {
                            if (log) std.debug.print("ext val bar\n", .{});
                            const val = try gpa.create(BarExt);
                            val.* = smith.next(BarExt);
                            const ext: Any = .init(BarExt, val);
                            try cb.extAnyVal(ext);
                            oracle.appendAssumeCapacity(.{ .ext = ext });
                        },
                        .baz => {
                            if (log) std.debug.print("ext val baz\n", .{});
                            const val = try gpa.create(BazExt);
                            val.* = smith.next(BazExt);
                            const ext: Any = .init(BazExt, val);
                            try cb.extAnyVal(ext);
                            oracle.appendAssumeCapacity(.{ .ext = ext });
                        },
                    },
                    .ext_ptr => switch (smith.next(enum { foo, bar, baz })) {
                        .foo => {
                            if (log) std.debug.print("ext ptr foo\n", .{});
                            const val = try gpa.create(FooExt);
                            val.* = FooExt.interned[smith.nextLessThan(u8, FooExt.interned.len)];
                            const comp: Any = .init(FooExt, val);
                            try cb.extAnyPtr(comp);
                            oracle.appendAssumeCapacity(.{ .ext = comp });
                        },
                        .bar => {
                            if (log) std.debug.print("ext ptr bar\n", .{});
                            const val = try gpa.create(BarExt);
                            val.* = BarExt.interned[smith.nextLessThan(u8, BarExt.interned.len)];
                            const comp: Any = .init(BarExt, val);
                            try cb.extAnyPtr(comp);
                            oracle.appendAssumeCapacity(.{ .ext = comp });
                        },
                        .baz => {
                            if (log) std.debug.print("ext ptr baz\n", .{});
                            const val = try gpa.create(BazExt);
                            val.* = BazExt.interned[smith.nextLessThan(u8, BazExt.interned.len)];
                            const comp: Any = .init(BazExt, val);
                            try cb.extAnyPtr(comp);
                            oracle.appendAssumeCapacity(.{ .ext = comp });
                        },
                    },
                }
            }
        }

        if (log) std.debug.print("check oracle\n", .{});
        var iter = cb.iterator();
        for (oracle.items) |oracle_batch| {
            const batch = iter.next().?;
            switch (batch) {
                .arch_change => |arch_change| {
                    if (log) std.debug.print("  es: arch change: {}\n", .{arch_change.entity});
                    const oracle_arch_change = oracle_batch.arch_change;
                    try expectEqual(oracle_arch_change.entity, arch_change.entity);
                    var batch_ops = arch_change.iterator();
                    for (oracle_arch_change.cb.items) |oracle_op| {
                        switch (oracle_op) {
                            .add => |oracle_comp| {
                                if (log) std.debug.print("    add\n", .{});
                                const add = batch_ops.next().?.add;
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
                                if (log) std.debug.print("    remove\n", .{});
                                try expectEqual(oracle_id, batch_ops.next().?.remove);
                            },
                            .destroy => {
                                if (log) std.debug.print("    destroy\n", .{});
                                try expectEqual(.destroy, batch_ops.next().?);

                                // The real encoder skips all ops after a destroy, verify it did
                                // this then ignore the rest of the data in the oracle for this
                                // batch
                                try expectEqual(null, batch_ops.next());
                                break;
                            },
                        }
                    }
                    try expectEqual(null, batch_ops.next());
                },
                .ext => |ext| {
                    if (log) {
                        if (ext.as(FooExt)) |v| {
                            std.debug.print("  es: ext: {}\n", .{v});
                        } else if (ext.as(BarExt)) |v| {
                            std.debug.print("  es: ext: {}\n", .{v});
                        } else if (ext.as(BazExt)) |v| {
                            std.debug.print("  es: ext: {}\n", .{v});
                        } else {
                            @panic("unexpected comp");
                        }
                    }
                    if (log) switch (oracle_batch) {
                        .arch_change => |ac| {
                            std.debug.print("  got ac: {}\n", .{ac.entity});
                            for (ac.cb.items) |op| {
                                std.debug.print("{}\n", .{op});
                            }
                        },
                        else => {},
                    };

                    const oracle_ext = oracle_batch.ext;
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
            }
        }
        if (log) std.debug.print("\n", .{});
        try expectEqual(null, iter.next());

        cb.clear(&es);
    }
}
