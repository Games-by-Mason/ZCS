//! Tests for the `Node` extension.

const std = @import("std");
const zcs = @import("zcs");
const types = @import("../types.zig");

const Fuzzer = @import("../EntitiesFuzzer.zig");

const Model = types.Model;

const Entity = zcs.Entity;
const Entities = zcs.Entities;
const Any = zcs.Any;
const CompFlag = zcs.CompFlag;
const CmdBuf = zcs.CmdBuf;
const Node = zcs.ext.Node;
const SetParent = zcs.ext.Node.SetParent;
const DirtyEvent = zcs.ext.DirtyEvent;

const gpa = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const log = false;

const cmds_capacity = 1000;

const Transform = struct {
    dirty: bool = false,
};

test "node immediate" {
    defer CompFlag.unregisterAll();

    var es = try Entities.init(gpa, .{ .max_entities = 128, .comp_bytes = 256 });
    defer es.deinit(gpa);

    const empty = Entity.reserveImmediate(&es);
    try expect(empty.changeArchImmediate(&es, .{ .add = &.{
        .init(Node, &.{}),
        .init(Model, &Model.interned[0]),
    } }));
    const parent = Entity.reserveImmediate(&es);
    try expect(parent.changeArchImmediate(&es, .{ .add = &.{.init(Node, &.{})} }));
    const child_1 = Entity.reserveImmediate(&es);
    try expect(child_1.changeArchImmediate(&es, .{ .add = &.{.init(Node, &.{})} }));
    const child_2 = Entity.reserveImmediate(&es);
    try expect(child_2.changeArchImmediate(&es, .{ .add = &.{.init(Node, &.{})} }));
    const descendant = Entity.reserveImmediate(&es);
    try expect(descendant.changeArchImmediate(&es, .{ .add = &.{.init(Node, &.{})} }));

    // Make sure this compiles
    try expectEqual(empty.get(&es, Node).?.getEntity(&es).get(&es, Model), empty.get(&es, Model).?);

    child_2.get(&es, Node).?.setParentImmediate(&es, parent.get(&es, Node).?);
    child_1.get(&es, Node).?.setParentImmediate(&es, parent.get(&es, Node).?);
    descendant.get(&es, Node).?.setParentImmediate(&es, child_1.get(&es, Node).?);

    try expect(!empty.get(&es, Node).?.isAncestorOf(&es, child_1.get(&es, Node).?));
    try expect(!child_1.get(&es, Node).?.isAncestorOf(&es, empty.get(&es, Node).?));
    try expect(!empty.get(&es, Node).?.isAncestorOf(&es, empty.get(&es, Node).?));

    try expectEqualEntity(parent, child_1.get(&es, Node).?.parent.unwrap().?);
    try expectEqualEntity(parent, child_2.get(&es, Node).?.parent.unwrap().?);
    try expect(!parent.get(&es, Node).?.isAncestorOf(&es, parent.get(&es, Node).?));
    try expect(parent.get(&es, Node).?.isAncestorOf(&es, descendant.get(&es, Node).?));
    try expect(!descendant.get(&es, Node).?.isAncestorOf(&es, parent.get(&es, Node).?));
    try expect(parent.get(&es, Node).?.isAncestorOf(&es, child_1.get(&es, Node).?));
    try expect(parent.get(&es, Node).?.isAncestorOf(&es, child_2.get(&es, Node).?));
    try expect(!child_1.get(&es, Node).?.isAncestorOf(&es, child_2.get(&es, Node).?));

    var children = parent.get(&es, Node).?.childIterator();
    try expectEqualEntity(child_1, children.next(&es).?.getEntity(&es));
    try expectEqualEntity(child_2, children.next(&es).?.getEntity(&es));
    try expectEqual(null, children.next(&es));

    parent.get(&es, Node).?.destroyImmediate(&es);
    try expect(!parent.exists(&es));
    try expect(!child_1.exists(&es));
    try expect(!child_2.exists(&es));

    try expect(!empty.get(&es, Node).?.isAncestorOf(&es, empty.get(&es, Node).?));
}

test "fuzz nodes immediate" {
    try std.testing.fuzz(fuzzNodes, .{ .corpus = &.{} });
}

test "fuzz node cycles" {
    try std.testing.fuzz(fuzzNodeCycles, .{ .corpus = &.{} });
}

test "rand nodes immediate" {
    var xoshiro_256: std.Random.Xoshiro256 = .init(0);
    const rand = xoshiro_256.random();
    const input: []u8 = try gpa.alloc(u8, 8192);
    defer gpa.free(input);
    rand.bytes(input);
    try fuzzNodes(input);
}

test "rand node cycles" {
    var xoshiro_256: std.Random.Xoshiro256 = .init(0);
    const rand = xoshiro_256.random();
    const input: []u8 = try gpa.alloc(u8, 8192);
    defer gpa.free(input);
    rand.bytes(input);
    try fuzzNodeCycles(input);
}

test "fuzz nodes cmdbuf" {
    try std.testing.fuzz(fuzzNodesCmdBuf, .{ .corpus = &.{} });
}

test "fuzz node cycles cmdbuf" {
    try std.testing.fuzz(fuzzNodeCyclesCmdBuf, .{ .corpus = &.{} });
}

test "rand nodes cmdbuf" {
    var xoshiro_256: std.Random.Xoshiro256 = .init(0);
    const rand = xoshiro_256.random();
    const input: []u8 = try gpa.alloc(u8, 8192);
    defer gpa.free(input);
    rand.bytes(input);
    try fuzzNodesCmdBuf(input);
}

test "rand node cycles cmdbuf" {
    var xoshiro_256: std.Random.Xoshiro256 = .init(0);
    const rand = xoshiro_256.random();
    const input: []u8 = try gpa.alloc(u8, 8192);
    defer gpa.free(input);
    rand.bytes(input);
    try fuzzNodeCyclesCmdBuf(input);
}

const OracleNode = struct {
    parent: Entity.Optional = .none,
    children: std.AutoArrayHashMapUnmanaged(Entity, void) = .{},

    fn deinit(self: *@This()) void {
        self.children.deinit(gpa);
    }
};

const Oracle = struct {
    /// The ground truth nodes.
    nodes: std.AutoHashMapUnmanaged(Entity, OracleNode),
    /// The max dirty events that may have been emitted. Not worth trying to match the dedup logic
    /// exactly, just verify that they're not accumulating more than they should.
    max_dirty: usize = 0,

    fn init() @This() {
        return .{
            .nodes = .{},
        };
    }

    fn deinit(self: *@This()) void {
        var iter = self.nodes.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.nodes.deinit(gpa);
        self.* = undefined;
    }
};

/// Fuzz random node operations.
fn fuzzNodes(input: []const u8) !void {
    defer CompFlag.unregisterAll();

    var fz: Fuzzer = try .init(input);
    defer fz.deinit();

    var o: Oracle = .init();
    defer o.deinit();

    while (!fz.smith.isEmpty()) {
        switch (fz.smith.next(enum {
            reserve,
            set_parent,
            destroy,
        })) {
            .reserve => try reserve(&fz, &o),
            .set_parent => try setParent(&fz, &o),
            .destroy => try destroy(&fz, &o),
        }

        try checkOracle(&fz, &o);
    }
}

/// Fuzz random node operations that are likely to create cycles that need breaking. This doesn't
/// occur very often when there are a large number of entities and entities are frequently removed,
/// so we bias for it here.
fn fuzzNodeCycles(input: []const u8) !void {
    defer CompFlag.unregisterAll();
    var fz: Fuzzer = try .init(input);
    defer fz.deinit();

    var o: Oracle = .init();
    defer o.deinit();

    for (0..16) |_| {
        try reserve(&fz, &o);
    }

    while (!fz.smith.isEmpty()) {
        try setParent(&fz, &o);
        try checkOracle(&fz, &o);
    }
}

/// Similar to `fuzzNodes` but uses command buffers.
fn fuzzNodesCmdBuf(input: []const u8) !void {
    defer CompFlag.unregisterAll();

    var fz: Fuzzer = try .init(input);
    defer fz.deinit();

    var o: Oracle = .init();
    defer o.deinit();

    var cb: CmdBuf = try .initGranularCapacity(gpa, &fz.es, b: {
        var cap: CmdBuf.GranularCapacity = .init(.{
            .cmds = cmds_capacity,
            .avg_any_bytes = @sizeOf(Node),
        });
        cap.reserved = 0;
        break :b cap;
    });
    defer cb.deinit(gpa, &fz.es);

    while (!fz.smith.isEmpty()) {
        for (0..fz.smith.nextLessThan(u16, cmds_capacity)) |_| {
            switch (fz.smith.next(enum {
                reserve,
                set_parent,
                destroy,
            })) {
                .reserve => try reserveCmd(&fz, &o),
                .set_parent => try setParentCmd(&fz, &o, &cb),
                .destroy => try destroyCmd(&fz, &o, &cb),
            }
        }

        Node.Exec(Transform).allImmediate(&fz.es, &.{cb});
        try checkOracle(&fz, &o);
        clear(&fz, &cb, &o);
        DirtyEvent(Transform).recycleAll(&fz.es);
    }
}

/// Similar to `fuzzNodeCycles` but uses command buffers.
fn fuzzNodeCyclesCmdBuf(input: []const u8) !void {
    defer CompFlag.unregisterAll();
    var fz: Fuzzer = try .init(input);
    defer fz.deinit();

    var o: Oracle = .init();
    defer o.deinit();

    var cb: CmdBuf = try .initGranularCapacity(gpa, &fz.es, b: {
        var cap: CmdBuf.GranularCapacity = .init(.{
            .cmds = cmds_capacity,
            .avg_any_bytes = @sizeOf(Node),
        });
        cap.reserved = 0;
        break :b cap;
    });
    defer cb.deinit(gpa, &fz.es);

    for (0..16) |_| {
        try reserve(&fz, &o);
    }

    while (!fz.smith.isEmpty()) {
        for (0..fz.smith.nextLessThan(u16, cmds_capacity)) |_| {
            try setParentCmd(&fz, &o, &cb);
        }

        Node.Exec(Transform).allImmediate(&fz.es, &.{cb});
        try checkOracle(&fz, &o);
        clear(&fz, &cb, &o);
        DirtyEvent(Transform).recycleAll(&fz.es);
    }
}

fn clear(fz: *Fuzzer, cb: *CmdBuf, o: *Oracle) void {
    cb.clear(&fz.es);
    o.max_dirty = 0;
}

fn checkOracle(fz: *Fuzzer, o: *const Oracle) !void {
    // Check the total entity count
    var dirty: usize = 0;
    var dirty_iter = fz.es.viewIterator(struct { dirty: *DirtyEvent(Transform) });
    while (dirty_iter.next()) |vw| {
        if (vw.dirty.entity.get(&fz.es, Transform)) |tr| tr.dirty = false;
        dirty += 1;
    }
    try expectEqual(o.nodes.count(), fz.es.count() + fz.es.reserved() - dirty);
    try expect(dirty <= o.max_dirty);

    // Check each entity
    var iterator = o.nodes.iterator();
    while (iterator.next()) |entry| {
        // Check the parent
        const node = entry.key_ptr.get(&fz.es, Node);
        const parent: Entity.Optional = if (node) |n| n.parent else .none;
        try expectEqualEntity(entry.value_ptr.parent, parent);

        // Check the children. We don't bother checking for dups since they would result in
        // the list being infinitely long and failing the implicit size check.
        if (node) |n| {
            var children = n.childIterator();
            var prev_sibling: Entity.Optional = .none;
            const keys = entry.value_ptr.children.keys();
            for (0..keys.len) |i| {
                const expected = keys[keys.len - i - 1];
                const child = children.next(&fz.es).?;
                const child_entity = child.getEntity(&fz.es);
                try expectEqualEntity(expected, child_entity);

                // Validate prev pointers to catch issues sooner
                try expectEqualEntity(prev_sibling, child.prev_sib);
                prev_sibling = child_entity.toOptional();
            }
            try expectEqual(null, children.next(&fz.es));
        }

        try checkPostOrder(fz, o, entry.key_ptr.*);
        try checkPreOrder(fz, o, entry.key_ptr.*);
    }
}

fn checkPostOrder(fz: *Fuzzer, o: *const Oracle, e: Entity) !void {
    var iter: Node.PostOrderIterator = if (e.get(&fz.es, Node)) |node| b: {
        break :b node.postOrderIterator(&fz.es);
    } else .{ .curr = .none, .end = undefined };
    try checkPostOrderInner(fz, o, e, e, &iter);
}

fn checkPostOrderInner(
    fz: *Fuzzer,
    o: *const Oracle,
    start: Entity,
    curr: Entity,
    iter: *Node.PostOrderIterator,
) !void {
    const oracle_children = o.nodes.get(curr).?.children.keys();
    for (0..oracle_children.len) |i| {
        const child = oracle_children[oracle_children.len - i - 1];
        try checkPostOrderInner(fz, o, start, child, iter);
    }
    if (curr == start) {
        try expectEqual(null, iter.next(&fz.es));
    } else {
        try expectEqualEntity(
            curr,
            (iter.next(&fz.es) orelse return error.ExpectedNext).getEntity(&fz.es),
        );
    }
}

fn checkPreOrder(fz: *Fuzzer, o: *const Oracle, e: Entity) !void {
    var iter: Node.PreOrderIterator = if (e.get(&fz.es, Node)) |node| b: {
        break :b node.preOrderIterator(&fz.es);
    } else .{ .start = undefined, .curr = .none };
    try checkPreOrderInner(fz, o, e, e, &iter);
    try expectEqual(null, iter.next(&fz.es));
}

fn checkPreOrderInner(
    fz: *Fuzzer,
    o: *const Oracle,
    start: Entity,
    curr: Entity,
    iter: *Node.PreOrderIterator,
) !void {
    if (curr != start) {
        const actual = iter.next(&fz.es);
        try expectEqualEntity(
            curr,
            (actual orelse return error.ExpectedNext).getEntity(&fz.es),
        );
    }
    const oracle_children = o.nodes.get(curr).?.children.keys();
    for (0..oracle_children.len) |i| {
        const child = oracle_children[oracle_children.len - i - 1];
        try checkPreOrderInner(fz, o, start, child, iter);
    }
}

fn reserve(fz: *Fuzzer, o: *Oracle) !void {
    const entity = (try fz.reserveImmediate()).unwrap() orelse return;
    try o.nodes.put(gpa, entity, .{});
}

fn reserveCmd(fz: *Fuzzer, o: *Oracle) !void {
    const entity = (try fz.reserveImmediate()).unwrap() orelse return;
    try expect(entity.changeArchImmediate(&fz.es, .{ .add = &.{
        .init(Transform, &.{}),
    } }));
    try o.nodes.put(gpa, entity, .{});
}

fn isAncestorOf(fz: *Fuzzer, o: *Oracle, ancestor: Entity, descendant: Entity) !bool {
    if (!ancestor.exists(&fz.es)) return false;
    const descendant_o = o.nodes.get(descendant) orelse return false;
    var c = descendant_o.parent;
    while (true) {
        if (c == ancestor.toOptional()) return true;
        const unwrapped = c.unwrap() orelse return false;
        c = o.nodes.getPtr(unwrapped).?.parent;
    }
}

fn setParent(fz: *Fuzzer, o: *Oracle) !void {
    // Get a random parent and child
    const parent = fz.randomEntity();
    const child = fz.randomEntity().unwrap() orelse return;
    if (log) std.debug.print("{}.parent = {}\n", .{ child, parent });

    const child_node = (child.viewOrAddImmediate(&fz.es, struct { *Node }, .{&Node{}}) orelse return)[0];
    const parent_node = if (parent.unwrap()) |p| b: {
        break :b (p.viewOrAddImmediate(&fz.es, struct { *Node }, .{&Node{}}) orelse return)[0];
    } else null;
    child_node.setParentImmediate(&fz.es, parent_node);
    try setParentInOracle(fz, o, child, parent);
}

fn setParentCmd(fz: *Fuzzer, o: *Oracle, cb: *CmdBuf) !void {
    // Get a random parent and child
    const parent = fz.randomEntity();
    const child = fz.randomEntity().unwrap() orelse return;
    if (log) std.debug.print("{}.parent = {}\n", .{ child, parent });

    child.cmd(cb, SetParent, .{parent});
    try setParentInOracle(fz, o, child, parent);
    o.max_dirty += 1;
}

fn setParentInOracle(fz: *Fuzzer, o: *Oracle, child: Entity, parent: Entity.Optional) !void {
    // Early out if child and parent are the same entity
    if (parent == child.toOptional()) return;

    // Early out if child doesn't exist
    if (!o.nodes.contains(child)) return;

    const child_o = o.nodes.getPtr(child).?;

    if (parent.unwrap()) |unwrapped| {
        // If parent doesn't exist, destroy child and early out
        if (!o.nodes.contains(unwrapped)) {
            return destroyInOracle(fz, o, child);
        }

        // If child is an ancestor of parent, break the loop by moving parent up to the same level
        // of child
        if (try isAncestorOf(fz, o, child, unwrapped)) {
            const parent_o = o.nodes.getPtr(unwrapped).?;
            const parent_parent = parent_o.parent.unwrap().?;
            try expect(o.nodes.getPtr(parent_parent).?.children.orderedRemove(unwrapped));
            parent_o.parent = child_o.parent;
            if (child_o.parent.unwrap()) |child_parent| {
                try o.nodes.getPtr(child_parent).?.children.put(gpa, unwrapped, {});
            }
        }
    }

    // Unparent the child
    const prev_parent = child_o.parent;
    if (prev_parent.unwrap()) |unwrapped| {
        const prev_parent_o = o.nodes.getPtr(unwrapped).?;
        try expect(prev_parent_o.children.orderedRemove(child));
    }
    child_o.parent = .none;

    // Set the parent
    if (parent.unwrap()) |unwrapped| {
        if (unwrapped.exists(&fz.es)) {
            child_o.parent = unwrapped.toOptional();
            try o.nodes.getPtr(unwrapped).?.children.put(gpa, child, {});
        }
    }
}

fn destroy(fz: *Fuzzer, o: *Oracle) !void {
    if (fz.shouldSkipDestroy()) return;

    // Get a random entity
    const entity = fz.randomEntity().unwrap() orelse return;
    if (log) std.debug.print("destroy {}\n", .{entity});

    // Destroy the real entity
    if (entity.get(&fz.es, Node)) |node| {
        _ = node.destroyImmediate(&fz.es);
    } else {
        _ = entity.destroyImmediate(&fz.es);
    }

    // Destroy it in the oracle
    try destroyInOracle(fz, o, entity);
}

fn destroyCmd(fz: *Fuzzer, o: *Oracle, cb: *CmdBuf) !void {
    if (fz.shouldSkipDestroy()) return;

    // Get a random entity
    const entity = fz.randomEntity().unwrap() orelse return;
    if (log) std.debug.print("destroy {}\n", .{entity});

    // Destroy the real entity
    entity.destroy(cb);

    // Destroy it in the oracle
    try destroyInOracle(fz, o, entity);
}

fn destroyInOracle(fz: *Fuzzer, o: *Oracle, e: Entity) !void {
    if (o.nodes.getPtr(e)) |n| {
        if (n.parent.unwrap()) |unwrapped| {
            try expect(o.nodes.getPtr(unwrapped).?.children.orderedRemove(e));
        }
    }
    try destroyInOracleInner(fz, o, e);
}

fn destroyInOracleInner(fz: *Fuzzer, o: *Oracle, e: Entity) !void {
    if (o.nodes.getPtr(e)) |n| {
        var iter = n.children.iterator();
        while (iter.next()) |entry| {
            try destroyInOracleInner(fz, o, entry.key_ptr.*);
        }
        n.deinit();
        try expect(o.nodes.remove(e));
    }
    try fz.destroyInOracle(e);
}

fn expectEqualEntity(expected: anytype, actual: anytype) !void {
    const e = if (@TypeOf(expected) == Entity.Optional) expected else expected.toOptional();
    const a = if (@TypeOf(actual) == Entity.Optional) actual else actual.toOptional();
    if (e != a) {
        if (std.testing.backend_can_print) {
            std.debug.print("expected {}, found {}\n", .{ e, a });
        }
        return error.TestExpectedEqual;
    }
}
