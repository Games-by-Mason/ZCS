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

test "node immediate" {
    defer Comp.unregisterAll();

    var es = try Entities.init(gpa, .{ .max_entities = 100, .comp_bytes = 100 });
    defer es.deinit(gpa);

    const parent = Entity.reserveImmediate(&es);
    const child_1 = Entity.reserveImmediate(&es);
    const child_2 = Entity.reserveImmediate(&es);
    Node.setParentImmediate(&es, child_2, parent);
    Node.setParentImmediate(&es, child_1, parent);

    try expectEqual(parent, child_1.getComp(&es, Node).?.parent);
    try expectEqual(parent, child_2.getComp(&es, Node).?.parent);

    var children = Node.childIterator(&es, parent);
    try expectEqual(child_1, children.next(&es));
    try expectEqual(child_2, children.next(&es));
    try expectEqual(Entity.none, children.next(&es));

    Node.destroyImmediate(&es, parent);
    try expect(!parent.exists(&es));
    try expect(!child_1.exists(&es));
    try expect(!child_2.exists(&es));
}

test "fuzz nodes" {
    try std.testing.fuzz(fuzzNodes, .{ .corpus = &.{} });
}

// XXX: do on more cores
test "fuzz nodes 0" {
    try std.testing.fuzz(fuzzNodes, .{ .corpus = &.{} });
}
test "fuzz nodes 1" {
    try std.testing.fuzz(fuzzNodes, .{ .corpus = &.{} });
}
test "fuzz nodes 2" {
    try std.testing.fuzz(fuzzNodes, .{ .corpus = &.{} });
}
test "fuzz nodes 3" {
    try std.testing.fuzz(fuzzNodes, .{ .corpus = &.{} });
}
test "fuzz nodes 4" {
    try std.testing.fuzz(fuzzNodes, .{ .corpus = &.{} });
}
test "fuzz nodes 5" {
    try std.testing.fuzz(fuzzNodes, .{ .corpus = &.{} });
}
test "fuzz nodes 6" {
    try std.testing.fuzz(fuzzNodes, .{ .corpus = &.{} });
}
test "fuzz nodes 7" {
    try std.testing.fuzz(fuzzNodes, .{ .corpus = &.{} });
}
test "fuzz nodes 8" {
    try std.testing.fuzz(fuzzNodes, .{ .corpus = &.{} });
}
test "fuzz nodes 9" {
    try std.testing.fuzz(fuzzNodes, .{ .corpus = &.{} });
}
test "fuzz nodes 10" {
    try std.testing.fuzz(fuzzNodes, .{ .corpus = &.{} });
}
test "fuzz nodes 11" {
    try std.testing.fuzz(fuzzNodes, .{ .corpus = &.{} });
}
test "fuzz nodes 12" {
    try std.testing.fuzz(fuzzNodes, .{ .corpus = &.{} });
}
test "fuzz nodes 13" {
    try std.testing.fuzz(fuzzNodes, .{ .corpus = &.{} });
}
test "fuzz nodes 14" {
    try std.testing.fuzz(fuzzNodes, .{ .corpus = &.{} });
}
test "fuzz nodes 15" {
    try std.testing.fuzz(fuzzNodes, .{ .corpus = &.{} });
}
test "fuzz nodes 16" {
    try std.testing.fuzz(fuzzNodes, .{ .corpus = &.{} });
}
test "fuzz nodes 17" {
    try std.testing.fuzz(fuzzNodes, .{ .corpus = &.{} });
}
test "fuzz nodes 18" {
    try std.testing.fuzz(fuzzNodes, .{ .corpus = &.{} });
}
test "fuzz nodes 19" {
    try std.testing.fuzz(fuzzNodes, .{ .corpus = &.{} });
}
test "fuzz nodes 20" {
    try std.testing.fuzz(fuzzNodes, .{ .corpus = &.{} });
}
test "fuzz nodes 21" {
    try std.testing.fuzz(fuzzNodes, .{ .corpus = &.{} });
}
test "fuzz nodes 22" {
    try std.testing.fuzz(fuzzNodes, .{ .corpus = &.{} });
}
test "fuzz nodes 23" {
    try std.testing.fuzz(fuzzNodes, .{ .corpus = &.{} });
}
test "fuzz nodes 24" {
    try std.testing.fuzz(fuzzNodes, .{ .corpus = &.{} });
}
test "fuzz nodes 25" {
    try std.testing.fuzz(fuzzNodes, .{ .corpus = &.{} });
}
test "fuzz nodes 26" {
    try std.testing.fuzz(fuzzNodes, .{ .corpus = &.{} });
}
test "fuzz nodes 27" {
    try std.testing.fuzz(fuzzNodes, .{ .corpus = &.{} });
}
test "fuzz nodes 28" {
    try std.testing.fuzz(fuzzNodes, .{ .corpus = &.{} });
}

test "rand nodes" {
    var xoshiro_256: std.Random.Xoshiro256 = .init(0);
    const rand = xoshiro_256.random();
    const input: []u8 = try gpa.alloc(u8, 8192);
    defer gpa.free(input);
    rand.bytes(input);
    try fuzzNodes(input);
}

const OracleNode = struct {
    parent: Entity = .none,
    children: std.AutoArrayHashMapUnmanaged(Entity, void) = .{},

    fn deinit(self: *@This()) void {
        self.children.deinit(gpa);
    }
};

const Oracle = std.AutoArrayHashMapUnmanaged(Entity, OracleNode);

fn fuzzNodes(input: []const u8) !void {
    defer Comp.unregisterAll();

    var fz: Fuzzer = try .init(input);
    defer fz.deinit();

    var o: Oracle = .{};
    defer o.deinit(gpa);
    defer for (o.values()) |*v| {
        v.deinit();
    };

    var roots: std.ArrayListUnmanaged(Entity) = .{};
    defer roots.deinit(gpa);

    while (!fz.parser.isEmpty()) {
        // Modify the hierarchy
        switch (fz.parser.next(enum {
            reserve,
            set_parent,
            destroy,
        })) {
            .reserve => try reserve(&fz, &o),
            .set_parent => try setParent(&fz, &o),
            .destroy => try destroy(&fz, &o),
        }

        // Check the oracle
        {
            // Check the total entity count
            try expectEqual(o.count(), fz.es.count() + fz.es.reserved());

            // Check each entity
            var iterator = o.iterator();
            while (iterator.next()) |entry| {
                // Check the parent
                const node = entry.key_ptr.getComp(&fz.es, Node);
                const parent: Entity = if (node) |n| n.parent else .none;
                try expectEqual(entry.value_ptr.parent, parent);

                // Check the children. We don't bother checking for dups since they would result in
                // the list being infinitely long and failing the implicit size check.
                var children = Node.childIterator(&fz.es, entry.key_ptr.*);
                var prev_sibling: Entity = .none;
                for (0..entry.value_ptr.children.count()) |_| {
                    const child = children.next(&fz.es);
                    if (child.eql(.none)) {
                        std.debug.print("no children found for {}\n", .{entry.key_ptr.*});
                    }
                    try expect(!child.eql(.none));
                    try expect(entry.value_ptr.children.contains(child));

                    // Validate prev pointers to catch issues sooner
                    try expectEqual(prev_sibling, child.getComp(&fz.es, Node).?.prev_sib);
                    prev_sibling = child;
                }
                // XXX: found a failure here
                try expect(children.next(&fz.es).eql(.none));
            }
        }
    }
}

fn reserve(fz: *Fuzzer, o: *Oracle) !void {
    const entity = try fz.reserveImmediate();
    try o.put(gpa, entity, .{});
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
                try expect(o.getPtr(parent_o.parent).?.children.swapRemove(parent));
                parent_o.parent = child_o.parent;
                if (!child_o.parent.eql(.none)) {
                    try o.getPtr(child_o.parent).?.children.put(gpa, child, {});
                }
            }

            // Unparent the child
            const prev_parent = child_o.parent;
            const prev_parent_o = if (prev_parent.eql(.none)) null else o.getPtr(prev_parent).?;
            if (prev_parent_o) |ppo| try expect(ppo.children.swapRemove(child));
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
            try expect(o.getPtr(n.parent).?.children.swapRemove(e));
        }
    }
    try destroyInOracleInner(fz, o, e);
}

fn destroyInOracleInner(fz: *Fuzzer, o: *Oracle, e: Entity) !void {
    if (o.getPtr(e)) |n| {
        for (n.children.keys()) |c| {
            try destroyInOracleInner(fz, o, c);
        }
        n.deinit();
        try expect(o.swapRemove(e));
    }
    try fz.destroyInOracle(e);
}
