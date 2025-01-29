const std = @import("std");
const assert = std.debug.assert;

const zcs = @import("../root.zig");
const Entity = zcs.Entity;
const Component = zcs.Component;
const CmdBuf = zcs.CmdBuf;
const Entities = zcs.Entities;

/// Implementation detail of `CmdBuf`. Archetype change commands are composed of a sequence of one
/// or more subcommands which are then encoded in a compact form.
pub const SubCmd = union(enum) {
    /// Binds an existing entity.
    bind_entity: Entity,
    /// Queues components to be added by value. ID is passed as an argument, component data is
    /// passed via component data.
    add_component_val: Component,
    /// Queues components to be added bye value. ID and a pointer to the component data are passed
    /// as arguments.
    add_component_ptr: Component,
    /// Queues a component to be removed.
    remove_component: Component.Id,

    /// If a new worst case command is introduced, also update the tests!
    pub const rename_when_changing_encoding = {};

    pub const Tag = @typeInfo(@This()).@"union".tag_type.?;

    /// Decodes encoded subcommands.
    pub const Decoder = struct {
        cmds: *const CmdBuf.ChangeArchetypes,
        es: *Entities,
        tag_index: usize = 0,
        arg_index: usize = 0,
        component_bytes_index: usize = 0,

        pub inline fn next(self: *@This()) ?SubCmd {
            _ = rename_when_changing_encoding;

            // Decode the next subcommand
            if (self.nextTag()) |tag| {
                switch (tag) {
                    .bind_entity => {
                        const entity: Entity = @bitCast(self.nextArg().?);
                        return .{ .bind_entity = entity };
                    },
                    .add_component_val => {
                        const id: Component.Id = @ptrFromInt(self.nextArg().?);
                        const bytes = self.nextComponentData(id);
                        const comp: Component = .{
                            .id = id,
                            .bytes = bytes,
                            .interned = false,
                        };
                        return .{ .add_component_val = comp };
                    },
                    .add_component_ptr => {
                        const id: Component.Id = @ptrFromInt(self.nextArg().?);
                        const bytes_unsized: [*]const u8 = @ptrFromInt(self.nextArg().?);
                        const bytes = bytes_unsized[0..id.size];
                        const comp: Component = .{
                            .id = id,
                            .bytes = bytes,
                            .interned = true,
                        };
                        return .{ .add_component_ptr = comp };
                    },
                    .remove_component => {
                        const id: Component.Id = @ptrFromInt(self.nextArg().?);
                        return .{ .remove_component = id };
                    },
                }
            }

            // Assert that we're fully empty, and return null
            assert(self.tag_index == self.cmds.tags.items.len);
            assert(self.arg_index == self.cmds.args.items.len);
            assert(self.component_bytes_index == self.cmds.comp_bytes.items.len);
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

        pub inline fn nextComponentData(self: *@This(), id: Component.Id) []const u8 {
            self.component_bytes_index = std.mem.alignForward(
                usize,
                self.component_bytes_index,
                id.alignment,
            );
            const result = self.cmds.comp_bytes.items[self.component_bytes_index..][0..id.size];
            self.component_bytes_index += id.size;
            return result;
        }
    };

    /// Encodes a subcommand.
    pub fn encode(
        changes: *CmdBuf.ChangeArchetypes,
        sub_cmd: SubCmd,
    ) error{ZcsCmdBufOverflow}!void {
        _ = SubCmd.rename_when_changing_encoding;

        switch (sub_cmd) {
            .bind_entity => |entity| {
                if (changes.bound == entity) return;
                changes.bound = entity;
                if (changes.tags.items.len >= changes.tags.capacity) return error.ZcsCmdBufOverflow;
                if (changes.args.items.len >= changes.args.capacity) return error.ZcsCmdBufOverflow;
                changes.tags.appendAssumeCapacity(.bind_entity);
                changes.args.appendAssumeCapacity(@bitCast(entity));
            },
            .add_component_val => |comp| {
                const aligned = std.mem.alignForward(
                    usize,
                    changes.comp_bytes.items.len,
                    comp.id.alignment,
                );
                if (changes.tags.items.len >= changes.tags.capacity) return error.ZcsCmdBufOverflow;
                if (changes.args.items.len + 1 > changes.args.capacity) return error.ZcsCmdBufOverflow;
                if (aligned + comp.bytes.len > changes.comp_bytes.capacity) {
                    return error.ZcsCmdBufOverflow;
                }
                changes.tags.appendAssumeCapacity(.add_component_val);
                changes.args.appendAssumeCapacity(@intFromPtr(comp.id));
                changes.comp_bytes.items.len = aligned;
                changes.comp_bytes.appendSliceAssumeCapacity(comp.bytes);
            },
            .add_component_ptr => |comp| {
                assert(comp.interned);
                if (changes.tags.items.len >= changes.tags.capacity) return error.ZcsCmdBufOverflow;
                if (changes.args.items.len + 2 > changes.args.capacity) return error.ZcsCmdBufOverflow;
                changes.tags.appendAssumeCapacity(.add_component_ptr);
                changes.args.appendAssumeCapacity(@intFromPtr(comp.id));
                changes.args.appendAssumeCapacity(@intFromPtr(comp.bytes.ptr));
            },
            .remove_component => |id| {
                if (changes.tags.items.len >= changes.tags.capacity) return error.ZcsCmdBufOverflow;
                if (changes.args.items.len >= changes.args.capacity) return error.ZcsCmdBufOverflow;
                changes.tags.appendAssumeCapacity(.remove_component);
                changes.args.appendAssumeCapacity(@intFromPtr(id));
            },
        }
    }
};
