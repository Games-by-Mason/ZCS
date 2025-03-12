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

    pub fn recycleImmediate(es: *Entities) void {
        es.recycleArchImmediate(.initOne(.registerImmediate(typeId(Event))));
    }
};

test "events" {
    defer CompFlag.unregisterAll();

    var es = try Entities.init(gpa, .{
        .max_entities = 20,
        .comp_bytes = 8192,
        .max_archetypes = 4,
    });
    defer es.deinit(gpa);

    var cb: CmdBuf = try .init(gpa, &es, .{
        .cmds = 10,
        .avg_cmd_bytes = @sizeOf(Event),
    });
    defer cb.deinit(gpa, &es);

    // Emit some events
    const e0 = Event.emit(&cb, 'a');
    const e1 = Event.emit(&cb, 'b');

    cb.execImmediate(&es);

    // Check that we received them in the expected order
    {
        try expectEqual(2, es.count());

        var events = es.viewIterator(struct { entity: Entity, event: *const Event });

        const recv_0 = events.next().?;
        try expectEqualEntity(e1, recv_0.entity);
        try expectEqual('b', recv_0.event.payload);

        const recv_1 = events.next().?;
        try expectEqualEntity(e0, recv_1.entity);
        try expectEqual('a', recv_1.event.payload);

        try expectEqual(null, events.next());
    }

    // Recycle the entities, and then clear the command buffer, reserving the same entities again
    Event.recycleImmediate(&es);
    cb.clear(&es);
    try expectEqual(0, es.count());

    // Emit some more events, this should recycle the old IDs
    try expectEqualEntity(e1, Event.emit(&cb, 'c'));
    try expectEqualEntity(e0, Event.emit(&cb, 'd'));

    cb.execImmediate(&es);

    // Check that we received them in order
    {
        try expectEqual(2, es.count());

        var events = es.viewIterator(struct { entity: Entity, event: *const Event });
        const recv_0 = events.next().?;
        try expectEqualEntity(e1, recv_0.entity);
        try expectEqual('c', recv_0.event.payload);

        const recv_1 = events.next().?;
        try expectEqualEntity(e0, recv_1.entity);
        try expectEqual('d', recv_1.event.payload);

        try expectEqual(null, events.next());
    }

    // Recycle the entities, and then clear the command buffer, reserving the same entities again
    Event.recycleImmediate(&es);
    cb.clear(&es);
    try expectEqual(0, es.count());
}
