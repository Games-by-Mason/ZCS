//! For internal use. See `Cmd`.

const std = @import("std");
const assert = std.debug.assert;

const zcs = @import("root.zig");
const Entity = zcs.Entity;
const Any = zcs.Any;
const TypeId = zcs.TypeId;
const CmdBuf = zcs.CmdBuf;
const Entities = zcs.Entities;

/// For internal use. An unencoded representation of command buffer commands.
pub const Cmd = union(enum) {
    /// Binds an existing entity.
    bind_entity: Entity,
    /// Destroys the bound entity.
    destroy: void,
    /// Queues a component to be added by value. The type ID is passed as an argument, component
    /// data is passed via any bytes.
    add_comp_val: Any,
    /// Queues a component to be added by pointer. The type ID and a pointer to the component data are
    /// passed as arguments.
    add_comp_ptr: Any,
    /// Queues an event to be added by value. The type ID is passed as an argument, the payload is
    /// passed via any bytes.
    event_val: Any,
    /// Queues an event to be added by pointer. The type ID and a pointer to the component data are
    /// passed as arguments.
    event_ptr: Any,
    /// Queues a component to be removed.
    remove_comp: TypeId,

    /// If a new worst case command is introduced, also update the tests!
    pub const rename_when_changing_encoding = {};

    pub const Tag = @typeInfo(@This()).@"union".tag_type.?;

    /// Decodes encoded commands.
    pub const Decoder = struct {
        cmds: *const CmdBuf,
        tag_index: usize = 0,
        arg_index: usize = 0,
        comp_bytes_index: usize = 0,

        pub inline fn next(self: *@This()) ?Cmd {
            _ = rename_when_changing_encoding;

            // Decode the next command
            if (self.nextTag()) |tag| {
                switch (tag) {
                    .bind_entity => {
                        const entity: Entity = @bitCast(self.nextArg().?);
                        return .{ .bind_entity = entity };
                    },
                    inline .add_comp_val, .event_val => |add| {
                        const id: TypeId = @ptrFromInt(self.nextArg().?);
                        const ptr = self.nextAny(id);
                        const any: Any = .{
                            .id = id,
                            .ptr = ptr,
                        };
                        return switch (add) {
                            .add_comp_val => .{ .add_comp_val = any },
                            .event_val => .{ .event_val = any },
                            else => comptime unreachable,
                        };
                    },
                    inline .add_comp_ptr, .event_ptr => |add| {
                        const id: TypeId = @ptrFromInt(self.nextArg().?);
                        const ptr: *const anyopaque = @ptrFromInt(self.nextArg().?);
                        const any: Any = .{
                            .id = id,
                            .ptr = ptr,
                        };
                        switch (add) {
                            .add_comp_ptr => return .{ .add_comp_ptr = any },
                            .event_ptr => return .{ .event_ptr = any },
                            else => comptime unreachable,
                        }
                    },
                    .remove_comp => {
                        const id: TypeId = @ptrFromInt(self.nextArg().?);
                        return .{ .remove_comp = id };
                    },
                    .destroy => return .destroy,
                }
            }

            // Assert that we're fully empty, and return null
            assert(self.tag_index == self.cmds.tags.items.len);
            assert(self.arg_index == self.cmds.args.items.len);
            assert(self.comp_bytes_index == self.cmds.any_bytes.items.len);
            return null;
        }

        pub inline fn peekTag(self: *@This()) ?Cmd.Tag {
            if (self.tag_index < self.cmds.tags.items.len) {
                return self.cmds.tags.items[self.tag_index];
            } else {
                return null;
            }
        }

        pub inline fn nextTag(self: *@This()) ?Cmd.Tag {
            const tag = self.peekTag() orelse return null;
            self.tag_index += 1;
            return tag;
        }

        pub inline fn nextArg(self: *@This()) ?u64 {
            if (self.arg_index < self.cmds.args.items.len) {
                const arg = self.cmds.args.items[self.arg_index];
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
            const bytes = &self.cmds.any_bytes.items[self.comp_bytes_index..][0..id.size];

            // Update the offset and return the pointer
            self.comp_bytes_index += id.size;
            return bytes.ptr;
        }
    };

    /// Encodes a command.
    pub fn encode(cmds: *CmdBuf, cmd: Cmd) error{ZcsCmdBufOverflow}!void {
        _ = Cmd.rename_when_changing_encoding;

        switch (cmd) {
            .destroy => {
                if (cmds.tags.items.len >= cmds.tags.capacity) return error.ZcsCmdBufOverflow;
                cmds.tags.appendAssumeCapacity(.destroy);
            },
            .bind_entity => |entity| {
                if (cmds.bound == entity.toOptional()) return;
                cmds.bound = entity.toOptional();
                if (cmds.tags.items.len >= cmds.tags.capacity) return error.ZcsCmdBufOverflow;
                if (cmds.args.items.len >= cmds.args.capacity) return error.ZcsCmdBufOverflow;
                cmds.tags.appendAssumeCapacity(.bind_entity);
                cmds.args.appendAssumeCapacity(@bitCast(entity));
            },
            inline .add_comp_val, .event_val => |comp| {
                const aligned = std.mem.alignForward(
                    usize,
                    cmds.any_bytes.items.len,
                    comp.id.alignment,
                );
                if (cmds.tags.items.len >= cmds.tags.capacity) return error.ZcsCmdBufOverflow;
                if (cmds.args.items.len + 1 > cmds.args.capacity) return error.ZcsCmdBufOverflow;
                if (aligned + comp.id.size > cmds.any_bytes.capacity) {
                    return error.ZcsCmdBufOverflow;
                }
                cmds.tags.appendAssumeCapacity(cmd);
                cmds.args.appendAssumeCapacity(@intFromPtr(comp.id));
                cmds.any_bytes.items.len = aligned;
                cmds.any_bytes.appendSliceAssumeCapacity(comp.constSlice());
            },
            .add_comp_ptr, .event_ptr => |comp| {
                if (cmds.tags.items.len >= cmds.tags.capacity) return error.ZcsCmdBufOverflow;
                if (cmds.args.items.len + 2 > cmds.args.capacity) return error.ZcsCmdBufOverflow;
                cmds.tags.appendAssumeCapacity(cmd);
                cmds.args.appendAssumeCapacity(@intFromPtr(comp.id));
                cmds.args.appendAssumeCapacity(@intFromPtr(comp.ptr));
            },
            .remove_comp => |id| {
                if (cmds.tags.items.len >= cmds.tags.capacity) return error.ZcsCmdBufOverflow;
                if (cmds.args.items.len >= cmds.args.capacity) return error.ZcsCmdBufOverflow;
                cmds.tags.appendAssumeCapacity(.remove_comp);
                cmds.args.appendAssumeCapacity(@intFromPtr(id));
            },
        }
    }
};
