const std = @import("std");
const zcs = @import("../root.zig");

const SubCmd = @import("sub_cmd.zig").SubCmd;
const Entities = zcs.Entities;
const Entity = zcs.Entity;
const Component = zcs.Component;

tags: std.ArrayListUnmanaged(SubCmd.Tag),
args: std.ArrayListUnmanaged(u64),
comp_bytes: std.ArrayListAlignedUnmanaged(u8, Component.max_align),
bound: Entity = .none,

/// Returns an iterator over the archetype changes.
pub fn iterator(self: *const @This(), es: *Entities) Iterator {
    return .{ .decoder = .{
        .cmds = self,
        .es = es,
    } };
}

/// A change archetype command.
pub const ChangeArchetype = struct {
    /// The bound entity.
    entity: Entity,
    decoder: SubCmd.Decoder,

    /// An iterator over the operations that make up this archetype change.
    pub fn iterator(self: @This()) OperationIterator {
        return .{ .decoder = self.decoder };
    }
};

// XXX: document why they're grouped like this so it makes more sense
/// An individual operation that's part of an archetype change.
pub const Operation = union(enum) {
    add: Component,
    remove: Component.Id,
};

/// An iterator over archetype change commands.
pub const Iterator = struct {
    decoder: SubCmd.Decoder,

    /// Returns the next archetype changed command, or `null` if there is none.
    pub fn next(self: *@This()) ?ChangeArchetype {
        while (self.decoder.next()) |cmd| {
            switch (cmd) {
                .bind_entity => |entity| {
                    const op_decoder = self.decoder;
                    // XXX: any way to avoid this? i mean we COULD just have you iterate over the
                    // ops but imo that's kinda annoying? or is it? it may only be OUR code that cares
                    // about grouping them! having to track the bound entity is annoying, but...our
                    // iterator could actually do that for us.
                    while (self.decoder.peekTag()) |subcmd| {
                        switch (subcmd) {
                            .bind_entity => break,
                            .add_component_val => _ = self.decoder.next().?.add_component_val,
                            .add_component_ptr => _ = self.decoder.next().?.add_component_ptr,
                            .remove_component => _ = self.decoder.next().?.remove_component,
                        }
                    }
                    return .{
                        .entity = entity,
                        .decoder = op_decoder,
                    };
                },
                .add_component_val, .add_component_ptr, .remove_component => {
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
                .add_component_val => .{ .add = self.decoder.next().?.add_component_val },
                .add_component_ptr => .{ .add = self.decoder.next().?.add_component_ptr },
                .remove_component => .{ .remove = self.decoder.next().?.remove_component },
                .bind_entity => break,
            };
        }
        return null;
    }
};
