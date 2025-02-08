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
const Entities = zcs.Entities;
const Entity = zcs.Entity;
const Any = zcs.Any;
const TypeId = zcs.TypeId;
const CompFlag = zcs.CompFlag;

const CmdBuf = @This();
const SubCmd = @import("CmdBuf/sub_cmd.zig").SubCmd;

tags: std.ArrayListUnmanaged(SubCmd.Tag),
args: std.ArrayListUnmanaged(u64),
any_bytes: std.ArrayListAlignedUnmanaged(u8, zcs.TypeInfo.max_align),
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

    var any_bytes: std.ArrayListAlignedUnmanaged(u8, zcs.TypeInfo.max_align) = try .initCapacity(
        gpa,
        capacity.any_bytes,
    );
    errdefer any_bytes.deinit(gpa);

    var reserved: std.ArrayListUnmanaged(Entity) = try .initCapacity(gpa, capacity.reserved);
    errdefer reserved.deinit(gpa);
    for (0..reserved.capacity) |_| {
        reserved.appendAssumeCapacity(try Entity.reserveImmediateOrErr(es));
    }

    return .{
        .reserved = reserved,
        .tags = tags,
        .args = args,
        .any_bytes = any_bytes,
    };
}

/// Destroys the command buffer.
pub fn deinit(self: *@This(), gpa: Allocator, es: *Entities) void {
    for (self.reserved.items) |entity| assert(entity.destroyImmediate(es));
    self.reserved.deinit(gpa);
    self.any_bytes.deinit(gpa);
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
    self.any_bytes.clearRetainingCapacity();
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
        usage(self.any_bytes),
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

/// Similar to `execute`, but returns `error.ZcsEntityOverflow` on failure instead of panicking. On
/// error, the command buffer will be partially executed.
pub fn executeOrErr(self: *@This(), es: *Entities) error{ZcsCompOverflow}!void {
    var cmds = self.iterator();
    while (cmds.next()) |cmd| {
        _ = try cmd.executeOrErr(es);
    }
}

/// Worst case capacity for a command buffer.
pub const Capacity = struct {
    /// Space for at least this many commands will be reserved.
    cmds: usize,
    /// Space for an average of at least this many bytes per `Any` will be reserved.
    avg_any_bytes: usize,
};

/// Per buffer capacity. Prefer `Capacity`.
pub const GranularCapacity = struct {
    tags: usize,
    args: usize,
    any_bytes: usize,
    reserved: usize,

    /// Estimates the granular capacity from worst case capacity.
    pub fn init(cap: Capacity) @This() {
        _ = SubCmd.rename_when_changing_encoding;

        // Each command can have at most one component's worth of component data.
        const comp_bytes_cap = (cap.avg_any_bytes + zcs.TypeInfo.max_align) * cap.cmds;

        // Each command can have at most two tags
        const tags_cap = cap.cmds * 2;

        // Each command can have at most 3 args (the add ptr subcommand does a bind which has one
        // arg if it's not skipped, and then it also passes the component ID and pointer as args as
        // well.
        const args_cap = cap.cmds * 3;

        // The most creates we could do is the number of commands.
        const reserved_cap = cap.cmds;

        return .{
            .tags = tags_cap,
            .args = args_cap,
            .any_bytes = comp_bytes_cap,
            .reserved = reserved_cap,
        };
    }
};

/// A single decoded command.
pub const Cmd = struct {
    /// The bound entity.
    entity: Entity,
    decoder: SubCmd.Decoder,
    add: CompFlag.Set,
    remove: CompFlag.Set,
    destroy: bool,

    /// An iterator over the operations that make up this command.
    pub fn iterator(self: @This()) @This().Iterator {
        return .{
            .decoder = self.decoder,
        };
    }

    /// Executes the change archetype command.
    pub fn execute(self: @This(), es: *Entities) void {
        self.executeOrErr(es) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `execute`, but returns `error.ZcsCompOverflow` on overflow instead of
    /// panicking.
    pub fn executeOrErr(self: @This(), es: *Entities) error{ZcsCompOverflow}!void {
        // If the entity is set for destruction, destroy it and early out
        if (self.destroy) {
            _ = self.entity.destroyImmediate(es);
            return;
        }

        // Otherwise issue the change archetype command.  If no changes were requested, this will
        // still commit the entity.
        if (try self.entity.changeArchUninitImmediateOrErr(es, .{
            .add = self.add,
            .remove = self.remove,
        })) {
            // Iterate over the ops and add the added components, unless they were subsequently
            // removed
            var ops = self.iterator();
            while (ops.next()) |op| {
                switch (op) {
                    .add => |comp| if (self.entity.getCompFromId(es, comp.id)) |dest| {
                        @memcpy(dest, comp.bytes());
                    },
                    .remove => {},
                }
            }
        }
    }

    /// An individual operation that's part of an archetype change.
    pub const Op = union(enum) {
        add: Any,
        remove: TypeId,
    };

    /// An iterator over the archetype change operations.
    pub const Iterator = struct {
        decoder: SubCmd.Decoder,

        /// Returns the next operation, or `null` if there are none.
        pub fn next(self: *@This()) ?Op {
            while (self.decoder.peekTag()) |tag| {
                // Get the next operation
                const op: Op = switch (tag) {
                    .add_comp_val => .{ .add = self.decoder.next().?.add_comp_val },
                    .add_comp_ptr => .{ .add = self.decoder.next().?.add_comp_ptr },
                    .remove_comp => .{ .remove = self.decoder.next().?.remove_comp },
                    .bind_entity, .destroy_entity => break,
                };

                // Return the operation.
                return op;
            }
            return null;
        }
    };
};

/// An iterator over the encoded commands.
pub const Iterator = struct {
    decoder: SubCmd.Decoder,

    /// Returns the next command, or `null` if there is none.
    pub fn next(self: *@This()) ?Cmd {
        _ = SubCmd.rename_when_changing_encoding;

        // We just return bind operations here, `Cmd` handles the add/remove commands. If the first
        // bind is `.none` it's elided, and we end up skipping the initial add/removes, but that's
        // fine since adding/removing to `.none` is a noop anyway.
        while (self.decoder.next()) |subcmd| {
            switch (subcmd) {
                .destroy_entity => |entity| return .{
                    .entity = entity,
                    .destroy = true,
                    .decoder = self.decoder,
                    .add = .{},
                    .remove = .{},
                },
                .bind_entity => |entity| {
                    // Save the encoder state for the command
                    const op_decoder = self.decoder;

                    // Read the add/remove commands preemptively, this makes for a nicer API since
                    // in practice we're always going to read them at least once. This doesn't add
                    // an extra pass since we would already need to do one pass to gather the set
                    // and one to get the component data.
                    var ops: Cmd.Iterator = .{ .decoder = self.decoder };
                    var add: CompFlag.Set = .{};
                    var remove: CompFlag.Set = .{};
                    while (ops.next()) |op| {
                        switch (op) {
                            .remove => |id| if (id.comp_flag) |flag| {
                                add.remove(flag);
                                remove.insert(flag);
                            },
                            .add => |comp| {
                                const flag = CompFlag.registerImmediate(comp.id);
                                add.insert(flag);
                                remove.remove(flag);
                            },
                        }
                    }

                    // Fast-forward our decoder past the add/remove commands
                    self.decoder = ops.decoder;

                    // Return the archetype change command
                    return .{
                        .entity = entity,
                        .decoder = op_decoder,
                        .add = add,
                        .remove = remove,
                        .destroy = false,
                    };
                },
                .add_comp_ptr, .add_comp_val, .remove_comp => {
                    // The API doesn't allow encoding these commands without an entity bound
                    unreachable;
                },
            }
        }

        return null;
    }
};
