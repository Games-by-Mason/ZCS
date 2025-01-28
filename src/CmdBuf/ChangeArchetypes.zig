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
            return .{
                .decoder = self.decoder,
                .skip = self.remove,
            };
        }
    };

    /// Returns the next archetype changed command, or `null` if there is none.
    pub fn next(self: *@This()) ?Item {
        while (self.decoder.next()) |cmd| {
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
                                const index = comp.id.register();
                                add.insert(index);
                                remove.remove(index);
                            },
                            .add_component_ptr => {
                                const comp = self.decoder.next().?.add_component_ptr;
                                const index = comp.id.register();
                                add.insert(index);
                                remove.remove(index);
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

/// An iterator over an archetype change command's added components.
///
/// The command encoder is allowed to modify, reorder or skip components so long as the result is
/// logically equivalent.
pub const ComponentIterator = struct {
    decoder: SubCmd.Decoder,
    skip: Component.Flags,

    /// Returns the next added component, or `null` if there are none.
    pub fn next(self: *@This()) ?Component {
        while (self.decoder.peekTag()) |tag| {
            const comp = switch (tag) {
                .add_component_val => self.decoder.next().?.add_component_val,
                .add_component_ptr => self.decoder.next().?.add_component_ptr,
                .remove_components => {
                    _ = self.decoder.next().?.remove_components;
                    continue;
                },
                .bind_entity => break,
            };
            // XXX: need to document that iterating registers stuff and therefore shouldn't be done on bg...
            const index = comp.id.register();
            if (!self.skip.contains(index)) return comp;
        }
        return null;
    }
};
