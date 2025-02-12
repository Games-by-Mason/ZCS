//! Tests for the `Node` extension.

const std = @import("std");
const zcs = @import("zcs");

const Entity = zcs.Entity;
const Entities = zcs.Entities;
const Any = zcs.Any;
const CompFlag = zcs.CompFlag;
const CmdBuf = zcs.CmdBuf;
const DirtyEvent = zcs.ext.DirtyEvent;

const gpa = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const log = false;

const Foo = struct {
    dirty: bool = false,
};

test "dirty immediate" {
    defer CompFlag.unregisterAll();

    var es = try Entities.init(gpa, .{ .max_entities = 128, .comp_bytes = 256 });
    defer es.deinit(gpa);

    const foo_0 = Entity.reserveImmediate(&es);
    try expect(foo_0.changeArchImmediate(&es, .{ .add = &.{
        .init(Foo, &.{}),
    } }));

    const foo_1 = Entity.reserveImmediate(&es);
    try expect(foo_1.changeArchImmediate(&es, .{ .add = &.{
        .init(Foo, &.{}),
    } }));

    const foo_2 = Entity.reserveImmediate(&es);
    try expect(foo_2.changeArchImmediate(&es, .{ .add = &.{
        .init(Foo, &.{}),
    } }));

    const empty = Entity.reserveImmediate(&es);
    try expect(empty.changeArchImmediate(&es, .{}));

    {
        var iter = es.viewIterator(struct { dirty: *const DirtyEvent(Foo) });
        try expectEqual(null, iter.next());
    }

    try expectEqual(4, es.count());
    try expectEqual(0, es.reserved());

    DirtyEvent(Foo).emitImmediate(&es, foo_0);
    DirtyEvent(Foo).emitImmediate(&es, foo_0);
    DirtyEvent(Foo).emitImmediate(&es, foo_2);
    DirtyEvent(Foo).emitImmediate(&es, foo_0);
    DirtyEvent(Foo).emitImmediate(&es, foo_2);
    DirtyEvent(Foo).emitImmediate(&es, empty);
    DirtyEvent(Foo).emitImmediate(&es, foo_2);

    try expect(foo_0.getComp(&es, Foo).?.dirty);
    try expect(!foo_1.getComp(&es, Foo).?.dirty);
    try expect(foo_2.getComp(&es, Foo).?.dirty);

    try expectEqual(6, es.count());
    try expectEqual(0, es.reserved());

    {
        var iter = es.viewIterator(struct { dirty: *const DirtyEvent(Foo) });
        try expectEqual(foo_0, iter.next().?.dirty.*.entity);
        try expectEqual(foo_2, iter.next().?.dirty.*.entity);
        try expectEqual(null, iter.next());
    }

    DirtyEvent(Foo).recycleAll(&es);
    try expect(foo_0.getComp(&es, Foo).?.dirty);
    try expect(!foo_1.getComp(&es, Foo).?.dirty);
    try expect(foo_2.getComp(&es, Foo).?.dirty);
    try expectEqual(4, es.count());
    try expectEqual(0, es.reserved());

    {
        var iter = es.viewIterator(struct { dirty: *const DirtyEvent(Foo) });
        try expectEqual(null, iter.next());
    }

    DirtyEvent(Foo).emitImmediate(&es, foo_0);
    try expectEqual(4, es.count());
    try expectEqual(0, es.reserved());

    {
        try expect(foo_0.getComp(&es, Foo).?.dirty);
        try expect(!foo_1.getComp(&es, Foo).?.dirty);
        try expect(foo_2.getComp(&es, Foo).?.dirty);
        var iter = es.viewIterator(struct { dirty: *const DirtyEvent(Foo) });
        try expectEqual(null, iter.next());
    }

    foo_0.getComp(&es, Foo).?.dirty = false;
    DirtyEvent(Foo).emitImmediate(&es, foo_0);
    try expectEqual(5, es.count());
    try expectEqual(0, es.reserved());

    {
        try expect(foo_0.getComp(&es, Foo).?.dirty);
        try expect(!foo_1.getComp(&es, Foo).?.dirty);
        try expect(foo_2.getComp(&es, Foo).?.dirty);
        var iter = es.viewIterator(struct { dirty: *const DirtyEvent(Foo) });
        try expectEqual(foo_0, iter.next().?.dirty.*.entity);
        try expectEqual(null, iter.next());
    }
}

fn execImmediateOrErr(es: *Entities, cb: *const CmdBuf) !void {
    var batches = cb.iterator();
    while (batches.next()) |batch| {
        var cmds = batch.iterator();
        while (cmds.next()) |cmd| {
            DirtyEvent(Foo).processCmdImmediate(es, batch, cmd);
        }
        _ = try batch.execImmediateOrErr(es, batch.getArchChangeImmediate(es));
    }
}

test "dirty cmd" {
    defer CompFlag.unregisterAll();

    var es = try Entities.init(gpa, .{ .max_entities = 20, .comp_bytes = 8192 });
    defer es.deinit(gpa);

    var cb: CmdBuf = try .init(gpa, &es, .{
        .cmds = 10,
        .avg_any_bytes = @sizeOf(Foo),
    });
    defer cb.deinit(gpa, &es);

    const foo_0 = Entity.popReserved(&cb);
    foo_0.addCompCmd(&cb, Foo, .{});

    const foo_1 = Entity.popReserved(&cb);
    foo_1.addCompCmd(&cb, Foo, .{});

    const foo_2 = Entity.popReserved(&cb);
    foo_2.addCompCmd(&cb, Foo, .{});

    const empty = Entity.popReserved(&cb);
    empty.commitCmd(&cb);

    try execImmediateOrErr(&es, &cb);
    cb.clear(&es);
    try expectEqual(4, es.count());

    {
        DirtyEvent(Foo).emitCmd(&cb, foo_0);
        DirtyEvent(Foo).emitCmd(&cb, foo_0);
        DirtyEvent(Foo).emitCmd(&cb, foo_2);
        DirtyEvent(Foo).emitCmd(&cb, foo_0);
        DirtyEvent(Foo).emitCmd(&cb, foo_2);
        DirtyEvent(Foo).emitCmd(&cb, empty);
        DirtyEvent(Foo).emitCmd(&cb, foo_2);

        try execImmediateOrErr(&es, &cb);
        cb.clear(&es);
        try expectEqual(6, es.count());

        try expect(foo_0.getComp(&es, Foo).?.dirty);
        try expect(foo_2.getComp(&es, Foo).?.dirty);

        var iter = es.viewIterator(struct { dirty: *const DirtyEvent(Foo) });
        try expectEqual(foo_0, iter.next().?.dirty.*.entity);
        try expectEqual(foo_2, iter.next().?.dirty.*.entity);
        try expectEqual(null, iter.next());
    }

    DirtyEvent(Foo).recycleAll(&es);
    try expect(foo_0.getComp(&es, Foo).?.dirty);
    try expect(foo_2.getComp(&es, Foo).?.dirty);
    try expectEqual(4, es.count());

    {
        var iter = es.viewIterator(struct { dirty: *const DirtyEvent(Foo) });
        try expectEqual(null, iter.next());
    }

    {
        DirtyEvent(Foo).emitCmd(&cb, foo_0);
        try execImmediateOrErr(&es, &cb);
        cb.clear(&es);
        try expectEqual(4, es.count());

        var iter = es.viewIterator(struct { dirty: *const DirtyEvent(Foo) });
        try expectEqual(null, iter.next());
    }

    {
        DirtyEvent(Foo).emitCmd(&cb, foo_0);
        foo_0.getComp(&es, Foo).?.dirty = false;
        try execImmediateOrErr(&es, &cb);
        cb.clear(&es);
        try expectEqual(5, es.count());

        var iter = es.viewIterator(struct { dirty: *const DirtyEvent(Foo) });
        try expectEqual(foo_0, iter.next().?.dirty.*.entity);
        try expectEqual(null, iter.next());
    }
}
