//! Tests the event pattern.

const std = @import("std");
const zcs = @import("zcs");

const Entity = zcs.Entity;
const Entities = zcs.Entities;
const Any = zcs.Any;
const CompFlag = zcs.CompFlag;
const CmdBuf = zcs.CmdBuf;
const DirtyEvent = zcs.ext.DirtyEvent;

const typeId = zcs.typeId;

const gpa = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualEntity = @import("root.zig").expectEqualEntity;

const log = false;

const Event = struct {
    payload: u21,

    pub fn emit(cb: *CmdBuf, payload: u21) Entity {
        const e: Entity = .reserve(cb);
        e.add(cb, @This(), .{ .payload = payload });
        return e;
    }

    pub fn emitImmediate(es: *Entities, payload: u21) !Entity {
        const e: Entity = .reserveImmediate(es);
        try expect(e.changeArchImmediate(
            es,
            struct { Event },
            .{ .add = .{.{ .payload = payload }} },
        ));
        return e;
    }

    pub fn recycleImmediate(es: *Entities) void {
        es.recycleArchImmediate(.initOne(.registerImmediate(typeId(Event))));
    }
};

test "events" {
    defer CompFlag.unregisterAll();

    var es: Entities = try .init(.{
        .gpa = gpa,
        .cap = .{
            .entities = 20,
            .arches = 4,
            .chunks = 4,
            .chunk = 512,
        },
    });
    defer es.deinit(gpa);

    var cb: CmdBuf = try .init(.{
        .name = null,
        .gpa = gpa,
        .es = &es,
        .cap = .{
            .cmds = 10,
            .data = .{ .bytes_per_cmd = @sizeOf(Event) },
            .reserved_entities = 10,
        },
    });
    defer cb.deinit(gpa, &es);

    // Emit some events
    _ = Event.emit(&cb, 'a');
    _ = Event.emit(&cb, 'b');

    CmdBuf.Exec.immediate(&es, &cb);

    // Check that we received them in the expected order
    {
        try expectEqual(2, es.count());

        var events = es.iterator(struct { entity: Entity, event: *const Event });

        const recv_0 = events.next(&es).?;
        try expectEqual('a', recv_0.event.payload);

        const recv_1 = events.next(&es).?;
        try expectEqual('b', recv_1.event.payload);

        try expectEqual(null, events.next(&es));
    }

    // Recycle the entities, and then clear the command buffer, reserving the same entities again
    Event.recycleImmediate(&es);
    cb.clear(&es);
    try expectEqual(0, es.count());

    // Emit some more events, this should recycle the old IDs
    _ = Event.emit(&cb, 'c');
    _ = Event.emit(&cb, 'd');

    CmdBuf.Exec.immediate(&es, &cb);

    // Check that we received them in order
    {
        try expectEqual(2, es.count());

        var events = es.iterator(struct { entity: Entity, event: *const Event });
        const recv_0 = events.next(&es).?;
        try expectEqual('c', recv_0.event.payload);

        const recv_1 = events.next(&es).?;
        try expectEqual('d', recv_1.event.payload);

        try expectEqual(null, events.next(&es));
    }

    // Recycle the entities, and then clear the command buffer, reserving the same entities again
    Event.recycleImmediate(&es);
    cb.clear(&es);
    try expectEqual(0, es.count());
}

test "many events" {
    defer CompFlag.unregisterAll();

    var es: Entities = try .init(.{
        .gpa = gpa,
        .cap = .{
            .entities = 100000,
            .arches = 4,
            .chunks = 4,
            .chunk = 4096,
        },
    });
    defer es.deinit(gpa);

    // Repeatedly generate a bunch of events and then recycle them, making sure they come back in
    // order even when spanning multiple chunks
    for (0..10) |i| {
        // Emit events
        for (0..1000) |j| {
            _ = try Event.emitImmediate(&es, @intCast(i + j));
        }

        // Check that we received them in the expected order
        {
            var iter = es.iterator(struct { ev: *const Event });
            for (0..1000) |j| {
                try std.testing.expectEqual(i + j, iter.next(&es).?.ev.payload);
            }
            try std.testing.expectEqual(null, iter.next(&es));
        }

        // Recycle the events
        Event.recycleImmediate(&es);
    }
}

test "recycle single" {
    defer CompFlag.unregisterAll();

    var es: Entities = try .init(.{
        .gpa = gpa,
        .cap = .{
            .entities = 100000,
            .arches = 4,
            .chunks = 4,
            .chunk = 4096,
        },
    });
    defer es.deinit(gpa);

    const e0: Entity = .reserveImmediate(&es);
    try expect(e0.exists(&es));
    try expect(!e0.committed(&es));
    try expect(e0.changeArchImmediate(
        &es,
        struct { Event },
        .{
            .add = .{
                .{ .payload = 0 },
            },
        },
    ));
    try expect(e0.committed(&es));

    es.recycleArchImmediate(.initOne(.registerImmediate(typeId(Event))));
    try expect(e0.exists(&es));
    try expect(e0.committed(&es));

    const e1: Entity = .reserveImmediate(&es);
    try std.testing.expectEqual(e0, e1);
    try std.testing.expect(e1.exists(&es));
    try expect(!e1.committed(&es));
    try expect(e1.changeArchImmediate(&es, struct {}, .{}));
    try expect(e1.committed(&es));

    es.recycleArchImmediate(.initOne(.registerImmediate(typeId(Event))));
    es.recycleArchImmediate(.initOne(.registerImmediate(typeId(Event))));
    try expect(e1.exists(&es));
    try expect(e1.committed(&es));
}
