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
const types = zcs.types;
const compId = zcs.compId;
const Entities = zcs.Entities;
const Entity = zcs.Entity;
const CmdBuf = zcs.CmdBuf;

const Node = @This();

parent: Entity.Optional = .none,
first_child: Entity.Optional = .none,
prev_sib: Entity.Optional = .none,
next_sib: Entity.Optional = .none,

/// A view of an entity containing a node.
pub const View = struct {
    entity: Entity,
    node: *Node,

    pub const initOrAddNodeImmediate = Mixins(@This()).initOrAddNodeImmediate;
    pub const initOrAddNodeImmediateOrErr = Mixins(@This()).initOrAddNodeImmediateOrErr;
    pub const getParent = Mixins(@This()).getParent;
    pub const getFirstChild = Mixins(@This()).getFirstChild;
    pub const getPrevSib = Mixins(@This()).getPrevSib;
    pub const getNextSib = Mixins(@This()).getNextSib;

    /// View mixins for working with custom views that contain nodes.
    pub fn Mixins(Self: type) type {
        return struct {
            pub fn initOrAddNodeImmediate(e: Entity, es: *Entities) ?Self {
                return @This().initOrAddNodeImmediateOrErr(e, es) catch |err|
                    @panic(@errorName(err));
            }

            pub fn initOrAddNodeImmediateOrErr(e: Entity, es: *Entities) error{ZcsCompOverflow}!?Self {
                return e.viewOrAddCompsImmediateOrErr(es, Self, .{ .node = &Node{} });
            }

            pub fn getParent(self: Self, es: *const Entities) ?Self {
                const node = view.asOptional(self.node) orelse return null;
                const parent = node.parent.unwrap() orelse return null;
                return parent.view(es, Self).?;
            }

            pub fn getFirstChild(self: Self, es: *const Entities) ?Self {
                const node = view.asOptional(self.node) orelse return null;
                const first_child = node.first_child.unwrap() orelse return null;
                return first_child.view(es, Self).?;
            }

            pub fn getPrevSib(self: Self, es: *const Entities) ?Self {
                const node = view.asOptional(self.node) orelse return null;
                const prev_sib = node.prev_sib.unwrap() orelse return null;
                return prev_sib.view(es, Self).?;
            }

            pub fn getNextSib(self: Self, es: *const Entities) ?Self {
                const node = view.asOptional(self.node) orelse return null;
                const next_sib = node.next_sib.unwrap() orelse return null;
                return next_sib.view(es, Self).?;
            }
        };
    }
};

/// Parents `child` and `parent` immediately. Returns true if the child exists after this operation,
/// false otherwise.
///
/// * If the relationship would result in a cycle, `parent` is first moved up the tree to the level
///   of `child`
/// * If parent is `.none`, child is unparented
/// * If parent and child are equal, no change is made
/// * If parent no longer exists, child is destroyed
/// * If child no longer exists, no change is made
pub fn setParentImmediate(es: *Entities, child: Entity, parent: Entity.Optional) bool {
    return setParentImmediateOrErr(es, child, parent) catch |err|
        @panic(@errorName(err));
}

/// Similar to `setParentImmediate`, but returns `error.ZcsCompOverflow` on error instead of
/// panicking. On error, an empty node may have been added as a component to some entities, but the
/// hierarchy is left unchanged.
pub fn setParentImmediateOrErr(
    es: *Entities,
    child: Entity,
    parent: Entity.Optional,
) error{ZcsCompOverflow}!bool {
    // Early out if the child and parent are the same
    if (child.toOptional() == parent) return child.exists(es);

    // Get the child view or return false if the child doesn't exist
    const child_view: View = try View.initOrAddNodeImmediateOrErr(child, es) orelse return false;

    // Get the parent view, or destroy the child if the parent view doesn't exist
    const parent_view: ?View = if (parent.unwrap()) |unwrapped| b: {
        if (try View.initOrAddNodeImmediateOrErr(unwrapped, es)) |v| {
            break :b v;
        } else {
            assert(destroyImmediate(es, child));
            return false;
        }
    } else null;
    setParentImmediateInner(es, child_view, parent_view, true);
    return true;
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
        if (break_cycles and isAncestorOf(es, child.entity, parent.entity)) {
            const op: ?View = if (original_parent.unwrap()) |unwrapped| b: {
                const op = unwrapped.view(es, View).?;
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

/// Destroys an entity and all of its children. Returns true if the entity was destroyed, false if
/// it didn't exist.
pub fn destroyImmediate(es: *Entities, e: Entity) bool {
    if (e.getComp(es, Node)) |node| {
        // Unparent ourselves
        assert(setParentImmediate(es, e, .none));

        // Destroy all our children depth first
        if (node.first_child.unwrap()) |start| {
            var curr = start.view(es, View).?;
            while (true) {
                if (curr.node.first_child.unwrap()) |first_child| {
                    curr = first_child.view(es, View).?;
                } else {
                    const prev = curr;
                    if (curr.node.next_sib.unwrap()) |next_sib| {
                        curr = next_sib.view(es, View).?;
                    } else {
                        curr = curr.node.parent.unwrap().?.view(es, View).?;
                        curr.node.first_child = .none;
                    }
                    assert(prev.entity.destroyImmediate(es));
                }
                if (curr.entity == e) break;
            }
        }
    }

    // Destroy ourselves
    return e.destroyImmediate(es);
}

/// Returns true if `ancestor` is an ancestor of `descendant`, otherwise returns false. Entities
/// cannot be ancestors of themselves.
pub fn isAncestorOf(es: *const Entities, ancestor: Entity, descendant: Entity) bool {
    const dview = descendant.view(es, View) orelse return false;
    var curr = dview.getParent(es) orelse return false;
    while (true) {
        if (curr.entity == ancestor) return true;
        curr = curr.getParent(es) orelse return false;
    }
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

/// Should be run before executing a command buffer command.
pub fn beforeExecute(cmd: CmdBuf.Cmd, es: *Entities) error{ZcsCompOverflow}!void {
    beforeExecuteOrErr(cmd, es) catch |err|
        @panic(@errorName(err));
}

/// Similar to `beforeExecute`, but returns `error.ZcsCompOverflow` on error instead of panicking.
pub fn beforeExecuteOrErr(cmd: CmdBuf.Cmd, es: *Entities) error{ZcsCompOverflow}!void {
    if (cmd.getRemove().contains(types.register(compId(Node)))) {
        destroyImmediate(cmd.getEntity(), es);
    }
}

/// Should be run after executing a command buffer command.
pub fn afterExecute(cmd: CmdBuf.Cmd, es: *Entities) error{ZcsCompOverflow}!void {
    afterExecuteOrErr(cmd, es) catch |err|
        @panic(@errorName(err));
}

/// Similar to `afterExecute`, but returns `error.ZcsCompOverflow` on error instead of panicking.
pub fn afterExecuteOrErr(cmd: CmdBuf.Cmd, es: *Entities) error{ZcsCompOverflow}!void {
    if (cmd.getAdd().contains(types.register(Node))) {
        switch (cmd) {
            .change_arch => |change_arch| {
                // Iterate over the added components, applying any requested transformations.
                var iter = cmd.iterator();
                while (iter.next()) |comp| {
                    if (comp.as(Node)) |cmd_node| {
                        // Adding a node with the parent set is treated as a set parent command. No
                        // other fields are allowed to be set.
                        assert(cmd_node.first_child == .none);
                        assert(cmd_node.prev_sib == .none);
                        assert(cmd_node.next_sib == .none);

                        // Clear the manually set parent, and then apply it properly via set parent.
                        if (change_arch.entity.getComp(Node)) |node| {
                            node.parent = .none;
                        }
                        setParentImmediateOrErr(es, change_arch.entity, cmd_node.parent);
                    }
                }
            },
            .destroy => unreachable,
        }
    }
}

/// Executes a command buffer, applying the node transformations along the way. This is provided as
/// an example, in practice you likely want to copy this code directly into your code base so that
/// other systems can also hook into the command buffer iterator.
pub fn execute(cmds: *const CmdBuf, es: *Entities) void {
    executeOrErr(cmds, es) catch |err|
        @panic(@errorName(err));
}

/// Similar to `execute`, but returns `error.ZcsCompOverflow` on error instead of panicking. On
/// error, the command buffer will be partially executed.
pub fn executeOrErr(cmds: *const CmdBuf, es: *Entities) error{ZcsCompOverflow}!void {
    var iter = cmds.iter();
    while (iter.next()) |cmd| {
        try cmd.execute(es);
    }
}
