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
const Insert = zcs.ext.Node.Insert;
const typeId = zcs.typeId;

const gpa = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualEntity = @import("../root.zig").expectEqualEntity;

const log = false;

const cmds_capacity = 10000;

test "immediate" {
    defer CompFlag.unregisterAll();

    var es: Entities = try .init(.{
        .gpa = gpa,
        .cap = .{
            .entities = 128,
            .arches = 8,
            .chunks = 8,
            .chunk = 512,
        },
    });
    defer es.deinit(gpa);

    var tr: Node.Tree = .empty;

    const empty = Entity.reserveImmediate(&es);
    try expect(empty.changeArchImmediate(
        &es,
        struct { Node, Model },
        .{ .add = .{
            Node{},
            Model.interned[0],
        } },
    ));
    empty.get(&es, Node).?.init(&es, &tr);
    const parent = Entity.reserveImmediate(&es);
    try expect(parent.changeArchImmediate(&es, struct { Node }, .{ .add = .{Node{}} }));
    parent.get(&es, Node).?.init(&es, &tr);
    const child_1 = Entity.reserveImmediate(&es);
    try expect(child_1.changeArchImmediate(&es, struct { Node }, .{ .add = .{Node{}} }));
    child_1.get(&es, Node).?.init(&es, &tr);
    const child_2 = Entity.reserveImmediate(&es);
    try expect(child_2.changeArchImmediate(&es, struct { Node }, .{ .add = .{Node{}} }));
    child_2.get(&es, Node).?.init(&es, &tr);
    const descendant = Entity.reserveImmediate(&es);
    try expect(descendant.changeArchImmediate(&es, struct { Node }, .{ .add = .{Node{}} }));
    descendant.get(&es, Node).?.init(&es, &tr);

    // Make sure this compiles
    try expectEqual(es.getEntity(empty.get(&es, Node).?).get(&es, Model), empty.get(&es, Model).?);

    child_2.get(&es, Node).?.setParentImmediate(&es, &tr, parent.get(&es, Node).?);
    child_1.get(&es, Node).?.setParentImmediate(&es, &tr, parent.get(&es, Node).?);
    descendant.get(&es, Node).?.setParentImmediate(&es, &tr, child_1.get(&es, Node).?);

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
    try expectEqual(
        parent.get(&es, Node).?.first_child.unwrap().?.get(&es, Node).?.siblingIterator(&es),
        children,
    );
    try expectEqualEntity(child_1, children.next(&es).?.entity);
    try expectEqualEntity(child_2, children.next(&es).?.entity);
    try expectEqual(null, children.next(&es));

    parent.get(&es, Node).?.destroyImmediate(&es, &tr);
    try expect(!parent.exists(&es));
    try expect(!child_1.exists(&es));
    try expect(!child_2.exists(&es));

    try expect(!empty.get(&es, Node).?.isAncestorOf(&es, empty.get(&es, Node).?));

    // Test `getInAncestor` and `viewInAncestor`
    {
        const target = Entity.reserveImmediate(&es);
        try expect(target.changeArchImmediate(
            &es,
            struct { Node, Model },
            .{ .add = .{
                Node{},
                Model.interned[0],
            } },
        ));
        const target_node = target.get(&es, Node).?;
        target_node.init(&es, &tr);

        const child = Entity.reserveImmediate(&es);
        try expect(child.changeArchImmediate(
            &es,
            struct { Node },
            .{ .add = .{Node{}} },
        ));
        const child_node = child.get(&es, Node).?;
        child_node.init(&es, &tr);

        const child_child = Entity.reserveImmediate(&es);
        try expect(child_child.changeArchImmediate(
            &es,
            struct { Node },
            .{ .add = .{Node{}} },
        ));
        const child_child_node = child_child.get(&es, Node).?;
        child_child_node.init(&es, &tr);

        child_child_node.setParentImmediate(&es, &tr, child_node);
        child_node.setParentImmediate(&es, &tr, target_node);

        try expectEqual(child_child_node.getInAncestor(&es, Model).?, target.get(&es, Model).?);
        const vw = child_child_node.viewInAncestor(&es, struct {
            model: *Model,
            node: *Node,
            entity: Entity,
        }).?;
        try expectEqual(vw.model, target.get(&es, Model).?);
        try expectEqual(vw.node, target_node);
        try expectEqual(vw.entity, target);
    }
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
    active_self: bool = true,

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
    /// Ground truth list of entities with no parents.
    roots: std.AutoArrayHashMapUnmanaged(Entity, void),

    fn init() @This() {
        return .{
            .entities = .{},
            .roots = .{},
        };
    }

    fn deinit(self: *@This()) void {
        var iter = self.entities.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.entities.deinit(gpa);
        self.roots.deinit(gpa);
        self.* = undefined;
    }
};

/// Fuzz random node operations.
fn fuzzNodes(_: void, input: []const u8) !void {
    defer CompFlag.unregisterAll();

    var tr: Node.Tree = .empty;

    var fz: Fuzzer = try .init(input);
    defer fz.deinit();

    var o: Oracle = .init();
    defer o.deinit();

    while (!fz.smith.isEmpty()) {
        switch (fz.smith.next(enum {
            reserve,
            set_parent,
            destroy,
            insert,
            set_active,
        })) {
            .reserve => try reserve(&fz, &o),
            .set_parent => try setParent(&fz, &tr, &o),
            .insert => try insert(&fz, &tr, &o),
            .set_active => try setActive(&fz, &tr, &o),
            .destroy => if (fz.smith.next(bool)) {
                try destroy(&fz, &tr, &o);
            } else {
                try remove(&fz, &tr, &o);
            },
        }

        try checkOracle(&fz, &o, &tr, 0);
    }
}

/// Fuzz random node operations that are likely to create cycles that need breaking. This doesn't
/// occur very often when there are a large number of entities and entities are frequently removed,
/// so we bias for it here.
fn fuzzNodeCycles(_: void, input: []const u8) !void {
    defer CompFlag.unregisterAll();
    var fz: Fuzzer = try .init(input);
    defer fz.deinit();

    var tr: Node.Tree = .empty;

    var o: Oracle = .init();
    defer o.deinit();

    for (0..16) |_| {
        try reserve(&fz, &o);
    }

    while (!fz.smith.isEmpty()) {
        try setParent(&fz, &tr, &o);
        try checkOracle(&fz, &o, &tr, 0);
    }
}

/// Similar to `fuzzNodes` but uses command buffers.
fn fuzzNodesCmdBuf(_: void, input: []const u8) !void {
    defer CompFlag.unregisterAll();

    var fz: Fuzzer = try .init(input);
    defer fz.deinit();

    var o: Oracle = .init();
    defer o.deinit();

    var tr: Node.Tree = .empty;

    const extra_reserved = cmds_capacity;
    var cb: CmdBuf = try .init(.{
        .name = null,
        .gpa = gpa,
        .es = &fz.es,
        .cap = .{
            .cmds = cmds_capacity,
            .data = .{ .bytes_per_cmd = @sizeOf(Node) },
            .reserved_entities = extra_reserved,
        },
    });
    defer cb.deinit(gpa, &fz.es);

    while (!fz.smith.isEmpty()) {
        const set_actives = cmds_capacity;
        comptime std.debug.assert(set_actives > 100); // Make sure decent number of these
        for (0..fz.smith.nextLessThan(u16, 100)) |_| {
            try setActive(&fz, &tr, &o);
        }

        for (0..fz.smith.nextLessThan(u16, cmds_capacity)) |_| {
            switch (fz.smith.next(enum {
                reserve,
                set_parent,
                insert,
                destroy,
            })) {
                .reserve => try reserveCmd(&fz, &o, &cb, &tr),
                .set_parent => try setParentCmd(&fz, &o, &cb),
                .insert => try insertCmd(&fz, &o, &cb),
                .destroy => if (fz.smith.next(bool)) {
                    try destroyCmd(&fz, &o, &cb);
                } else {
                    try removeCmd(&fz, &o, &cb);
                },
            }
        }

        Node.Exec.immediate(&fz.es, &cb, &tr);
        try checkOracle(&fz, &o, &tr, extra_reserved);
    }
}

/// Similar to `fuzzNodeCycles` but uses command buffers.
fn fuzzNodeCyclesCmdBuf(_: void, input: []const u8) !void {
    defer CompFlag.unregisterAll();
    var fz: Fuzzer = try .init(input);
    defer fz.deinit();

    var o: Oracle = .init();
    defer o.deinit();

    var tr: Node.Tree = .empty;

    var cb: CmdBuf = try .init(.{
        .name = null,
        .gpa = gpa,
        .es = &fz.es,
        .cap = .{
            .cmds = cmds_capacity,
            .data = .{ .bytes_per_cmd = @sizeOf(Node) },
            .reserved_entities = 0,
        },
    });
    defer cb.deinit(gpa, &fz.es);

    for (0..16) |_| {
        try reserve(&fz, &o);
    }

    while (!fz.smith.isEmpty()) {
        for (0..fz.smith.nextLessThan(u16, cmds_capacity)) |_| {
            try setParentCmd(&fz, &o, &cb);
        }

        Node.Exec.immediate(&fz.es, &cb, &tr);
        try checkOracle(&fz, &o, &tr, 0);
    }
}

fn checkOracle(fz: *Fuzzer, o: *const Oracle, tr: *const Node.Tree, extra_reserved: usize) !void {
    if (log) std.debug.print("check oracle\n", .{});

    // Check the total entity count
    if (o.entities.count() != fz.es.count() + fz.es.reserved() - extra_reserved) {
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
                std.debug.print("oracle missing {f}\n", .{vw.e});
            }
        }

        // Check for entities the real data is missing
        var keys = o.entities.keyIterator();
        while (keys.next()) |e| {
            if (!e.exists(&fz.es)) {
                std.debug.print("entities missing {f}\n", .{e.*});
            }
        }
    }
    try expectEqual(o.entities.count(), fz.es.count() + fz.es.reserved() - extra_reserved);

    // Check each entity
    var iterator = o.entities.iterator();
    while (iterator.next()) |entry| {
        // Check the parent
        const node = entry.key_ptr.get(&fz.es, Node);
        const parent: Entity.Optional = if (entry.value_ptr.node) |n| n.parent else .none;
        const actual = if (node) |n| n.parent else Entity.Optional.none;
        try expectEqualEntity(actual, parent);

        // Check the active flag. We just check `active_self` here, we'll check
        // `active_in_hierarchy` in one go while traversing the tree later.
        if (entry.value_ptr.node) |oracle_node| {
            try expect(node != null);
            try expectEqual(oracle_node.active_self, node.?.active_self);
        } else {
            try expect(node == null);
        }

        // Check the children. We don't bother checking for dups since they would result in
        // the list being infinitely long and failing the implicit size check.
        if (node) |n| {
            var children = n.childIterator();
            var prev_sibling: Entity.Optional = .none;
            const keys = entry.value_ptr.node.?.children.keys();
            for (0..keys.len) |i| {
                const expected = keys[keys.len - i - 1];
                const child = children.next(&fz.es).?;
                try expectEqualEntity(expected, child.entity);

                // Validate prev pointers to catch issues sooner
                try expectEqualEntity(prev_sibling, child.node.prev_sib);
                prev_sibling = child.entity.toOptional();
            }
            try expectEqual(null, children.next(&fz.es));
        }

        try checkPostOrder(fz, o, entry.key_ptr.*);
        try checkPreOrder(fz, o, entry.key_ptr.*);
    }

    // Check the roots, make sure they're in order
    {
        const oracle_keys = o.roots.keys();
        var curr: Entity.Optional = tr.first_child;
        var i: usize = 0;
        while (curr.unwrap()) |c| : (i += 1) {
            try expect(oracle_keys[oracle_keys.len - i - 1] == c);
            curr = c.get(&fz.es, Node).?.next_sib;
            if (curr.unwrap()) |next| {
                try expect(next.get(&fz.es, Node).?.prev_sib == c.toOptional());
            }
        }
        try expectEqual(oracle_keys.len, i);
    }

    // Check active in hierarchy
    {
        var children = tr.childIterator();
        while (children.next(&fz.es)) |root| {
            try checkActiveInHierarchy(&fz.es, root.node, true);
        }
    }
}

fn checkActiveInHierarchy(es: *const Entities, node: *const Node, parent_active: bool) !void {
    // Check ourselves
    try expectEqual(node.active_self and parent_active, node.active_in_hierarchy);

    // Check our children
    var children = node.childIterator();
    while (children.next(es)) |child| {
        try checkActiveInHierarchy(es, child.node, node.active_in_hierarchy);
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
            const next = iter.next(&fz.es) orelse return error.ExpectedNext;
            try expectEqualEntity(curr, next.entity);
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
        const actual = iter.next(&fz.es) orelse return error.ExpectedNext;
        try expectEqualEntity(curr, actual.entity);
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

fn reserveCmd(fz: *Fuzzer, o: *Oracle, cb: *CmdBuf, tr: *Node.Tree) !void {
    // We reserve with a command buffer to exercise the `afterArchChangeImmediate` code in the test
    const entity: Entity = .reserve(cb);
    if (fz.smith.next(bool)) {
        entity.add(cb, Node, .{});
        try fz.committed.put(gpa, entity, .{});
        try o.entities.put(gpa, entity, .{ .node = .{} });
        try o.roots.put(gpa, entity, {});
    } else {
        entity.commit(cb);
        try fz.committed.put(gpa, entity, .{});
        try o.entities.put(gpa, entity, .{});
    }
    Node.Exec.immediate(&fz.es, cb, tr);
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

fn setParent(fz: *Fuzzer, tr: *Node.Tree, o: *Oracle) !void {
    // Get a random parent and child
    const parent = fz.randomEntity();
    const child = fz.randomEntity().unwrap() orelse return;
    if (log) std.debug.print("{f}.parent = {f}\n", .{ child, parent });

    if (parent.unwrap()) |p| if (!p.exists(&fz.es)) return;
    if (!child.exists(&fz.es)) return;
    const child_node = (child.viewOrAddImmediate(
        &fz.es,
        struct { *Node },
        .{&Node{}},
    ) orelse return)[0];
    if (child_node.uninitialized(&fz.es, tr)) {
        child_node.init(&fz.es, tr);
        try o.roots.put(gpa, child, {});
    }
    const parent_node = if (parent.unwrap()) |p| b: {
        const n = (p.viewOrAddImmediate(&fz.es, struct { *Node }, .{&Node{}}) orelse return)[0];
        if (n.uninitialized(&fz.es, tr)) {
            n.init(&fz.es, tr);
            try o.roots.put(gpa, p, {});
        }
        break :b n;
    } else null;
    child_node.setParentImmediate(&fz.es, tr, parent_node);
    try setParentInOracle(fz, o, child, parent);
}

fn insert(fz: *Fuzzer, tr: *Node.Tree, o: *Oracle) !void {
    // Get a random self, loc and operation
    const self = fz.randomEntity().unwrap() orelse return;
    const other = fz.randomEntity().unwrap() orelse return;
    const relative = fz.smith.next(std.meta.Tag(Node.Insert.Position));

    if (log) std.debug.print("insert {f} {t} {f}\n", .{ self, relative, other });

    if (!self.exists(&fz.es)) return;
    if (!other.exists(&fz.es)) return;
    const self_node = (self.viewOrAddImmediate(
        &fz.es,
        struct { *Node },
        .{&Node{}},
    ) orelse return)[0];
    if (self_node.uninitialized(&fz.es, tr)) {
        self_node.init(&fz.es, tr);
        try o.roots.put(gpa, self, {});
    }
    const other_node = (other.viewOrAddImmediate(
        &fz.es,
        struct { *Node },
        .{&Node{}},
    ) orelse return)[0];
    if (other_node.uninitialized(&fz.es, tr)) {
        other_node.init(&fz.es, tr);
        try o.roots.put(gpa, other, {});
    }

    self_node.insertImmediate(&fz.es, tr, relative, other_node);
    try insertInOracle(fz, o, self, relative, other);
}

fn setActive(fz: *Fuzzer, tr: *Node.Tree, o: *Oracle) !void {
    // Get a random self and active flag
    const self = fz.randomEntity().unwrap() orelse return;
    const active = fz.smith.next(bool);

    if (log) std.debug.print("setActive {f} {}\n", .{ self, active });

    if (!self.exists(&fz.es)) return;
    const self_node = (self.viewOrAddImmediate(
        &fz.es,
        struct { *Node },
        .{&Node{}},
    ) orelse return)[0];
    if (self_node.uninitialized(&fz.es, tr)) {
        self_node.init(&fz.es, tr);
        try o.roots.put(gpa, self, {});
    }

    self_node.setActive(&fz.es, active);
    try setActiveInOracle(o, self, active);
}

fn setParentCmd(fz: *Fuzzer, o: *Oracle, cb: *CmdBuf) !void {
    // Get a random parent and child
    const parent = fz.randomEntity();
    const child = fz.randomEntity().unwrap() orelse return;
    if (log) std.debug.print("{f}.parent = {f}\n", .{ child, parent });

    cb.ext(SetParent, .{ .child = child, .parent = parent });
    try setParentInOracle(fz, o, child, parent);
}

fn insertCmd(fz: *Fuzzer, o: *Oracle, cb: *CmdBuf) !void {
    // Get a self and other
    const self = fz.randomEntity().unwrap() orelse return;
    const other = fz.randomEntity().unwrap() orelse return;
    const relative = fz.smith.next(std.meta.Tag(Node.Insert.Position));
    if (log) std.debug.print("insert {f} {t} {f}\n", .{ self, relative, other });

    cb.ext(Insert, .{ .entity = self, .position = switch (relative) {
        .before => .{ .before = other },
        .after => .{ .after = other },
    } });
    try insertInOracle(fz, o, self, relative, other);
}

fn setParentInOracle(fz: *Fuzzer, o: *Oracle, child: Entity, parent: Entity.Optional) !void {
    // Get the oracle entity, adding a node if needed
    const optional_child_o = o.entities.getPtr(child);
    if (optional_child_o) |child_o| {
        if (child_o.node == null) {
            child_o.node = .{};
            try o.roots.put(gpa, child, {});
        }
    }

    if (parent.unwrap()) |p| {
        if (o.entities.getPtr(p)) |po| {
            if (po.node == null) {
                po.node = .{};
                try o.roots.put(gpa, p, {});
            }
        }
    }

    const child_o = optional_child_o orelse return;

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
    _ = o.roots.orderedRemove(child);
    const child_o_node = &child_o.node.?;
    const prev_parent = child_o_node.parent;
    if (prev_parent.unwrap()) |unwrapped| {
        const prev_parent_o = o.entities.getPtr(unwrapped).?;
        try expect(prev_parent_o.node.?.children.orderedRemove(child));
    }
    child_o_node.parent = .none;

    // Set the parent
    if (parent.unwrap()) |unwrapped| {
        if (unwrapped.exists(&fz.es)) {
            child_o_node.parent = unwrapped.toOptional();
            if (o.entities.getPtr(unwrapped).?.node == null) {
                o.entities.getPtr(unwrapped).?.node = .{};
            }
            try o.entities.getPtr(unwrapped).?.node.?.children.put(gpa, child, {});
        }
        _ = o.roots.orderedRemove(child);
    } else {
        try o.roots.put(gpa, child, {});
    }
}

fn insertInOracle(
    fz: *Fuzzer,
    o: *Oracle,
    self: Entity,
    relative: std.meta.Tag(Node.Insert.Position),
    other: Entity,
) !void {
    // Get the oracle entity, adding a node if needed
    const maybe_self_o = o.entities.getPtr(self);
    if (maybe_self_o) |self_o| {
        if (self_o.node == null) {
            self_o.node = .{};
            try o.roots.put(gpa, self, {});
        }
    }

    const other_o = o.entities.getPtr(other);
    if (other_o) |oo| {
        if (oo.node == null) {
            oo.node = .{};
            try o.roots.put(gpa, other, {});
        }
    }

    const self_o = maybe_self_o orelse return;

    // Early out if self and other are the same entity
    if (self == other) return;

    // Early out if self doesn't exist
    if (!o.entities.contains(self)) return;

    // If other doesn't exist, destroy self and early out
    if (!o.entities.contains(other)) {
        return destroyInOracle(fz, o, self);
    }

    // If self is an ancestor of other, early out
    if (try isAncestorOf(fz, o, self, other)) {
        return;
    }

    // Get the oracle nodes
    const self_node = &self_o.node.?;
    const other_node = &other_o.?.node.?;

    // Unparent the child
    _ = o.roots.orderedRemove(self);
    const prev_parent = self_node.parent;
    if (prev_parent.unwrap()) |unwrapped| {
        const prev_parent_o = o.entities.getPtr(unwrapped).?;
        try expect(prev_parent_o.node.?.children.orderedRemove(self));
    }
    self_node.parent = .none;

    // Insert the child at the new location
    self_node.parent = other_node.parent;
    const children = if (other_node.parent.unwrap()) |parent|
        &o.entities.getPtr(parent).?.node.?.children
    else
        &o.roots;
    // Offsets flipped since we push to the front of the children linked list, not the back
    const index = children.getIndex(other).? + switch (relative) {
        .after => @as(usize, 0),
        .before => @as(usize, 1),
    };
    if (index == children.count()) {
        // Add to the end of the map
        try children.put(gpa, self, {});
    } else {
        // Insert in the middle of the map and re-index
        try children.entries.insert(gpa, index, .{
            .key = self,
            .value = {},
            .hash = undefined, // Will be initialized by `reIndex`
        });
        try children.reIndex(gpa);
    }
}

fn setActiveInOracle(
    o: *Oracle,
    self: Entity,
    active: bool,
) !void {
    // Get the oracle entity, adding a node if needed
    const self_o = o.entities.getPtr(self).?;
    if (self_o.node == null) {
        self_o.node = .{};
        try o.roots.put(gpa, self, {});
    }

    // Early out if self doesn't exist
    if (!o.entities.contains(self)) return;

    // Set the oracle active flag
    self_o.node.?.active_self = active;
}

fn destroy(fz: *Fuzzer, tr: *Node.Tree, o: *Oracle) !void {
    if (fz.shouldSkipDestroy()) return;

    // Get a random entity
    const entity = fz.randomEntity().unwrap() orelse return;
    if (log) std.debug.print("destroy {f}\n", .{entity});

    // Destroy the real entity
    if (entity.get(&fz.es, Node)) |node| {
        _ = node.destroyImmediate(&fz.es, tr);
    } else {
        _ = entity.destroyImmediate(&fz.es);
    }

    // Destroy it in the oracle
    try destroyInOracle(fz, o, entity);
}

fn remove(fz: *Fuzzer, tr: *Node.Tree, o: *Oracle) !void {
    if (fz.shouldSkipDestroy()) return;

    // Get a random entity
    const entity = fz.randomEntity().unwrap() orelse return;
    if (log) std.debug.print("remove {f}\n", .{entity});

    // Remove from the real entity
    if (entity.get(&fz.es, Node)) |node| {
        _ = node.destroyChildrenAndPluckImmediate(&fz.es, tr);
        _ = entity.changeArchImmediate(&fz.es, struct {}, .{
            .add = .{},
            .remove = CompFlag.Set.initOne(CompFlag.registerImmediate(typeId(Node))),
        });
        _ = o.roots.orderedRemove(entity);
    }

    // Remove from the oracle
    try removeInOracle(fz, o, entity);
}

fn destroyCmd(fz: *Fuzzer, o: *Oracle, cb: *CmdBuf) !void {
    if (fz.shouldSkipDestroy()) return;

    // Get a random entity
    const entity = fz.randomEntity().unwrap() orelse return;
    if (log) std.debug.print("destroy {f}\n", .{entity});

    // Destroy the real entity
    entity.destroy(cb);

    // Destroy it in the oracle
    try destroyInOracle(fz, o, entity);
}

fn removeCmd(fz: *Fuzzer, o: *Oracle, cb: *CmdBuf) !void {
    if (fz.shouldSkipDestroy()) return;

    // Get a random entity
    const entity = fz.randomEntity().unwrap() orelse return;
    if (log) std.debug.print("remove {f}\n", .{entity});

    // Remove from the real entity
    entity.remove(cb, Node);
    _ = o.roots.orderedRemove(entity);

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
        _ = o.roots.orderedRemove(e);
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
        _ = o.roots.orderedRemove(e);
    }
}
