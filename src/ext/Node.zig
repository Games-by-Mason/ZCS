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
const typeId = zcs.typeId;
const TypeId = zcs.TypeId;
const Entities = zcs.Entities;
const Entity = zcs.Entity;
const CmdBuf = zcs.CmdBuf;
const CompFlag = zcs.CompFlag;
const DirtyEvent = zcs.ext.DirtyEvent;

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

/// Similar to `SetParent`, but sets the parent immediately. Returns true if the child exists after
/// this operation, false otherwise.
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
/// it didn't exist. This behavior occurs automatically via `Exec` when an entity with an entity
/// with a node is destroyed.
pub fn destroyImmediate(es: *Entities, e: Entity) bool {
    destroyChildrenAndUnparentImmediate(es, e);
    return e.destroyImmediate(es);
}

/// Destroys an entity's children and then unparents it. This behavior occurs automatically via
/// `Exec` when a node is removed from an entity.
pub fn destroyChildrenAndUnparentImmediate(es: *Entities, e: Entity) void {
    if (e.getComp(es, Node)) |n| {
        var iter = Node.postOrderIterator(es, e);
        while (iter.next(es)) |curr| {
            assert(curr.destroyImmediate(es));
        }
        assert(setParentImmediate(es, e, .none));
        n.first_child = .none;
    }
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

    /// Returns the next child, or `null` if there are none.
    pub fn next(self: *@This(), es: *const Entities) ?Entity {
        const entity = self.curr.unwrap() orelse return null;
        const node = entity.getComp(es, Node).?;
        self.curr = node.next_sib;
        return entity;
    }
};

/// Iterates over the entity's children pre-order. Pre-order traversal visits parents before
/// children.
pub fn preOrderIterator(es: *const Entities, e: Entity) PreOrderIterator {
    return .{
        .start = e,
        .curr = b: {
            var curr = e.view(es, View);
            if (curr) |unwrapped| curr = unwrapped.getFirstChild(es);
            break :b curr;
        },
    };
}

/// A pre-order node iterator over `(start, ...]`.
pub const PreOrderIterator = struct {
    start: Entity,
    curr: ?View,

    /// Returns the next child, or `null` if there are none.
    pub fn next(self: *@This(), es: *const Entities) ?Entity {
        // Save the pre node, or early out
        const pre = self.curr orelse return null;

        if (pre.getFirstChild(es)) |first_child| {
            // Navigate to the first child
            self.curr = first_child;
        } else {
            // Walk up the tree until we have a siblingIf we don't have a sibling, walk up the tree until we do
            while (self.curr.?.node.next_sib.unwrap() == null) {
                // Early out if we're at the end
                if (self.curr.?.node.parent == self.start.toOptional()) {
                    self.curr = null;
                    return pre.entity;
                }
                self.curr = self.curr.?.getParent(es).?;
            }

            // Move to the next sibling
            self.curr = self.curr.?.getNextSib(es).?;
        }

        return pre.entity;
    }
};

/// Iterates over the entity's children post-order. Post-order traversal visits parents after
/// children.
pub fn postOrderIterator(es: *const Entities, e: Entity) PostOrderIterator {
    return .{
        // We start on the leftmost leaf
        .curr = b: {
            var curr = e.view(es, View);
            if (curr != null) {
                while (curr.?.getFirstChild(es)) |first_child| {
                    curr = first_child;
                }
            }
            break :b curr;
        },
        // And we end when we reach the given entity
        .end = e,
    };
}

/// A post-order iterator over `[curr, end)`.
pub const PostOrderIterator = struct {
    curr: ?View,
    end: Entity,

    /// Returns the next child, or `null` if there are none.
    pub fn next(self: *@This(), es: *const Entities) ?Entity {
        if (self.curr == null or self.curr.?.entity == self.end) return null;
        const post = self.curr.?;
        if (self.curr.?.getNextSib(es)) |next_sib| {
            self.curr = next_sib;
            while (self.curr.?.getFirstChild(es)) |fc| self.curr = fc;
        } else {
            self.curr = self.curr.?.getParent(es).?;
        }
        return post.entity;
    }
};

/// Encodes a command that requests to parent `child` and `parent`.
///
/// * If the relationship would result in a cycle, `parent` is first moved up the tree to the level
///   of `child`
/// * If parent is `.none`, child is unparented
/// * If parent and child are equal, no change is made
/// * If parent no longer exists, child is destroyed
/// * If child no longer exists, no change is made
pub const SetParent = struct { Entity.Optional };

/// `Exec` provides helpers for processing hierarchy changes via the command buffer.
///
/// By convention, `Exec` only calls into the stable public interface of the types it's working
/// with. As such, documentation is sparse. You are welcome to call these methods directly, or
/// use them as reference for implementing your own command buffer iterator.
pub fn Exec(
    /// If non null, `DirtyEvent` is emitted for the given component on parent change.
    DirtyComp: ?type,
) type {
    return struct {
        init_node: bool = false,

        /// Provided as reference. Executes a list of command buffers, maintaining the hierarchy and
        /// reacting to related events along the way. In practice, you likely want to call the finer
        /// grained functions provided directly, so that other libraries you use can also hook into
        /// the command buffer iterator.
        pub fn allImmediate(es: *Entities, cbs: []const CmdBuf) void {
            allImmediateOrErr(es, cbs) catch |err|
                @panic(@errorName(err));
        }

        /// Similar to `allImmediate`, but returns `error.ZcsCompOverflow` and
        /// `error.ZcsEntityOverflow` on error instead of panicking. On error the commands are left
        /// partially evaluated.
        pub fn allImmediateOrErr(
            es: *Entities,
            cbs: []const CmdBuf,
        ) error{ ZcsCompOverflow, ZcsEntityOverflow }!void {
            for (cbs) |cb| try immediate(es, cb);
        }

        pub fn immediate(
            es: *Entities,
            cb: CmdBuf,
        ) error{ ZcsCompOverflow, ZcsEntityOverflow }!void {
            var batches = cb.iterator();
            while (batches.next()) |batch| {
                var node_exec: @This() = .{};

                var arch_change = batch.getArchChangeImmediate(es);
                {
                    var iter = batch.iterator();
                    while (iter.next()) |cmd| {
                        node_exec.beforeCmdImmediate(es, batch, &arch_change, cmd);
                    }
                }

                _ = try batch.execImmediateOrErr(es, arch_change);

                {
                    var iter = batch.iterator();
                    while (iter.next()) |cmd| {
                        try node_exec.afterCmdImmediate(es, batch, arch_change, cmd);
                    }
                }
            }
        }

        pub fn beforeCmdImmediate(
            self: *@This(),
            es: *Entities,
            batch: CmdBuf.Batch,
            arch_change: *CmdBuf.Batch.ArchChange,
            cmd: CmdBuf.Batch.Item,
        ) void {
            switch (cmd) {
                .ext => |payload| self.beforeExtImmediate(arch_change, payload),
                .destroy => beforeDestroyImmediate(es, batch),
                .remove_comp => |id| beforeRemoveCompImmediate(es, batch, id),
                .add_comp => {},
            }
        }

        pub fn afterCmdImmediate(
            self: *@This(),
            es: *Entities,
            batch: CmdBuf.Batch,
            arch_change: CmdBuf.Batch.ArchChange,
            cmd: CmdBuf.Batch.Item,
        ) error{ ZcsCompOverflow, ZcsEntityOverflow }!void {
            switch (cmd) {
                .ext => |ev| if (ev.as(SetParent)) |set_parent| {
                    if (self.init_node and !arch_change.from.contains(typeId(Node).comp_flag.?)) {
                        if (batch.entity.getComp(es, Node)) |node| {
                            node.* = .{};
                        }
                        self.init_node = false;
                    }
                    if (try setParentImmediateOrErr(es, batch.entity, set_parent[0])) {
                        if (DirtyComp) |T| {
                            DirtyEvent(T).emitImmediate(es, batch.entity);
                        }
                    }
                },
                .destroy, .add_comp, .remove_comp => {},
            }
        }

        pub fn beforeExtImmediate(
            self: *@This(),
            arch_change: *CmdBuf.Batch.ArchChange,
            ext: zcs.Any,
        ) void {
            if (ext.id != typeId(SetParent)) return;
            if (arch_change.from.contains(.registerImmediate(typeId(Node)))) return;
            arch_change.add.insert(typeId(Node).comp_flag.?);
            self.init_node = true;
        }

        pub fn beforeDestroyImmediate(es: *Entities, cmd: CmdBuf.Batch) void {
            _ = destroyChildrenAndUnparentImmediate(es, cmd.entity);
        }

        /// Preprocessing for remove component commands. Destroys children of removed nodes.
        pub fn beforeRemoveCompImmediate(es: *Entities, batch: CmdBuf.Batch, id: TypeId) void {
            if (id != typeId(Node)) return;
            _ = destroyChildrenAndUnparentImmediate(es, batch.entity);
        }
    };
}
