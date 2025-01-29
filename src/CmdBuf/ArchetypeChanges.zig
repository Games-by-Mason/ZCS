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
pub const ArchetypeChange = struct {
    /// The bound entity.
    entity: Entity,
    decoder: SubCmd.Decoder,

    /// An iterator over the operations that make up this archetype change.
    pub fn iterator(self: @This()) OperationIterator {
        return .{ .decoder = self.decoder };
    }
};

/// An individual operation that's part of an archetype change.
pub const Operation = union(enum) {
    add: Comp,
    remove: Comp.Id,
};

/// An iterator over archetype change commands.
pub const Iterator = struct {
    decoder: SubCmd.Decoder,

    /// Returns the next archetype changed command, or `null` if there is none.
    pub fn next(self: *@This()) ?ArchetypeChange {
        while (self.decoder.next()) |cmd| {
            switch (cmd) {
                .bind_entity => |entity| {
                    const op_decoder = self.decoder;
                    while (self.decoder.peekTag()) |subcmd| {
                        switch (subcmd) {
                            .bind_entity => break,
                            .add_comp_val => _ = self.decoder.next().?.add_comp_val,
                            .add_comp_ptr => _ = self.decoder.next().?.add_comp_ptr,
                            .remove_comp => _ = self.decoder.next().?.remove_comp,
                        }
                    }
                    return .{
                        .entity = entity,
                        .decoder = op_decoder,
                    };
                },
                .add_comp_val, .add_comp_ptr, .remove_comp => {
                    // Add/remove commands with no entity bound. This can occur if the first entity
                    // we bind is `.none`. Since it is none, and the default cached binding is none,
                    // the binding is omitted.
                    //
                    // Adding/removing components from entities that don't exist, such as `.none`,
                    // is a noop, so we just skip these commands.
                    continue;
                },
            }
        }

        return null;
    }
};

/// An iterator over an archetype change command's operations.
pub const OperationIterator = struct {
    decoder: SubCmd.Decoder,

    /// Returns the next operation, or `null` if there are none.
    pub fn next(self: *@This()) ?Operation {
        while (self.decoder.peekTag()) |tag| {
            return switch (tag) {
                .add_comp_val => .{ .add = self.decoder.next().?.add_comp_val },
                .add_comp_ptr => .{ .add = self.decoder.next().?.add_comp_ptr },
                .remove_comp => .{ .remove = self.decoder.next().?.remove_comp },
                .bind_entity => break,
            };
        }
        return null;
    }
};
