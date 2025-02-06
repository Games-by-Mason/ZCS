//! A component that tracks parent child relationships.
//!
//! Node fields must be kept logically consistent. It's recommended that you only modify them
//! through command buffers, and then use the provided command buffer processing to synchronize
//! your changes.
//!
//! If you need to make immediate changes to an entity's hierarchy, some helpers are also provided
//! for this. This is discouraged as this approach requires you to remember to call these functions
//! at the correct times, whereas the command buffer approach is just requires you process the
//! command buffer before executing it.

const std = @import("std");
const assert = std.debug.assert;

const zcs = @import("../root.zig");
const view = zcs.view;
const Entities = zcs.Entities;
const Entity = zcs.Entity;

const Node = @This();

parent: Entity.Optional = .none,
first_child: Entity.Optional = .none,
prev_sib: Entity.Optional = .none,
next_sib: Entity.Optional = .none,

/// View mixins for working with nodes.
pub fn Mixins(Self: type) type {
    return struct {
        pub fn getParent(self: Self, es: *const Entities) ?Self {
            const node = view.asOptional(self.node) orelse return null;
            const parent = node.parent.unwrap() orelse return null;
            return Self.init(es, parent).?;
        }

        pub fn getFirstChild(self: Self, es: *const Entities) ?Self {
            const node = view.asOptional(self.node) orelse return null;
            const first_child = node.first_child.unwrap() orelse return null;
            return Self.init(es, first_child).?;
        }

        pub fn getPrevSib(self: Self, es: *const Entities) ?Self {
            const node = view.asOptional(self.node) orelse return null;
            const prev_sib = node.prev_sib.unwrap() orelse return null;
            return Self.init(es, prev_sib).?;
        }

        pub fn getNextSib(self: Self, es: *const Entities) ?Self {
            const node = view.asOptional(self.node) orelse return null;
            const next_sib = node.next_sib.unwrap() orelse return null;
            return Self.init(es, next_sib).?;
        }
    };
}

/// A view of an entity containing a node.
pub const View = struct {
    entity: Entity,
    node: *Node,

    pub const init = view.Mixins(@This()).init;

    pub fn gop(es: *Entities, entity: Entity) ?View {
        return .{
            .entity = entity,
            .node = entity.getComp(es, Node) orelse b: {
                if (!entity.changeArchImmediate(es, .{ .add = &.{.init(Node, &.{})} })) {
                    return null;
                }
                break :b entity.getComp(es, Node).?;
            },
        };
    }

    pub const getParent = Mixins(@This()).getParent;
    pub const getFirstChild = Mixins(@This()).getFirstChild;
    pub const getPrevSib = Mixins(@This()).getPrevSib;
    pub const getNextSib = Mixins(@This()).getNextSib;
};

/// Parents `child` and `parent` immediately.
///
/// * If the relationship would result in a cycle, `parent` is first moved up the tree to the level
///   of `child`
/// * If parent is `.none`, child is unparented
/// * If parent and child are equal, no change is made
/// * If parent no longer exists, child is destroyed
/// * If child no longer exists, no change is made
pub fn setParentImmediate(es: *Entities, child: Entity, parent: Entity.Optional) void {
    if (child.toOptional() == parent) return;
    const child_view: View = View.gop(es, child) orelse return;
    const parent_view: ?View = if (parent.unwrap()) |unwrapped| b: {
        if (View.gop(es, unwrapped)) |v| {
            break :b v;
        } else {
            destroyImmediate(es, unwrapped);
            return;
        }
    } else null;
    setParentImmediateInner(es, child_view, parent_view, true);
}

fn setParentImmediateInner(
    es: *Entities,
    child: View,
    optional_parent: ?View,
    break_cycles: bool,
) void {
    const original_parent = child.node.parent;

    // Unparent the child
    if (child.getParent(es)) |curr_parent| {
        if (child.getPrevSib(es)) |prev_sib| {
            prev_sib.node.next_sib = child.node.next_sib;
        } else {
            curr_parent.node.first_child = child.node.next_sib;
        }
        if (child.node.next_sib.unwrap()) |next_sib| {
            next_sib.getComp(es, Node).?.prev_sib = child.node.prev_sib;
            child.node.next_sib = .none;
        }
        child.node.prev_sib = .none;
        child.node.parent = .none;
    }

    // Set the new parent
    if (optional_parent) |parent| {
        // If this relationship would create a cycle, parent the new parent to the child's original
        // parent
        if (break_cycles and isAncestor(es, child.entity, parent.node.parent)) {
            const op: ?View = if (original_parent.unwrap()) |unwrapped| b: {
                const op = View.init(es, unwrapped).?;
                break :b op;
            } else null;
            setParentImmediateInner(es, parent, op, false);
        }

        // Parent the child
        child.node.parent = parent.entity.toOptional();
        child.node.next_sib = parent.node.first_child;
        if (parent.node.first_child.unwrap()) |first_child| {
            first_child.getComp(es, Node).?.prev_sib = child.entity.toOptional();
        }
        parent.node.first_child = child.entity.toOptional();
    }
}

/// Destroys an entity and all of its children.
pub fn destroyImmediate(es: *Entities, e: Entity) void {
    if (e.getComp(es, Node)) |node| {
        // Unparent ourselves
        setParentImmediate(es, e, .none);

        // Destroy all our children depth first
        if (node.first_child.unwrap()) |start| {
            var curr = View.init(es, start).?;
            while (true) {
                if (curr.node.first_child.unwrap()) |first_child| {
                    curr = View.init(es, first_child).?;
                } else {
                    const prev = curr;
                    if (curr.node.next_sib.unwrap()) |next_sib| {
                        curr = View.init(es, next_sib).?;
                    } else {
                        curr = View.init(es, curr.node.parent.unwrap().?).?;
                        curr.node.first_child = .none;
                    }
                    prev.entity.destroyImmediate(es);
                }
                if (curr.entity == e) break;
            }
        }
    }

    // Destroy ourselves
    e.destroyImmediate(es);
}

/// Returns true if `ancestor` is identical to or is an ancestor of `descendant`, otherwise returns
/// false.
pub fn isAncestor(es: *const Entities, ancestor: Entity, descendant: Entity.Optional) bool {
    var curr = descendant;
    while (curr.unwrap()) |unwrapped| {
        if (unwrapped == ancestor) return true;
        curr = unwrapped.getComp(es, Node).?.parent;
    }
    return false;
}

/// Returns an iterator over the given entity's immediate children.
pub fn childIterator(es: *const Entities, e: Entity) ChildIterator {
    const node = e.getComp(es, Node) orelse return .{ .curr = .none };
    return .{ .curr = node.first_child };
}

/// An iterator over an entity's immediate children.
const ChildIterator = struct {
    curr: Entity.Optional,

    /// Returns the next child, or `.none` if there are none.
    pub fn next(self: *@This(), es: *const Entities) ?Entity {
        const entity = self.curr.unwrap() orelse return null;
        const node = entity.getComp(es, Node).?;
        self.curr = node.next_sib;
        return entity;
    }
};
