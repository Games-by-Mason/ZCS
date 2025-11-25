//! Tests for the `Node` extension.

const std = @import("std");
const zcs = @import("zcs");
const types = @import("../types.zig");

const Fuzzer = @import("../EntitiesFuzzer.zig");

const CompFlag = zcs.CompFlag;
const Entity = zcs.Entity;
const Entities = zcs.Entities;
const CmdBuf = zcs.CmdBuf;
const Node = zcs.ext.Node;
const SetParent = zcs.ext.Node.SetParent;
const Tag = zcs.ext.Tag;
const typeId = zcs.typeId;

const gpa = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualEntity = @import("../root.zig").expectEqualEntity;

const log = false;

// https://github.com/ziglang/zig/issues/26044
const global: Tag = .init(u32);
test "miscompilation" {
    var copy: Tag = undefined;
    copy = global;
    try std.testing.expectEqual(global.id, copy.id);
}

test "tags" {
    defer CompFlag.unregisterAll();

    const tag_a = Tag.init(struct {});
    const tag_b = Tag.init(struct {});
    const tag_c = Tag.init(struct {});
    const tag_d = Tag.init(struct {});
    const tag_e = Tag.init(struct {});

    var es: Entities = try .init(.{ .gpa = gpa });
    defer es.deinit(gpa);

    var tr: Node.Tree = .empty;

    var cb: CmdBuf = try .init(.{
        .name = null,
        .gpa = gpa,
        .es = &es,
    });
    defer cb.deinit(gpa, &es);

    const great_grandparent: Entity = .reserve(&cb);
    const grandparent: Entity = .reserve(&cb);
    const parent: Entity = .reserve(&cb);
    const child_0: Entity = .reserve(&cb);
    const child_1: Entity = .reserve(&cb);

    if (log) {
        std.debug.print("child_0: {f}\n", .{child_0});
        std.debug.print("child_1: {f}\n", .{child_1});
        std.debug.print("parent: {f}\n", .{parent});
        std.debug.print("grandparent: {f}\n", .{grandparent});
        std.debug.print("great_grandparent: {f}\n", .{great_grandparent});
    }

    {
        defer flush(&es, &cb, &tr);

        _ = cb.ext(Node.SetParent, .{
            .child = child_0,
            .parent = parent.toOptional(),
        });
        _ = cb.ext(Node.SetParent, .{
            .child = child_1,
            .parent = parent.toOptional(),
        });
        _ = cb.ext(Node.SetParent, .{
            .child = parent,
            .parent = grandparent.toOptional(),
        });
        _ = cb.ext(Node.SetParent, .{
            .child = grandparent,
            .parent = great_grandparent.toOptional(),
        });
    }

    try expectEqualEntity(Entity.Optional.none, tag_a.findAncestorOf(&es, child_0.get(&es, Node).?));
    try expectEqualEntity(Entity.Optional.none, tag_b.findAncestorOf(&es, child_0.get(&es, Node).?));
    try expectEqualEntity(Entity.Optional.none, tag_c.findAncestorOf(&es, child_0.get(&es, Node).?));
    try expectEqualEntity(Entity.Optional.none, tag_d.findAncestorOf(&es, child_0.get(&es, Node).?));
    try expectEqualEntity(Entity.Optional.none, tag_e.findAncestorOf(&es, child_0.get(&es, Node).?));

    try expect(!tag_a.matches(&es, child_0));
    try expect(!tag_b.matches(&es, child_0));

    {
        defer flush(&es, &cb, &tr);

        _ = child_0.add(&cb, Tag, tag_a);
        _ = child_1.add(&cb, Tag, tag_b);
        _ = grandparent.add(&cb, Tag, tag_c);
    }

    try expectEqualEntity(Entity.Optional.none, tag_a.findAncestorOf(&es, child_0.get(&es, Node).?));
    try expectEqualEntity(Entity.Optional.none, tag_b.findAncestorOf(&es, child_0.get(&es, Node).?));
    try expectEqualEntity(grandparent, tag_c.findAncestorOf(&es, child_0.get(&es, Node).?));
    try expectEqualEntity(Entity.Optional.none, tag_d.findAncestorOf(&es, child_0.get(&es, Node).?));
    try expectEqualEntity(Entity.Optional.none, tag_e.findAncestorOf(&es, child_0.get(&es, Node).?));

    try expect(tag_a.matches(&es, child_0));
    try expect(!tag_b.matches(&es, child_0));

    {
        defer flush(&es, &cb, &tr);

        _ = parent.add(&cb, Tag, tag_d);
        _ = great_grandparent.add(&cb, Tag, tag_e);
    }

    try expectEqualEntity(Entity.Optional.none, tag_a.findAncestorOf(&es, child_0.get(&es, Node).?));
    try expectEqualEntity(Entity.Optional.none, tag_b.findAncestorOf(&es, child_0.get(&es, Node).?));
    try expectEqualEntity(grandparent, tag_c.findAncestorOf(&es, child_0.get(&es, Node).?));
    try expectEqualEntity(parent, tag_d.findAncestorOf(&es, child_0.get(&es, Node).?));
    try expectEqualEntity(great_grandparent, tag_e.findAncestorOf(&es, child_0.get(&es, Node).?));

    {
        defer flush(&es, &cb, &tr);

        _ = grandparent.add(&cb, Tag, tag_e);
    }

    try expectEqualEntity(Entity.Optional.none, tag_a.findAncestorOf(&es, child_0.get(&es, Node).?));
    try expectEqualEntity(Entity.Optional.none, tag_b.findAncestorOf(&es, child_0.get(&es, Node).?));
    try expectEqualEntity(grandparent, tag_e.findAncestorOf(&es, child_0.get(&es, Node).?));
    try expectEqualEntity(parent, tag_d.findAncestorOf(&es, child_0.get(&es, Node).?));

    try expectEqualEntity(Entity.Optional.none, tag_a.findAncestorOf(&es, great_grandparent.get(&es, Node).?));
}

fn flush(es: *Entities, cb: *CmdBuf, tr: *Node.Tree) void {
    Node.Exec.immediate(es, cb, tr);
    cb.clear(es);
}
