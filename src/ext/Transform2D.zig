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
const Any = zcs.Any;
const Node = zcs.ext.Node;
const Vec2 = zcs.ext.geom.Vec2;
const Rotor2 = zcs.ext.geom.Rotor2;
const Mat2x3 = zcs.ext.geom.Mat2x3;

const Transform2D = @This();

/// For internal use. The cached local position.
cached_local_pos: Vec2,
/// For internal use. The cached local orientation.
cached_local_orientation: Rotor2,
/// For internal use. The cached world from model matrix.
cached_world_from_model: Mat2x3,
/// Whether or not this transform's space is relative to its parent.
relative: bool,
/// For internal use. The cache status.
cache: enum {
    /// This transform's cache is clean.
    clean,
    /// This transform's cache is dirty.
    dirty,
    /// This transform's cache is dirty, and has been visited by the dirty subtree iterator.
    dirty_visited,
},

/// Options for `initLocal`.
pub const InitLocalOptions = struct {
    /// The initial position in local space.
    pos: Vec2 = .zero,
    /// The initial orientation in local space.
    orientation: Rotor2 = .identity,
    /// Whether or not this transform's space is relative to its parent.
    relative: bool = true,
};

/// Initialize a transform with the given local position and orientation.
pub fn initLocal(options: InitLocalOptions) @This() {
    return .{
        .cached_local_pos = options.pos,
        .cached_local_orientation = options.orientation,
        .cached_world_from_model = undefined,
        .relative = options.relative,
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

/// Returns the parent's world form model matrix, or identity if not relative.
pub inline fn getRelativeWorldFromModel(self: *const @This(), es: *const Entities) Mat2x3 {
    if (!self.relative) return .identity;
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

/// Returns an iterator over the roots of the dirty subtrees. This will flip the root cache of each
/// subtree from `.dirty` to `.dirty_subtreee` to prevent the results from overlapping, this means
/// that you can use this method to synchronize subtrees on separate threads if desired.
pub fn dirtySubtreeIterator(es: *const Entities) DirtySubtreeIterator {
    return .{
        .events = es.viewIterator(DirtySubtreeIterator.EventView),
    };
}

/// An iterator over the roots of the dirty subtrees.
pub const DirtySubtreeIterator = struct {
    const EventView = struct { dirty: *const Dirty };
    events: Entities.ViewIterator(EventView),

    /// Returns the next transform.
    pub fn next(self: *@This(), es: *const Entities) ?Subtree {
        // Iterate over the dirty events
        ev: while (self.events.next()) |event| {
            if (event.dirty.entity.view(es, struct {
                transform: *Transform2D,
                node: ?*const Node,
            })) |vw| {
                // If we've already visited this transform skip it. The list of dirty events is not
                // supposed to have duplicates, but since we always traverse up to the root of the
                // dirty subtree we may have already encountered this transform.
                if (vw.transform.cache == .dirty_visited) continue :ev;

                // Create a subtree at this node and mark it as visited
                var root: Subtree = .{
                    .node = vw.node,
                    .transform = vw.transform,
                };
                assert(vw.transform.cache == .dirty);
                vw.transform.cache = .dirty_visited;

                // Move to the topmost dirty node in this transform subtree so that we don't process
                // the same transforms multiple times
                if (root.node) |event_node| {
                    if (vw.transform.relative) {
                        var ancestors = event_node.ancestorIterator();
                        while (ancestors.next(es)) |curr| {
                            // Get the transform, or early out if there is none since we don't
                            // propagate through non transform nodes
                            const transform = curr.get(es, Transform2D) orelse break;

                            // Check the cache state
                            switch (transform.cache) {
                                // If the transform is dirty, set it as the new root
                                .dirty => {
                                    root = .{
                                        .transform = transform,
                                        .node = curr,
                                    };
                                    root.transform.cache = .dirty_visited;
                                },
                                // If it's clean ignore it
                                .clean => {},
                                // We've already visited this subtree, move onto the next event
                                .dirty_visited => continue :ev,
                            }

                            // If this transform isn't relative to its parent, stop searching
                            // parents
                            if (!transform.relative) break;
                        }
                    }
                }

                // Return the root of the dirty subtree
                return root;
            }
        }

        return null;
    }
};

/// A transform subtree, only follows relative transforms. See `DirtySubtreeIterator`.
pub const Subtree = struct {
    transform: *Transform2D,
    node: ?*const Node,

    /// Returns a post order iterator over the subtree. This will visit parents before children.
    pub fn preOrderIterator(self: @This(), es: *const Entities) Iterator {
        return .{
            .parent = self.transform,
            .children = if (self.node) |node| node.preOrderIterator(es) else .empty,
        };
    }

    /// A post order iterator over the subtree. Skips subtrees of this subtree whose roots do
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
                // If the next child has a transform and that transform is relative to its parent,
                // return it.
                if (node.get(es, Transform2D)) |transform| {
                    if (transform.relative) {
                        return transform;
                    }
                }
                // Otherwise, skip this subtree.
                self.children.skipSubtree(es, node);
            }

            return null;
        }
    };
};

/// Immediately synchronize the world space position and orientation of all dirty entities and their
/// children. Recycles all dirty events. For multithreaded sync, see `syncAllThreadPool`.
pub fn syncAllImmediate(es: *Entities) void {
    // Iterate over the subtrees
    var subtrees = dirtySubtreeIterator(es);
    while (subtrees.next(es)) |subtree| {
        // Synchronize the subtree
        var transforms = subtree.preOrderIterator(es);
        while (transforms.next(es)) |transform| {
            transform.syncImmediate(transform.getRelativeWorldFromModel(es));
        }
    }

    // Check assertions and clean up
    finishSyncAllImmediate(es);
}

/// Options for `syncAllThreadPool`.
pub const SyncAllThreadPoolOptions = struct {
    /// The max number of subtrees per chunk.
    chunk_size: usize,
};

/// Spawns tasks to sync the dirty transforms in parallel on the given thread pool. Call
/// `finishSyncAllImmediate` after waiting on the wait group.
///
/// May be used as a reference for implementing your own multithreaded sync if you're
/// not using the standard library thread pool.
pub fn syncAllThreadPool(
    es: *Entities,
    tp: *std.Thread.Pool,
    wg: *std.Thread.WaitGroup,
    comptime options: SyncAllThreadPoolOptions,
) void {
    // Divide the dirty subtrees into chunks, and spawn a task for each chunk
    var chunk: std.BoundedArray(Subtree, options.chunk_size) = .{};
    var subtrees = dirtySubtreeIterator(es);
    var done = false;
    while (!done) {
        // Fill the chunk
        for (0..options.chunk_size) |_| {
            chunk.appendAssumeCapacity(subtrees.next(es) orelse {
                done = true;
                break;
            });
        }

        // Spawn a task to sync a copy of the chunk, then clear the chunk for the next iteration
        tp.spawnWg(wg, syncChunkImmediate, .{ es, chunk });
        chunk.clear();
    }
}

/// Immediately sync a chunk, used by `syncAllThreadPool`.
fn syncChunkImmediate(es: *Entities, subtrees: anytype) void {
    for (subtrees.constSlice()) |subtree| {
        var transforms = subtree.preOrderIterator(es);
        while (transforms.next(es)) |transform| {
            transform.syncImmediate(transform.getRelativeWorldFromModel(es));
        }
    }
}

/// If implementing a custom sync, call this after it completes to clean up dirty events and check
/// that all dirty entities were synced.
pub fn finishSyncAllImmediate(es: *Entities) void {
    var it = es.viewIterator(DirtySubtreeIterator.EventView);
    while (it.next()) |vw| {
        if (vw.dirty.entity.get(es, Transform2D)) |transform| {
            transform.cache = .clean;
        }
    }

    // Recycle all dirty events
    Dirty.recycleAllImmediate(es);
}

/// Immediately synchronize this entity using the given `world_from_model` matrix.
pub fn syncImmediate(self: *@This(), parent_world_from_model: Mat2x3) void {
    const translation: Mat2x3 = .translation(self.cached_local_pos);
    const rotation: Mat2x3 = .rotation(self.cached_local_orientation);
    self.cached_world_from_model = rotation.applied(translation).applied(parent_world_from_model);
}

/// `Exec` provides helpers for processing hierarchy changes via the command buffer.
///
/// By convention, `Exec` only calls into the stable public interface of the types it's working
/// with. As such, documentation is sparse. You are welcome to call these methods directly, or
/// use them as reference for implementing your own command buffer iterator.
pub const exec = struct {
    /// Similar to `Node.exec.immediate`, but marks transforms as dirty as needed.
    pub fn immediate(es: *Entities, cb: CmdBuf) void {
        immediateOrErr(es, cb) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `immediate`, but returns an error on failure instead of panicking. On error the
    /// commands are left partially evaluated.
    pub fn immediateOrErr(es: *Entities, cb: CmdBuf) error{
        ZcsCompOverflow,
        ZcsEntityOverflow,
        ZcsArchOverflow,
        ZcsChunkOverflow,
        ZcsChunkPoolOverflow,
    }!void {
        var batches = cb.iterator();
        while (batches.next()) |batch| {
            switch (batch) {
                .arch_change => |arch_change| {
                    {
                        var delta: CmdBuf.Batch.ArchChange.Delta = .{};
                        var ops = arch_change.iterator();
                        while (ops.next()) |op| {
                            Node.exec.beforeArchChangeImmediate(es, arch_change, op);
                            delta.updateImmediate(op);
                        }

                        _ = arch_change.execImmediate(es, delta);
                    }

                    {
                        var ops = arch_change.iterator();
                        while (ops.next()) |op| {
                            afterArchChangeImmediate(es, arch_change, op);
                        }
                    }
                },
                .ext => |ext| try extImmediateOrErr(es, ext),
            }
        }
    }

    /// Call this after executing a command.
    pub fn afterArchChangeImmediate(
        es: *Entities,
        batch: CmdBuf.Batch.ArchChange,
        op: CmdBuf.Batch.ArchChange.Op,
    ) void {
        switch (op) {
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

    pub fn extImmediateOrErr(
        es: *Entities,
        payload: Any,
    ) error{ ZcsCompOverflow, ZcsArchOverflow, ZcsChunkOverflow, ZcsChunkPoolOverflow }!void {
        try Node.exec.extImmediateOrErr(es, payload);
        if (payload.as(Node.SetParent)) |set_parent| {
            if (set_parent.child.get(es, Transform2D)) |transform| {
                transform.markDirtyImmediate(es);
            }
        }
    }
};

/// Emits an event marking the transform as dirty if it is not already marked as dirty. Called
/// automatically when the position or orientation are changed via the setters, or the node's parent
/// is changed.
///
//// Must be called manually if modifying the transform fields directly.
pub fn markDirty(self: *@This(), es: *const Entities, cb: *CmdBuf) void {
    assert(self.cache != .dirty_visited);
    if (self.cache == .dirty) return;

    self.cache = .dirty;
    const e: Entity = .reserve(cb);
    e.add(cb, Dirty, .{ .entity = .from(es, self) });
}

/// Similar to `markDirty`, but immediately emits the event instead of adding it to a command
/// buffer.
pub fn markDirtyImmediate(self: *@This(), es: *Entities) void {
    assert(self.cache != .dirty_visited);
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
