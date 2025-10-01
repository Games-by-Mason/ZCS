//! A component that tracks parent child relationships.
//!
//! Node fields must be kept logically consistent. The recommended approach is to only modify nodes
//! through command buffers, and then use the provided command buffer processing to synchronize
//! your changes.

const std = @import("std");
const tracy = @import("tracy");

const assert = std.debug.assert;

const zcs = @import("../root.zig");
const typeId = zcs.typeId;
const TypeId = zcs.TypeId;
const Entities = zcs.Entities;
const Entity = zcs.Entity;
const CmdBuf = zcs.CmdBuf;
const CompFlag = zcs.CompFlag;
const Any = zcs.Any;

const Zone = tracy.Zone;

const Node = @This();

pub const Tree = struct {
    pub const empty: @This() = .{ .first_child = .none };
    first_child: Entity.Optional,

    pub fn getFirstChild(self: @This(), es: *Entities) ?*Node {
        const entity = self.first_child.unwrap() orelse return null;
        return entity.get(es, Node).?;
    }
};

parent: Entity.Optional = .none,
first_child: Entity.Optional = .none,
prev_sib: Entity.Optional = .none,
next_sib: Entity.Optional = .none,

/// Initializes this node. Called automatically by the command buffer API, must be called manually
/// before using a node if working with the immediate API.
pub fn init(self: *@This(), es: *Entities, tr: *Tree) void {
    assert(self.uninitialized(es, tr));
    const entity = es.getEntity(self);
    self.next_sib = tr.first_child;
    if (tr.getFirstChild(es)) |fc| fc.prev_sib = entity.toOptional();
    tr.first_child = entity.toOptional();
}

/// Returns true if this node has not yet been initialized.
pub fn uninitialized(self: *const @This(), es: *const Entities, tr: *const Tree) bool {
    const entity = es.getEntity(self);
    if (self.parent.unwrap() == null and
        self.prev_sib.unwrap() == null and
        tr.first_child != entity.toOptional())
    {
        assert(self.next_sib.unwrap() == null);
        assert(self.first_child.unwrap() == null);
        return true;
    }
    return false;
}

/// Returns the parent node, or null if none exists.
pub fn getParent(self: *const @This(), es: *const Entities) ?*Node {
    const parent = self.parent.unwrap() orelse return null;
    return parent.get(es, Node).?;
}

/// Returns the first child, or null if none exists.
pub fn getFirstChild(self: *const @This(), es: *const Entities) ?*Node {
    const first_child = self.first_child.unwrap() orelse return null;
    return first_child.get(es, Node).?;
}

/// Returns the previous sibling, or null if none exists.
pub fn getPrevSib(self: *const @This(), es: *const Entities) ?*Node {
    const prev_sib = self.prev_sib.unwrap() orelse return null;
    return prev_sib.get(es, Node).?;
}

/// Returns the next sibling, or null if none exists.
pub fn getNextSib(self: *const @This(), es: *const Entities) ?*Node {
    const next_sib = self.next_sib.unwrap() orelse return null;
    return next_sib.get(es, Node).?;
}

/// Similar to the `SetParent` command, but sets the parent immediately.
pub fn setParentImmediate(self: *Node, es: *Entities, tr: *Tree, parent_opt: ?*Node) void {
    const pointer_lock = es.pointer_generation.lock();
    defer pointer_lock.check(es.pointer_generation);

    // If the relationship would result in a cycle, or parent and child are equal, early out.
    if (parent_opt) |parent| {
        if (self == parent) return;
        if (self.isAncestorOf(es, parent)) return;
    }

    // Remove this node from the tree
    pluckImmediate(self, es, tr);

    // Add this node back to the tree with the new parent
    if (parent_opt) |parent| {
        self.parent = es.getEntity(parent).toOptional();
        self.next_sib = parent.first_child;
        const child_entity = es.getEntity(self);
        if (parent.first_child.unwrap()) |first_child| {
            first_child.get(es, Node).?.prev_sib = child_entity.toOptional();
        }
        parent.first_child = child_entity.toOptional();
    } else {
        const child = es.getEntity(self);
        self.next_sib = tr.first_child;
        if (tr.getFirstChild(es)) |fc| fc.prev_sib = child.toOptional();
        tr.first_child = child.toOptional();
    }
}

/// Similar to the `Insert`, but makes the change immediately.
pub fn insert(
    self: *Node,
    es: *Entities,
    tr: *Tree,
    relative: std.meta.Tag(Insert.Position),
    other: *Node,
) void {
    const pointer_lock = es.pointer_generation.lock();
    defer pointer_lock.check(es.pointer_generation);

    // If the relationship would result in a cycle, or parent and child are equal, early out.
    if (self == other) return;
    if (self.isAncestorOf(es, other)) return;

    // Remove this node from the tree
    pluckImmediate(self, es, tr);

    // Add this node back to the tree in the new location
    const self_entity = es.getEntity(self);
    const other_entity = es.getEntity(other);

    self.parent = other.parent;

    switch (relative) {
        .after => {
            self.next_sib = other.next_sib;
            if (self.next_sib.unwrap()) |next_sib| {
                next_sib.get(es, Node).?.prev_sib = self_entity.toOptional();
            }
            self.prev_sib = other_entity.toOptional();
            other.next_sib = self_entity.toOptional();
        },
        .before => {
            self.prev_sib = other.prev_sib;
            if (self.prev_sib.unwrap()) |prev_sib| {
                prev_sib.get(es, Node).?.next_sib = self_entity.toOptional();
            } else if (self.getParent(es)) |parent| {
                assert(parent.first_child == other_entity.toOptional());
                parent.first_child = self_entity.toOptional();
            } else {
                assert(tr.first_child == other_entity.toOptional());
                tr.first_child = self_entity.toOptional();
            }
            self.next_sib = other_entity.toOptional();
            other.prev_sib = self_entity.toOptional();
        },
    }
}

/// Destroys a node, its entity, and all of its children. This behavior occurs automatically via
/// `exec` when an entity with an entity with a node is destroyed.
///
/// Invalidates pointers.
pub fn destroyImmediate(unstable_ptr: *@This(), es: *Entities, tr: *Tree) void {
    // Cache the entity handle since we're about to invalidate pointers
    const e = es.getEntity(unstable_ptr);

    // Destroy the children and unparent this node
    unstable_ptr.destroyChildrenAndPluckImmediate(es, tr);

    // Destroy the entity
    assert(e.destroyImmediate(es));
}

/// Intended for internal use, but may have advanced external uses. Removes this node from its
/// parents without adding it to the root of the tree. To result in a well formed tree, you must
/// follow this up by destroying the entity, removing the node, or replacing it elsewhere in the
/// tree.
fn pluckImmediate(self: *@This(), es: *Entities, tr: *Tree) void {
    // Update the previous sibling
    if (self.getPrevSib(es)) |prev_sib| {
        prev_sib.next_sib = self.next_sib;
    } else if (self.getParent(es)) |parent| {
        assert(parent.first_child == es.getEntity(self).toOptional());
        parent.first_child = self.next_sib;
    } else {
        assert(tr.first_child == es.getEntity(self).toOptional());
        tr.first_child = self.next_sib;
        if (tr.getFirstChild(es)) |fc| fc.prev_sib = .none;
    }

    // Update the next sibling
    if (self.next_sib.unwrap()) |next_sib| {
        next_sib.get(es, Node).?.prev_sib = self.prev_sib;
    }

    // Null out our tree pointers
    self.prev_sib = .none;
    self.next_sib = .none;
    self.parent = .none;
}

/// Intended for internal use, see `pluckImmediate`. Similar but destroys children before plucking.
///
/// Invalidates pointers.
pub fn destroyChildrenAndPluckImmediate(
    unstable_ptr: *@This(),
    es: *Entities,
    tr: *Tree,
) void {
    const pointer_lock = es.pointer_generation.lock();

    // Get an iterator over the node's children and then destroy it
    var children = b: {
        defer pointer_lock.check(es.pointer_generation);
        const self = unstable_ptr; // Not yet disturbed

        const iter = self.postOrderIterator(es);
        self.pluckImmediate(es, tr);
        self.first_child = .none;

        break :b iter;
    };

    // Iterate over the children and destroy them, this will invalidate `unstable_ptr`
    es.pointer_generation.increment();
    while (children.next(es)) |curr| {
        assert(es.getEntity(curr).destroyImmediate(es));
    }
}

/// Returns true if an ancestor of `descendant`, false otherwise. Entities are not ancestors of
/// themselves.
pub fn isAncestorOf(self: *const @This(), es: *const Entities, descendant: *const Node) bool {
    var curr = descendant.getParent(es) orelse return false;
    while (true) {
        if (curr == self) return true;
        curr = curr.getParent(es) orelse return false;
    }
}

/// Returns an iterator over the node's immediate children.
pub fn childIterator(self: *const @This()) SiblingIterator {
    return .{ .curr = self.first_child };
}

/// Returns an iterator over the node's ancestors. The iterator starts at the parent, if any, and
/// then, follows the parent chain until it hits a node with no parent.
pub fn ancestorIterator(self: *const @This()) AncestorIterator {
    return .{ .curr = self.parent };
}

/// An iterator over a node's ancestors.
pub const AncestorIterator = struct {
    curr: Entity.Optional,

    /// Returns the next ancestor, or `null` if there are none.
    pub fn next(self: *@This(), es: *const Entities) ?*Node {
        const entity = self.curr.unwrap() orelse return null;
        const node = entity.get(es, Node).?;
        self.curr = node.parent;
        return node;
    }
};

/// Returns an iterator over the node and its it's upcoming siblings.
pub fn siblingIterator(self: *const @This(), es: *Entities) SiblingIterator {
    return .{ .curr = es.getEntity(self).toOptional() };
}

/// An iterator over a node and it's upcoming siblings.
pub const SiblingIterator = struct {
    curr: Entity.Optional,

    /// Returns the next sibling, or `null` if there are none.
    pub fn next(self: *@This(), es: *const Entities) ?*Node {
        const entity = self.curr.unwrap() orelse return null;
        const node = entity.get(es, Node).?;
        self.curr = node.next_sib;
        return node;
    }
};

/// Returns a pre-order iterator over a node's children. Pre-order traversal visits parents before
/// children.
pub fn preOrderIterator(self: *const @This(), es: *const Entities) PreOrderIterator {
    return .{
        .start = es.getEntity(self).toOptional(),
        .curr = self.first_child,
    };
}

/// A pre-order iterator over `(start, ...]`.
pub const PreOrderIterator = struct {
    start: Entity.Optional,
    curr: Entity.Optional,

    /// An empty pre-order iterator.
    pub const empty: @This() = .{
        .start = .none,
        .curr = .none,
    };

    /// Returns the next child, or `null` if there are none.
    pub fn next(self: *@This(), es: *const Entities) ?*Node {
        const pre_entity = self.curr.unwrap() orelse return null;
        const pre = pre_entity.get(es, Node).?;
        if (pre.first_child != Entity.Optional.none) {
            self.curr = pre.first_child;
        } else {
            var has_next_sib = pre;
            while (has_next_sib.next_sib.unwrap() == null) {
                if (has_next_sib.parent.unwrap().? == self.start.unwrap().?) {
                    self.curr = .none;
                    return pre;
                }
                has_next_sib = has_next_sib.getParent(es).?;
            }
            self.curr = has_next_sib.next_sib.unwrap().?.toOptional();
        }
        return pre;
    }

    /// Fast forward the iterator to just after the given subtree.
    ///
    /// Asserts that `subtree` is a subtree of this iterator.
    pub fn skipSubtree(self: *@This(), es: *const Entities, subtree: *const Node) void {
        // Assert that subtree is contained by this iterator. If it isn't, we'd end up with an
        // infinite loop.
        if (self.start.unwrap()) |start| {
            assert(start.get(es, Node).?.isAncestorOf(es, subtree));
        }

        var has_next_sib = subtree;
        while (has_next_sib.next_sib.unwrap() == null) {
            if (has_next_sib.parent.unwrap().? == self.start.unwrap().?) {
                self.curr = .none;
                return;
            }
            has_next_sib = has_next_sib.getParent(es).?;
        }
        self.curr = has_next_sib.next_sib.unwrap().?.toOptional();
    }
};

/// Returns a post-order iterator over a node's children. Post-order traversal visits parents after
/// children.
pub fn postOrderIterator(self: *const @This(), es: *const Entities) PostOrderIterator {
    return .{
        // We start on the leftmost leaf
        .curr = b: {
            var curr = self.first_child.unwrap() orelse break :b .none;
            while (curr.get(es, Node).?.first_child.unwrap()) |fc| curr = fc;
            break :b curr.toOptional();
        },
        // And we end when we reach the given entity
        .end = es.getEntity(self),
    };
}

/// A post-order iterator over `[curr, end)`.
pub const PostOrderIterator = struct {
    curr: Entity.Optional,
    end: Entity,

    /// Returns the next child, or `null` if there are none.
    pub fn next(self: *@This(), es: *const Entities) ?*Node {
        const post_entity = self.curr.unwrap() orelse return null;
        if (post_entity == self.end) return null;
        const post = post_entity.get(es, Node).?;
        if (post.next_sib.unwrap()) |next_sib| {
            var curr = next_sib;
            while (curr.get(es, Node).?.first_child.unwrap()) |fc| curr = fc;
            self.curr = curr.toOptional();
        } else {
            self.curr = self.curr.unwrap().?.get(es, Node).?.parent.unwrap().?.toOptional();
        }
        return post;
    }
};

/// Encodes a command that requests to parent `child` and `parent`.
///
/// * If the relationship would result in a cycle, parent and child are equal, or child no longer
///   exists, then no change is made.
/// * If parent is `.none`, child is unparented.
/// * If parent no longer exists, child is destroyed.
pub const SetParent = struct {
    child: Entity,
    parent: Entity.Optional,
};

/// Encodes a command that requests to insert self relative to other.
///
/// * If the relationship would result in a cycle, self and other are equal, or self no longer
///   exists, then no change is made.
/// * If other no longer exists, self is destroyed.
pub const Insert = struct {
    pub const Position = union(enum) {
        before: Entity,
        after: Entity,

        pub fn entity(self: @This()) Entity {
            return switch (self) {
                .before => |e| e,
                .after => |e| e,
            };
        }
    };

    entity: Entity,
    position: Position,
};

/// `Exec` provides helpers for processing hierarchy changes via the command buffer.
///
/// By convention, `exec` only calls into the stable public interface of the types it's working
/// with. As such, documentation is sparse. You are welcome to call these methods directly, or
/// use them as reference for implementing your own command buffer iterator.
pub const Exec = struct {
    /// Provided as reference. Executes a command buffer, maintaining the hierarchy and reacting to
    /// related events along the way. In practice, you likely want to call the finer grained
    /// functions provided directly, so that other libraries you use can also hook into the command
    /// buffer iterator.
    pub fn immediate(es: *Entities, cb: *CmdBuf, tr: *Tree) void {
        immediateOrErr(es, cb, tr) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `immediate`, but returns an error on failure instead of panicking. On error the
    /// commands are left partially evaluated.
    ///
    /// Invalidates pointers.
    pub fn immediateOrErr(
        es: *Entities,
        cb: *CmdBuf,
        tr: *Tree,
    ) error{ ZcsArchOverflow, ZcsChunkOverflow, ZcsChunkPoolOverflow, ZcsEntityOverflow }!void {
        var default_exec: CmdBuf.Exec = .init();

        es.pointer_generation.increment();

        var batches = cb.iterator();
        while (batches.next()) |batch| {
            switch (batch) {
                .arch_change => |arch_change| {
                    {
                        var delta: CmdBuf.Batch.ArchChange.Delta = .{};
                        var ops = arch_change.iterator();
                        while (ops.next()) |op| {
                            beforeArchChangeImmediate(es, tr, arch_change, op);
                            delta.updateImmediate(op);
                        }

                        _ = try arch_change.execImmediateOrErr(es, delta);
                    }

                    {
                        var ops = arch_change.iterator();
                        while (ops.next()) |op| {
                            afterArchChangeImmediate(es, tr, arch_change, op);
                        }
                    }
                },
                .ext => |ext| {
                    try extImmediateOrErr(es, tr, ext);
                    default_exec.extImmediateOrErr(ext);
                },
            }
        }

        try default_exec.finish(cb, es);
    }

    /// Executes an extension command.
    pub inline fn extImmediateOrErr(
        es: *Entities,
        tr: *Tree,
        payload: Any,
    ) error{ ZcsArchOverflow, ZcsChunkOverflow, ZcsChunkPoolOverflow }!void {
        if (payload.as(SetParent)) |args| {
            // Get or add node the parent and child
            const child_node = try args.child.getOrAddImmediateOrErr(es, Node, .{});
            if (child_node) |child| {
                if (child.uninitialized(es, tr)) {
                    child.init(es, tr);
                }
            }

            const parent_node = if (args.parent.unwrap()) |parent|
                try parent.getOrAddImmediateOrErr(es, Node, .{})
            else
                null;
            if (parent_node) |parent| {
                if (parent.uninitialized(es, tr)) {
                    parent.init(es, tr);
                }
            }

            // Set up the parent child relationship
            if (child_node) |child| {
                if (parent_node) |parent| {
                    // Set as the child's parent
                    child.setParentImmediate(es, tr, parent);
                } else if (args.parent.unwrap() == null) {
                    // Clear the child's parent
                    child.setParentImmediate(es, tr, null);
                } else {
                    // The parent has since been deleted, destroy the child
                    child.destroyImmediate(es, tr);
                }
            }
        } else if (payload.as(Insert)) |args| {
            // Get or add node the self and other
            const self_node = try args.entity.getOrAddImmediateOrErr(es, Node, .{});
            if (self_node) |self| {
                if (self.uninitialized(es, tr)) {
                    self.init(es, tr);
                }
            }

            const other_node = try args.position.entity().getOrAddImmediateOrErr(es, Node, .{});
            if (other_node) |other| {
                if (other.uninitialized(es, tr)) {
                    other.init(es, tr);
                }
            }

            // Set up the relationship
            if (self_node) |self| {
                if (other_node) |other| {
                    // Set up the relationship
                    self.insert(es, tr, std.meta.activeTag(args.position), other);
                } else {
                    // Other has since been deleted, destroy the child
                    self.destroyImmediate(es, tr);
                }
            }
        }
    }

    /// Call this before executing a command.
    pub inline fn beforeArchChangeImmediate(
        es: *Entities,
        tr: *Tree,
        arch_change: CmdBuf.Batch.ArchChange,
        op: CmdBuf.Batch.ArchChange.Op,
    ) void {
        switch (op) {
            .destroy => if (arch_change.entity.get(es, Node)) |node| {
                _ = node.destroyChildrenAndPluckImmediate(es, tr);
            },
            .remove => |id| if (id == typeId(Node)) {
                if (arch_change.entity.get(es, Node)) |node| {
                    _ = node.destroyChildrenAndPluckImmediate(es, tr);
                }
            },
            .add => {},
        }
    }

    /// Call this after executing a command.
    pub inline fn afterArchChangeImmediate(
        es: *Entities,
        tr: *Tree,
        arch_change: CmdBuf.Batch.ArchChange,
        op: CmdBuf.Batch.ArchChange.Op,
    ) void {
        switch (op) {
            .destroy => {},
            .remove => {},
            .add => |comp| if (comp.id == typeId(Node)) {
                if (arch_change.entity.get(es, Node)) |node| {
                    if (node.uninitialized(es, tr)) node.init(es, tr);
                }
            },
        }
    }
};
