const std = @import("std");
const zcs = @import("../root.zig");

const SubCmd = @import("sub_cmd.zig").SubCmd;
const Entities = zcs.Entities;
const Entity = zcs.Entity;
const Component = zcs.Component;

tags: std.ArrayListUnmanaged(SubCmd.Tag),
args: std.ArrayListUnmanaged(u64),
comp_bytes: std.ArrayListAlignedUnmanaged(u8, Entities.max_align),

/// Returns an iterator over the archetype changes.
pub fn iterator(self: *const @This(), es: *const Entities) Iterator {
    return .{ .decoder = .{
        .cmds = self,
        .es = es,
    } };
}

/// An iterator over archetype change commands.
///
/// The command encoder is allowed to modify, reorder or skip commands so long as the result is
/// logically equivalent.
pub const Iterator = struct {
    decoder: SubCmd.Decoder,

    /// A change archetype command.
    pub const Item = struct {
        /// The changed entity.
        entity: Entity,
        /// The removed component types.
        remove: Component.Flags,
        /// The added component types.
        add: Component.Flags,
        decoder: SubCmd.Decoder,

        /// An iterator over the added components.
        pub fn componentIterator(self: @This()) ComponentIterator {
            return .{ .decoder = self.decoder };
        }
    };

    /// Returns the next archetype changed command, or `null` if there is none.
    pub fn next(self: *@This()) ?Item {
        if (self.decoder.next()) |cmd| {
            switch (cmd) {
                .bind_entity => |entity| {
                    const comp_decoder = self.decoder;
                    var remove: Component.Flags = .{};
                    var add: Component.Flags = .{};
                    while (self.decoder.peekTag()) |subcmd| {
                        switch (subcmd) {
                            .bind_entity => break,
                            .add_component_val => {
                                const comp = self.decoder.next().?.add_component_val;
                                add.insert(comp.id);
                                remove.remove(comp.id);
                            },
                            .add_component_ptr => {
                                const comp = self.decoder.next().?.add_component_ptr;
                                add.insert(comp.id);
                                remove.remove(comp.id);
                            },
                            .remove_components => {
                                const comps = self.decoder.next().?.remove_components;
                                remove.setUnion(comps);
                                add = add.differenceWith(comps);
                            },
                        }
                    }
                    return .{
                        .remove = remove,
                        .add = add,
                        .entity = entity,
                        .decoder = comp_decoder,
                    };
                },
                .add_component_val, .add_component_ptr, .remove_components => {
                    unreachable; // Add/remove encoded without binding!
                },
            }
        }

        return null;
    }
};

/// An iterator over an archetype change command's added components.
///
/// The command encoder is allowed to modify, reorder or skip components so long as the result is
/// logically equivalent.
pub const ComponentIterator = struct {
    decoder: SubCmd.Decoder,

    /// Returns the next added component, or `null` if there are none.
    pub fn next(self: *@This()) ?Component {
        while (self.decoder.peekTag()) |tag| {
            switch (tag) {
                .add_component_val => return self.decoder.next().?.add_component_val,
                .add_component_ptr => return self.decoder.next().?.add_component_ptr,
                .remove_components => _ = self.decoder.next().?.remove_components,
                .bind_entity => break,
            }
        }
        return null;
    }
};
