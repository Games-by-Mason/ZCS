//! For internal use. Subcommand encoding for the command buffer.

const std = @import("std");
const assert = std.debug.assert;

const zcs = @import("../root.zig");
const Entity = zcs.Entity;
const Comp = zcs.Comp;
const CmdBuf = zcs.CmdBuf;
const Entities = zcs.Entities;

/// For internal use. Archetype change commands are composed of a sequence of one  or more
/// subcommands which are then encoded in a compact form.
pub const SubCmd = union(enum) {
    /// Destroys the given entity. Clears the bound entity if there is one to ease decoding, this
    /// guarantees that all archetype changes start with a bind.
    destroy_entity: Entity,
    /// Binds an existing entity.
    bind_entity: Entity,
    /// Queues components to be added by value. ID is passed as an argument, component data is
    /// passed via component data.
    add_comp_val: Comp,
    /// Queues components to be added bye value. ID and a pointer to the component data are passed
    /// as arguments.
    add_comp_ptr: Comp,
    /// Queues a component to be removed.
    remove_comp: Comp.Id,

    /// If a new worst case command is introduced, also update the tests!
    pub const rename_when_changing_encoding = {};

    pub const Tag = @typeInfo(@This()).@"union".tag_type.?;

    /// Decodes encoded subcommands.
    pub const Decoder = struct {
        cmds: *const CmdBuf,
        tag_index: usize = 0,
        arg_index: usize = 0,
        comp_bytes_index: usize = 0,

        pub inline fn next(self: *@This()) ?SubCmd {
            _ = rename_when_changing_encoding;

            // Decode the next subcommand
            if (self.nextTag()) |tag| {
                switch (tag) {
                    .destroy_entity => {
                        const entity: Entity = @bitCast(self.nextArg().?);
                        return .{ .destroy_entity = entity };
                    },
                    .bind_entity => {
                        const entity: Entity = @bitCast(self.nextArg().?);
                        return .{ .bind_entity = entity };
                    },
                    .add_comp_val => {
                        const id: Comp.Id = @ptrFromInt(self.nextArg().?);
                        const ptr = self.nextComponentData(id);
                        const comp: Comp = .{
                            .id = id,
                            .ptr = ptr,
                        };
                        return .{ .add_comp_val = comp };
                    },
                    .add_comp_ptr => {
                        const id: Comp.Id = @ptrFromInt(self.nextArg().?);
                        const ptr: *const anyopaque = @ptrFromInt(self.nextArg().?);
                        const comp: Comp = .{
                            .id = id,
                            .ptr = ptr,
                        };
                        return .{ .add_comp_ptr = comp };
                    },
                    .remove_comp => {
                        const id: Comp.Id = @ptrFromInt(self.nextArg().?);
                        return .{ .remove_comp = id };
                    },
                }
            }

            // Assert that we're fully empty, and return null
            assert(self.tag_index == self.cmds.tags.items.len);
            assert(self.arg_index == self.cmds.args.items.len);
            assert(self.comp_bytes_index == self.cmds.comp_bytes.items.len);
            return null;
        }

        pub inline fn peekTag(self: *@This()) ?SubCmd.Tag {
            if (self.tag_index < self.cmds.tags.items.len) {
                return self.cmds.tags.items[self.tag_index];
            } else {
                return null;
            }
        }

        pub inline fn nextTag(self: *@This()) ?SubCmd.Tag {
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

        pub inline fn nextComponentData(self: *@This(), id: Comp.Id) *const anyopaque {
            // Align the read
            self.comp_bytes_index = std.mem.alignForward(
                usize,
                self.comp_bytes_index,
                id.alignment,
            );

            // Get the pointer as a slice, this way we don't fail on zero sized types
            const bytes = &self.cmds.comp_bytes.items[self.comp_bytes_index..][0..id.size];

            // Update the offset and return the pointer
            self.comp_bytes_index += id.size;
            return bytes.ptr;
        }
    };

    /// Encodes a subcommand.
    pub fn encode(cmds: *CmdBuf, sub_cmd: SubCmd) error{ZcsCmdBufOverflow}!void {
        _ = SubCmd.rename_when_changing_encoding;

        switch (sub_cmd) {
            .destroy_entity => |entity| {
                if (cmds.tags.items.len >= cmds.tags.capacity) return error.ZcsCmdBufOverflow;
                if (cmds.args.items.len >= cmds.args.capacity) return error.ZcsCmdBufOverflow;
                cmds.tags.appendAssumeCapacity(.destroy_entity);
                cmds.args.appendAssumeCapacity(@bitCast(entity));
                cmds.bound = .none;
            },
            .bind_entity => |entity| {
                if (cmds.bound == entity.toOptional()) return;
                cmds.bound = entity.toOptional();
                if (cmds.tags.items.len >= cmds.tags.capacity) return error.ZcsCmdBufOverflow;
                if (cmds.args.items.len >= cmds.args.capacity) return error.ZcsCmdBufOverflow;
                cmds.tags.appendAssumeCapacity(.bind_entity);
                cmds.args.appendAssumeCapacity(@bitCast(entity));
            },
            .add_comp_val => |comp| {
                const aligned = std.mem.alignForward(
                    usize,
                    cmds.comp_bytes.items.len,
                    comp.id.alignment,
                );
                if (cmds.tags.items.len >= cmds.tags.capacity) return error.ZcsCmdBufOverflow;
                if (cmds.args.items.len + 1 > cmds.args.capacity) return error.ZcsCmdBufOverflow;
                if (aligned + comp.id.size > cmds.comp_bytes.capacity) {
                    return error.ZcsCmdBufOverflow;
                }
                cmds.tags.appendAssumeCapacity(.add_comp_val);
                cmds.args.appendAssumeCapacity(@intFromPtr(comp.id));
                cmds.comp_bytes.items.len = aligned;
                cmds.comp_bytes.appendSliceAssumeCapacity(comp.constSlice());
            },
            .add_comp_ptr => |comp| {
                if (cmds.tags.items.len >= cmds.tags.capacity) return error.ZcsCmdBufOverflow;
                if (cmds.args.items.len + 2 > cmds.args.capacity) return error.ZcsCmdBufOverflow;
                cmds.tags.appendAssumeCapacity(.add_comp_ptr);
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
