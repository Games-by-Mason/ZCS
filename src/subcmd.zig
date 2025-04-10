const std = @import("std");
const assert = std.debug.assert;

const zcs = @import("root.zig");
const typeId = zcs.typeId;
const Entity = zcs.Entity;
const Any = zcs.Any;
const TypeId = zcs.TypeId;
const CmdBuf = zcs.CmdBuf;
const Entities = zcs.Entities;

/// An unencoded representation of command buffer commands.
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
                        @setEvalBranchQuota(2000);
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
            assert(self.comp_bytes_index == self.cb.data.items.len);
            return null;
        }

        pub inline fn peekTag(self: *@This()) ?Subcmd.Tag {
            if (self.tag_index < self.cb.tags.items.len) {
                return self.cb.tags.items[self.tag_index];
            } else {
                @branchHint(.unlikely);
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
            const bytes = &self.cb.data.items[self.comp_bytes_index..][0..id.size];

            // Update the offset and return the pointer
            self.comp_bytes_index += id.size;
            return bytes.ptr;
        }
    };

    /// Encode adding a component to an entity by value.
    pub fn encodeAddVal(cb: *CmdBuf, entity: Entity, T: type, comp: T) error{ZcsCmdBufOverflow}!void {
        try Subcmd.encodeBind(cb, entity);
        try Subcmd.encodeVal(cb, .add_val, T, comp);
    }

    /// Encode adding a component to an entity by pointer.
    pub fn encodeAddPtr(cb: *CmdBuf, entity: Entity, T: type, comp: *const T) error{ZcsCmdBufOverflow}!void {
        try Subcmd.encodeBind(cb, entity);
        try Subcmd.encodePtr(cb, .add_ptr, T, comp);
    }

    /// Encode an extension command by value.
    pub fn encodeExtVal(cb: *CmdBuf, T: type, payload: T) error{ZcsCmdBufOverflow}!void {
        // Clear the binding. Archetype changes must start with a bind so we don't want it to be
        // cached across other commands.
        cb.binding = .none;
        try Subcmd.encodeVal(cb, .ext_val, T, payload);
    }

    /// Encode an extension command by pointer.
    pub fn encodeExtPtr(cb: *CmdBuf, T: type, payload: *const T) error{ZcsCmdBufOverflow}!void {
        // Clear the binding. Archetype changes must start with a bind so we don't want it to be
        // cached across other commands.
        cb.binding = .none;
        try Subcmd.encodePtr(cb, .ext_ptr, T, payload);
    }

    /// Encode removing a component from an entity.
    pub fn encodeRemove(cb: *CmdBuf, entity: Entity, id: TypeId) error{ZcsCmdBufOverflow}!void {
        errdefer if (std.debug.runtime_safety) {
            cb.invalid = true;
        };
        try Subcmd.encodeBind(cb, entity);
        if (cb.binding.destroyed) return;
        if (cb.tags.items.len >= cb.tags.capacity) return error.ZcsCmdBufOverflow;
        if (cb.args.items.len >= cb.args.capacity) return error.ZcsCmdBufOverflow;
        cb.tags.appendAssumeCapacity(.remove);
        cb.args.appendAssumeCapacity(@intFromPtr(id));
    }

    /// Encode committing an entity.
    pub fn encodeCommit(cb: *CmdBuf, entity: Entity) error{ZcsCmdBufOverflow}!void {
        try encodeBind(cb, entity);
    }

    /// Encode destroying an entity.
    pub fn encodeDestroy(cb: *CmdBuf, entity: Entity) error{ZcsCmdBufOverflow}!void {
        errdefer if (std.debug.runtime_safety) {
            cb.invalid = true;
        };
        try Subcmd.encodeBind(cb, entity);
        if (cb.binding.destroyed) return;
        if (cb.tags.items.len >= cb.tags.capacity) return error.ZcsCmdBufOverflow;
        cb.tags.appendAssumeCapacity(.destroy);
        cb.binding.destroyed = true;
    }

    /// Encode binding an entity as part of a subcommand.
    fn encodeBind(cb: *CmdBuf, entity: Entity) error{ZcsCmdBufOverflow}!void {
        errdefer if (std.debug.runtime_safety) {
            cb.invalid = true;
        };
        if (cb.binding.entity != entity.toOptional()) {
            if (cb.tags.items.len >= cb.tags.capacity) return error.ZcsCmdBufOverflow;
            cb.binding = .{ .entity = entity.toOptional() };
            cb.tags.appendAssumeCapacity(.bind_entity);
            cb.args.appendAssumeCapacity(@bitCast(entity));
        }
    }

    /// Encode a value as part of a subcommand.
    fn encodeVal(cb: *CmdBuf, tag: Tag, T: type, val: T) error{ZcsCmdBufOverflow}!void {
        errdefer if (std.debug.runtime_safety) {
            cb.invalid = true;
        };

        if (cb.binding.destroyed) return;

        const aligned = std.mem.alignForward(usize, cb.data.items.len, @alignOf(T));
        if (cb.tags.items.len >= cb.tags.capacity) return error.ZcsCmdBufOverflow;
        if (aligned + @sizeOf(T) > cb.data.capacity) return error.ZcsCmdBufOverflow;
        cb.tags.appendAssumeCapacity(tag);
        cb.args.appendAssumeCapacity(@intFromPtr(typeId(T)));

        cb.data.items.len = aligned;
        cb.data.appendSliceAssumeCapacity(std.mem.asBytes(&val));
    }

    /// Encode a pointer as part of a subcommand.
    fn encodePtr(cb: *CmdBuf, tag: Tag, T: type, ptr: *const T) error{ZcsCmdBufOverflow}!void {
        errdefer if (std.debug.runtime_safety) {
            cb.invalid = true;
        };

        if (cb.binding.destroyed) return;

        if (cb.tags.items.len >= cb.tags.capacity) return error.ZcsCmdBufOverflow;
        if (cb.args.items.len + 2 > cb.args.capacity) return error.ZcsCmdBufOverflow;

        cb.tags.appendAssumeCapacity(tag);
        cb.args.appendAssumeCapacity(@intFromPtr(typeId(T)));
        cb.args.appendAssumeCapacity(@intFromPtr(ptr));
    }
};
