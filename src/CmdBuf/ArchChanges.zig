//! A set of archetype changes.

const std = @import("std");
const zcs = @import("../root.zig");

const SubCmd = @import("sub_cmd.zig").SubCmd;
const Entities = zcs.Entities;
const Entity = zcs.Entity;
const Comp = zcs.Comp;

tags: std.ArrayListUnmanaged(SubCmd.Tag),
args: std.ArrayListUnmanaged(u64),
comp_bytes: std.ArrayListAlignedUnmanaged(u8, Comp.max_align),
bound: Entity = .none,

/// Returns an iterator over the archetype changes.
pub fn iterator(self: *const @This()) Iterator {
    return .{ .decoder = .{ .cmds = self } };
}

/// A single archetype change, encoded as a sequence of archetype change operations. Change
/// operations are grouped per entity for efficient execution.
pub const Cmd = struct {
    /// The bound entity.
    entity: Entity,
    decoder: SubCmd.Decoder,
    parent: *Iterator,

    /// An iterator over the operations that make up this archetype change.
    pub fn iterator(self: @This()) OpIterator {
        return .{
            .decoder = self.decoder,
            .parent = self.parent,
        };
    }
};

/// An individual operation that's part of an archetype change.
pub const Op = union(enum) {
    add: Comp,
    remove: Comp.Id,
};

/// An iterator over archetype change commands.
pub const Iterator = struct {
    decoder: SubCmd.Decoder,

    /// Returns the next archetype changed command, or `null` if there is none.
    pub fn next(self: *@This()) ?Cmd {
        // We just return bind operations here, `Cmd` handles the add/remove commands. If the first
        // bind is `.none` it's elided, and we end up skipping the initial add/removes, but that's
        // fine since adding/removing to `.none` is a noop anyway.
        while (self.decoder.next()) |subcmd| {
            switch (subcmd) {
                .bind_entity => |entity| return .{
                    .entity = entity,
                    .decoder = self.decoder,
                    .parent = self,
                },
                else => {},
            }
        }

        return null;
    }
};

/// An iterator over an archetype change command's operations.
pub const OpIterator = struct {
    decoder: SubCmd.Decoder,
    parent: *Iterator,

    /// Returns the next operation, or `null` if there are none.
    pub fn next(self: *@This()) ?Op {
        while (self.decoder.peekTag()) |tag| {
            // Get the next operation
            const op: Op = switch (tag) {
                .add_comp_val => .{ .add = self.decoder.next().?.add_comp_val },
                .add_comp_ptr => .{ .add = self.decoder.next().?.add_comp_ptr },
                .remove_comp => .{ .remove = self.decoder.next().?.remove_comp },
                .bind_entity => break,
            };

            // If we're ahead of the parent iterator, fast forward it. This isn't necessary but saves
            // us from parsing the same subcommands multiple times.
            if (self.decoder.tag_index > self.parent.decoder.tag_index) {
                self.parent.decoder = self.decoder;
            }

            // Return the operation.
            return op;
        }
        return null;
    }
};
