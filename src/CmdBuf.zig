//! Buffers ECS commands for later execution.
//!
//! This allows queuing destructive operations while iterating, or from multiple threads safely. All
//! commands are noops if the entity in question is destroyed before the time of execution.
//!
//! `CmdBuf` alloctes at init time, and then never again. It should be cleared and reused when
//! possible.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const zcs = @import("root.zig");
const Entities = zcs.Entities;
const Entity = zcs.Entity;
const Component = zcs.Component;

const SubCmd = @import("CmdBuf/sub_cmd.zig").SubCmd;

pub const ChangeArchetypes = @import("CmdBuf/ChangeArchetypes.zig");

/// Entities queued for destruction.
destroy: std.ArrayListUnmanaged(Entity),
/// Archetype changes queued for execution.
change_archetype: ChangeArchetypes,
/// Reserved entities.
reserved: std.ArrayListUnmanaged(Entity),

/// Initializes a command buffer.
pub fn init(
    gpa: Allocator,
    es: *Entities,
    capacity: usize,
) error{ OutOfMemory, ZcsEntityOverflow }!@This() {
    return initGranularCapacity(gpa, es, .init(es, capacity));
}

/// Similar to `init`, but allows you to specify capacity with more granularity. Prefer `init`.
pub fn initGranularCapacity(
    gpa: Allocator,
    es: *Entities,
    capacity: Capacity,
) error{ OutOfMemory, ZcsEntityOverflow }!@This() {
    comptime assert(Component.Id.max < std.math.maxInt(u64));

    var tags: std.ArrayListUnmanaged(SubCmd.Tag) = try .initCapacity(gpa, capacity.tags);
    errdefer tags.deinit(gpa);

    var args: std.ArrayListUnmanaged(u64) = try .initCapacity(gpa, capacity.args);
    errdefer args.deinit(gpa);

    var comp_bytes: std.ArrayListAlignedUnmanaged(u8, Entities.max_align) = try .initCapacity(
        gpa,
        capacity.comp_bytes,
    );
    errdefer comp_bytes.deinit(gpa);

    var destroy: std.ArrayListUnmanaged(Entity) = try .initCapacity(gpa, capacity.destroy);
    errdefer destroy.deinit(gpa);

    var reserved: std.ArrayListUnmanaged(Entity) = try .initCapacity(gpa, capacity.reserved);
    errdefer reserved.deinit(gpa);
    for (0..reserved.capacity) |_| {
        reserved.appendAssumeCapacity(try Entity.reserveImmediatelyChecked(es));
    }

    return .{
        .destroy = destroy,
        .reserved = reserved,
        .change_archetype = .{
            .tags = tags,
            .args = args,
            .comp_bytes = comp_bytes,
        },
    };
}

/// Destroys the command buffer.
pub fn deinit(self: *@This(), gpa: Allocator, es: *Entities) void {
    for (self.reserved.items) |entity| entity.destroyImmediately(es);
    self.reserved.deinit(gpa);
    self.destroy.deinit(gpa);
    self.change_archetype.comp_bytes.deinit(gpa);
    self.change_archetype.args.deinit(gpa);
    self.change_archetype.tags.deinit(gpa);
    self.* = undefined;
}

/// Clears the command buffer for reuse. Refills the reserved entity list to capacity.
pub fn clear(self: *@This(), es: *Entities) void {
    self.clearChecked(es) catch |err|
        @panic(@errorName(err));
}

/// Similar to `clear`, but returns `error.ZcsEntityOverflow` when failing to refill the reserved
/// entity list instead of panicking.
pub fn clearChecked(self: *@This(), es: *Entities) error{ZcsEntityOverflow}!void {
    self.destroy.clearRetainingCapacity();
    self.change_archetype.comp_bytes.clearRetainingCapacity();
    self.change_archetype.args.clearRetainingCapacity();
    self.change_archetype.tags.clearRetainingCapacity();
    while (self.reserved.items.len < self.reserved.capacity) {
        self.reserved.appendAssumeCapacity(try Entity.reserveImmediatelyChecked(es));
    }
}

/// Returns the ratio of length to capacity for the internal buffer that is the nearest to being
/// full.
pub fn worstCaseUsage(self: @This()) f32 {
    return @max(
        usage(self.destroy),
        usage(self.change_archetype.comp_bytes),
        usage(self.change_archetype.args),
        usage(self.change_archetype.tags),
    );
}

/// Calculates the usage of a list as a ratio.
fn usage(list: anytype) f32 {
    if (list.capacity == 0) return 1.0;
    return @as(f32, @floatFromInt(list.items.len)) / @as(f32, @floatFromInt(list.capacity));
}

/// Executes the command buffer.
pub fn execute(self: *@This(), es: *Entities) void {
    self.executeChecked(es) catch |err|
        @panic(@errorName(err));
}

/// Similar to `execute`, but returns `error.ZcsEntityOverflow` on failure instead of panicking.
///
/// On overflow, all work that doesn't trigger an overflow is still completed regardless of order
/// relative to the overflowing work.
pub fn executeChecked(self: *@This(), es: *Entities) error{ZcsEntityOverflow}!void {
    if (!self.executeOrOverflow(es)) return error.ZcsEntityOverflow;
}

/// Submits the command buffer, returns true on success false on overflow. Pulled out into a
/// separate function to avoid accidentally using `try` and returning before processing all
/// commands.
fn executeOrOverflow(self: *@This(), es: *Entities) bool {
    var overflow = false;

    // Execute the destroys first since they might make some of the archetype changes redundant
    for (self.destroy.items) |entity| {
        entity.destroyImmediately(es);
    }

    // Execute the archetype changes
    var iter = self.change_archetype.iterator(es);
    while (iter.next()) |change| {
        if (change.entity.exists(es)) {
            change.entity.changeArchetypeUninitializedImmediatelyChecked(es, .{
                .remove = change.remove,
                .add = change.add,
            }) catch |err| switch (err) {
                error.ZcsEntityOverflow => {
                    overflow = true;
                    continue;
                },
            };
            var comps = change.componentIterator();
            while (comps.next()) |comp| {
                const src = comp.bytes();
                const dest = change.entity.getComponentFromId(es, comp.id).?;
                @memcpy(dest, src);
            }
        }
    }

    // Return whether or not we overflowed.
    return !overflow;
}

/// Per buffer capacity. Prefer `CmdBuf.init`.
pub const Capacity = struct {
    tags: usize,
    args: usize,
    comp_bytes: usize,
    destroy: usize,
    reserved: usize,

    /// Sets each buffer capacity to be at least enough for the given number of commands.
    pub fn init(es: *const Entities, cmds: usize) Capacity {
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
