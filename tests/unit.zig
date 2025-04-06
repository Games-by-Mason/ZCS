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

    var es: Entities = try .init(gpa, .{
        .max_entities = 100,
        .max_archetypes = 8,
        .max_chunks = 8,
        .chunk_size = 512,
    });
    defer es.deinit(gpa);

    // Check some entity equality stuff not tested elsewhere, OrErr more extensively in slot map
    try expect(Entity.Optional.none == Entity.Optional.none);
    try expectEqual(null, Entity.Optional.none.unwrap());

    var cb: CmdBuf = try .init(gpa, &es, .{
        .cmds = 4,
        .data = .{ .bytes_per_cmd = @sizeOf(RigidBody) },
        .reserved_entities = 0,
    });
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
    CmdBuf.Exec.immediate(&es, &cb, "exec");
    try expectEqual(0, es.reserved());
    try expectEqual(3, es.count());
    cb.clear(&es);

    var iter = es.iterator(struct { e: Entity });

    try expect(iter.next(&es).?.e == e0);
    try expectEqual(null, e0.get(&es, RigidBody));
    try expectEqual(null, e0.get(&es, Model));
    try expectEqual(null, e0.get(&es, Tag));

    try expect(e1 == iter.next(&es).?.e);
    try expectEqual(null, e1.get(&es, RigidBody));
    try expectEqual(null, e1.get(&es, Model));
    try expectEqual(null, e1.get(&es, Tag));

    try expect(e2 == iter.next(&es).?.e);
    try expectEqual(rb, e2.get(&es, RigidBody).?.*);
    try expectEqual(null, e2.get(&es, Model));
    try expectEqual(null, e2.get(&es, Tag));

    try expectEqual(null, iter.next(&es));

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
    CmdBuf.Exec.immediate(&es, &cb, null);
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

    // Make sure this compiles
    es.updateStats(.{ .emit_warnings = false });
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

    var es: Entities = try .init(gpa, .{
        .max_entities = 100,
        .max_archetypes = 8,
        .max_chunks = 8,
        .chunk_size = 512,
    });
    defer es.deinit(gpa);

    var cb: CmdBuf = try .init(gpa, &es, .{ .cmds = 24 });
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
    cb.ext(BarExt, bar_ev_value);
    cb.ext(FooExt, foo_ev_interned);

    e1.add(&cb, Model, model_interned);
    e1.add(&cb, RigidBody, rb_value);
    cb.ext(BarExt, bar_ev_interned);
    cb.ext(FooExt, foo_ev_value);

    // Explicit by value
    try e0.addVal(&cb, Model, model_value);
    try e0.addVal(&cb, RigidBody, rb_interned);
    try cb.extVal(BarExt, bar_ev_value);
    try cb.extVal(FooExt, foo_ev_interned);

    try e1.addVal(&cb, Model, model_interned);
    try e1.addVal(&cb, RigidBody, rb_value);
    try cb.extVal(BarExt, bar_ev_interned);
    try cb.extVal(FooExt, foo_ev_value);

    // Throw in a destroy for good measure, verify the components end up in the remove flags
    try expect(e2.changeArchImmediate(
        &es,
        struct { rb: RigidBody, model: Model },
        .{
            .add = .{ .rb = .{ .mass = 1.0 }, .model = .{ .vertex_start = 2 } },
            .remove = .initEmpty(),
        },
    ));
    e2.destroy(&cb);

    // Explicit interning
    try e0.addPtr(&cb, RigidBody, &rb_interned);
    try e0.addPtr(&cb, Model, &model_interned);
    try cb.extPtr(BarExt, &bar_ev_interned);
    try cb.extPtr(FooExt, &foo_ev_interned);

    // Zero sized types
    e1.add(&cb, Tag, .{});
    try e1.addVal(&cb, Tag, .{});
    try e1.addPtr(&cb, Tag, &.{});
    cb.ext(BazExt, .{});
    try cb.extVal(BazExt, .{});
    try cb.extPtr(BazExt, &.{});

    // Test the results
    var iter = cb.iterator();

    {
        const ac = iter.next().?.arch_change;
        try expectEqual(e0, ac.entity);
        var ops = ac.iterator();
        const comp1 = ops.next().?.add;
        try expect(isInAnyBytes(cb, comp1.as(Model).?));
        try expectEqual(model_value, comp1.as(Model).?.*);
        const comp2 = ops.next().?.add;
        try expect(!isInAnyBytes(cb, comp2.as(RigidBody).?));
        try expectEqual(rb_interned, comp2.as(RigidBody).?.*);
        try expectEqual(null, ops.next());
    }
    {
        const ext1 = iter.next().?.ext;
        try expect(isInAnyBytes(cb, ext1.as(BarExt).?));
        try expectEqual(bar_ev_value, ext1.as(BarExt).?.*);
        const ext2 = iter.next().?.ext;
        try expect(!isInAnyBytes(cb, ext2.as(FooExt).?));
        try expectEqual(foo_ev_interned, ext2.as(FooExt).?.*);
    }
    {
        const ac = iter.next().?.arch_change;
        try expectEqual(e1, ac.entity);
        var ops = ac.iterator();
        const comp1 = ops.next().?.add;
        try expect(isInAnyBytes(cb, comp1.as(Model).?)); // By value because it's too small!
        try expectEqual(model_interned, comp1.as(Model).?.*);
        const comp2 = ops.next().?.add;
        try expect(isInAnyBytes(cb, comp2.as(RigidBody).?));
        try expectEqual(rb_value, comp2.as(RigidBody).?.*);
    }
    {
        const ext1 = iter.next().?.ext;
        try expect(isInAnyBytes(cb, ext1.as(BarExt).?)); // By value because it's too small!
        try expectEqual(bar_ev_interned, ext1.as(BarExt).?.*);
        const ext2 = iter.next().?.ext;
        try expect(isInAnyBytes(cb, ext2.as(FooExt).?));
        try expectEqual(foo_ev_value, ext2.as(FooExt).?.*);
    }
    {
        const ac = iter.next().?.arch_change;
        try expectEqual(e0, ac.entity);
        var ops = ac.iterator();
        const comp1 = ops.next().?.add;
        try expect(isInAnyBytes(cb, comp1.as(Model).?));
        try expectEqual(model_value, comp1.as(Model).?.*);
        const comp2 = ops.next().?.add;
        try expect(isInAnyBytes(cb, comp2.as(RigidBody).?));
        try expectEqual(rb_interned, comp2.as(RigidBody).?.*);
    }
    {
        const ext1 = iter.next().?.ext;
        try expect(isInAnyBytes(cb, ext1.as(BarExt).?));
        try expectEqual(bar_ev_value, ext1.as(BarExt).?.*);
        const ext2 = iter.next().?.ext;
        try expect(isInAnyBytes(cb, ext2.as(FooExt).?));
        try expectEqual(foo_ev_interned, ext2.as(FooExt).?.*);
    }
    {
        const ac = iter.next().?.arch_change;
        try expectEqual(e1, ac.entity);
        var ops = ac.iterator();
        const comp1 = ops.next().?.add;
        try expect(isInAnyBytes(cb, comp1.as(Model).?));
        try expectEqual(model_interned, comp1.as(Model).?.*);
        const comp2 = ops.next().?.add;
        try expect(isInAnyBytes(cb, comp2.as(RigidBody).?));
        try expectEqual(rb_value, comp2.as(RigidBody).?.*);
    }
    {
        const ext1 = iter.next().?.ext;
        try expect(isInAnyBytes(cb, ext1.as(BarExt).?));
        try expectEqual(bar_ev_interned, ext1.as(BarExt).?.*);
        const ext2 = iter.next().?.ext;
        try expect(isInAnyBytes(cb, ext2.as(FooExt).?));
        try expectEqual(foo_ev_value, ext2.as(FooExt).?.*);
    }
    {
        const ac = iter.next().?.arch_change;
        var ops = ac.iterator();
        try expectEqual(.destroy, ops.next());
        try expectEqual(null, ops.next());
    }
    {
        const cmd = iter.next().?.arch_change;
        try expectEqual(e0, cmd.entity);
        var ops = cmd.iterator();
        const comp1 = ops.next().?.add;
        try expect(!isInAnyBytes(cb, comp1.as(RigidBody).?));
        try expectEqual(rb_interned, comp1.as(RigidBody).?.*);
        const comp2 = ops.next().?.add;
        try expect(!isInAnyBytes(cb, comp2.as(Model).?));
        try expectEqual(model_interned, comp2.as(Model).?.*);
    }
    {
        const ext1 = iter.next().?.ext;
        try expect(!isInAnyBytes(cb, ext1.as(BarExt).?));
        try expectEqual(bar_ev_interned, ext1.as(BarExt).?.*);
        const ext2 = iter.next().?.ext;
        try expect(!isInAnyBytes(cb, ext2.as(FooExt).?));
        try expectEqual(foo_ev_interned, ext2.as(FooExt).?.*);
    }
    {
        const ac = iter.next().?.arch_change;
        try expectEqual(e1, ac.entity);
        var ops = ac.iterator();
        const comp1 = ops.next().?.add;
        try expect(isInAnyBytes(cb, comp1.as(Tag).?));
        try expectEqual(Tag{}, comp1.as(Tag).?.*);
        const comp2 = ops.next().?.add;
        try expect(isInAnyBytes(cb, comp2.as(Tag).?));
        try expectEqual(Tag{}, comp2.as(Tag).?.*);
        const comp3 = ops.next().?.add;
        try expect(!isInAnyBytes(cb, comp3.as(Tag).?));
        try expectEqual(Tag{}, comp3.as(Tag).?.*);
    }
    {
        const ext1 = iter.next().?.ext;
        try expect(isInAnyBytes(cb, ext1.as(BazExt).?));
        try expectEqual(BazExt{}, ext1.as(BazExt).?.*);
        const ext2 = iter.next().?.ext;
        try expect(isInAnyBytes(cb, ext2.as(BazExt).?));
        try expectEqual(BazExt{}, ext2.as(BazExt).?.*);
        const ev3 = iter.next().?.ext;
        try expect(!isInAnyBytes(cb, ev3.as(BazExt).?));
        try expectEqual(BazExt{}, ev3.as(BazExt).?.*);
    }

    try expectEqual(null, iter.next());
}

test "cb overflow" {
    defer CompFlag.unregisterAll();
    // Not very exhaustive, but checks that command buffers return the overflow error on failure to
    // append, and on submits that fail.

    var xoshiro_256: std.Random.Xoshiro256 = .init(0);
    const rand = xoshiro_256.random();

    var es: Entities = try .init(gpa, .{
        .max_entities = 100,
        .max_archetypes = 8,
        .max_chunks = 8,
        .chunk_size = 512,
    });
    defer es.deinit(gpa);

    // Cmd overflow
    {
        var cb: CmdBuf = try .init(gpa, &es, .{
            .cmds = 0,
            .data = .{ .bytes = 100 },
            .reserved_entities = 0,
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
    }

    // Comp data overflow
    {
        var cb: CmdBuf = try .init(gpa, &es, .{
            .cmds = 50,
            .data = .{ .bytes = @sizeOf(RigidBody) * 2 - 1 },
            .reserved_entities = 0,
        });
        defer cb.deinit(gpa, &es);

        const e: Entity = Entity.reserveImmediate(&es);
        const rb = RigidBody.random(rand);

        _ = Entity.reserveImmediate(&es).add(&cb, RigidBody, rb);
        e.commit(&cb);
        try expectError(error.ZcsCmdBufOverflow, e.addOrErr(
            &cb,
            RigidBody,
            RigidBody.random(rand),
        ));

        try expectEqual(
            @as(f32, @sizeOf(RigidBody)) / @as(f32, @sizeOf(RigidBody) * 2 - 1),
            cb.worstCaseUsage(),
        );
    }

    // Extension data overflow
    {
        var cb: CmdBuf = try .init(gpa, &es, .{
            .cmds = 50,
            .data = .{ .bytes = @sizeOf(FooExt) * 2 - 1 },
            .reserved_entities = 0,
        });
        defer cb.deinit(gpa, &es);

        const e: Entity = Entity.reserveImmediate(&es);
        const foo = FooExt.random(rand);

        cb.ext(FooExt, foo);
        e.destroy(&cb);
        try expectError(error.ZcsCmdBufOverflow, cb.extOrErr(
            FooExt,
            FooExt.random(rand),
        ));

        try expectEqual(@as(f32, @sizeOf(FooExt)) / @as(f32, @sizeOf(FooExt) * 2 - 1), cb.worstCaseUsage());
    }

    // Reserved underflow
    {
        var cb: CmdBuf = try .init(gpa, &es, .{
            .cmds = 50,
            .data = .{ .bytes = @sizeOf(RigidBody) * 2 - 1 },
            .reserved_entities = 2,
        });
        defer cb.deinit(gpa, &es);

        _ = try Entity.reserveOrErr(&cb);
        _ = try Entity.reserveOrErr(&cb);
        try expectError(error.ZcsReservedEntityUnderflow, Entity.reserveOrErr(&cb));
    }

    // Calling some things just to make sure they compile that we don't test elsewhere
    var cb: CmdBuf = try .init(gpa, &es, .{
        .cmds = 50,
        .data = .{ .bytes = @sizeOf(RigidBody) * 2 - 1 },
        .reserved_entities = 0,
    });
    defer cb.deinit(gpa, &es);
    const e = Entity.reserveImmediate(&es);
    try expect(e.changeArchImmediate(&es, struct {}, .{}));
    try e.addVal(&cb, RigidBody, .{});
    try e.addPtr(&cb, RigidBody, &.{});
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

    var es: Entities = try .init(gpa, .{
        .max_entities = cb_capacity * 10,
        .max_archetypes = 8,
        .max_chunks = 8,
        .chunk_size = 512,
    });
    defer es.deinit(gpa);

    var cb: CmdBuf = try .init(gpa, &es, .{
        .cmds = cb_capacity,
        .data = .{ .bytes_per_cmd = 22 },
    });
    defer cb.deinit(gpa, &es);

    // Change archetype
    {
        // Add val
        const e0 = Entity.reserveImmediate(&es);
        const e1 = Entity.reserveImmediate(&es);

        for (0..cb_capacity / 12) |_| {
            try e0.addVal(&cb, u0, 0);
            try e1.addVal(&cb, u8, 0);
            try e0.addVal(&cb, u16, 0);
            try e1.addVal(&cb, u32, 0);
            try e0.addVal(&cb, u64, 0);
            try e1.addVal(&cb, u128, 0);
        }

        try expect(cb.worstCaseUsage() < 1.0);
        cb.clear(&es);

        for (0..cb_capacity / 6) |_| {
            try e0.addVal(&cb, u0, 0);
            try e1.addVal(&cb, u8, 0);
            try e0.addVal(&cb, u16, 0);
            try e1.addVal(&cb, u32, 0);
            try e0.addVal(&cb, u64, 0);
            try e1.addVal(&cb, u128, 0);
        }

        try expectEqual(1.0, cb.worstCaseUsage());
        cb.clear(&es);

        // Add ptr
        for (0..cb_capacity / 12) |_| {
            try e0.addPtr(&cb, u0, &0);
            try e1.addPtr(&cb, u8, &0);
            try e0.addPtr(&cb, u16, &0);
            try e1.addPtr(&cb, u32, &0);
            try e0.addPtr(&cb, u64, &0);
            try e1.addPtr(&cb, u128, &0);
        }

        try expect(cb.worstCaseUsage() < 1.0);
        cb.clear(&es);

        for (0..cb_capacity / 6) |_| {
            try e0.addPtr(&cb, u0, &0);
            try e1.addPtr(&cb, u8, &0);
            try e0.addPtr(&cb, u16, &0);
            try e1.addPtr(&cb, u32, &0);
            try e0.addPtr(&cb, u64, &0);
            try e1.addPtr(&cb, u128, &0);
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
        for (0..cb_capacity / 4) |_| {
            try cb.extVal(u0, 0);
            try cb.extVal(u8, 0);
            try cb.extVal(u16, 0);
            try cb.extVal(u32, 0);
            try cb.extVal(u64, 0);
            try cb.extVal(u128, 0);
        }

        try expect(cb.worstCaseUsage() < 1.0);
        cb.clear(&es);

        for (0..cb_capacity / 3) |_| {
            try cb.extVal(u0, 0);
            try cb.extVal(u8, 0);
            try cb.extVal(u16, 0);
            try cb.extVal(u32, 0);
            try cb.extVal(u64, 0);
            try cb.extVal(u128, 0);
        }

        try expectEqual(1.0, cb.worstCaseUsage());
        cb.clear(&es);

        // Extension ptr
        for (0..cb_capacity / 4) |_| {
            try cb.extPtr(u0, &0);
            try cb.extPtr(u8, &0);
            try cb.extPtr(u16, &0);
            try cb.extPtr(u32, &0);
            try cb.extPtr(u64, &0);
            try cb.extPtr(u128, &0);
        }

        try expect(cb.worstCaseUsage() < 1.0);
        cb.clear(&es);

        for (0..cb_capacity / 3) |_| {
            try cb.extPtr(u0, &0);
            try cb.extPtr(u8, &0);
            try cb.extPtr(u16, &0);
            try cb.extPtr(u32, &0);
            try cb.extPtr(u64, &0);
            try cb.extPtr(u128, &0);
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
    var es: Entities = try .init(gpa, .{
        .max_entities = 100,
        .max_archetypes = 8,
        .max_chunks = 8,
        .chunk_size = 512,
    });
    defer es.deinit(gpa);

    {
        const e = Entity.reserveImmediate(&es);
        try expect(e.changeArchImmediate(
            &es,
            struct { ?RigidBody, Model },
            .{
                .add = .{ RigidBody{ .mass = 1.0 }, Model{ .vertex_start = 2 } },
                .remove = .initMany(&.{CompFlag.registerImmediate(typeId(RigidBody))}),
            },
        ));
        try expectEqual(Model{ .vertex_start = 2 }, e.get(&es, Model).?.*);
        try expectEqual(null, e.get(&es, RigidBody));
        try expectEqual(null, e.get(&es, Tag));
    }

    {
        const e = Entity.reserveImmediate(&es);
        try expect(e.changeArchImmediate(
            &es,
            struct { RigidBody, Model, ?Tag },
            .{
                .add = .{
                    RigidBody{ .mass = 0.5 },
                    Model{ .vertex_start = 20 },
                    null,
                },
                .remove = .initMany(&.{CompFlag.registerImmediate(typeId(Tag))}),
            },
        ));
        try expectEqual(RigidBody{ .mass = 0.5 }, e.get(&es, RigidBody).?.*);
        try expectEqual(Model{ .vertex_start = 20 }, e.get(&es, Model).?.*);
        try expectEqual(null, e.get(&es, Tag));
    }

    {
        const e = Entity.reserveImmediate(&es);
        try expect(e.destroyImmediate(&es));
        try expect(!e.changeArchImmediate(
            &es,
            struct { RigidBody, Model },
            .{
                .add = .{
                    RigidBody{ .mass = 0.5 },
                    Model{ .vertex_start = 20 },
                },
                .remove = .initMany(&.{CompFlag.registerImmediate(typeId(Tag))}),
            },
        ));
        try expectEqual(null, e.get(&es, RigidBody));
        try expectEqual(null, e.get(&es, Model));
        try expectEqual(null, e.get(&es, Tag));

        try expect(!e.changeArchImmediate(&es, struct {}, .{}));
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
    var es: Entities = try .init(gpa, .{
        .max_entities = 100,
        .max_archetypes = 8,
        .max_chunks = 8,
    });
    defer es.deinit(gpa);
    const e = Entity.reserveImmediate(&es);
    // Should register two types
    try expect(e.changeArchImmediate(
        &es,
        struct { RigidBody, Model },
        .{ .add = .{
            RigidBody{},
            Model{},
        } },
    ));
    // Should not result in a registration
    _ = typeId(i32);
    var cb: CmdBuf = try .init(gpa, &es, .{ .cmds = 24 });
    defer cb.deinit(gpa, &es);
    cb.ext(BarExt, .{ .bar = 1 });
    CmdBuf.Exec.immediate(&es, &cb, "exec");

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
    var es: Entities = try .init(gpa, .{
        .max_entities = 3,
        .max_archetypes = 8,
        .max_chunks = 8,
        .chunk_size = 512,
    });
    defer es.deinit(gpa);

    const e0 = Entity.reserveImmediate(&es);
    _ = Entity.reserveImmediate(&es);
    _ = Entity.reserveImmediate(&es);
    try expectError(error.ZcsEntityOverflow, Entity.reserveImmediateOrErr(&es));

    try expect(e0.changeArchImmediate(
        &es,
        struct { u32 },
        .{ .add = .{0} },
    ));
    var dummy: [256]u8 = undefined;
    try expectError(error.ZcsChunkOverflow, e0.changeArchAnyImmediate(&es, .{ .add = &.{
        .init([256]u8, &dummy),
    } }));
    try expectError(
        error.ZcsChunkOverflow,
        e0.changeArchImmediateOrErr(
            &es,
            struct { [256]u8 },
            .{ .add = .{dummy} },
        ),
    );
}

test "archetype overflow" {
    defer CompFlag.unregisterAll();
    var es: Entities = try .init(gpa, .{
        .max_entities = 3,
        .max_archetypes = 2,
        .max_chunks = 4,
        .chunk_size = 512,
    });
    defer es.deinit(gpa);

    const e0 = Entity.reserveImmediate(&es);
    try expectEqual(0, es.chunk_lists.arches.count());

    // Create three archetypes
    try expect(try e0.changeArchImmediateOrErr(&es, struct { u1 }, .{ .add = .{0} }));
    try expectEqual(1, es.chunk_lists.arches.count());

    try expect(try e0.changeArchImmediateOrErr(&es, struct { u2 }, .{ .add = .{0} }));
    try expectEqual(2, es.chunk_lists.arches.count());

    // Test that trying to create additional archetypes causes it to overflow
    try expectError(error.ZcsArchOverflow, e0.changeArchImmediateOrErr(
        &es,
        struct { u3 },
        .{ .add = .{0} },
    ));
    try expectError(error.ZcsArchOverflow, e0.changeArchImmediateOrErr(
        &es,
        struct { u3 },
        .{ .add = .{0} },
    ));
    try expectError(error.ZcsArchOverflow, e0.changeArchImmediateOrErr(
        &es,
        struct { u4 },
        .{ .add = .{0} },
    ));
    try expectEqual(2, es.chunk_lists.arches.count());

    // Trying to create an archetype that already exists should be fine
    try expect(try e0.changeArchImmediateOrErr(&es, struct {}, .{
        .remove = .initMany(&.{typeId(u2).comp_flag.?}),
    }));
    try expectEqual(2, es.chunk_lists.arches.count());
    try expect(try e0.changeArchImmediateOrErr(&es, struct { u2 }, .{ .add = .{0} }));
    try expectEqual(2, es.chunk_lists.arches.count());
}

test "chunk pool overflow" {
    defer CompFlag.unregisterAll();
    var es: Entities = try .init(gpa, .{
        .max_entities = 4096,
        .max_archetypes = 5,
        .max_chunks = 1,
        .chunk_size = 512,
    });
    defer es.deinit(gpa);

    const e0 = Entity.reserveImmediate(&es);
    try expectEqual(0, es.chunk_lists.arches.count());

    // Create one chunk
    try expect(try e0.changeArchImmediateOrErr(&es, struct { u1 }, .{ .add = .{0} }));
    try expectEqual(1, es.chunk_pool.reserved);
    try expectEqual(1, es.chunk_lists.arches.count());

    // Try to create a new archetype, and fail due to chunk overflow
    for (0..2) |_| {
        try expectError(error.ZcsChunkPoolOverflow, e0.changeArchImmediateOrErr(
            &es,
            struct { u2 },
            .{ .add = .{0} },
        ));
        try expectEqual(1, es.chunk_pool.reserved);
        try expect(!e0.has(&es, u2));
        try expectEqual(2, es.chunk_lists.arches.count());
    }

    // Create new entities in the chunk that was already allocated, this should be fine
    const n = 45;
    for (0..n) |_| {
        const e = Entity.reserveImmediate(&es);
        try expect(try e.changeArchImmediateOrErr(&es, struct { u1 }, .{ .add = .{0} }));
    }
    try expectEqual(1, es.chunk_pool.reserved);
    try expectEqual(n + 1, es.count());
    try expectEqual(2, es.chunk_lists.arches.count());

    // Go past the end of the chunk, causing it to overflow since we've used up all available chunks
    {
        const e = Entity.reserveImmediate(&es);
        try expectError(error.ZcsChunkPoolOverflow, e.changeArchAnyImmediate(&es, .{ .add = &.{
            .init(u1, &0),
        } }));
        try expectError(error.ZcsChunkPoolOverflow, e.changeArchImmediateOrErr(
            &es,
            struct { u1 },
            .{ .add = .{0} },
        ));
        try expectEqual(n + 1, es.count());
    }
    var count: usize = 0;
    var iter = es.iterator(struct { e: Entity });
    while (iter.next(&es)) |_| count += 1;
    try expectEqual(es.count(), count);

    // Recycle all the entities we created
    es.recycleArchImmediate(.initOne(.registerImmediate(typeId(u1))));
    try expectEqual(0, es.count());

    // Now that the chunk was returned the pool, we can create a different archetype
    for (0..n + 1) |_| {
        const e = Entity.reserveImmediate(&es);
        _ = try e.changeArchImmediateOrErr(&es, struct { u2 }, .{ .add = .{0} });
        try expectEqual(1, es.chunk_pool.reserved);
        try expect(!e.has(&es, u1));
        try expect(e.has(&es, u2));
        try expectEqual(3, es.chunk_lists.arches.count());
    }

    // Make sure we can't overfill it
    {
        const e = Entity.reserveImmediate(&es);
        try expectError(error.ZcsChunkPoolOverflow, e.changeArchImmediateOrErr(
            &es,
            struct { u2 },
            .{ .add = .{0} },
        ));
        try expectEqual(n + 1, es.count());
    }

    // Destroy all the entities we created
    {
        var cb: CmdBuf = try .init(gpa, &es, .{ .cmds = n + 1 });
        defer cb.deinit(gpa, &es);
        var it = es.iterator(struct { e: Entity });
        while (it.next(&es)) |vw| vw.e.destroy(&cb);
        CmdBuf.Exec.immediate(&es, &cb, null);
        try expectEqual(0, es.count());
    }

    // Now that the chunk was returned the pool again, we can create a different archetype
    for (0..n + 1) |_| {
        const e = Entity.reserveImmediate(&es);
        _ = try e.changeArchImmediateOrErr(&es, struct { u3 }, .{ .add = .{0} });
        try expectEqual(1, es.chunk_pool.reserved);
        try expect(!e.has(&es, u1));
        try expect(!e.has(&es, u2));
        try expect(e.has(&es, u3));
        try expectEqual(4, es.chunk_lists.arches.count());
    }

    // Make sure we can't overfill it
    {
        const e = Entity.reserveImmediate(&es);
        try expectError(error.ZcsChunkPoolOverflow, e.changeArchAnyImmediate(&es, .{ .add = &.{
            .init(u3, &0),
        } }));
        try expectError(error.ZcsChunkPoolOverflow, e.changeArchImmediateOrErr(
            &es,
            struct { u3 },
            .{ .add = .{0} },
        ));
        try expectEqual(n + 1, es.count());
    }

    // Destroy all the entities we created
    {
        var cb: CmdBuf = try .init(gpa, &es, .{ .cmds = n + 1 });
        defer cb.deinit(gpa, &es);
        var it = es.iterator(struct { e: Entity });
        while (it.next(&es)) |vw| vw.e.destroy(&cb);
        CmdBuf.Exec.immediate(&es, &cb, null);
        try expectEqual(0, es.count());
    }

    // Refill a chunk list that already existed
    for (0..n + 1) |_| {
        const e = Entity.reserveImmediate(&es);
        _ = try e.changeArchImmediateOrErr(&es, struct { u3 }, .{ .add = .{0} });
        try expectEqual(1, es.chunk_pool.reserved);
        try expect(!e.has(&es, u1));
        try expect(!e.has(&es, u2));
        try expect(e.has(&es, u3));
        try expectEqual(4, es.chunk_lists.arches.count());
    }

    // Make sure we can't overfill it
    {
        const e = Entity.reserveImmediate(&es);
        try expectError(error.ZcsChunkPoolOverflow, e.changeArchImmediateOrErr(
            &es,
            struct { u3 },
            .{ .add = .{0} },
        ));
        try expectError(error.ZcsChunkPoolOverflow, e.changeArchAnyImmediate(&es, .{ .add = &.{
            .init(u3, &0),
        } }));
        try expectEqual(n + 1, es.count());
    }
}

test "chunk overflow" {
    defer CompFlag.unregisterAll();

    // Not even enough room for the header
    {
        var es: Entities = try .init(gpa, .{
            .max_entities = 4096,
            .max_archetypes = 5,
            .max_chunks = 1,
            .chunk_size = 16,
        });
        defer es.deinit(gpa);

        const e0 = Entity.reserveImmediate(&es);
        try expectEqual(0, es.chunk_lists.arches.count());

        // Create one chunk
        try expectError(error.ZcsChunkOverflow, e0.changeArchAnyImmediate(&es, .{ .add = &.{
            .init(u1, &0),
        } }));
        try expectError(error.ZcsChunkOverflow, e0.changeArchImmediateOrErr(
            &es,
            struct { u1 },
            .{ .add = .{0} },
        ));
        try expectEqual(0, es.chunk_pool.reserved);
        try expectEqual(0, es.chunk_lists.arches.count());
    }

    // Enough room for the header, but a component is too big
    {
        var es: Entities = try .init(gpa, .{
            .max_entities = 4096,
            .max_archetypes = 5,
            .max_chunks = 1,
            .chunk_size = 4096,
        });
        defer es.deinit(gpa);

        const e0 = Entity.reserveImmediate(&es);
        try expectEqual(0, es.chunk_lists.arches.count());

        // Create one chunk
        try expectError(error.ZcsChunkOverflow, e0.changeArchImmediateOrErr(
            &es,
            struct { [4096]u8 },
            .{ .add = .{undefined} },
        ));
        try expectError(error.ZcsChunkOverflow, e0.changeArchAnyImmediate(&es, .{ .add = &.{
            .init([4096]u8, undefined),
        } }));
        try expectEqual(0, es.chunk_pool.reserved);
        try expectEqual(0, es.chunk_lists.arches.count());
    }
}

// This test isn't intentionally testing anything not covered by other tests, the intention is that
// when more complex tests fail (especially fuzz tests) it may sometimes be easier to modify this
// test to hit the failure than to debug the more complex test directly.
test "smoke test" {
    defer CompFlag.unregisterAll();
    var es: Entities = try .init(gpa, .{
        .max_entities = 3,
        .max_archetypes = 3,
        .max_chunks = 3,
        .chunk_size = 512,
    });
    defer es.deinit(gpa);

    const e0: Entity = .reserveImmediate(&es);

    _ = try e0.changeArchAnyImmediate(&es, .{ .add = &.{
        .init(f32, &1.5),
        .init(bool, &true),
    } });
    try expectEqual(@as(f32, 1.5), e0.get(&es, f32).?.*);
    try expectEqual(true, e0.get(&es, bool).?.*);

    _ = try e0.changeArchAnyImmediate(&es, .{
        .add = &.{.init(u8, &2)},
        .remove = .initMany(&.{CompFlag.registerImmediate(typeId(bool))}),
    });
    try expectEqual(@as(f32, 1.5), e0.get(&es, f32).?.*);
    try expectEqual(null, e0.get(&es, bool));
    try expectEqual(2, e0.get(&es, u8).?.*);
}
