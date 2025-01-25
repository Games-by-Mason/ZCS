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
//! var cmds = try CmdBuf.init(gpa, &es, 4);
//! defer cmds.deinit(gpa);
//!
//! cmds.changeArchetype(&es, es.reserve(), Component.flags(&es, &.{Fire}), .{ Hammer{} });
//! cmds.execute(&es);
//! cmds.destroy(entity1);
//! cmds.clear();
//! ```

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const zcs = @import("root.zig");
const Entities = zcs.Entities;
const Entity = zcs.Entity;
const Component = zcs.Component;

const SubCmd = @import("CmdBuf/sub_cmd.zig").SubCmd;

const CmdBuf = @This();

tags: std.ArrayListUnmanaged(SubCmd.Tag),
args: std.ArrayListUnmanaged(u64),
comp_bytes: std.ArrayListAlignedUnmanaged(u8, Entities.max_align),
/// All entities queued for destruction.
destroy_queue: std.ArrayListUnmanaged(Entity),
reserved: std.ArrayListUnmanaged(Entity),

/// Similar to `init`, but also reserves enough entities to satisfy `capacity`.
pub fn init(
    gpa: Allocator,
    es: *Entities,
    capacity: usize,
) error{ OutOfMemory, ZcsEntityOverflow }!@This() {
    return initSeparateCapacities(gpa, es, .initFromCmds(es, capacity));
}

/// Initializes a command buffer with at least enough capacity for the given number of commands.
///
/// The reserved entity buffer's capacity is set to zero.
pub fn initNoReserve(gpa: Allocator, es: *Entities, capacity: usize) Allocator.Error!@This() {
    var capacities: Capacities = .initFromCmds(es, capacity);
    capacities.reserved = 0;
    return initSeparateCapacities(gpa, es, capacities) catch |err| switch (err) {
        error.ZcsEntityOverflow => unreachable, // We set reserve cap to 0, so it can't fail
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Similar to `init` and `init`, but allows you to specify each buffer size
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
        reserved.appendAssumeCapacity(try Entity.reserveImmediatelyChecked(es));
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

pub fn clear(self: *@This(), es: *Entities) void {
    self.clearChecked(es) catch |err|
        @panic(@errorName(err));
}

pub fn clearChecked(self: *@This(), es: *Entities) error{ZcsEntityOverflow}!void {
    self.clearWithoutRefill();
    try self.refillReservedEntitiesChecked(es);
}

/// Clears the command buffer for reuse.
pub fn clearWithoutRefill(self: *@This()) void {
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
        self.reserved.appendAssumeCapacity(try Entity.reserveImmediatelyChecked(es));
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

/// Executes the command buffer.
pub fn execute(self: *@This(), es: *Entities) void {
    self.executeChecked(es) catch |err|
        @panic(@errorName(err));
}

/// Similar to `execute`, but returns `error.ZcsEntityOverflow` on failure instead of panicking. On
/// overflow, all work that doesn't trigger an overflow is still completed regardless of order
/// relative to the overflowing work.
pub fn executeChecked(self: *@This(), es: *Entities) error{ZcsEntityOverflow}!void {
    if (!self.executeOrOverflow(es)) return error.ZcsEntityOverflow;
}

/// Submits the command buffer, returns true on success false on overflow. Pulled out into a
/// separate function to avoid accidentally using `try` and returning before processing all
/// commands.
fn executeOrOverflow(self: *@This(), es: *Entities) bool {
    var overflow = false;

    // execute the commands
    var iter = self.iterator(es);
    while (iter.next()) |cmd| {
        switch (cmd) {
            .change_archetype => |args| {
                if (args.entity.exists(es)) {
                    args.entity.changeArchetypeUninitializedImmediatelyChecked(es, .{
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

/// Returns an iterator over the commands in this command buffer. Iteration order is implementation
/// defined but guaranteed to provide the same result as the order the commands were issued.
pub fn iterator(self: *const @This(), es: *const Entities) Iterator {
    return .{ .decoder = .{
        .cmds = self,
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
        if (self.destroy_index < self.decoder.cmds.destroy_queue.items.len) {
            const entity = self.decoder.cmds.destroy_queue.items[self.destroy_index];
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
        _ = SubCmd.rename_when_changing_encoding;

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
