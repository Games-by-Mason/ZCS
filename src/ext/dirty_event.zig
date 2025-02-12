//! See `Dirty`.

const std = @import("std");
const assert = std.debug.assert;

const zcs = @import("../root.zig");
const typeId = zcs.typeId;
const Entity = zcs.Entity;
const Entities = zcs.Entities;
const CmdBuf = zcs.CmdBuf;
const CompFlag = zcs.CompFlag;

/// An event that can be used to track when a component is dirty.
///
/// When emitted, it will check if the component's `dirty` flag is already true. If it is, the
/// duplicate event will not be emitted. If it is not, it will set it and emit the event.
///
/// Events are just normal entities with a single component of this type. You likely want to call
/// `recycleAll` at the end of your frame to clear all dirty events. It's up to you to reset the
/// dirty flags on each component, if you'd like them reset.
pub fn DirtyEvent(T: type) type {
    return struct {
        /// The extension command used to mark components as dirty via the command buffer.
        pub const Cmd = struct {};

        /// The entity that owns the dirty component.
        entity: Entity,

        /// Immediately emits a dirty event for the given entity if it has component `T`.
        pub fn emitImmediate(es: *Entities, entity: Entity) void {
            emitImmediateOrErr(es, entity) catch |err|
                @panic(@errorName(err));
        }

        /// Similar to `emitImmediate` but returns `error.ZcsEntityOverflow` or
        /// `error.ZcsCompOverflow` on failure instead of panicking.
        pub fn emitImmediateOrErr(
            es: *Entities,
            entity: Entity,
        ) error{ ZcsEntityOverflow, ZcsCompOverflow }!void {
            // If we don't have `T`, early out
            const comp = entity.getComp(es, T) orelse return;

            // If `T` is already marked as dirty early out, otherwise mark it as dirty
            if (comp.dirty) return;
            comp.dirty = true;

            // Emit the event
            const event = try Entity.reserveImmediateOrErr(es);
            assert(try event.changeArchImmediateOrErr(es, .{
                .add = &.{.init(@This(), &.{ .entity = entity })},
            }));
        }

        /// Queues a dirty event to be emitted when the command buffer is processed.
        pub inline fn emitCmd(cb: *CmdBuf, entity: Entity) void {
            emitCmdOrErr(cb, entity) catch |err|
                @panic(@errorName(err));
        }

        /// Similar to `emitCmd`, but returns `error.ZcsCmdBufOverflow` on error instead of
        /// panicking.
        pub inline fn emitCmdOrErr(cb: *CmdBuf, entity: Entity) error{ZcsCmdBufOverflow}!void {
            try entity.extCmdOrErr(cb, Cmd, .{});
        }

        /// Recycles all events, allowing for reuse of their entities.
        pub fn recycleAll(es: *Entities) void {
            es.recycleArchImmediate(.initOne(CompFlag.registerImmediate(typeId(@This()))));
        }

        /// Processes the extension command for this event. Call this from your command buffer
        /// iterator.
        pub fn processCmdImmediate(
            es: *Entities,
            batch: CmdBuf.Batch,
            cmd: CmdBuf.Batch.Item,
        ) void {
            switch (cmd) {
                .ext => |ext| if (ext.id == typeId(Cmd)) {
                    emitImmediate(es, batch.entity);
                },
                else => {},
            }
        }
    };
}
