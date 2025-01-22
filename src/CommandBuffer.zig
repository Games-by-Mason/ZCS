//! A buffer for queuing up ECS commands to execute later.
//!
//! Useful for doing operations while iterating without invalidating the iterator, or for working
//! with ECS data from multiple threads. All commands are noops if the entity in question has been
//! destroyed.
//!
//! You may also use `iterator` to inspect the contents of a command buffer and do additional
//! processing, for example to maintain transform hierarchies when entities are scheduled for
//! deletion.
//!
//! Command buffers make a single allocation at init time, and never again. They should be cleared
//! and reused when possible.
//!
//! # Example
//! ```zig
//! var cb = try CommandBuffer.init(gpa, &es, 4);
//! defer cb.deinit(gpa);
//!
//! cb.create(&es, .{RigidBody { .mass = 0.5 }, Mesh { .model = player });
//! cb.destroy(entity1);
//! cb.changeArchetype(&es, entity2, Component.flags(&es, &.{Fire}), .{ Hammer{} });
//! cb.submit(&es);
//! cb.clear();
//! ```

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const zcs = @import("root.zig");
const Entities = zcs.Entities;
const Entity = zcs.Entity;
const Component = zcs.Component;

const CommandBuffer = @This();

const meta = @import("meta.zig");

/// All entities queued for destruction.
destroy_queue: std.ArrayListUnmanaged(Entity),
tags: std.ArrayListUnmanaged(SubCmd.Tag),
args: std.ArrayListUnmanaged(u64),
comp_buf: std.ArrayListAlignedUnmanaged(u8, Entities.max_align),

/// Initializes a command buffer with at least enough capacity for the given number of commands.
pub fn init(gpa: Allocator, es: *const Entities, capacity: usize) Allocator.Error!@This() {
    return initSeparateCapacities(gpa, .initFromCmds(es, capacity));
}

/// Initializes the command buffer with separate capacities for each internal buffer. Generally, you
/// should prefer `init`.
pub fn initSeparateCapacities(gpa: Allocator, capacities: Capacities) Allocator.Error!@This() {
    comptime assert(Component.Id.max < std.math.maxInt(u64));

    var tags: std.ArrayListUnmanaged(SubCmd.Tag) = try .initCapacity(gpa, capacities.tags);
    errdefer tags.deinit(gpa);

    var args: std.ArrayListUnmanaged(u64) = try .initCapacity(gpa, capacities.args);
    errdefer args.deinit(gpa);

    var comp_buf: std.ArrayListAlignedUnmanaged(u8, Entities.max_align) = try .initCapacity(
        gpa,
        capacities.comp_buf,
    );
    errdefer comp_buf.deinit(gpa);

    var destroy_queue: std.ArrayListUnmanaged(Entity) = try .initCapacity(gpa, capacities.destroy);
    errdefer destroy_queue.deinit(gpa);

    return .{
        .tags = tags,
        .args = args,
        .comp_buf = comp_buf,
        .destroy_queue = destroy_queue,
    };
}

/// Destroys the command buffer.
pub fn deinit(self: *@This(), gpa: Allocator) void {
    self.destroy_queue.deinit(gpa);
    self.comp_buf.deinit(gpa);
    self.args.deinit(gpa);
    self.tags.deinit(gpa);
    self.* = undefined;
}

/// Clears the command buffer, allowing for reuse.
pub fn clear(self: *@This()) void {
    self.destroy_queue.clearRetainingCapacity();
    self.comp_buf.clearRetainingCapacity();
    self.args.clearRetainingCapacity();
    self.tags.clearRetainingCapacity();
}

fn usage(list: anytype) f32 {
    if (list.capacity == 0) return 1.0;
    return @as(f32, @floatFromInt(list.items.len)) / @as(f32, @floatFromInt(list.capacity));
}

/// Returns the ratio of length to capacity for the internal buffer that is the nearest to being
/// full.
pub fn worstCaseUsage(self: @This()) f32 {
    return @max(
        usage(self.destroy_queue),
        usage(self.comp_buf),
        usage(self.args),
        usage(self.tags),
    );
}

/// Appends a `Entity.create` command.
///
/// See `Entity.create` for what types are allowed in `comps`. Comptime fields are passed by
/// pointer if the underlying type is larger than a pointer.
pub fn create(self: *@This(), es: *const Entities, comps: anytype) void {
    self.createChecked(es, comps) catch |err|
        @panic(@errorName(err));
}

/// Similar to `create`, but returns `error.Overflow` when out of space.
pub fn createChecked(
    self: *@This(),
    es: *const Entities,
    comps: anytype,
) error{Overflow}!void {
    // Check the types
    meta.checkComponents(@TypeOf(comps));
    const fields = @typeInfo(@TypeOf(comps)).@"struct".fields;

    // Restore the state on failure
    const restore = self.*;
    errdefer self.* = restore;

    // Sort for minimal padding.
    const sorted_fields = comptime meta.alignmentSort(@TypeOf(comps));

    // Issue the subcommands
    try self.subCmd(es, .bind_new_entity);
    inline for (0..fields.len) |i| {
        const field = fields[sorted_fields[i]];
        const optional: ?meta.Unwrapped(field.type) = @field(comps, field.name);
        if (optional) |some| {
            if (field.is_comptime and @sizeOf(@TypeOf(some)) > @sizeOf(usize)) {
                try self.subCmd(es, .{
                    .add_component_ptr = .{
                        .id = es.getComponentId(@TypeOf(some)),
                        .ptr = &struct {
                            const interned = some;
                        }.interned,
                        .interned = true,
                    },
                });
            } else {
                try self.subCmd(es, .{ .add_component_val = .{
                    .id = es.getComponentId(@TypeOf(some)),
                    .ptr = @ptrCast(&some),
                    .interned = false,
                } });
            }
        }
    }
}

/// Similar to `create`, but doesn't require compile time types.
///
/// Components set to `.none` have no effect.
pub fn createFromComponents(
    self: *@This(),
    es: *const Entities,
    comps: []const Component.Optional,
) void {
    self.createFromComponentsChecked(es, comps) catch |err|
        @panic(@errorName(err));
}

/// Similar to `createFromComponents`, but returns `error.Overflow` when out of space.
pub fn createFromComponentsChecked(
    self: *@This(),
    es: *const Entities,
    comps: []const Component.Optional,
) error{Overflow}!void {
    const restore = self.*;
    errdefer self.* = restore;

    // Add all the components in reverse order, skipping any types we've already added. This
    // preserves expected behavior while also conforming to our capacity guarantees.
    try self.subCmd(es, .bind_new_entity);
    try self.addComponents(es, comps);
}

/// Appends an `Entity.changeArchetype` command.
///
/// See `Entity.changeArchetype` for documentation on what's types are allowed in `comps`.
/// Comptime fields are interned if they're larger than a pointer.
pub fn changeArchetype(
    self: *@This(),
    es: *const Entities,
    entity: Entity,
    remove: Component.Flags,
    comps: anytype,
) void {
    self.changeArchetypeChecked(es, entity, remove, comps) catch |err|
        @panic(@errorName(err));
}

/// Similar to `changeArchetype`, but returns `error.Overflow` when out of space.
pub fn changeArchetypeChecked(
    self: *@This(),
    es: *const Entities,
    entity: Entity,
    remove: Component.Flags,
    add: anytype,
) error{Overflow}!void {
    // Check the types
    meta.checkComponents(@TypeOf(add));
    const fields = @typeInfo(@TypeOf(add)).@"struct".fields;

    // Restore the state on failure
    const restore = self.*;
    errdefer self.* = restore;

    // Sort for minimal padding
    const sorted_fields = comptime meta.alignmentSort(@TypeOf(add));

    // Issue the subcommands
    try self.subCmd(es, .{ .bind_entity = entity });
    try self.subCmd(es, .{ .remove_components = remove });
    inline for (0..fields.len) |i| {
        const field = fields[sorted_fields[i]];

        const optional: ?meta.Unwrapped(field.type) = @field(add, field.name);
        if (optional) |some| {
            if (field.is_comptime and @sizeOf(@TypeOf(some)) > @sizeOf(usize)) {
                try self.subCmd(es, .{ .add_component_ptr = .{
                    .id = es.getComponentId(@TypeOf(some)),
                    .ptr = &struct {
                        const interned = some;
                    }.interned,
                    .interned = true,
                } });
            } else {
                try self.subCmd(es, .{ .add_component_val = .{
                    .id = es.getComponentId(@TypeOf(some)),
                    .ptr = @ptrCast(&some),
                    .interned = false,
                } });
            }
        }
    }
}

/// Similar to `changeArchetype` but does not require compile time types.
///
/// Components set to `.none` have no effect.
pub fn changeArchetypeFromComponents(
    self: *@This(),
    es: *const Entities,
    entity: Entity,
    remove: Component.Flags,
    comps: []const Component.Optional,
) void {
    self.changeArchetypeFromComponentsChecked(es, entity, remove, comps) catch |err|
        @panic(@errorName(err));
}

/// Similar to `changeArchetypeFromComponents` but returns `error.Overflow` when out of space.
pub fn changeArchetypeFromComponentsChecked(
    self: *@This(),
    es: *const Entities,
    entity: Entity,
    remove: Component.Flags,
    comps: []const Component.Optional,
) error{Overflow}!void {
    const restore = self.*;
    errdefer self.* = restore;

    try self.subCmd(es, .{ .bind_entity = entity });
    if (!remove.eql(.{})) {
        try self.subCmd(es, .{ .remove_components = remove });
    }

    try self.addComponents(es, comps);
}

/// Appends an `Entity.destroy` command.
pub fn destroy(self: *@This(), entity: Entity) void {
    self.destroyChecked(entity) catch |err|
        @panic(@errorName(err));
}

/// Similar to `destroy`, but returns `error.Overflow` when out of space.
pub fn destroyChecked(self: *@This(), entity: Entity) error{Overflow}!void {
    if (self.destroy_queue.items.len >= self.destroy_queue.capacity) {
        return error.Overflow;
    }
    self.destroy_queue.appendAssumeCapacity(entity);
}

/// Executes the command buffer.
pub fn submit(self: *const @This(), es: *Entities) void {
    self.submitChecked(es) catch |err|
        @panic(@errorName(err));
}

/// Similar to `submit`, but returns `error.Overflow` when out of space. On failure, partial changes
/// to entities are *not* reverted. As such, some component data may be uninitialized.
pub fn submitChecked(self: *const @This(), es: *Entities) error{Overflow}!void {
    var iter = self.iterator(es);
    while (iter.next()) |cmd| {
        switch (cmd) {
            .create => |args| {
                const entity = try Entity.createUninitializedChecked(es, args.archetype);
                var comps = args.componentIterator();
                while (comps.next()) |comp| {
                    const src = comp.bytes();
                    const dest = entity.getComponentFromId(es, comp.id).?;
                    @memcpy(dest, src);
                }
            },
            .destroy => |entity| entity.destroy(es),
            .change_archetype => |args| {
                if (args.entity.exists(es)) {
                    try args.entity.changeArchetypeUnintializedChecked(es, .{
                        .remove = args.remove,
                        .add = args.add,
                    });
                    var comps = args.componentIterator();
                    while (comps.next()) |comp| {
                        const src = comp.bytes();
                        const dest = args.entity.getComponentFromId(es, comp.id).?;
                        @memcpy(dest, src);
                    }
                }
            },
        }
    }
}

/// Issue subcommands to add the listed components. Issued in reverse order, duplicates are skipped.
fn addComponents(
    self: *@This(),
    es: *const Entities,
    comps: []const Component.Optional,
) error{Overflow}!void {
    var added: Component.Flags = .{};
    for (0..comps.len) |i| {
        const comp = comps[comps.len - i - 1];
        if (comp.unwrap()) |some| {
            if (!added.contains(some.id)) {
                added.insert(some.id);
                if (some.interned) {
                    try self.subCmd(es, .{ .add_component_ptr = some });
                } else {
                    try self.subCmd(es, .{ .add_component_val = some });
                }
            }
        }
    }
}

/// If a new worst case command is introduced, also update the tests!
const rename_when_changing_encoding = {};

/// Submits a subcommand. The public facing commands are all build up of one or more subcommands for
/// encoding purposes. When modifying this encoding, keep `initFromCmds` in sync.
fn subCmd(self: *@This(), es: *const Entities, sub_cmd: SubCmd) error{Overflow}!void {
    _ = rename_when_changing_encoding;

    switch (sub_cmd) {
        .bind_entity => |entity| {
            if (self.tags.items.len >= self.tags.capacity) return error.Overflow;
            if (self.args.items.len >= self.args.capacity) return error.Overflow;
            self.tags.appendAssumeCapacity(.bind_entity);
            self.args.appendAssumeCapacity(@bitCast(entity));
        },
        .bind_new_entity => {
            if (self.tags.items.len >= self.tags.capacity) return error.Overflow;
            self.tags.appendAssumeCapacity(.bind_new_entity);
        },
        .add_component_val => |comp| {
            const size = es.getComponentSize(comp.id);
            const alignment = es.getComponentAlignment(comp.id);
            const aligned = std.mem.alignForward(usize, self.comp_buf.items.len, alignment);
            if (self.tags.items.len >= self.tags.capacity) return error.Overflow;
            if (self.args.items.len + 1 > self.args.capacity) return error.Overflow;
            if (aligned + size > self.comp_buf.capacity) {
                return error.Overflow;
            }
            self.tags.appendAssumeCapacity(.add_component_val);
            self.args.appendAssumeCapacity(@intFromEnum(comp.id));
            const bytes = comp.bytes();
            self.comp_buf.items.len = aligned;
            self.comp_buf.appendSliceAssumeCapacity(bytes[0..size]);
        },
        .add_component_ptr => |comp| {
            assert(comp.interned);
            if (self.tags.items.len >= self.tags.capacity) return error.Overflow;
            if (self.args.items.len + 2 > self.args.capacity) return error.Overflow;
            self.tags.appendAssumeCapacity(.add_component_ptr);
            self.args.appendAssumeCapacity(@intFromEnum(comp.id));
            self.args.appendAssumeCapacity(@intFromPtr(comp.ptr));
        },
        .remove_components => |comps| {
            if (self.tags.items.len >= self.tags.capacity) return error.Overflow;
            if (self.args.items.len >= self.args.capacity) return error.Overflow;
            self.tags.appendAssumeCapacity(.remove_components);
            self.args.appendAssumeCapacity(comps.bits.mask);
        },
    }
}

/// Returns an iterator over the commands in this command buffer. Iteration order is implementation
/// defined but guaranteed to provide the same result as the order the commands were issued.
pub fn iterator(self: *const @This(), es: *const Entities) Iterator {
    return .{ .decoder = .{
        .cb = self,
        .es = es,
    } };
}

/// A command buffer command.
pub const Cmd = union(enum) {
    /// Create a new entity with the given archetype and components.
    create: struct {
        archetype: Component.Flags,
        decoder: SubCmd.Decoder,

        pub fn componentIterator(self: @This()) ComponentIterator {
            return .{ .decoder = self.decoder };
        }
    },
    /// Destroy the given entity if it exists.
    destroy: Entity,
    /// Change the archetype of the given entity if it exists.
    change_archetype: struct {
        entity: Entity,
        remove: Component.Flags,
        add: Component.Flags,
        decoder: SubCmd.Decoder,

        pub fn componentIterator(self: @This()) ComponentIterator {
            return .{ .decoder = self.decoder };
        }
    },
};

/// Commands are comprised of a sequence of one or more subcommands which are encoded in a compact
/// form in the command buffer.
const SubCmd = union(enum) {
    /// Binds an existing entity.
    bind_entity: Entity,
    /// Creates a new entity and binds it.
    bind_new_entity,
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

    const Tag = @typeInfo(@This()).@"union".tag_type.?;

    const Decoder = struct {
        cb: *const CommandBuffer,
        es: *const Entities,
        tag_index: usize = 0,
        arg_index: usize = 0,
        component_bytes_index: usize = 0,

        inline fn next(self: *@This()) ?SubCmd {
            _ = rename_when_changing_encoding;

            // Decode the next subcommand
            if (self.nextTag()) |tag| {
                switch (tag) {
                    .bind_entity => {
                        const entity: Entity = @bitCast(self.nextArg().?);
                        return .{ .bind_entity = entity };
                    },
                    .bind_new_entity => return .bind_new_entity,
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
            assert(self.component_bytes_index == self.cb.comp_buf.items.len);
            return null;
        }

        inline fn peekTag(self: *@This()) ?SubCmd.Tag {
            if (self.tag_index < self.cb.tags.items.len) {
                return self.cb.tags.items[self.tag_index];
            } else {
                return null;
            }
        }

        inline fn nextTag(self: *@This()) ?SubCmd.Tag {
            const tag = self.peekTag() orelse return null;
            self.tag_index += 1;
            return tag;
        }

        inline fn nextArg(self: *@This()) ?u64 {
            if (self.arg_index < self.cb.args.items.len) {
                const arg = self.cb.args.items[self.arg_index];
                self.arg_index += 1;
                return arg;
            } else {
                return null;
            }
        }

        inline fn nextComponentData(self: *@This(), id: Component.Id) [*]const u8 {
            const size = self.es.getComponentSize(id);
            const alignment = self.es.getComponentAlignment(id);
            self.component_bytes_index = std.mem.alignForward(
                usize,
                self.component_bytes_index,
                alignment,
            );
            const result = self.cb.comp_buf.items[self.component_bytes_index..].ptr;
            self.component_bytes_index += size;
            return result;
        }
    };
};

/// See `CommandBuffer.iterator`.
pub const Iterator = struct {
    destroy_index: usize = 0,
    decoder: SubCmd.Decoder,

    pub fn next(self: *@This()) ?Cmd {
        if (self.nextDestroy()) |entity| {
            return .{ .destroy = entity };
        }

        if (self.decoder.next()) |cmd| {
            switch (cmd) {
                .bind_entity => |entity| {
                    const comp_decoder = self.decoder;
                    var remove: Component.Flags = .{};
                    var add: Component.Flags = .{};
                    while (self.decoder.peekTag()) |subcmd| {
                        switch (subcmd) {
                            .bind_entity, .bind_new_entity => break,
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
                    return .{ .change_archetype = .{
                        .remove = remove,
                        .add = add,
                        .entity = entity,
                        .decoder = comp_decoder,
                    } };
                },
                .bind_new_entity => {
                    const comp_decoder = self.decoder;
                    var archetype: Component.Flags = .{};
                    while (self.decoder.peekTag()) |subcmd| {
                        switch (subcmd) {
                            .bind_entity, .bind_new_entity => break,
                            .add_component_val => {
                                const comp = self.decoder.next().?.add_component_val;
                                archetype.insert(comp.id);
                            },
                            .add_component_ptr => {
                                const comp = self.decoder.next().?.add_component_ptr;
                                archetype.insert(comp.id);
                            },
                            .remove_components => {
                                const comps = self.decoder.next().?.remove_components;
                                archetype = archetype.differenceWith(comps);
                            },
                        }
                    }
                    return .{ .create = .{
                        .archetype = archetype,
                        .decoder = comp_decoder,
                    } };
                },
                .add_component_val, .add_component_ptr, .remove_components => {
                    unreachable; // Add/remove encoded without binding!
                },
            }
        }

        return null;
    }

    inline fn nextDestroy(self: *@This()) ?Entity {
        if (self.destroy_index < self.decoder.cb.destroy_queue.items.len) {
            const entity = self.decoder.cb.destroy_queue.items[self.destroy_index];
            self.destroy_index += 1;
            return entity;
        } else {
            return null;
        }
    }
};

/// An iterator over a command's component arguments.
pub const ComponentIterator = struct {
    decoder: SubCmd.Decoder,

    pub fn next(self: *@This()) ?Component {
        while (self.decoder.peekTag()) |tag| {
            switch (tag) {
                .bind_entity, .bind_new_entity => {
                    break;
                },
                .add_component_val => {
                    return self.decoder.next().?.add_component_val;
                },
                .add_component_ptr => {
                    return self.decoder.next().?.add_component_ptr;
                },
                .remove_components => {
                    _ = self.decoder.next().?.remove_components;
                },
            }
        }
        return null;
    }
};

/// Per buffer capacity.
pub const Capacities = struct {
    tags: usize,
    args: usize,
    comp_buf: usize,
    destroy: usize,

    /// Sets each buffer capacity to be at least enough for the given number of commands.
    pub fn initFromCmds(es: *const Entities, cmds: usize) Capacities {
        _ = rename_when_changing_encoding;

        // Worst case component data size. Technically we could make this slightly tighter since
        // alignment must be a power of two, but this calculation is much simpler.
        var comp_buf_cap: usize = 0;
        for (0..es.comp_types.count()) |i| {
            const id: Component.Id = @enumFromInt(i);
            comp_buf_cap += es.getComponentSize(id);
            comp_buf_cap += es.getComponentAlignment(id) - 1;
        }
        comp_buf_cap *= cmds;

        // The command with the most subcommands is change archetype
        var change_archetype_tags: usize = 0;
        change_archetype_tags += 1; // Bind
        change_archetype_tags += 1; // Remove components
        change_archetype_tags += es.comp_types.count(); // Add component
        const tags_cap = change_archetype_tags * cmds;

        // The command with the most args is change archetype with interned components
        var change_archetype_args: usize = 0;
        change_archetype_args += 1; // Bind
        change_archetype_args += es.comp_types.count() * 2; // comps * (id + ptr)
        const args_cap = change_archetype_args * cmds;

        // The most destroys we could do is the number of commands.
        const destroy_cap = cmds;

        return .{
            .tags = tags_cap,
            .args = args_cap,
            .comp_buf = comp_buf_cap,
            .destroy = destroy_cap,
        };
    }
};
