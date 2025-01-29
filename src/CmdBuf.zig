//! Buffers ECS commands for later execution.
//!
//! This allows queuing destructive operations while iterating, or from multiple threads safely by
//! assigning each thread its own command buffer. All commands are noops if the entity in question
//! is destroyed before the time of execution.
//!
//! `CmdBuf` allocates at init time, and then never again. It should be cleared and reused when
//! possible.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const zcs = @import("root.zig");
const types = @import("types.zig");
const CompFlag = types.CompFlag;
const Entities = zcs.Entities;
const Entity = zcs.Entity;
const Comp = zcs.Comp;

const SubCmd = @import("CmdBuf/sub_cmd.zig").SubCmd;

pub const ArchetypeChanges = @import("CmdBuf/ArchetypeChanges.zig");

/// Entities queued for destruction.
destroy: std.ArrayListUnmanaged(Entity),
/// Archetype changes queued for execution.
archetype_changes: ArchetypeChanges,
/// Reserved entities.
reserved: std.ArrayListUnmanaged(Entity),

/// Initializes a command buffer.
pub fn init(
    gpa: Allocator,
    es: *Entities,
    capacity: Capacity,
) error{ OutOfMemory, ZcsEntityOverflow }!@This() {
    return initGranularCapacity(gpa, es, .init(capacity));
}

/// Similar to `init`, but allows you to specify capacity with more granularity. Prefer `init`.
pub fn initGranularCapacity(
    gpa: Allocator,
    es: *Entities,
    capacity: GranularCapacity,
) error{ OutOfMemory, ZcsEntityOverflow }!@This() {
    comptime assert(CompFlag.max < std.math.maxInt(u64));

    var tags: std.ArrayListUnmanaged(SubCmd.Tag) = try .initCapacity(gpa, capacity.tags);
    errdefer tags.deinit(gpa);

    var args: std.ArrayListUnmanaged(u64) = try .initCapacity(gpa, capacity.args);
    errdefer args.deinit(gpa);

    var comp_bytes: std.ArrayListAlignedUnmanaged(u8, Comp.max_align) = try .initCapacity(
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
        .archetype_changes = .{
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
    self.archetype_changes.comp_bytes.deinit(gpa);
    self.archetype_changes.args.deinit(gpa);
    self.archetype_changes.tags.deinit(gpa);
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
    self.archetype_changes.comp_bytes.clearRetainingCapacity();
    self.archetype_changes.args.clearRetainingCapacity();
    self.archetype_changes.tags.clearRetainingCapacity();
    self.archetype_changes.bound = .none;
    while (self.reserved.items.len < self.reserved.capacity) {
        self.reserved.appendAssumeCapacity(try Entity.reserveImmediatelyChecked(es));
    }
}

/// Returns the ratio of length to capacity for the internal buffer that is the nearest to being
/// full.
pub fn worstCaseUsage(self: @This()) f32 {
    return @max(
        usage(self.destroy),
        usage(self.archetype_changes.comp_bytes),
        usage(self.archetype_changes.args),
        usage(self.archetype_changes.tags),
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
    var changes = self.archetype_changes.iterator(es);
    while (changes.next()) |change| {
        if (change.entity.exists(es)) {
            var add: CompFlag.Set = .{};
            var remove: CompFlag.Set = .{};

            {
                var ops = change.iterator();
                while (ops.next()) |op| {
                    switch (op) {
                        .remove => |id| if (id.flag) |flag| {
                            add.remove(flag);
                            remove.insert(flag);
                        },
                        .add => |comp| {
                            const flag = types.register(comp.id);
                            add.insert(flag);
                            remove.remove(flag);
                        },
                    }
                }

                change.entity.changeArchetypeUninitializedImmediatelyChecked(es, .{
                    .add = add,
                    .remove = remove,
                }) catch |err| switch (err) {
                    error.ZcsEntityOverflow => {
                        overflow = true;
                        continue;
                    },
                };
            }

            {
                var ops = change.iterator();
                while (ops.next()) |op| {
                    switch (op) {
                        .add => |comp| if (change.entity.getCompFromId(es, comp.id)) |dest| {
                            @memcpy(dest, comp.bytes());
                        },
                        .remove => {},
                    }
                }
            }
        }
    }

    // Return whether or not we overflowed.
    return !overflow;
}

/// Worst case capacity for a command buffer.
pub const Capacity = struct {
    /// Space for at least this many commands will be reserved.
    cmds: usize,
    /// Space for an average of at least this many bytes per component will be reserved.
    comp_bytes: usize,
};

/// Per buffer capacity. Prefer `Capacity`.
pub const GranularCapacity = struct {
    tags: usize,
    args: usize,
    comp_bytes: usize,
    destroy: usize,
    reserved: usize,

    /// Estimates the granular capacity from worst case capacity.
    pub fn init(cap: Capacity) @This() {
        _ = SubCmd.rename_when_changing_encoding;

        // Each command can have at most one component's worth of component data.
        const comp_bytes_cap = (cap.comp_bytes + Comp.max_align) * cap.cmds;

        // The command with the most subcommands is change archetype
        var change_archetype_tags: usize = 0;
        change_archetype_tags += 1; // Bind
        change_archetype_tags += 1; // Remove components
        change_archetype_tags += 1; // Add component
        const tags_cap = change_archetype_tags * cap.cmds;

        // The command with the most args is change archetype with by pointer components
        var change_archetype_args: usize = 0;
        change_archetype_args += 1; // Bind
        change_archetype_args += 2; // comps * (id + ptr)
        const args_cap = change_archetype_args * cap.cmds;

        // The most destroys we could do is the number of commands.
        const destroy_cap = cap.cmds;

        // The most creates we could do is the number of commands.
        const reserved_cap = cap.cmds;

        return .{
            .tags = tags_cap,
            .args = args_cap,
            .comp_bytes = comp_bytes_cap,
            .destroy = destroy_cap,
            .reserved = reserved_cap,
        };
    }
};
