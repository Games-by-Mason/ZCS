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

    var es: Entities = try .init(gpa, .{
        .max_entities = 20,
        .max_archetypes = 4,
        .max_chunks = 4,
        .chunk_size = 512,
    });
    defer es.deinit(gpa);

    var cb: CmdBuf = try .init(gpa, &es, .{
        .cmds = 10,
        .data = .{ .bytes_per_cmd = @sizeOf(Event) },
    });
    defer cb.deinit(gpa, &es);

    // Emit some events
    _ = Event.emit(&cb, 'a');
    _ = Event.emit(&cb, 'b');

    CmdBuf.Exec.immediate(&es, &cb, .{ .name = "events" });

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

    CmdBuf.Exec.immediate(&es, &cb, .{ .name = "events" });

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
