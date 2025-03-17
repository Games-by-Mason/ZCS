//! For internal use. See `Subcmd`.

const std = @import("std");
const assert = std.debug.assert;

const zcs = @import("root.zig");
const Entity = zcs.Entity;
const Any = zcs.Any;
const TypeId = zcs.TypeId;
const CmdBuf = zcs.CmdBuf;
const Entities = zcs.Entities;

/// For internal use. An unencoded representation of command buffer commands.
pub const Subcmd = union(enum) {
    /// Binds an existing entity.
    bind_entity: Entity,
    /// Destroys the bound entity.
    destroy: void,
    /// Queues a component to be added by value. The type ID is passed as an argument, component
    /// data is passed via any bytes.
    add_val: Any,
    /// Queues a component to be added by pointer. The type ID and a pointer to the component data
    /// are passed as arguments.
    add_ptr: Any,
    /// Queues an extension command to be added by value. The type ID is passed as an argument, the
    /// payload is passed via any bytes.
    ext_val: Any,
    /// Queues an extension command to be added by pointer. The type ID and a pointer to the
    /// component data are passed as arguments.
    ext_ptr: Any,
    /// Queues a component to be removed.
    remove: TypeId,

    /// If a new worst case command is introduced, also update the tests!
    pub const rename_when_changing_encoding = {};

    pub const Tag = @typeInfo(@This()).@"union".tag_type.?;

    /// Decodes encoded commands.
    pub const Decoder = struct {
        cb: *const CmdBuf,
        tag_index: usize = 0,
        arg_index: usize = 0,
        comp_bytes_index: usize = 0,

        pub inline fn next(self: *@This()) ?Subcmd {
            _ = rename_when_changing_encoding;

            // Decode the next command
            if (self.nextTag()) |tag| {
                switch (tag) {
                    .bind_entity => {
                        const entity: Entity = @bitCast(self.nextArg().?);
                        return .{ .bind_entity = entity };
                    },
                    inline .add_val, .ext_val => |add| {
                        const id: TypeId = @ptrFromInt(self.nextArg().?);
                        const ptr = self.nextAny(id);
                        const any: Any = .{
                            .id = id,
                            .ptr = ptr,
                        };
                        return switch (add) {
                            .add_val => .{ .add_val = any },
                            .ext_val => .{ .ext_val = any },
                            else => comptime unreachable,
                        };
                    },
                    inline .add_ptr, .ext_ptr => |add| {
                        const id: TypeId = @ptrFromInt(self.nextArg().?);
                        const ptr: *const anyopaque = @ptrFromInt(self.nextArg().?);
                        const any: Any = .{
                            .id = id,
                            .ptr = ptr,
                        };
                        switch (add) {
                            .add_ptr => return .{ .add_ptr = any },
                            .ext_ptr => return .{ .ext_ptr = any },
                            else => comptime unreachable,
                        }
                    },
                    .remove => {
                        const id: TypeId = @ptrFromInt(self.nextArg().?);
                        return .{ .remove = id };
                    },
                    .destroy => return .destroy,
                }
            }

            // Assert that we're fully empty, and return null
            assert(self.tag_index == self.cb.tags.items.len);
            assert(self.arg_index == self.cb.args.items.len);
            assert(self.comp_bytes_index == self.cb.any_bytes.items.len);
            return null;
        }

        pub inline fn peekTag(self: *@This()) ?Subcmd.Tag {
            if (self.tag_index < self.cb.tags.items.len) {
                return self.cb.tags.items[self.tag_index];
            } else {
                return null;
            }
        }

        pub inline fn nextTag(self: *@This()) ?Subcmd.Tag {
            const tag = self.peekTag() orelse return null;
            self.tag_index += 1;
            return tag;
        }

        pub inline fn nextArg(self: *@This()) ?u64 {
            if (self.arg_index < self.cb.args.items.len) {
                const arg = self.cb.args.items[self.arg_index];
                self.arg_index += 1;
                return arg;
            } else {
                return null;
            }
        }

        pub inline fn nextAny(self: *@This(), id: TypeId) *const anyopaque {
            // Align the read
            self.comp_bytes_index = std.mem.alignForward(
                usize,
                self.comp_bytes_index,
                id.alignment,
            );

            // Get the pointer as a slice, this way we don't fail on zero sized types
            const bytes = &self.cb.any_bytes.items[self.comp_bytes_index..][0..id.size];

            // Update the offset and return the pointer
            self.comp_bytes_index += id.size;
            return bytes.ptr;
        }
    };

    /// Encodes a command.
    pub fn encode(cb: *CmdBuf, subcmd: Subcmd) error{ZcsCmdBufOverflow}!void {
        _ = Subcmd.rename_when_changing_encoding;

        // Decide whether or not to keep the bound entity
        switch (subcmd) {
            // We're in an archetype change, keep it
            .destroy, .bind_entity, .add_val, .add_ptr, .remove => {},
            // We're in an extension command, clear it. Archetype changes must start with a bind so we
            // don't want it to be cached across other commands.
            .ext_ptr, .ext_val => cb.binding = .none,
        }

        switch (subcmd) {
            .bind_entity => |entity| {
                if (cb.binding.entity == entity.toOptional()) return;
                if (cb.tags.items.len >= cb.tags.capacity) return error.ZcsCmdBufOverflow;
                if (cb.args.items.len >= cb.args.capacity) return error.ZcsCmdBufOverflow;
                cb.binding = .{ .entity = entity.toOptional() };
                cb.tags.appendAssumeCapacity(.bind_entity);
                cb.args.appendAssumeCapacity(@bitCast(entity));
            },
            .destroy => {
                if (cb.binding.destroyed) return;
                if (cb.tags.items.len >= cb.tags.capacity) return error.ZcsCmdBufOverflow;
                cb.tags.appendAssumeCapacity(.destroy);
                cb.binding.destroyed = true;
            },
            inline .add_val, .ext_val => |comp| {
                if (cb.binding.destroyed) return;
                const aligned = std.mem.alignForward(
                    usize,
                    cb.any_bytes.items.len,
                    comp.id.alignment,
                );
                if (cb.tags.items.len >= cb.tags.capacity) return error.ZcsCmdBufOverflow;
                if (cb.args.items.len + 1 > cb.args.capacity) return error.ZcsCmdBufOverflow;
                if (aligned + comp.id.size > cb.any_bytes.capacity) {
                    return error.ZcsCmdBufOverflow;
                }

                cb.tags.appendAssumeCapacity(subcmd);
                cb.args.appendAssumeCapacity(@intFromPtr(comp.id));
                cb.any_bytes.items.len = aligned;
                cb.any_bytes.appendSliceAssumeCapacity(comp.constSlice());
            },
            inline .add_ptr, .ext_ptr => |comp| {
                if (cb.binding.destroyed) return;
                if (cb.tags.items.len >= cb.tags.capacity) return error.ZcsCmdBufOverflow;
                if (cb.args.items.len + 2 > cb.args.capacity) return error.ZcsCmdBufOverflow;

                cb.tags.appendAssumeCapacity(subcmd);
                cb.args.appendAssumeCapacity(@intFromPtr(comp.id));
                cb.args.appendAssumeCapacity(@intFromPtr(comp.ptr));
            },
            .remove => |id| {
                if (cb.binding.destroyed) return;
                if (cb.tags.items.len >= cb.tags.capacity) return error.ZcsCmdBufOverflow;
                if (cb.args.items.len >= cb.args.capacity) return error.ZcsCmdBufOverflow;
                cb.tags.appendAssumeCapacity(.remove);
                cb.args.appendAssumeCapacity(@intFromPtr(id));
            },
        }
    }
};
