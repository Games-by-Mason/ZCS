const std = @import("std");
const assert = std.debug.assert;

const zcs = @import("../root.zig");
const Entity = zcs.Entity;
const Component = zcs.Component;
const CmdBuf = zcs.CmdBuf;
const Entities = zcs.Entities;

/// Commands are comprised of a sequence of one or more subcommands which are encoded in a compact
/// form in the command buffer.
pub const SubCmd = union(enum) {
    /// Binds an existing entity.
    bind_entity: Entity,
    /// Schedules components to be added bye value. Always executes after `remove_components`
    /// commands on the current binding, regardless of submission order. ID is passed as an
    /// argument, component data is passed via component data.
    add_component_val: Component,
    /// Schedules components to be added bye value. Always executes after `remove_components`
    /// commands on the current binding, regardless of submission order. ID and a pointer to the
    /// component data are passed as arguments.
    add_component_ptr: Component,
    /// Schedules components to be removed. Always executes before any `add_component_val` commands on
    /// current binding, regardless of submission order.
    remove_components: Component.Flags,

    /// If a new worst case command is introduced, also update the tests!
    pub const rename_when_changing_encoding = {};

    pub const Tag = @typeInfo(@This()).@"union".tag_type.?;

    pub const Decoder = struct {
        cb: *const CmdBuf,
        es: *const Entities,
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
                        const id: Component.Id = @enumFromInt(self.nextArg().?);
                        const ptr = self.nextComponentData(id);
                        const comp: Component = .{
                            .id = id,
                            .ptr = ptr,
                            .interned = false,
                        };
                        return .{ .add_component_val = comp };
                    },
                    .add_component_ptr => {
                        const id: Component.Id = @enumFromInt(self.nextArg().?);
                        const ptr: [*]u8 = @ptrFromInt(self.nextArg().?);
                        const comp: Component = .{
                            .id = id,
                            .ptr = ptr,
                            .interned = true,
                        };
                        return .{ .add_component_ptr = comp };
                    },
                    .remove_components => {
                        const comps: Component.Flags = .{ .bits = .{
                            .mask = @intCast(self.nextArg().?),
                        } };
                        return .{ .remove_components = comps };
                    },
                }
            }

            // Assert that we're fully empty, and return null
            assert(self.tag_index == self.cb.tags.items.len);
            assert(self.arg_index == self.cb.args.items.len);
            assert(self.component_bytes_index == self.cb.comp_bytes.items.len);
            return null;
        }

        pub inline fn peekTag(self: *@This()) ?SubCmd.Tag {
            if (self.tag_index < self.cb.tags.items.len) {
                return self.cb.tags.items[self.tag_index];
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
            if (self.arg_index < self.cb.args.items.len) {
                const arg = self.cb.args.items[self.arg_index];
                self.arg_index += 1;
                return arg;
            } else {
                return null;
            }
        }

        pub inline fn nextComponentData(self: *@This(), id: Component.Id) [*]const u8 {
            const size = self.es.getComponentSize(id);
            const alignment = self.es.getComponentAlignment(id);
            self.component_bytes_index = std.mem.alignForward(
                usize,
                self.component_bytes_index,
                alignment,
            );
            const result = self.cb.comp_bytes.items[self.component_bytes_index..].ptr;
            self.component_bytes_index += size;
            return result;
        }
    };

    /// Submits a subcommand. The public facing commands are all build up of one or more subcommands for
    /// encoding purposes. When modifying this encoding, keep `initFromCmds` in sync.
    pub fn encode(es: *const Entities, cb: *CmdBuf, sub_cmd: SubCmd) error{ZcsCmdBufOverflow}!void {
        _ = SubCmd.rename_when_changing_encoding;

        switch (sub_cmd) {
            .bind_entity => |entity| {
                if (cb.tags.items.len >= cb.tags.capacity) return error.ZcsCmdBufOverflow;
                if (cb.args.items.len >= cb.args.capacity) return error.ZcsCmdBufOverflow;
                cb.tags.appendAssumeCapacity(.bind_entity);
                cb.args.appendAssumeCapacity(@bitCast(entity));
            },
            .add_component_val => |comp| {
                const size = es.getComponentSize(comp.id);
                const alignment = es.getComponentAlignment(comp.id);
                const aligned = std.mem.alignForward(usize, cb.comp_bytes.items.len, alignment);
                if (cb.tags.items.len >= cb.tags.capacity) return error.ZcsCmdBufOverflow;
                if (cb.args.items.len + 1 > cb.args.capacity) return error.ZcsCmdBufOverflow;
                if (aligned + size > cb.comp_bytes.capacity) {
                    return error.ZcsCmdBufOverflow;
                }
                cb.tags.appendAssumeCapacity(.add_component_val);
                cb.args.appendAssumeCapacity(@intFromEnum(comp.id));
                const bytes = comp.bytes();
                cb.comp_bytes.items.len = aligned;
                cb.comp_bytes.appendSliceAssumeCapacity(bytes[0..size]);
            },
            .add_component_ptr => |comp| {
                assert(comp.interned);
                if (cb.tags.items.len >= cb.tags.capacity) return error.ZcsCmdBufOverflow;
                if (cb.args.items.len + 2 > cb.args.capacity) return error.ZcsCmdBufOverflow;
                cb.tags.appendAssumeCapacity(.add_component_ptr);
                cb.args.appendAssumeCapacity(@intFromEnum(comp.id));
                cb.args.appendAssumeCapacity(@intFromPtr(comp.ptr));
            },
            .remove_components => |comps| {
                if (cb.tags.items.len >= cb.tags.capacity) return error.ZcsCmdBufOverflow;
                if (cb.args.items.len >= cb.args.capacity) return error.ZcsCmdBufOverflow;
                cb.tags.appendAssumeCapacity(.remove_components);
                cb.args.appendAssumeCapacity(comps.bits.mask);
            },
        }
    }
};
