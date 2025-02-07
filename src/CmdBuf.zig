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

const CmdBuf = @This();
const SubCmd = @import("CmdBuf/sub_cmd.zig").SubCmd;

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

    var reserved: std.ArrayListUnmanaged(Entity) = try .initCapacity(gpa, capacity.reserved);
    errdefer reserved.deinit(gpa);
    for (0..reserved.capacity) |_| {
        reserved.appendAssumeCapacity(try Entity.reserveImmediateOrErr(es));
    }

    return .{
        .reserved = reserved,
        .tags = tags,
        .args = args,
        .comp_bytes = comp_bytes,
    };
}

/// Destroys the command buffer.
pub fn deinit(self: *@This(), gpa: Allocator, es: *Entities) void {
    for (self.reserved.items) |entity| assert(entity.destroyImmediate(es));
    self.reserved.deinit(gpa);
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
    /// Space for an average of at least this many bytes per component will be reserved.
    avg_comp_bytes: usize,
};

/// Per buffer capacity. Prefer `Capacity`.
pub const GranularCapacity = struct {
    tags: usize,
    args: usize,
    comp_bytes: usize,
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

        // The most creates we could do is the number of commands.
        const reserved_cap = cap.cmds;

        return .{
            .tags = tags_cap,
            .args = args_cap,
            .comp_bytes = comp_bytes_cap,
            .reserved = reserved_cap,
        };
    }
};

/// A single decoded command.
pub const Cmd = union(enum) {
    change_arch: ChangeArch,
    destroy: Entity,

    /// Executes the command. Returns true if the command executes, false if the entity does not
    /// exist.
    pub fn execute(self: @This(), es: *Entities) bool {
        return self.executeOrErr(es) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `execute`, but returns `error.ZcsCompOverflow` on overflow instead of panicking.
    pub fn executeOrErr(self: @This(), es: *Entities) error{ZcsCompOverflow}!bool {
        switch (self) {
            .change_arch => |change_arch| return change_arch.executeOrErr(es),
            .destroy => |entity| return entity.destroyImmediate(es),
        }
    }

    /// A single archetype change command, encoded as a sequence of archetype change operations.
    /// Change operations are grouped per entity for efficient execution.
    pub const ChangeArch = struct {
        /// The bound entity.
        entity: Entity,
        decoder: SubCmd.Decoder,
        parent: *CmdBuf.Iterator,

        /// An iterator over the operations that make up this archetype change.
        pub fn iterator(self: @This()) @This().Iterator {
            return .{
                .decoder = self.decoder,
                .parent = self.parent,
            };
        }

        /// Executes the change archetype command. Returns true if the change was made, false if the
        /// entity does not exist.
        pub fn execute(self: @This(), es: *Entities) bool {
            self.executeOrErr(es) catch |err|
                @panic(@errorName(err));
        }

        /// Similar to `execute`, but returns `error.ZcsCompOverflow` on overflow instead of
        /// panicking.
        pub fn executeOrErr(self: @This(), es: *Entities) error{ZcsCompOverflow}!bool {
            // Figure out which components we need to add/remove
            var add: CompFlag.Set = .{};
            var remove: CompFlag.Set = .{};
            {
                var ops = self.iterator();
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
            }

            // Change the archetype without initializing the components, early out if it doesn't
            // exist
            {
                const exists = try self.entity.changeArchUninitImmediateOrErr(es, .{
                    .add = add,
                    .remove = remove,
                });
                if (!exists) return false;
            }

            // Initialize the components and return success
            {
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

            return true;
        }

        /// An individual operation that's part of an archetype change.
        pub const Op = union(enum) {
            add: Comp,
            remove: Comp.Id,
        };

        /// An iterator over the archetype change operations.
        pub const Iterator = struct {
            decoder: SubCmd.Decoder,
            parent: *CmdBuf.Iterator,

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
                .destroy_entity => |entity| return .{ .destroy = entity },
                .bind_entity => |entity| return .{ .change_arch = .{
                    .entity = entity,
                    .decoder = self.decoder,
                    .parent = self,
                } },
                else => {},
            }
        }

        return null;
    }
};
