const std = @import("std");
const zcs = @import("../root.zig");
const tracy = @import("tracy");

const math = std.math;
const assert = std.debug.assert;
const typeId = zcs.typeId;

const Entity = zcs.Entity;
const Entities = zcs.Entities;
const CmdBuf = zcs.CmdBuf;
const Any = zcs.Any;
const PointerLock = zcs.PointerLock;
const Node = zcs.ext.Node;
const Vec2 = zcs.ext.geom.Vec2;
const Vec3 = zcs.ext.geom.Vec3;
const Rotor2 = zcs.ext.geom.Rotor2;
const Rotor3 = zcs.ext.geom.Rotor3;
const Mat2x3 = zcs.ext.geom.Mat2x3;
const Mat3x4 = zcs.ext.geom.Mat3x4;

const Zone = tracy.Zone;

pub const Options = struct {
    dimensions: enum { @"2", @"3" },
    Order: type,
};

/// A component that tracks the position and orientation of an entity in 2D or 3D. Hierarchical
/// relationships formed by the `Node` component are respected if present.
///
/// You can synchronize a transform's `world_from_model` field, and the `world_from_model` fields of
/// all its relative children by calling `sync`. This is necessary when modifying the transform, or
/// changing the hierarchy by adding or removing a transform.
///
/// To alleviate this burden, a number of setters are provided that call `sync` for you, and command
/// buffer integration is provided for automatically calling sync when transforms are added and
/// removed.
///
/// Order is a relative value that may be used to sort transforms at the same depth, or may be
/// ignored by using a zero sized type (e.g. `u0`).
///
/// For more information on command buffer integration, see `exec`.
///
/// If you need features not provided by this implementation, you're encouraged to use this as a
/// reference for your own transform component.
pub fn Transform(options: Options) type {
    const Vec = switch (options.dimensions) {
        .@"2" => Vec2,
        .@"3" => Vec3,
    };
    const Rotor = switch (options.dimensions) {
        .@"2" => Rotor2,
        .@"3" => Rotor3,
    };
    const Mat = switch (options.dimensions) {
        .@"2" => Mat2x3,
        .@"3" => Mat3x4,
    };
    const Order = options.Order;

    return struct {
        const Self = @This();

        /// The transform's local position.
        pos: Vec = .zero,
        /// The transform's local orientation.
        rot: Rotor = .identity,
        /// The transform's local scale.
        scale: Vec = .splat(1),
        /// The transform's world from model matrix.
        world_from_model: Mat = .identity,
        /// Whether or not this transform's space and order is relative to its parent.
        relative: bool = true,
        /// The transform's sort order. Unused internally, user can interpret as desired.
        order: Order = 0,

        /// It's frequently useful to pair an entity and transform together.
        ///
        /// See `Node.View` for rationale.
        pub const View = struct {
            transform: *Self,
            entity: Entity,
        };

        /// Move the transform in local space by `delta` and then calls `sync`.
        pub fn move(self: *@This(), es: *const Entities, delta: Vec) void {
            self.pos.add(delta);
            self.sync(es);
        }

        /// Set the local position to `pos` and then calls `sync`.
        pub fn setPos(self: *@This(), es: *const Entities, pos: Vec) void {
            self.pos = pos;
            self.sync(es);
        }

        /// Rotates the local space and then calls `sync`.
        pub fn rotate(self: *@This(), es: *const Entities, rotation: Rotor) void {
            self.rot.mul(rotation);
            self.sync(es);
        }

        /// Sets the local orientation to `rot` and then calls `sync`.
        pub fn setRot(self: *@This(), es: *const Entities, rot: Rotor) void {
            self.rot = rot;
            self.sync(es);
        }

        /// Scales the local space by `factor` and then calls `sync`.
        pub fn scaleBy(self: *@This(), es: *const Entities, factor: Vec) void {
            self.scale = self.scale.timesComps(factor);
            self.sync(es);
        }

        /// Sets the local scale to `amount` and then calls `sync`.
        pub fn setScale(self: *@This(), es: *const Entities, amount: Vec) void {
            self.scale = amount;
            self.sync(es);
        }

        /// Returns the world space position.
        pub inline fn getWorldPos(self: @This()) Vec {
            return self.world_from_model.getTranslation();
        }

        /// Updates the `world_from_model` matrix on this transform, and all of its transitive
        /// relative children.
        pub fn sync(self: *@This(), es: *const Entities) void {
            var transforms = self.preOrderIterator(es);
            while (transforms.next(es)) |curr| {
                const translation: Mat = .translation(curr.transform.pos);
                const rotation: Mat = .rotation(curr.transform.rot);
                const scale: Mat = .scale(curr.transform.scale);
                const parent_world_from_model = curr.transform.getRelativeWorldFromModel(es);
                curr.transform.world_from_model = scale
                    .applied(rotation)
                    .applied(translation)
                    .applied(parent_world_from_model);
            }
        }

        /// Returns the parent's world form model matrix, or identity if not relative.
        pub inline fn getRelativeWorldFromModel(self: *const @This(), es: *const Entities) Mat {
            if (!self.relative) return .identity;
            const node = es.getComp(self, Node) orelse return .identity;
            const parent = node.parent.unwrap() orelse return .identity;
            const parent_transform = parent.get(es, Self) orelse return .identity;
            return parent_transform.world_from_model;
        }

        /// Returns the forward direction of this transform.
        pub fn getForward(self: *const @This()) Vec {
            return self.world_from_model.timesDir(.y_pos);
        }

        /// Returns a pre-order iterator over the subtree of relative transforms starting at `self`. This
        /// will visit parents before children, and it will include `self`.
        pub fn preOrderIterator(self: *@This(), es: *const Entities) PreOrderIterator {
            return .{
                .parent = self,
                .children = if (es.getComp(self, Node)) |node| node.preOrderIterator(es) else .empty,
                .pointer_lock = es.pointer_generation.lock(),
            };
        }

        /// A pre-order iterator over relative transforms.
        pub const PreOrderIterator = struct {
            parent: ?*Self,
            children: Node.PreOrderIterator,
            pointer_lock: PointerLock,

            /// Returns the next transform.
            pub fn next(self: *@This(), es: *const Entities) ?View {
                self.pointer_lock.check(es.pointer_generation);

                if (self.parent) |parent| {
                    self.parent = null;
                    return .{
                        .entity = es.getEntity(parent),
                        .transform = parent,
                    };
                }

                while (self.children.next(es)) |child| {
                    // If the next child has a transform and that transform is relative to its parent,
                    // return it.
                    if (child.entity.view(es, View)) |curr| {
                        if (curr.transform.relative) {
                            return curr;
                        }
                    }
                    // Otherwise, skip this subtree.
                    self.children.skipSubtree(es, child.node);
                }

                return null;
            }
        };

        /// `Exec` provides helpers for processing hierarchy changes via the command buffer.
        ///
        /// By convention, `Exec` only calls into the stable public interface of the types it's working
        /// with. As such, documentation is sparse. You are welcome to call these methods directly, or
        /// use them as reference for implementing your own command buffer iterator.
        pub const Exec = struct {
            /// Similar to `Node.Exec.immediate`, but marks transforms as dirty as needed.
            pub fn immediate(es: *Entities, cb: *CmdBuf, tr: *Node.Tree) void {
                immediateOrErr(es, cb, tr) catch |err|
                    @panic(@errorName(err));
            }

            /// Similar to `immediate`, but returns an error on failure instead of panicking. On error the
            /// commands are left partially evaluated.
            pub fn immediateOrErr(
                es: *Entities,
                cb: *CmdBuf,
                tr: *Node.Tree,
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
                                    Node.Exec.beforeArchChangeImmediate(
                                        es,
                                        tr,
                                        arch_change,
                                        delta,
                                        op,
                                    );
                                    delta.updateImmediate(op);
                                }

                                _ = arch_change.execImmediate(es, delta);
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

            /// Call this after executing a command.
            pub inline fn afterArchChangeImmediate(
                es: *Entities,
                tr: *Node.Tree,
                arch_change: CmdBuf.Batch.ArchChange,
                op: CmdBuf.Batch.ArchChange.Op,
            ) void {
                Node.Exec.afterArchChangeImmediate(es, tr, arch_change, op);
                switch (op) {
                    .add => |comp| if (comp.id == typeId(Self)) {
                        if (arch_change.entity.get(es, Self)) |transform| {
                            transform.sync(es);
                        }
                    },
                    .remove => |id| {
                        if (id == typeId(Node)) {
                            if (arch_change.entity.get(es, Self)) |transform| {
                                transform.sync(es);
                            }
                        } else if (id == typeId(Self)) {
                            if (arch_change.entity.get(es, Node)) |node| {
                                var children = node.childIterator();
                                while (children.next(es)) |child| {
                                    if (child.entity.get(es, Self)) |child_transform| {
                                        child_transform.sync(es);
                                    }
                                }
                            }
                        }
                    },
                    else => {},
                }
            }

            /// Call this to process an extension command.
            pub inline fn extImmediateOrErr(
                es: *Entities,
                tr: *Node.Tree,
                payload: Any,
            ) error{ ZcsArchOverflow, ZcsChunkOverflow, ZcsChunkPoolOverflow }!void {
                try Node.Exec.extImmediateOrErr(es, tr, payload);
                if (payload.as(Node.SetParent)) |set_parent| {
                    if (set_parent.child.get(es, Self)) |transform| {
                        transform.sync(es);
                    }
                }
            }
        };
    };
}
