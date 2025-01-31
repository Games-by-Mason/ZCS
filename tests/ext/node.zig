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

    // Destroy the real entity
    Node.destroyImmediate(&fz.es, entity);

    // Destroy it in the oracle
    try destroyInOracle(fz, o, entity);
}

fn destroyInOracle(fz: *Fuzzer, o: *Oracle, e: Entity) !void {
    if (o.getPtr(e)) |n| {
        for (n.children.keys()) |c| {
            try destroyInOracle(fz, o, c);
        }
        n.deinit();
        try expect(o.swapRemove(e));
    }
    try fz.destroyInOracle(e);
}
