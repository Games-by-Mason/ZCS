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

pub fn getParent(self: *const @This(), es: *const Entities) ?*Node {
    const parent = self.parent.unwrap() orelse return null;
    return parent.getComp(es, Node).?;
}

pub fn getFirstChild(self: *const @This(), es: *const Entities) ?*Node {
    const first_child = self.first_child.unwrap() orelse return null;
    return first_child.getComp(es, Node).?;
}

pub fn getPrevSib(self: *const @This(), es: *const Entities) ?*Node {
    const prev_sib = self.prev_sib.unwrap() orelse return null;
    return prev_sib.getComp(es, Node).?;
}

pub fn getNextSib(self: *const @This(), es: *const Entities) ?*Node {
    const next_sib = self.next_sib.unwrap() orelse return null;
    return next_sib.getComp(es, Node).?;
}

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

/// Similar to `SetParent`, but sets the parent immediately.
pub fn setParentImmediate(self: *Node, es: *Entities, parent: ?*Node) void {
    self.setParentImmediateOrErr(es, parent) catch |err|
        @panic(@errorName(err));
}

/// Similar to `setParentImmediate`, but returns `error.ZcsCompOverflow` on error instead of
/// panicking. On error, an empty node may have been added as a component to some entities, but the
/// hierarchy is left unchanged.
pub fn setParentImmediateOrErr(
    self: *Node,
    es: *Entities,
    parent: ?*Node,
) error{ZcsCompOverflow}!void {
    if (self == parent) return;
    setParentImmediateInner(
        es,
        .{ .node = self, .entity = .fromComp(es, self) },
        if (parent) |p| .{ .node = p, .entity = .fromComp(es, p) } else null,
        true,
    );
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
        if (break_cycles and child.node.isAncestorOf(es, parent.node)) {
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
pub fn destroyImmediate(self: *@This(), es: *Entities) bool {
    self.destroyChildrenAndUnparentImmediate(es);
    return Entity.fromComp(es, self).destroyImmediate(es);
}

/// Destroys an entity's children and then unparents it. This behavior occurs automatically via
/// `Exec` when a node is removed from an entity.
pub fn destroyChildrenAndUnparentImmediate(self: *@This(), es: *Entities) void {
    var iter = self.postOrderIterator(es);
    while (iter.next(es)) |curr| {
        assert(Entity.fromComp(es, curr).destroyImmediate(es));
    }
    self.setParentImmediate(es, null);
    self.first_child = .none;
}

/// Returns true if `ancestor` is an ancestor of `descendant`, otherwise returns false. Entities
/// cannot be ancestors of themselves.
pub fn isAncestorOf(self: *const @This(), es: *const Entities, descendant: *const Node) bool {
    var curr = descendant.getParent(es) orelse return false;
    while (true) {
        if (curr == self) return true;
        curr = curr.getParent(es) orelse return false;
    }
}

/// Returns an iterator over the given entity's immediate children.
pub fn childIterator(self: *const @This()) ChildIterator {
    return .{ .curr = self.first_child };
}

/// An iterator over an entity's immediate children.
const ChildIterator = struct {
    curr: Entity.Optional,

    /// Returns the next child, or `null` if there are none.
    pub fn next(self: *@This(), es: *const Entities) ?*Node {
        const entity = self.curr.unwrap() orelse return null;
        const node = entity.getComp(es, Node).?;
        self.curr = node.next_sib;
        return node;
    }
};

/// Iterates over the entity's children pre-order. Pre-order traversal visits parents before
/// children.
pub fn preOrderIterator(self: *const @This(), es: *const Entities) PreOrderIterator {
    return .{
        .start = self,
        .curr = self.getFirstChild(es),
    };
}

/// A pre-order node iterator over `(start, ...]`.
pub const PreOrderIterator = struct {
    start: *const Node,
    curr: ?*Node,

    /// Returns the next child, or `null` if there are none.
    pub fn next(self: *@This(), es: *const Entities) ?*Node {
        const pre = self.curr orelse return null;
        if (pre.getFirstChild(es)) |first_child| {
            self.curr = first_child;
        } else {
            var has_next_sib = pre;
            while (has_next_sib.next_sib.unwrap() == null) {
                if (has_next_sib.parent == Entity.fromComp(es, self.start).toOptional()) {
                    self.curr = null;
                    return pre;
                }
                has_next_sib = has_next_sib.getParent(es).?;
            }
            self.curr = has_next_sib.getNextSib(es).?;
        }
        return pre;
    }
};

/// Iterates over the entity's children post-order. Post-order traversal visits parents after
/// children.
pub fn postOrderIterator(self: *const @This(), es: *const Entities) PostOrderIterator {
    return .{
        // We start on the leftmost leaf
        .curr = b: {
            var curr = self.getFirstChild(es) orelse break :b null;
            while (curr.getFirstChild(es)) |first_child| curr = first_child;
            break :b curr;
        },
        // And we end when we reach the given entity
        .end = self,
    };
}

/// A post-order iterator over `[curr, end)`.
pub const PostOrderIterator = struct {
    curr: ?*Node,
    end: *const Node,

    /// Returns the next child, or `null` if there are none.
    pub fn next(self: *@This(), es: *const Entities) ?*Node {
        if (self.curr == null or self.curr == self.end) return null;
        const post = self.curr.?;
        if (self.curr.?.getNextSib(es)) |next_sib| {
            self.curr = next_sib;
            while (self.curr.?.getFirstChild(es)) |fc| self.curr = fc;
        } else {
            self.curr = self.curr.?.getParent(es).?;
        }
        return post;
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
                    if (batch.entity.getComp(es, Node)) |node| {
                        if (set_parent[0].unwrap()) |parent| {
                            if (try parent.viewOrAddCompsImmediateOrErr(
                                es,
                                struct { node: *Node },
                                .{ .node = &Node{} },
                            )) |parent_view| {
                                try node.setParentImmediateOrErr(es, parent_view.node);
                                if (DirtyComp) |T| {
                                    DirtyEvent(T).emitImmediate(es, batch.entity);
                                }
                            } else {
                                assert(node.destroyImmediate(es));
                            }
                        } else {
                            try node.setParentImmediateOrErr(es, null);
                            if (DirtyComp) |T| {
                                DirtyEvent(T).emitImmediate(es, batch.entity);
                            }
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

        pub fn beforeDestroyImmediate(es: *Entities, batch: CmdBuf.Batch) void {
            if (batch.entity.getComp(es, Node)) |node| {
                _ = node.destroyChildrenAndUnparentImmediate(es);
            }
        }

        /// Preprocessing for remove component commands. Destroys children of removed nodes.
        pub fn beforeRemoveCompImmediate(es: *Entities, batch: CmdBuf.Batch, id: TypeId) void {
            if (id != typeId(Node)) return;
            if (batch.entity.getComp(es, Node)) |node| {
                _ = node.destroyChildrenAndUnparentImmediate(es);
            }
        }
    };
}
