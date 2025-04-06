//! A component that tracks parent child relationships.
//!
//! Node fields must be kept logically consistent. The recommended approach is to only modify nodes
//! through command buffers, and then use the provided command buffer processing to synchronize
//! your changes.

const std = @import("std");
const assert = std.debug.assert;

const zcs = @import("../root.zig");
const typeId = zcs.typeId;
const TypeId = zcs.TypeId;
const Entities = zcs.Entities;
const Entity = zcs.Entity;
const CmdBuf = zcs.CmdBuf;
const CompFlag = zcs.CompFlag;
const Any = zcs.Any;

const Node = @This();

parent: Entity.Optional = .none,
first_child: Entity.Optional = .none,
prev_sib: Entity.Optional = .none,
next_sib: Entity.Optional = .none,

pub const get = Entity.getMixin;
pub const getEntity = Entity.getEntityMixin;

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
pub fn setParentImmediate(self: *Node, es: *Entities, parent_opt: ?*Node) void {
    const pointer_lock = es.pointer_generation.lock();
    defer pointer_lock.check(es.pointer_generation);

    // If the relationship would result in a cycle, or parent and child are equal, early out.
    if (parent_opt) |parent| {
        if (self == parent) return;
        if (self.isAncestorOf(es, parent)) return;
    }

    // Unparent the child
    if (self.getParent(es)) |curr_parent| {
        if (self.getPrevSib(es)) |prev_sib| {
            prev_sib.next_sib = self.next_sib;
        } else {
            curr_parent.first_child = self.next_sib;
        }
        if (self.next_sib.unwrap()) |next_sib| {
            next_sib.get(es, Node).?.prev_sib = self.prev_sib;
            self.next_sib = .none;
        }
        self.prev_sib = .none;
        self.parent = .none;
    }

    // Set the new parent
    if (parent_opt) |parent| {
        self.parent = parent.getEntity(es).toOptional();
        self.next_sib = parent.first_child;
        const child_entity = self.getEntity(es);
        if (parent.first_child.unwrap()) |first_child| {
            first_child.get(es, Node).?.prev_sib = child_entity.toOptional();
        }
        parent.first_child = child_entity.toOptional();
    }
}

/// Destroys a node, its entity, and all of its children. This behavior occurs automatically via
/// `exec` when an entity with an entity with a node is destroyed.
///
/// Invalidates pointers.
pub fn destroyImmediate(unstable_ptr: *@This(), es: *Entities) void {
    // Cache the entity handle since we're about to invalidate pointers
    const e = unstable_ptr.getEntity(es);

    // Destroy the children and unparent this node
    unstable_ptr.destroyChildrenAndUnparentImmediate(es);

    // Destroy the entity
    assert(e.destroyImmediate(es));
}

/// Destroys a node's children and then unparents it. This behavior occurs automatically via `exec`
/// when a node is removed from an entity.
///
/// Invalidates pointers.
pub fn destroyChildrenAndUnparentImmediate(unstable_ptr: *@This(), es: *Entities) void {
    const pointer_lock = es.pointer_generation.lock();

    // Get an iterator over the node's children and then destroy it
    var children = b: {
        defer pointer_lock.check(es.pointer_generation);
        const self = unstable_ptr; // Not yet disturbed

        const iter = self.postOrderIterator(es);
        self.setParentImmediate(es, null);
        self.first_child = .none;

        break :b iter;
    };

    // Iterate over the children and destroy them, this will invalidate `unstable_ptr`
    es.pointer_generation.increment();
    while (children.next(es)) |curr| {
        assert(curr.getEntity(es).destroyImmediate(es));
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
pub fn childIterator(self: *const @This()) ChildIterator {
    return .{ .curr = self.first_child };
}

/// An iterator over a node's immediate children.
const ChildIterator = struct {
    curr: Entity.Optional,

    /// Returns the next child, or `null` if there are none.
    pub fn next(self: *@This(), es: *const Entities) ?*Node {
        const entity = self.curr.unwrap() orelse return null;
        const node = entity.get(es, Node).?;
        self.curr = node.next_sib;
        return node;
    }
};

/// Returns an iterator over the node's ancestors. The iterator starts at the parent, if any, and
/// then, follows the parent chain until it hits a node with no parent.
pub fn ancestorIterator(self: *const @This()) AncestorIterator {
    return .{ .curr = self.parent };
}

/// An iterator over a node's ancestors.
const AncestorIterator = struct {
    curr: Entity.Optional,

    /// Returns the next ancestor, or `null` if there are none.
    pub fn next(self: *@This(), es: *const Entities) ?*Node {
        const entity = self.curr.unwrap() orelse return null;
        const node = entity.get(es, Node).?;
        self.curr = node.parent;
        return node;
    }
};

/// Returns a pre-order iterator over a node's children. Pre-order traversal visits parents before
/// children.
pub fn preOrderIterator(self: *const @This(), es: *const Entities) PreOrderIterator {
    return .{
        .start = self.getEntity(es).toOptional(),
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
        .end = self.getEntity(es),
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

/// `exec` provides helpers for processing hierarchy changes via the command buffer.
///
/// By convention, `exec` only calls into the stable public interface of the types it's working
/// with. As such, documentation is sparse. You are welcome to call these methods directly, or
/// use them as reference for implementing your own command buffer iterator.
pub const exec = struct {
    /// Provided as reference. Executes a command buffer, maintaining the hierarchy and reacting to
    /// related events along the way. In practice, you likely want to call the finer grained
    /// functions provided directly, so that other libraries you use can also hook into the command
    /// buffer iterator.
    pub fn immediate(es: *Entities, cb: CmdBuf) void {
        immediateOrErr(es, cb) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `immediate`, but returns an error on failure instead of panicking. On error the
    /// commands are left partially evaluated.
    ///
    /// Invalidates pointers.
    pub fn immediateOrErr(
        es: *Entities,
        cb: CmdBuf,
    ) error{ ZcsArchOverflow, ZcsChunkOverflow, ZcsChunkPoolOverflow }!void {
        es.pointer_generation.increment();

        var batches = cb.iterator();
        while (batches.next()) |batch| {
            switch (batch) {
                .arch_change => |arch_change| {
                    var delta: CmdBuf.Batch.ArchChange.Delta = .{};
                    var ops = arch_change.iterator();
                    while (ops.next()) |op| {
                        beforeArchChangeImmediate(es, arch_change, op);
                        delta.updateImmediate(op);
                    }

                    _ = try arch_change.execImmediateOrErr(es, delta);
                },
                .ext => |ext| try extImmediateOrErr(es, ext),
            }
        }
    }

    /// Executes an extension command.
    pub inline fn extImmediateOrErr(
        es: *Entities,
        payload: Any,
    ) error{ ZcsArchOverflow, ZcsChunkOverflow, ZcsChunkPoolOverflow }!void {
        es.pointer_generation.increment();

        if (payload.as(SetParent)) |set_parent| {
            const child = set_parent.child;
            if (set_parent.parent.unwrap()) |parent| {
                if (try child.getOrAddImmediateOrErr(es, Node, .{})) |child_node| {
                    if (try parent.getOrAddImmediateOrErr(es, Node, .{})) |parent_node| {
                        // If a parent that exists is assigned, set it as the parent
                        child_node.setParentImmediate(es, parent_node);
                    } else {
                        // Otherwise destroy the child
                        child_node.destroyImmediate(es);
                    }
                }
            } else {
                // If our parent is being cleared and we have a node, clear it. If not leave
                // it alone since it's implicitly clear.
                if (child.get(es, Node)) |node| {
                    node.setParentImmediate(es, null);
                }
            }
        }
    }

    /// Call this before executing a command.
    pub inline fn beforeArchChangeImmediate(
        es: *Entities,
        arch_change: CmdBuf.Batch.ArchChange,
        op: CmdBuf.Batch.ArchChange.Op,
    ) void {
        switch (op) {
            .destroy => if (arch_change.entity.get(es, Node)) |node| {
                _ = node.destroyChildrenAndUnparentImmediate(es);
            },
            .remove => |id| if (id == typeId(Node)) {
                if (arch_change.entity.get(es, Node)) |node| {
                    _ = node.destroyChildrenAndUnparentImmediate(es);
                }
            },
            .add => {},
        }
    }
};
