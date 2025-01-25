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
//! Command buffers allocate at init time, and then never again. They should be reused when possible
//! rather than destroyed and recreated.
//!
//! # Example
//! ```zig
//! var cb = try CmdBuf.init(gpa, &es, 4);
//! defer cb.deinit(gpa);
//!
//! cb.changeArchetype(&es, es.reserve(), Component.flags(&es, &.{Fire}), .{ Hammer{} });
//! cb.submit(&es);
//! cb.destroy(entity1);
//! cb.clear();
//! ```

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const zcs = @import("root.zig");
const Entities = zcs.Entities;
const Entity = zcs.Entity;
const Component = zcs.Component;

const CmdBuf = @This();

const meta = @import("meta.zig");

tags: std.ArrayListUnmanaged(SubCmd.Tag),
args: std.ArrayListUnmanaged(u64),
comp_bytes: std.ArrayListAlignedUnmanaged(u8, Entities.max_align),
/// All entities queued for destruction.
destroy_queue: std.ArrayListUnmanaged(Entity),
reserved: std.ArrayListUnmanaged(Entity),

/// Initializes a command buffer with at least enough capacity for the given number of commands.
///
/// The reserved entity buffer's capacity is set to zero.
pub fn init(gpa: Allocator, es: *Entities, capacity: usize) Allocator.Error!@This() {
    var capacities: Capacities = .initFromCmds(es, capacity);
    capacities.reserved = 0;
    return initSeparateCapacities(gpa, es, capacities) catch |err| switch (err) {
        error.ZcsEntityOverflow => unreachable, // We set reserve cap to 0, so it can't fail
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Similar to `init`, but also reserves enough entities to satisfy `capacity`.
pub fn initAndReserveEntities(
    gpa: Allocator,
    es: *Entities,
    capacity: usize,
) error{ OutOfMemory, ZcsEntityOverflow }!@This() {
    return initSeparateCapacities(gpa, .initFromCmds(es, capacity));
}

/// Similar to `init` and `initAndReserveEntities`, but allows you to specify each buffer size
/// individually.
pub fn initSeparateCapacities(
    gpa: Allocator,
    es: *Entities,
    capacities: Capacities,
) error{ OutOfMemory, ZcsEntityOverflow }!@This() {
    comptime assert(Component.Id.max < std.math.maxInt(u64));

    var tags: std.ArrayListUnmanaged(SubCmd.Tag) = try .initCapacity(gpa, capacities.tags);
    errdefer tags.deinit(gpa);

    var args: std.ArrayListUnmanaged(u64) = try .initCapacity(gpa, capacities.args);
    errdefer args.deinit(gpa);

    var comp_bytes: std.ArrayListAlignedUnmanaged(u8, Entities.max_align) = try .initCapacity(
        gpa,
        capacities.comp_bytes,
    );
    errdefer comp_bytes.deinit(gpa);

    var destroy_queue: std.ArrayListUnmanaged(Entity) = try .initCapacity(gpa, capacities.destroy);
    errdefer destroy_queue.deinit(gpa);

    var reserved: std.ArrayListUnmanaged(Entity) = try .initCapacity(gpa, capacities.reserved);
    errdefer reserved.deinit(gpa);
    for (0..reserved.capacity) |_| {
        reserved.appendAssumeCapacity(try Entity.reserveChecked(es));
    }

    return .{
        .tags = tags,
        .args = args,
        .comp_bytes = comp_bytes,
        .destroy_queue = destroy_queue,
        .reserved = reserved,
    };
}

/// Destroys the command buffer.
pub fn deinit(self: *@This(), gpa: Allocator, es: *Entities) void {
    for (self.reserved.items) |entity| entity.destroyImmediately(es);
    self.reserved.deinit(gpa);
    self.destroy_queue.deinit(gpa);
    self.comp_bytes.deinit(gpa);
    self.args.deinit(gpa);
    self.tags.deinit(gpa);
    self.* = undefined;
}

/// Clears the command buffer for reuse.
pub fn clear(self: *@This()) void {
    self.destroy_queue.clearRetainingCapacity();
    self.comp_bytes.clearRetainingCapacity();
    self.args.clearRetainingCapacity();
    self.tags.clearRetainingCapacity();
}

/// Refills the reserved entities buffer to full capacity.
pub fn refillReservedEntities(self: *@This(), es: *Entities) void {
    self.refillReservedEntitiesChecked(es) catch |err|
        @panic(@errorName(err));
}

/// Similar to `refillReservedEntities`, but returns `error.ZcsEntityOverflow` on failure instead of
/// panicking.
pub fn refillReservedEntitiesChecked(self: *@This(), es: *Entities) error{ZcsEntityOverflow}!void {
    while (self.reserved.items.len < self.reserved.capacity) {
        self.reserved.appendAssumeCapacity(try Entity.reserve(es));
    }
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
        usage(self.comp_bytes),
        usage(self.args),
        usage(self.tags),
    );
}

/// Pops a reserved entity from the reserved buffer.
pub fn popReserved(self: *@This()) Entity {
    return self.popReservedChecked() catch |err|
        @panic(@errorName(err));
}

/// Similar to `popReserved`, but returns `error.EntityReserveUnderflow` if there are no more
/// reserved entities instead of panicking.
pub fn popReservedChecked(self: *@This()) error{EntityReserveUnderflow}.Entity {
    return self.reserved.popOrNull() orelse error.EntityReserveUnderflow;
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

/// Similar to `changeArchetype`, but returns `error.ZcsCmdBufOverflow` on failure instead of
/// panicking.
pub fn changeArchetypeChecked(
    self: *@This(),
    es: *const Entities,
    entity: Entity,
    remove: Component.Flags,
    add: anytype,
) error{ZcsCmdBufOverflow}!void {
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

/// Similar to `changeArchetypeFromComponents` but returns `error.ZcsCmdBufOverflow` on failure
/// instead of panicking.
pub fn changeArchetypeFromComponentsChecked(
    self: *@This(),
    es: *const Entities,
    entity: Entity,
    remove: Component.Flags,
    comps: []const Component.Optional,
) error{ZcsCmdBufOverflow}!void {
    const restore = self.*;
    errdefer self.* = restore;

    try self.subCmd(es, .{ .bind_entity = entity });
    if (!remove.eql(.{})) {
        try self.subCmd(es, .{ .remove_components = remove });
    }

    // Issue subcommands to add the listed components. Issued in reverse order, duplicates are
    // skipped.
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

/// Appends an `Entity.destroy` command.
pub fn destroy(self: *@This(), entity: Entity) void {
    self.destroyChecked(entity) catch |err|
        @panic(@errorName(err));
}

/// Similar to `destroy`, but returns `error.ZcsCmdBufOverflow` on failure instead of panicking.
pub fn destroyChecked(self: *@This(), entity: Entity) error{ZcsCmdBufOverflow}!void {
    if (self.destroy_queue.items.len >= self.destroy_queue.capacity) {
        return error.ZcsCmdBufOverflow;
    }
    self.destroy_queue.appendAssumeCapacity(entity);
}

/// Executes the command buffer.
pub fn submit(self: *@This(), es: *Entities) void {
    self.submitChecked(es) catch |err|
        @panic(@errorName(err));
}

/// Similar to `submit`, but returns `error.ZcsEntityOverflow` on failure instead of panicking. On
/// overflow, all work that doesn't trigger an overflow is still completed regardless of order
/// relative to the overflowing work.
pub fn submitChecked(self: *@This(), es: *Entities) error{ZcsEntityOverflow}!void {
    if (!self.submitOrOverflow(es)) return error.ZcsEntityOverflow;
}

/// Submits the command buffer, returns true on success false on overflow. Pulled out into a
/// separate function to avoid accidentally using `try` and returning before processing all
/// commands.
fn submitOrOverflow(self: *@This(), es: *Entities) bool {
    var overflow = false;

    // Submit the commands
    var iter = self.iterator(es);
    while (iter.next()) |cmd| {
        switch (cmd) {
            .change_archetype => |args| {
                if (args.entity.exists(es)) {
                    args.entity.changeArchetypeUnintializedImmediatelyChecked(es, .{
                        .remove = args.remove,
                        .add = args.add,
                    }) catch |err| switch (err) {
                        error.ZcsEntityOverflow => {
                            overflow = true;
                            continue;
                        },
                    };
                    var comps = args.componentIterator();
                    while (comps.next()) |comp| {
                        const src = comp.bytes();
                        const dest = args.entity.getComponentFromId(es, comp.id).?;
                        @memcpy(dest, src);
                    }
                }
            },
            .destroy => |entity| entity.destroyImmediately(es),
        }
    }

    // Return whether or not we overflowed.
    return !overflow;
}

/// If a new worst case command is introduced, also update the tests!
const rename_when_changing_encoding = {};

/// Submits a subcommand. The public facing commands are all build up of one or more subcommands for
/// encoding purposes. When modifying this encoding, keep `initFromCmds` in sync.
fn subCmd(self: *@This(), es: *const Entities, sub_cmd: SubCmd) error{ZcsCmdBufOverflow}!void {
    _ = rename_when_changing_encoding;

    switch (sub_cmd) {
        .bind_entity => |entity| {
            if (self.tags.items.len >= self.tags.capacity) return error.ZcsCmdBufOverflow;
            if (self.args.items.len >= self.args.capacity) return error.ZcsCmdBufOverflow;
            self.tags.appendAssumeCapacity(.bind_entity);
            self.args.appendAssumeCapacity(@bitCast(entity));
        },
        .add_component_val => |comp| {
            const size = es.getComponentSize(comp.id);
            const alignment = es.getComponentAlignment(comp.id);
            const aligned = std.mem.alignForward(usize, self.comp_bytes.items.len, alignment);
            if (self.tags.items.len >= self.tags.capacity) return error.ZcsCmdBufOverflow;
            if (self.args.items.len + 1 > self.args.capacity) return error.ZcsCmdBufOverflow;
            if (aligned + size > self.comp_bytes.capacity) {
                return error.ZcsCmdBufOverflow;
            }
            self.tags.appendAssumeCapacity(.add_component_val);
            self.args.appendAssumeCapacity(@intFromEnum(comp.id));
            const bytes = comp.bytes();
            self.comp_bytes.items.len = aligned;
            self.comp_bytes.appendSliceAssumeCapacity(bytes[0..size]);
        },
        .add_component_ptr => |comp| {
            assert(comp.interned);
            if (self.tags.items.len >= self.tags.capacity) return error.ZcsCmdBufOverflow;
            if (self.args.items.len + 2 > self.args.capacity) return error.ZcsCmdBufOverflow;
            self.tags.appendAssumeCapacity(.add_component_ptr);
            self.args.appendAssumeCapacity(@intFromEnum(comp.id));
            self.args.appendAssumeCapacity(@intFromPtr(comp.ptr));
        },
        .remove_components => |comps| {
            if (self.tags.items.len >= self.tags.capacity) return error.ZcsCmdBufOverflow;
            if (self.args.items.len >= self.args.capacity) return error.ZcsCmdBufOverflow;
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
    /// Destroy the given entity if it exists.
    destroy: Entity,
};

/// Commands are comprised of a sequence of one or more subcommands which are encoded in a compact
/// form in the command buffer.
const SubCmd = union(enum) {
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

    const Tag = @typeInfo(@This()).@"union".tag_type.?;

    const Decoder = struct {
        cb: *const CmdBuf,
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
            const result = self.cb.comp_bytes.items[self.component_bytes_index..].ptr;
            self.component_bytes_index += size;
            return result;
        }
    };
};

/// See `CmdBuf.iterator`.
pub const Iterator = struct {
    destroy_index: usize = 0,
    decoder: SubCmd.Decoder,
    committed: usize = 0,

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
                    return .{ .change_archetype = .{
                        .remove = remove,
                        .add = add,
                        .entity = entity,
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
                .add_component_val => return self.decoder.next().?.add_component_val,
                .add_component_ptr => return self.decoder.next().?.add_component_ptr,
                .remove_components => _ = self.decoder.next().?.remove_components,
                .bind_entity => break,
            }
        }
        return null;
    }
};

/// Per buffer capacity.
pub const Capacities = struct {
    tags: usize,
    args: usize,
    comp_bytes: usize,
    destroy: usize,
    reserved: usize,

    /// Sets each buffer capacity to be at least enough for the given number of commands.
    pub fn initFromCmds(es: *const Entities, cmds: usize) Capacities {
        _ = rename_when_changing_encoding;

        // Worst case component data size. Technically we could make this slightly tighter since
        // alignment must be a power of two, but this calculation is much simpler.
        var comp_bytes_cap: usize = 0;
        for (0..es.comp_types.count()) |i| {
            const id: Component.Id = @enumFromInt(i);
            comp_bytes_cap += es.getComponentSize(id);
            comp_bytes_cap += es.getComponentAlignment(id) - 1;
        }
        comp_bytes_cap *= cmds;

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

        // The most creates we could do is the number of commands.
        const reserved_cap = cmds;

        return .{
            .tags = tags_cap,
            .args = args_cap,
            .comp_bytes = comp_bytes_cap,
            .destroy = destroy_cap,
            .reserved = reserved_cap,
        };
    }
};
