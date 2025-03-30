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
const typeId = zcs.typeId;

const gpa = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualEntity = @import("../root.zig").expectEqualEntity;

const log = false;

const cmds_capacity = 10000;

test "immediate" {
    defer CompFlag.unregisterAll();

    var es: Entities = try .init(gpa, .{
        .max_entities = 128,
        .max_archetypes = 8,
        .max_chunks = 8,
        .chunk_size = 512,
    });
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

test "fuzz immediate" {
    try std.testing.fuzz({}, fuzzNodes, .{ .corpus = &.{} });
}

test "fuzz cycles" {
    try std.testing.fuzz({}, fuzzNodeCycles, .{ .corpus = &.{} });
}

test "rand immediate" {
    var xoshiro_256: std.Random.Xoshiro256 = .init(0);
    const rand = xoshiro_256.random();
    const input: []u8 = try gpa.alloc(u8, 32768);
    defer gpa.free(input);
    rand.bytes(input);
    try fuzzNodes({}, input);
}

test "rand cycles" {
    var xoshiro_256: std.Random.Xoshiro256 = .init(0);
    const rand = xoshiro_256.random();
    const input: []u8 = try gpa.alloc(u8, 524288);
    defer gpa.free(input);
    rand.bytes(input);
    try fuzzNodeCycles({}, input);
}

test "fuzz cb" {
    try std.testing.fuzz({}, fuzzNodesCmdBuf, .{ .corpus = &.{} });
}

test "fuzz cycles cb" {
    try std.testing.fuzz({}, fuzzNodeCyclesCmdBuf, .{ .corpus = &.{} });
}

test "rand cb" {
    var xoshiro_256: std.Random.Xoshiro256 = .init(0);
    const rand = xoshiro_256.random();
    const input: []u8 = try gpa.alloc(u8, 131072);
    defer gpa.free(input);
    rand.bytes(input);
    try fuzzNodesCmdBuf({}, input);
}

test "rand cycles cb" {
    var xoshiro_256: std.Random.Xoshiro256 = .init(0);
    const rand = xoshiro_256.random();
    const input: []u8 = try gpa.alloc(u8, 16777216);
    defer gpa.free(input);
    rand.bytes(input);
    try fuzzNodeCyclesCmdBuf({}, input);
}

const OracleNode = struct {
    parent: Entity.Optional = .none,
    children: std.AutoArrayHashMapUnmanaged(Entity, void) = .{},

    fn deinit(self: *@This()) void {
        self.children.deinit(gpa);
        self.* = undefined;
    }
};

const OracleEntity = struct {
    node: ?OracleNode = null,

    fn deinit(self: *@This()) void {
        if (self.node) |*node| node.deinit();
        self.* = undefined;
    }
};

const Oracle = struct {
    /// The ground truth entities.
    entities: std.AutoHashMapUnmanaged(Entity, OracleEntity),

    fn init() @This() {
        return .{
            .entities = .{},
        };
    }

    fn deinit(self: *@This()) void {
        var iter = self.entities.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.entities.deinit(gpa);
        self.* = undefined;
    }
};

/// Fuzz random node operations.
fn fuzzNodes(_: void, input: []const u8) !void {
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
            .destroy => if (fz.smith.next(bool)) {
                try destroy(&fz, &o);
            } else {
                try remove(&fz, &o);
            },
        }

        try checkOracle(&fz, &o);
    }
}

/// Fuzz random node operations that are likely to create cycles that need breaking. This doesn't
/// occur very often when there are a large number of entities and entities are frequently removed,
/// so we bias for it here.
fn fuzzNodeCycles(_: void, input: []const u8) !void {
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
fn fuzzNodesCmdBuf(_: void, input: []const u8) !void {
    defer CompFlag.unregisterAll();

    var fz: Fuzzer = try .init(input);
    defer fz.deinit();

    var o: Oracle = .init();
    defer o.deinit();

    var cb: CmdBuf = try .initGranularCapacity(gpa, &fz.es, b: {
        var cap: CmdBuf.GranularCapacity = .init(.{
            .cmds = cmds_capacity,
            .avg_cmd_bytes = @sizeOf(Node),
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
                .destroy => if (fz.smith.next(bool)) {
                    try destroyCmd(&fz, &o, &cb);
                } else {
                    try removeCmd(&fz, &o, &cb);
                },
            }
        }

        Node.exec.immediate(&fz.es, cb);
        try checkOracle(&fz, &o);
        cb.clear(&fz.es);
    }
}

/// Similar to `fuzzNodeCycles` but uses command buffers.
fn fuzzNodeCyclesCmdBuf(_: void, input: []const u8) !void {
    defer CompFlag.unregisterAll();
    var fz: Fuzzer = try .init(input);
    defer fz.deinit();

    var o: Oracle = .init();
    defer o.deinit();

    var cb: CmdBuf = try .initGranularCapacity(gpa, &fz.es, b: {
        var cap: CmdBuf.GranularCapacity = .init(.{
            .cmds = cmds_capacity,
            .avg_cmd_bytes = @sizeOf(Node),
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

        Node.exec.immediate(&fz.es, cb);
        try checkOracle(&fz, &o);
        cb.clear(&fz.es);
    }
}

fn checkOracle(fz: *Fuzzer, o: *const Oracle) !void {
    if (log) std.debug.print("check oracle\n", .{});

    // Check the total entity count
    if (o.entities.count() != fz.es.count() + fz.es.reserved()) {
        std.debug.print("oracle count: {}\n", .{o.entities.count()});
        std.debug.print("entities: count={} + reserved={} = {}\n", .{
            fz.es.count(),
            fz.es.reserved(),
            fz.es.count() + fz.es.reserved(),
        });

        // Check for entities the oracle is missing
        var iter = fz.es.iterator(struct { e: Entity });
        while (iter.next(&fz.es)) |vw| {
            if (!o.entities.contains(vw.e)) {
                std.debug.print("oracle missing {}\n", .{vw.e});
            }
        }

        // Check for entities the real data is missing
        var keys = o.entities.keyIterator();
        while (keys.next()) |e| {
            if (!e.exists(&fz.es)) {
                std.debug.print("entities missing {}\n", .{e});
            }
        }
    }
    try expectEqual(o.entities.count(), fz.es.count() + fz.es.reserved());

    // Check each entity
    var iterator = o.entities.iterator();
    while (iterator.next()) |entry| {
        // Check the parent
        const node = entry.key_ptr.get(&fz.es, Node);
        const parent: Entity.Optional = if (entry.value_ptr.node) |n| n.parent else .none;
        const actual = if (entry.value_ptr.node) |n| n.parent else Entity.Optional.none;
        try expectEqualEntity(actual, parent);

        // Check the children. We don't bother checking for dups since they would result in
        // the list being infinitely long and failing the implicit size check.
        if (node) |n| {
            var children = n.childIterator();
            var prev_sibling: Entity.Optional = .none;
            if (entry.value_ptr.node == null) std.debug.print("{} should have a node, real data does: {?}\n", .{ entry.key_ptr.*, entry.key_ptr.*.get(&fz.es, Node) });
            const keys = entry.value_ptr.node.?.children.keys();
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
    const entity_oracle = o.entities.get(curr).?;
    if (entity_oracle.node) |node| {
        const oracle_children = node.children.keys();
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
    } else {
        try expect(curr.get(&fz.es, Node) == null);
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
    if (o.entities.get(curr).?.node) |node| {
        const oracle_children = node.children.keys();
        for (0..oracle_children.len) |i| {
            const child = oracle_children[oracle_children.len - i - 1];
            try checkPreOrderInner(fz, o, start, child, iter);
        }
    }
}

fn reserve(fz: *Fuzzer, o: *Oracle) !void {
    const entity = (try fz.reserveImmediate()).unwrap() orelse return;
    try o.entities.put(gpa, entity, .{});
}

fn reserveCmd(fz: *Fuzzer, o: *Oracle) !void {
    const entity = (try fz.reserveImmediate()).unwrap() orelse return;
    try o.entities.put(gpa, entity, .{});
}

fn isAncestorOf(fz: *Fuzzer, o: *Oracle, ancestor: Entity, descendant: Entity) !bool {
    if (!ancestor.exists(&fz.es)) return false;
    const descendant_o = o.entities.get(descendant) orelse return false;
    var c = (descendant_o.node orelse return false).parent;
    while (true) {
        if (c == ancestor.toOptional()) return true;
        const unwrapped = c.unwrap() orelse return false;
        c = (o.entities.getPtr(unwrapped).?.node orelse return false).parent;
    }
}

fn setParent(fz: *Fuzzer, o: *Oracle) !void {
    // Get a random parent and child
    const parent = fz.randomEntity();
    const child = fz.randomEntity().unwrap() orelse return;
    if (log) std.debug.print("{}.parent = {}\n", .{ child, parent });

    if (parent.unwrap()) |p| if (!p.exists(&fz.es)) return;
    if (!child.exists(&fz.es)) return;
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

    cb.ext(SetParent, .{ .child = child, .parent = parent });
    if (o.entities.getPtr(child) != null) {
        try setParentInOracle(fz, o, child, parent);
    }
}

fn setParentInOracle(fz: *Fuzzer, o: *Oracle, child: Entity, parent: Entity.Optional) !void {
    // Get the oracle entity, adding a node if needed
    const child_o = o.entities.getPtr(child).?;
    if (child_o.node == null) child_o.node = .{};

    // Early out if child and parent are the same entity
    if (parent == child.toOptional()) return;

    // Early out if child doesn't exist
    if (!o.entities.contains(child)) return;

    if (parent.unwrap()) |unwrapped| {
        // If parent doesn't exist, destroy child and early out
        if (!o.entities.contains(unwrapped)) {
            return destroyInOracle(fz, o, child);
        }

        // If child is an ancestor of parent, early out
        if (try isAncestorOf(fz, o, child, unwrapped)) {
            return;
        }
    }

    // Unparent the child
    const prev_parent = child_o.node.?.parent;
    if (prev_parent.unwrap()) |unwrapped| {
        const prev_parent_o = o.entities.getPtr(unwrapped).?;
        try expect(prev_parent_o.node.?.children.orderedRemove(child));
    }
    child_o.node.?.parent = .none;

    // Set the parent
    if (parent.unwrap()) |unwrapped| {
        if (unwrapped.exists(&fz.es)) {
            child_o.node.?.parent = unwrapped.toOptional();
            if (o.entities.getPtr(unwrapped).?.node == null) {
                o.entities.getPtr(unwrapped).?.node = .{};
            }
            try o.entities.getPtr(unwrapped).?.node.?.children.put(gpa, child, {});
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

fn remove(fz: *Fuzzer, o: *Oracle) !void {
    if (fz.shouldSkipDestroy()) return;

    // Get a random entity
    const entity = fz.randomEntity().unwrap() orelse return;
    if (log) std.debug.print("remove {}\n", .{entity});

    // Remove from the real entity
    if (entity.get(&fz.es, Node)) |node| {
        _ = node.destroyChildrenAndUnparentImmediate(&fz.es);
        _ = entity.changeArchImmediate(&fz.es, .{
            .remove = CompFlag.Set.initOne(CompFlag.registerImmediate(typeId(Node))),
        });
    }

    // Remove from the oracle
    try removeInOracle(fz, o, entity);
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

fn removeCmd(fz: *Fuzzer, o: *Oracle, cb: *CmdBuf) !void {
    if (fz.shouldSkipDestroy()) return;

    // Get a random entity
    const entity = fz.randomEntity().unwrap() orelse return;
    if (log) std.debug.print("remove {}\n", .{entity});

    // Remove from the real entity
    entity.remove(cb, Node);

    // Remove from in the oracle
    try removeInOracle(fz, o, entity);
}

fn destroyInOracle(fz: *Fuzzer, o: *Oracle, e: Entity) !void {
    if (o.entities.getPtr(e)) |oe| {
        if (oe.node) |*n| {
            if (n.parent.unwrap()) |unwrapped| {
                try expect(o.entities.getPtr(unwrapped).?.node.?.children.orderedRemove(e));
            }
        }
    }
    try destroyInOracleInner(fz, o, e);
}

fn destroyInOracleInner(fz: *Fuzzer, o: *Oracle, e: Entity) !void {
    if (o.entities.getPtr(e)) |oe| {
        if (oe.node) |*n| {
            var iter = n.children.iterator();
            while (iter.next()) |entry| {
                try destroyInOracleInner(fz, o, entry.key_ptr.*);
            }
        }
        oe.deinit();
        try expect(o.entities.remove(e));
    }
    try fz.destroyInOracle(e);
}

fn removeInOracle(fz: *Fuzzer, o: *Oracle, e: Entity) !void {
    if (o.entities.getPtr(e)) |oe| {
        if (oe.node) |*n| {
            var iter = n.children.iterator();
            while (iter.next()) |entry| {
                try destroyInOracleInner(fz, o, entry.key_ptr.*);
            }
            if (n.parent.unwrap()) |parent| {
                try expect(o.entities.getPtr(parent).?.node.?.children.orderedRemove(e));
            }
        }
        if (oe.node) |*n| n.deinit();
        oe.node = null;
    }
}
