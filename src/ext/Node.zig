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

const zcs = @import("../root.zig");
const Entities = zcs.Entities;
const Entity = zcs.Entity;

const Node = @This();

parent: Entity = .none,
first_child: Entity = .none,
prev_sib: Entity = .none,
next_sib: Entity = .none,

/// Parents child and parent immediately.
///
/// If parent is `.none`, child is unparented.
///
/// If the relationship would result in a cycle, parent is moved up the tree to the level of child
/// before the parenting is done.
pub fn setParentImmediate(es: *Entities, child: Entity, parent: Entity) void {
    setParentImmediateInner(es, child, parent, true);
}

fn setParentImmediateInner(es: *Entities, child: Entity, parent: Entity, break_cycles: bool) void {
    if (child.eql(parent)) return;

    if (!child.exists(es)) return;
    if (!child.hasComp(es, Node)) {
        child.changeArchImmediate(es, .{ .add = &.{.init(Node, &.{})} });
    }
    const child_node = child.getComp(es, Node).?;
    const original_parent = child_node.parent;

    // Unparent the child
    if (!child_node.parent.eql(.none)) {
        const curr_parent = child_node.parent.getComp(es, Node).?;

        if (child_node.prev_sib.eql(.none)) {
            curr_parent.first_child = child_node.next_sib;
        } else {
            child_node.prev_sib.getComp(es, Node).?.next_sib = child_node.next_sib;
        }
        if (!child_node.next_sib.eql(.none)) {
            child_node.next_sib.getComp(es, Node).?.prev_sib = child_node.prev_sib;
            child_node.next_sib = .none;
        }
        child_node.prev_sib = .none;
        child_node.parent = .none;
    }

    // Set the new parent
    if (parent.exists(es)) {
        // Get node from parent
        if (!parent.hasComp(es, Node)) {
            parent.changeArchImmediate(es, .{ .add = &.{.init(Node, &.{})} });
        }
        const parent_node = parent.getComp(es, Node).?;

        // If this would create a cycle, parent the new parent to the child's old parent
        if (break_cycles) {
            var curr = parent_node.parent;
            while (!curr.eql(.none)) {
                if (curr.eql(child)) {
                    setParentImmediateInner(es, parent, original_parent, false);
                    break;
                }
                curr = curr.getComp(es, Node).?.parent;
            }
        }

        // Parent the child
        child_node.parent = parent;
        child_node.next_sib = parent_node.first_child;
        if (!parent_node.first_child.eql(.none)) {
            parent_node.first_child.getComp(es, Node).?.prev_sib = child;
        }
        parent_node.first_child = child;
    }
}

/// Destroys an entity and all of its children.
pub fn destroyImmediate(es: *Entities, e: Entity) void {
    if (e.getComp(es, Node)) |node| {
        // Unparent ourselves
        setParentImmediate(es, e, .none);

        // Destroy all our children depth first
        var curr = node.first_child;
        if (!curr.eql(.none)) {
            var curr_node = curr.getComp(es, Node).?;
            while (!curr.eql(e)) {
                if (!curr_node.first_child.eql(.none)) {
                    curr = curr_node.first_child;
                    curr_node = curr.getComp(es, Node).?;
                } else {
                    const prev = curr;
                    if (!curr_node.next_sib.eql(.none)) {
                        curr = curr_node.next_sib;
                        curr_node = curr.getComp(es, Node).?;
                    } else {
                        curr = curr_node.parent;
                        curr_node = curr.getComp(es, Node).?;
                        curr_node.first_child = .none;
                    }
                    prev.destroyImmediate(es);
                }
            }
        }
    }

    // Destroy ourselves
    e.destroyImmediate(es);
}

pub fn childIterator(es: *const Entities, e: Entity) ChildIterator {
    const node = e.getComp(es, Node) orelse return .{ .curr = .none };
    return .{ .curr = node.first_child };
}

const ChildIterator = struct {
    curr: Entity,

    pub fn next(self: *@This(), es: *const Entities) Entity {
        if (self.curr.eql(.none)) return .none;
        const node = self.curr.getComp(es, Node).?;
        const result = self.curr;
        self.curr = node.next_sib;
        return result;
    }
};
