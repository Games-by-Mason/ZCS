//! A component that tracks the position and orientation of an entity in 2D. Hierarchical
//! relationships formed by the `Node` component are respected if present.
//!
//! See `syncAllImmediate` and `Exec` for integration into your game.
//!
//! You're encouraged to access the state via the provided getters instead of reading/writing the
//! fields directly.
//!
//! If you need features not provided by this implementation, for example a third dimension, you're
//! encouraged to use this as a reference for your own transform component.

const std = @import("std");
const zcs = @import("../root.zig");

const math = std.math;
const assert = std.debug.assert;
const typeId = zcs.typeId;

const Entity = zcs.Entity;
const Entities = zcs.Entities;
const CmdBuf = zcs.CmdBuf;
const Node = zcs.ext.Node;
const Vec2 = zcs.ext.geom.Vec2;
const Rotor2 = zcs.ext.geom.Rotor2;
const Mat2x3 = zcs.ext.geom.Mat2x3;

const Transform2D = @This();

cached_local_pos: Vec2,
cached_local_orientation: Rotor2,
cached_world_from_model: Mat2x3,
cache: enum { clean, dirty, pending },

pub const InitLocalOptions = struct {
    pos: Vec2 = .zero,
    orientation: Rotor2 = .identity,
};

/// Initialize a transform with the given local position and orientation.
pub fn initLocal(options: InitLocalOptions) @This() {
    return .{
        .cached_local_pos = options.pos,
        .cached_local_orientation = options.orientation,
        .cached_world_from_model = undefined,
        .cache = .dirty,
    };
}

/// Move the transform in local space by `delta`.
pub fn move(self: *@This(), es: *const Entities, cb: *CmdBuf, delta: Vec2) void {
    self.cached_local_pos.add(delta);
    self.markDirty(es, cb);
}

/// Set the local position to `pos`.
pub fn setLocalPos(self: *@This(), es: *const Entities, cb: *CmdBuf, pos: Vec2) void {
    self.cached_local_pos = pos;
    self.markDirty(es, cb);
}

/// Returns the local position.
pub inline fn getLocalPos(self: @This()) Vec2 {
    return self.cached_local_pos;
}

/// Returns the world space position calculated during the last call to `syncAllImmediate`.
pub inline fn getPos(self: @This()) Vec2 {
    return self.cached_world_from_model.getTranslation();
}

/// Rotates the local space.
pub fn rotate(self: *@This(), es: *const Entities, cb: *CmdBuf, rotation: Rotor2) void {
    self.cached_local_orientation.mul(rotation);
    self.markDirty(es, cb);
}

/// Sets the local orientation.
pub fn setLocalOrientation(
    self: *@This(),
    es: *const Entities,
    cb: *CmdBuf,
    orientation: Rotor2,
) void {
    self.cached_local_orientation = orientation;
    self.markDirty(es, cb);
}

/// Returns the local orientation in radians.
pub inline fn getLocalOrientation(self: @This()) Rotor2 {
    return self.cached_local_orientation;
}

/// Returns the world from model matrix.
pub inline fn getWorldFromModel(self: @This()) Mat2x3 {
    return self.cached_world_from_model;
}

/// Returns the parent's world form model matrix.
pub inline fn getParentWorldFromModel(self: *const @This(), es: *const Entities) Mat2x3 {
    const entity: Entity = .from(es, self);
    const node = entity.get(es, Node) orelse return .identity;
    const parent = node.parent.unwrap() orelse return .identity;
    const parent_transform = parent.get(es, Transform2D) orelse return .identity;
    return parent_transform.getWorldFromModel();
}

/// Returns the forward direction of this transform.
pub fn getForward(self: @This()) Vec2 {
    return self.cached_world_from_model.timesDir(.y_pos);
}

/// Returns an iterator over the roots of the dirty subtrees.
pub fn dirtySubtreeIterator(es: *const Entities) DirtySubtreeIterator {
    return .{
        .events = es.viewIterator(DirtySubtreeIterator.EventView),
    };
}

/// An iterator over the roots of the dirty subtrees.
pub const DirtySubtreeIterator = struct {
    const EventView = struct { dirty: *const Dirty };

    events: Entities.ViewIterator(EventView),

    total: usize = 0,
    updated: usize = 0,

    /// Returns the next transform.
    pub fn next(self: *@This(), es: *const Entities) ?DirtySubtree {
        while (self.events.next()) |event| {
            if (event.dirty.entity.view(es, struct {
                transform: *Transform2D,
                node: ?*const Node,
            })) |vw| {
                self.total += 1;

                // If we've already processed this transform, skip it
                if (vw.transform.cache == .clean) continue;

                // Get the event entity's node
                const event_node = vw.node orelse {
                    // The event's entity has no node, mark it as pending and return it as its own
                    // subtree
                    assert(vw.transform.cache != .pending); // Impossible with no node
                    vw.transform.cache = .pending;
                    return .{
                        .transform = vw.transform,
                        .node = null,
                    };
                };

                // Move to the topmost dirty node in this transform subtree so that we don't
                // process the same transforms multiple times
                var subtree = .{
                    .node = event_node,
                    .transform = vw.transform,
                };
                var ancestors = event_node.ancestorIterator();
                while (ancestors.next(es)) |curr| {
                    // Get the transform, or early out if there is none since we don't propagate
                    // through non transform nodes
                    const transform = curr.get(es, Transform2D) orelse break;

                    // Check the cache state
                    switch (transform.cache) {
                        // If the transform is dirty, set it as the new root
                        .dirty => subtree = .{
                            .transform = transform,
                            .node = curr,
                        },
                        // If it's clean ignore it
                        .clean => {},
                        // If it's pending, this subtree has already been queued up for processing
                        // so we should skip it. This is relevant when queuing up of subtrees is
                        // separated from processing them, e.g. when multithreading.
                        .pending => continue,
                    }
                }

                // Mark the subtree root as pending and return it
                assert(subtree.transform.cache == .dirty);
                subtree.transform.cache = .pending;
                return .{
                    .transform = subtree.transform,
                    .node = subtree.node,
                };
            }
        }

        assert(self.total == self.updated);
        return null;
    }
};

/// A dirty transform subtree.
pub const DirtySubtree = struct {
    transform: *Transform2D,
    node: ?*const Node,

    /// Returns a post order iterator over the subtree. This will visit parents before children.
    pub fn preOrderIterator(self: @This(), es: *const Entities) Iterator {
        return .{
            .parent = self.transform,
            .children = if (self.node) |node| node.preOrderIterator(es) else .empty,
        };
    }

    /// A post order iterator over the dirty subtree. Skips subtrees of this subtree whose roots do
    /// not have transforms.
    pub const Iterator = struct {
        parent: ?*Transform2D,
        children: Node.PreOrderIterator,

        /// Returns the next transform.
        pub fn next(self: *@This(), es: *const Entities) ?*Transform2D {
            if (self.parent) |parent| {
                self.parent = null;
                return parent;
            }

            while (self.children.next(es)) |node| {
                if (node.get(es, Transform2D)) |transform| {
                    return transform;
                } else {
                    self.children.skipSubtree(es, node);
                }
            }

            return null;
        }
    };
};

/// Immediately synchronize the world space position and orientation of all dirty entities and their
/// children. Recycles all dirty events.
pub fn syncAllImmediate(es: *Entities) void {
    var subtrees = dirtySubtreeIterator(es);
    while (subtrees.next(es)) |subtree| {
        var transforms = subtree.preOrderIterator(es);
        while (transforms.next(es)) |transform| {
            if (transform.cache != .clean) subtrees.updated += 1;
            transform.syncImmediate(es);
        }
    }

    // Recycle all dirty events
    Dirty.recycleAllImmediate(es);
}

/// Immediately synchronize this entity using the given `world_from_model` matrix.
inline fn syncImmediate(self: *@This(), es: *const Entities) void {
    const world_from_model = self.getParentWorldFromModel(es);
    const translation: Mat2x3 = .translation(self.cached_local_pos);
    const rotation: Mat2x3 = .rotation(self.cached_local_orientation);
    self.cached_world_from_model = rotation.applied(translation).applied(world_from_model);
    self.cache = .clean;
}

/// `Exec` provides helpers for processing hierarchy changes via the command buffer.
///
/// By convention, `Exec` only calls into the stable public interface of the types it's working
/// with. As such, documentation is sparse. You are welcome to call these methods directly, or
/// use them as reference for implementing your own command buffer iterator.
pub const Exec = struct {
    /// Call this after executing a command.
    pub fn afterCmdImmediate(es: *Entities, batch: CmdBuf.Batch, cmd: CmdBuf.Batch.Item) void {
        switch (cmd) {
            .ext => |ext| if (ext.id == typeId(Node.SetParent)) {
                if (batch.entity.get(es, Transform2D)) |transform| {
                    transform.markDirtyImmediate(es);
                }
            },
            .add => |comp| if (comp.id == typeId(Transform2D)) {
                if (batch.entity.get(es, Transform2D)) |transform| {
                    transform.cache = .clean;
                    transform.markDirtyImmediate(es);
                }
            },
            .remove => |id| {
                if (id == typeId(Node)) {
                    if (batch.entity.get(es, Transform2D)) |transform| {
                        transform.markDirtyImmediate(es);
                    }
                } else if (id == typeId(Transform2D)) {
                    if (batch.entity.get(es, Node)) |node| {
                        var children = node.childIterator();
                        while (children.next(es)) |child| {
                            if (child.get(es, Transform2D)) |child_transform| {
                                child_transform.markDirtyImmediate(es);
                            }
                        }
                    }
                }
            },
            else => {},
        }
    }
};

/// Emits an event marking the transform as dirty if it is not already marked as dirty. Called
/// automatically when the position or orientation are changed via the setters, or the node's parent
/// is changed.
///
//// Must be called manually if modifying the transform fields directly.
pub fn markDirty(self: *@This(), es: *const Entities, cb: *CmdBuf) void {
    assert(self.cache != .pending);
    if (self.cache == .dirty) return;

    self.cache = .dirty;
    const e: Entity = .reserve(cb);
    e.add(cb, Dirty, .{ .entity = .from(es, self) });
}

/// Similar to `markDirty`, but immediately emits the event instead of adding it to a command
/// buffer.
pub fn markDirtyImmediate(self: *@This(), es: *Entities) void {
    assert(self.cache != .pending);
    if (self.cache == .dirty) return;

    self.cache = .dirty;
    const e: Entity = .reserveImmediate(es);
    const dirty: Dirty = .{ .entity = .from(es, self) };
    assert(e.changeArchImmediate(es, .{ .add = &.{.init(Dirty, &dirty)} }));
}

/// The dirty event is emitted for transforms that have been moved or re-parented.
pub const Dirty = struct {
    /// The dirty entity.
    entity: Entity,

    /// Recycles all dirty events, allowing their entities to be reused.
    pub inline fn recycleAllImmediate(es: *Entities) void {
        es.recycleArchImmediate(.initOne(.registerImmediate(typeId(Dirty))));
    }
};
