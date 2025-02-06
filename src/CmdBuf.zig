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

destroy: std.ArrayListUnmanaged(Entity),
tags: std.ArrayListUnmanaged(SubCmd.Tag),
args: std.ArrayListUnmanaged(u64),
comp_bytes: std.ArrayListAlignedUnmanaged(u8, Comp.max_align),
bound: Entity.Optional = .none,
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
        reserved.appendAssumeCapacity(try Entity.reserveImmediateOrErr(es));
    }

    return .{
        .destroy = destroy,
        .reserved = reserved,
        .tags = tags,
        .args = args,
        .comp_bytes = comp_bytes,
    };
}

/// Destroys the command buffer.
pub fn deinit(self: *@This(), gpa: Allocator, es: *Entities) void {
    for (self.reserved.items) |entity| entity.destroyImmediate(es);
    self.reserved.deinit(gpa);
    self.destroy.deinit(gpa);
    self.comp_bytes.deinit(gpa);
    self.args.deinit(gpa);
    self.tags.deinit(gpa);
    self.* = undefined;
}

/// Clears the command buffer for reuse. Refills the reserved entity list to capacity.
pub fn clear(self: *@This(), es: *Entities) void {
    self.clearOrErr(es) catch |err|
        @panic(@errorName(err));
}

/// Similar to `clear`, but returns `error.ZcsEntityOverflow` when failing to refill the reserved
/// entity list instead of panicking.
pub fn clearOrErr(self: *@This(), es: *Entities) error{ZcsEntityOverflow}!void {
    self.destroy.clearRetainingCapacity();
    self.comp_bytes.clearRetainingCapacity();
    self.args.clearRetainingCapacity();
    self.tags.clearRetainingCapacity();
    self.bound = .none;
    while (self.reserved.items.len < self.reserved.capacity) {
        self.reserved.appendAssumeCapacity(try Entity.reserveImmediateOrErr(es));
    }
}

/// Returns the ratio of length to capacity for the internal buffer that is the nearest to being
/// full.
pub fn worstCaseUsage(self: @This()) f32 {
    const reserved_used: f32 = @floatFromInt(self.reserved.capacity - self.reserved.items.len);
    const reserved_usage = if (self.reserved.capacity == 0)
        0.0
    else
        reserved_used / @as(f32, @floatFromInt(self.reserved.capacity));
    return @max(
        usage(self.destroy),
        usage(self.comp_bytes),
        usage(self.args),
        usage(self.tags),
        reserved_usage,
    );
}

/// Calculates the usage of a list as a ratio.
fn usage(list: anytype) f32 {
    if (list.capacity == 0) return 1.0;
    return @as(f32, @floatFromInt(list.items.len)) / @as(f32, @floatFromInt(list.capacity));
}

/// Returns an iterator over the encoded commands.
pub fn iterator(self: *const @This()) Iterator {
    return .{ .decoder = .{ .cmds = self } };
}

/// Executes the command buffer.
pub fn execute(self: *@This(), es: *Entities) void {
    self.executeOrErr(es) catch |err|
        @panic(@errorName(err));
}

/// Similar to `execute`, but returns `error.ZcsEntityOverflow` on failure instead of panicking.
///
/// On overflow, all work that doesn't trigger an overflow is still completed regardless of order
/// relative to the overflowing work.
pub fn executeOrErr(self: *@This(), es: *Entities) error{ZcsCompOverflow}!void {
    if (!self.executeOrOverflow(es)) return error.ZcsCompOverflow;
}

/// Submits the command buffer, returns true on success false on overflow. Pulled out into a
/// separate function to avoid accidentally using `try` and returning before processing all
/// commands.
fn executeOrOverflow(self: *@This(), es: *Entities) bool {
    var overflow = false;

    // Execute the destroys first since they might make some of the archetype changes redundant
    for (self.destroy.items) |entity| {
        entity.destroyImmediate(es);
    }

    // Execute the archetype changes
    var changes = self.iterator();
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

                _ = change.entity.changeArchUninitImmediateOrErr(es, .{
                    .add = add,
                    .remove = remove,
                }) catch |err| switch (err) {
                    error.ZcsCompOverflow => {
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

    // Return whether or not we overflowed
    return !overflow;
}

/// Worst case capacity for a command buffer.
pub const Capacity = struct {
    /// Space for at least this many commands will be reserved.
    cmds: usize,
    /// Space for an average of at least this many bytes per component will be reserved.
    avg_comp_bytes: usize,
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
        const comp_bytes_cap = (cap.avg_comp_bytes + Comp.max_align) * cap.cmds;

        // Each command can have at most two tags
        const tags_cap = cap.cmds * 2;

        // Each command can have at most 3 args (the add ptr subcommand does a bind which has one
        // arg if it's not skipped, and then it also passes the component ID and pointer as args as
        // well.
        const args_cap = cap.cmds * 3;

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

/// An individual operation that's part of an archetype change.
pub const ArchChangeOp = union(enum) {
    add: Comp,
    remove: Comp.Id,
};

/// A single command, encoded as a sequence of archetype change operations. Change operations are
/// grouped per entity for efficient execution.
pub const Cmd = struct {
    /// The bound entity.
    entity: Entity,
    decoder: SubCmd.Decoder,
    parent: *Iterator,

    /// An iterator over the operations that make up this archetype change.
    pub fn iterator(self: @This()) ArchChangeOpIterator {
        return .{
            .decoder = self.decoder,
            .parent = self.parent,
        };
    }
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
pub const ArchChangeOpIterator = struct {
    decoder: SubCmd.Decoder,
    parent: *Iterator,

    /// Returns the next operation, or `null` if there are none.
    pub fn next(self: *@This()) ?ArchChangeOp {
        while (self.decoder.peekTag()) |tag| {
            // Get the next operation
            const op: ArchChangeOp = switch (tag) {
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
