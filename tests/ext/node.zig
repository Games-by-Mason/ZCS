//! Tests for the `Node` extension.

const std = @import("std");
const zcs = @import("zcs");

const Fuzzer = @import("../Fuzzer.zig");

const Entity = zcs.Entity;
const Entities = zcs.Entities;
const Comp = zcs.Comp;
const Node = zcs.ext.Node;

const gpa = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const log = false;

fn expectEqualEntity(expected: Entity, actual: Entity) !void {
    if (!expected.eql(actual)) {
        if (std.testing.backend_can_print) {
            std.debug.print("expected {}, found {}\n", .{ expected, actual });
        }
        return error.TestExpectedEqual;
    }
}

test "node immediate" {
    defer Comp.unregisterAll();

    var es = try Entities.init(gpa, .{ .max_entities = 128, .comp_bytes = 256 });
    defer es.deinit(gpa);

    const parent = Entity.reserveImmediate(&es);
    const child_1 = Entity.reserveImmediate(&es);
    const child_2 = Entity.reserveImmediate(&es);
    const descendant = Entity.reserveImmediate(&es);
    Node.setParentImmediate(&es, child_2, parent);
    Node.setParentImmediate(&es, child_1, parent);
    Node.setParentImmediate(&es, descendant, child_1);

    try expectEqualEntity(parent, child_1.getComp(&es, Node).?.parent);
    try expectEqualEntity(parent, child_2.getComp(&es, Node).?.parent);
    try expect(Node.isAncestor(&es, parent, descendant));
    try expect(!Node.isAncestor(&es, descendant, parent));
    try expect(Node.isAncestor(&es, parent, child_1));
    try expect(Node.isAncestor(&es, parent, child_2));
    try expect(!Node.isAncestor(&es, child_1, child_2));

    var children = Node.childIterator(&es, parent);
    try expectEqualEntity(child_1, children.next(&es));
    try expectEqualEntity(child_2, children.next(&es));
    try expectEqualEntity(.none, children.next(&es));

    Node.destroyImmediate(&es, parent);
    try expect(!parent.exists(&es));
    try expect(!child_1.exists(&es));
    try expect(!child_2.exists(&es));
}

test "fuzz nodes" {
    try std.testing.fuzz(fuzzNodes, .{ .corpus = &.{} });
}

test "fuzz node cycles" {
    try std.testing.fuzz(fuzzNodeCycles, .{ .corpus = &.{} });
}

test "rand nodes" {
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

const OracleNode = struct {
    parent: Entity = .none,
    children: std.AutoHashMapUnmanaged(Entity, void) = .{},

    fn deinit(self: *@This()) void {
        self.children.deinit(gpa);
    }
};

const Oracle = std.AutoHashMapUnmanaged(Entity, OracleNode);

/// Fuzz random node operations.
fn fuzzNodes(input: []const u8) !void {
    defer Comp.unregisterAll();

    var fz: Fuzzer = try .init(input);
    defer fz.deinit();

    var o: Oracle = .{};
    defer {
        var iter = o.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        o.deinit(gpa);
    }

    while (!fz.parser.isEmpty()) {
        switch (fz.parser.next(enum {
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
    defer Comp.unregisterAll();
    var fz: Fuzzer = try .init(input);
    defer fz.deinit();

    var o: Oracle = .{};
    defer {
        var iter = o.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        o.deinit(gpa);
    }

    for (0..16) |_| {
        try reserve(&fz, &o);
    }

    while (!fz.parser.isEmpty()) {
        try setParent(&fz, &o);
        try checkOracle(&fz, &o);
    }
}

fn checkOracle(fz: *const Fuzzer, o: *const Oracle) !void {
    // Check the total entity count
    try expectEqual(o.count(), fz.es.count() + fz.es.reserved());

    // Check each entity
    var iterator = o.iterator();
    while (iterator.next()) |entry| {
        // Check the parent
        const node = entry.key_ptr.getComp(&fz.es, Node);
        const parent: Entity = if (node) |n| n.parent else .none;
        try expectEqualEntity(entry.value_ptr.parent, parent);

        // Check the children. We don't bother checking for dups since they would result in
        // the list being infinitely long and failing the implicit size check.
        var children = Node.childIterator(&fz.es, entry.key_ptr.*);
        var prev_sibling: Entity = .none;
        for (0..entry.value_ptr.children.count()) |_| {
            const child = children.next(&fz.es);
            try expect(!child.eql(.none));
            try expect(entry.value_ptr.children.contains(child));

            // Validate prev pointers to catch issues sooner
            try expectEqualEntity(prev_sibling, child.getComp(&fz.es, Node).?.prev_sib);
            prev_sibling = child;
        }
        try expectEqualEntity(.none, children.next(&fz.es));
    }
}

fn reserve(fz: *Fuzzer, o: *Oracle) !void {
    const entity = try fz.reserveImmediate();
    if (!entity.eql(.none)) try o.put(gpa, entity, .{});
}

fn isAncestor(fz: *Fuzzer, o: *Oracle, ancestor: Entity, e: Entity) !bool {
    if (!e.exists(&fz.es)) return false;
    if (!ancestor.exists(&fz.es)) return false;

    var c = e;
    while (true) {
        if (c.eql(ancestor)) return true;
        if (c.eql(.none)) return false;
        c = o.getPtr(c).?.parent;
    }
}

fn setParent(fz: *Fuzzer, o: *Oracle) !void {
    // Get a random parent and child
    const parent = fz.randomEntity();
    const child = fz.randomEntity();
    if (log) std.debug.print("{}.parent = {}\n", .{ child, parent });

    // Update the real data
    Node.setParentImmediate(&fz.es, child, parent);

    // Update the oracle
    if (!parent.eql(child)) {
        if (child.exists(&fz.es)) {
            const child_o = o.getPtr(child).?;

            // If child is an ancestor of parent, move parent up the tree
            if (try isAncestor(fz, o, child, parent)) {
                const parent_o = o.getPtr(parent).?;
                try expect(o.getPtr(parent_o.parent).?.children.remove(parent));
                parent_o.parent = child_o.parent;
                if (!child_o.parent.eql(.none)) {
                    try o.getPtr(child_o.parent).?.children.put(gpa, parent, {});
                }
            }

            // Unparent the child
            const prev_parent = child_o.parent;
            const prev_parent_o = if (prev_parent.eql(.none)) null else o.getPtr(prev_parent).?;
            if (prev_parent_o) |ppo| try expect(ppo.children.remove(child));
            child_o.parent = .none;

            // Set the parent
            if (parent.exists(&fz.es)) {
                child_o.parent = parent;
                try o.getPtr(parent).?.children.put(gpa, child, {});
            }
        }
    }
}

fn destroy(fz: *Fuzzer, o: *Oracle) !void {
    if (fz.shouldSkipDestroy()) return;

    // Get a random entity
    const entity = fz.randomEntity();
    if (log) std.debug.print("destroy {}\n", .{entity});

    // Destroy the real entity
    Node.destroyImmediate(&fz.es, entity);

    // Destroy it in the oracle
    try destroyInOracle(fz, o, entity);
}

fn destroyInOracle(fz: *Fuzzer, o: *Oracle, e: Entity) !void {
    if (o.getPtr(e)) |n| {
        if (!n.parent.eql(.none)) {
            try expect(o.getPtr(n.parent).?.children.remove(e));
        }
    }
    try destroyInOracleInner(fz, o, e);
}

fn destroyInOracleInner(fz: *Fuzzer, o: *Oracle, e: Entity) !void {
    if (o.getPtr(e)) |n| {
        var iter = n.children.iterator();
        while (iter.next()) |entry| {
            try destroyInOracleInner(fz, o, entry.key_ptr.*);
        }
        n.deinit();
        try expect(o.remove(e));
    }
    try fz.destroyInOracle(e);
}
