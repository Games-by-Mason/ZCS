//! Tests for the `Node` extension.

const std = @import("std");
const zcs = @import("zcs");

const Fuzzer = @import("../EntitiesFuzzer.zig");

const Entity = zcs.Entity;
const Entities = zcs.Entities;
const Any = zcs.Any;
const CompFlag = zcs.CompFlag;
const CmdBuf = zcs.CmdBuf;
const Node = zcs.ext.Node;
const SetParent = zcs.ext.Node.SetParent;

const gpa = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const log = false;

const cmds_capacity = 1000;

test "node immediate" {
    defer CompFlag.unregisterAll();

    var es = try Entities.init(gpa, .{ .max_entities = 128, .comp_bytes = 256 });
    defer es.deinit(gpa);

    const empty = Entity.reserveImmediate(&es);
    const parent = Entity.reserveImmediate(&es);
    const child_1 = Entity.reserveImmediate(&es);
    const child_2 = Entity.reserveImmediate(&es);
    const descendant = Entity.reserveImmediate(&es);
    try expect(Node.setParentImmediate(&es, child_2, parent.toOptional()));
    try expect(Node.setParentImmediate(&es, child_1, parent.toOptional()));
    try expect(Node.setParentImmediate(&es, descendant, child_1.toOptional()));

    try expect(!Node.isAncestorOf(&es, empty, child_1));
    try expect(!Node.isAncestorOf(&es, child_1, empty));
    try expect(!Node.isAncestorOf(&es, empty, empty));

    try expectEqualEntity(parent, child_1.getComp(&es, Node).?.parent.unwrap().?);
    try expectEqualEntity(parent, child_2.getComp(&es, Node).?.parent.unwrap().?);
    try expect(!Node.isAncestorOf(&es, parent, parent));
    try expect(Node.isAncestorOf(&es, parent, descendant));
    try expect(!Node.isAncestorOf(&es, descendant, parent));
    try expect(Node.isAncestorOf(&es, parent, child_1));
    try expect(Node.isAncestorOf(&es, parent, child_2));
    try expect(!Node.isAncestorOf(&es, child_1, child_2));

    var children = Node.childIterator(&es, parent);
    try expectEqualEntity(child_1, children.next(&es).?);
    try expectEqualEntity(child_2, children.next(&es).?);
    try expectEqual(null, children.next(&es));

    try expect(Node.destroyImmediate(&es, parent));
    try expect(!parent.exists(&es));
    try expect(!child_1.exists(&es));
    try expect(!child_2.exists(&es));

    try expect(!Node.isAncestorOf(&es, child_1, child_2));
    try expect(!Node.isAncestorOf(&es, child_1, child_1));
    try expect(!Node.isAncestorOf(&es, child_1, empty));
    try expect(!Node.isAncestorOf(&es, empty, child_1));
    try expect(!Node.isAncestorOf(&es, empty, empty));
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
    children: std.AutoHashMapUnmanaged(Entity, void) = .{},

    fn deinit(self: *@This()) void {
        self.children.deinit(gpa);
    }
};

const Oracle = struct {
    nodes: std.AutoHashMapUnmanaged(Entity, OracleNode),

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
                .reserve => try reserve(&fz, &o),
                .set_parent => try setParentCmd(&fz, &o, &cb),
                .destroy => try destroyCmd(&fz, &o, &cb),
            }
        }

        Node.Exec.allImmediate(&fz.es, &.{cb});
        try checkOracle(&fz, &o);
        clear(&fz, &cb, &o);
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

        Node.Exec.allImmediate(&fz.es, &.{cb});
        try checkOracle(&fz, &o);
        clear(&fz, &cb, &o);
    }
}

fn clear(fz: *Fuzzer, cb: *CmdBuf, o: *Oracle) void {
    _ = o;
    cb.clear(&fz.es);
}

fn checkOracle(fz: *Fuzzer, o: *const Oracle) !void {
    // Check the total entity count
    try expectEqual(o.nodes.count(), fz.es.count() + fz.es.reserved());

    // Check each entity
    var iterator = o.nodes.iterator();
    while (iterator.next()) |entry| {
        // Check the parent
        const node = entry.key_ptr.getComp(&fz.es, Node);
        const parent: Entity.Optional = if (node) |n| n.parent else .none;
        try expectEqualEntity(entry.value_ptr.parent, parent);

        // Check the children. We don't bother checking for dups since they would result in
        // the list being infinitely long and failing the implicit size check.
        var children = Node.childIterator(&fz.es, entry.key_ptr.*);
        var prev_sibling: Entity.Optional = .none;
        for (0..entry.value_ptr.children.count()) |_| {
            const child = children.next(&fz.es).?;
            try expect(entry.value_ptr.children.contains(child));

            // Validate prev pointers to catch issues sooner
            try expectEqualEntity(prev_sibling, child.getComp(&fz.es, Node).?.prev_sib);
            prev_sibling = child.toOptional();
        }
        try expectEqual(null, children.next(&fz.es));
    }
}

fn reserve(fz: *Fuzzer, o: *Oracle) !void {
    const entity = (try fz.reserveImmediate()).unwrap() orelse return;
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

    const result = Node.setParentImmediate(&fz.es, child, parent);
    const exists_after = child.exists(&fz.es);
    try expectEqual(exists_after, result);
    try setParentInOracle(fz, o, child, parent);
}

fn setParentCmd(fz: *Fuzzer, o: *Oracle, cb: *CmdBuf) !void {
    // Get a random parent and child
    const parent = fz.randomEntity();
    const child = fz.randomEntity().unwrap() orelse return;
    if (log) std.debug.print("{}.parent = {}\n", .{ child, parent });

    child.extCmd(cb, SetParent, .{parent});
    try setParentInOracle(fz, o, child, parent);
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
            try expect(o.nodes.getPtr(parent_parent).?.children.remove(unwrapped));
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
        try expect(prev_parent_o.children.remove(child));
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
    _ = Node.destroyImmediate(&fz.es, entity);

    // Destroy it in the oracle
    try destroyInOracle(fz, o, entity);
}

fn destroyCmd(fz: *Fuzzer, o: *Oracle, cb: *CmdBuf) !void {
    if (fz.shouldSkipDestroy()) return;

    // Get a random entity
    const entity = fz.randomEntity().unwrap() orelse return;
    if (log) std.debug.print("destroy {}\n", .{entity});

    // Destroy the real entity
    entity.destroyCmd(cb);

    // Destroy it in the oracle
    try destroyInOracle(fz, o, entity);
}

fn destroyInOracle(fz: *Fuzzer, o: *Oracle, e: Entity) !void {
    if (o.nodes.getPtr(e)) |n| {
        if (n.parent.unwrap()) |unwrapped| {
            try expect(o.nodes.getPtr(unwrapped).?.children.remove(e));
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
