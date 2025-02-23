//! A component that tracks the position and orientation of an entity in 2D. Hierarchical
//! relationships formed by the `Node` component are respected if present.
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
dirty: bool,

pub const InitOptions = struct {
    local_pos: Vec2 = .zero,
    local_orientation: Rotor2 = .identity,
};

/// Initialize a transform with the given position and orientation.
pub fn init(options: InitOptions) @This() {
    return .{
        .cached_local_pos = options.local_pos,
        .cached_local_orientation = options.local_orientation,
        .cached_world_from_model = undefined,
        .dirty = true,
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
pub inline fn getLocalOrientation(self: @This()) f32 {
    return self.cached_local_orientation;
}

pub inline fn getWorldFromModel(self: @This()) Mat2x3 {
    return self.cached_world_from_model;
}

pub fn getForward(self: @This()) Vec2 {
    return self.cached_world_from_model.timesDir(.y_pos);
}

/// Immediately synchronize the world space position and orientation of all dirty entities and their
/// children. Recycles all dirty events.
pub fn syncAllImmediate(es: *Entities) void {
    var it = es.viewIterator(struct { dirty: *const Dirty });
    var total: usize = 0;
    var updated: usize = 0;
    while (it.next()) |event| {
        if (event.dirty.entity.view(es, struct {
            transform: *Transform2D,
            node: ?*const Node,
        })) |vw| {
            total += 1;
            if (!vw.transform.dirty) continue;
            if (vw.node) |unwrapped| {
                // Move to the topmost dirty node in this tree of the hierarchy so that we don't
                // reprocess nodes multiple times
                const node = b: {
                    var curr = unwrapped;
                    var topmost_dirty = unwrapped;
                    while (curr.getParent(es)) |parent| {
                        const parent_transform = parent.get(es, Transform2D) orelse break;
                        if (parent_transform.dirty) {
                            topmost_dirty = parent;
                        }
                        curr = parent;
                    }
                    break :b topmost_dirty;
                };

                // Update the transform and all its children
                vw.transform.syncImmediate(.identity);
                updated += 1;

                var children = node.preOrderIterator(es);
                while (children.next(es)) |child| {
                    if (child.get(es, Transform2D)) |child_transform| {
                        const parent = child.getParent(es).?;
                        if (child_transform.dirty) updated += 1;
                        if (parent.get(es, Transform2D)) |parent_transform| {
                            child_transform.syncImmediate(parent_transform.cached_world_from_model);
                        } else {
                            child_transform.syncImmediate(.identity);
                        }
                    }
                }
            } else {
                // Transforms with no parents are updated directly
                vw.transform.syncImmediate(.identity);
                updated += 1;
            }
        }
    }
    assert(total == updated);

    // Recycle all dirty events
    Dirty.recycleAllImmediate(es);
}

/// Immediately synchronize this entity using the given `world_from_local` matrix.
inline fn syncImmediate(self: *@This(), world_from_local: Mat2x3) void {
    const translation: Mat2x3 = .translation(self.cached_local_pos);
    const rotation: Mat2x3 = .rotation(self.cached_local_orientation);
    self.cached_world_from_model = rotation.applied(translation).applied(world_from_local);
    self.dirty = false;
}

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
                transform.dirty = false;
                transform.markDirtyImmediate(es);
            }
        },
        .remove => |id| if (id == typeId(Node)) {
            if (batch.entity.get(es, Transform2D)) |transform| {
                transform.markDirtyImmediate(es);
            }
        },
        else => {},
    }
}

/// Emits an event marking the transform as dirty if it is not already marked as dirty. Called
/// automatically when the position or orientation are changed via the setters, or the node's parent
/// is changed.
///
//// Must be called manually if modifying the transform fields directly.
pub fn markDirty(self: *@This(), es: *const Entities, cb: *CmdBuf) void {
    if (!self.dirty) {
        self.dirty = true;
        const e: Entity = .reserve(cb);
        e.add(cb, Dirty, .{ .entity = .from(es, self) });
    }
}

/// Similar to `markDirty`, but immediately emits the event instead of adding it to a command
/// buffer.
pub fn markDirtyImmediate(self: *@This(), es: *Entities) void {
    if (!self.dirty) {
        self.dirty = true;
        const e: Entity = .reserveImmediate(es);
        const dirty: Dirty = .{ .entity = .from(es, self) };
        assert(e.changeArchImmediate(es, .{ .add = &.{.init(Dirty, &dirty)} }));
    }
}

/// The dirty event is emitted for transforms that have been moved or re-parented.
pub const Dirty = struct {
    /// The dirty entity.
    entity: Entity,

    /// Recycles all dirty events, allowing their entities to be reused.
    pub fn recycleAllImmediate(es: *Entities) void {
        es.recycleArchImmediate(.initOne(.registerImmediate(typeId(Dirty))));
    }
};
