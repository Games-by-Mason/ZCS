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

const meta = @import("meta.zig");

const zcs = @import("root.zig");
const Entities = zcs.Entities;
const Entity = zcs.Entity;
const Any = zcs.Any;
const TypeId = zcs.TypeId;
const CompFlag = zcs.CompFlag;

const CmdBuf = @This();
const Subcmd = @import("subcmd.zig").Subcmd;

const Binding = struct {
    pub const none: @This() = .{ .entity = .none };
    entity: Entity.Optional = .none,
    destroyed: bool = false,
};

tags: std.ArrayListUnmanaged(Subcmd.Tag),
args: std.ArrayListUnmanaged(u64),
any_bytes: std.ArrayListAlignedUnmanaged(u8, zcs.TypeInfo.max_align),
binding: Binding = .{ .entity = .none },
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

    var tags: std.ArrayListUnmanaged(Subcmd.Tag) = try .initCapacity(gpa, capacity.tags);
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

/// Appends an extension command to the buffer.
///
/// See notes on `Entity.add` with regards to performance and pass by value vs pointer.
pub inline fn ext(self: *@This(), T: type, payload: T) void {
    // Don't get tempted to remove inline from here! It's required for `isComptimeKnown`.
    comptime assert(@typeInfo(@TypeOf(ext)).@"fn".calling_convention == .@"inline");
    self.extOrErr(T, payload) catch |err|
        @panic(@errorName(err));
}

/// Similar to `ext`, but returns an error on failure instead of panicking.
pub inline fn extOrErr(self: *@This(), T: type, payload: T) error{ZcsCmdBufOverflow}!void {
    // Don't get tempted to remove inline from here! It's required for `isComptimeKnown`.
    comptime assert(@typeInfo(@TypeOf(extOrErr)).@"fn".calling_convention == .@"inline");
    if (@sizeOf(T) > @sizeOf(*T) and meta.isComptimeKnown(payload)) {
        const Interned = struct {
            const value = payload;
        };
        try self.extAnyPtr(.init(T, comptime &Interned.value));
    } else {
        try self.extAnyVal(.init(T, &payload));
    }
}

/// Similar to `extOrErr`, but doesn't require compile time types and forces the command to be
/// copied by value to the command buffer. Prefer `ext`.
pub fn extAnyVal(self: *@This(), payload: Any) error{ZcsCmdBufOverflow}!void {
    try Subcmd.encode(self, .{ .ext_val = payload });
}

/// Similar to `extOrErr`, but doesn't require compile time types and forces the command to be
/// copied by pointer to the command buffer. Prefer `ext`.
pub fn extAnyPtr(self: *@This(), payload: Any) error{ZcsCmdBufOverflow}!void {
    try Subcmd.encode(self, .{ .ext_ptr = payload });
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
    self.binding = .none;
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
    return .{ .decoder = .{ .cb = self } };
}

/// Executes the command buffer.
pub fn execImmediate(self: *@This(), es: *Entities) void {
    self.execImmediateOrErr(es) catch |err|
        @panic(@errorName(err));
}

/// Similar to `execImmediate`, but returns an error on failure instead of panicking. On error, the
/// command buffer will be partially executed.
pub fn execImmediateOrErr(
    self: *@This(),
    es: *Entities,
) error{ ZcsCompOverflow, ZcsArchOverflow, ZcsChunkOverflow }!void {
    var iter = self.iterator();
    while (iter.next()) |batch| {
        switch (batch) {
            .arch_change => |arch_change| {
                const delta = arch_change.deltaImmediate();
                _ = try arch_change.execImmediateOrErr(es, delta);
            },
            .ext => {},
        }
    }
}

/// Worst case capacity for a command buffer.
pub const Capacity = struct {
    /// Space for at least this many commands will be reserved.
    cmds: usize,
    /// Space for an average of at least this many bytes of extra data per command will be reserved.
    /// This is used for components and custom event payloads.
    avg_cmd_bytes: usize,
};

/// Per buffer capacity. Prefer `Capacity`.
pub const GranularCapacity = struct {
    tags: usize,
    args: usize,
    any_bytes: usize,
    reserved: usize,

    /// Estimates the granular capacity from worst case capacity.
    pub fn init(cap: Capacity) @This() {
        _ = Subcmd.rename_when_changing_encoding;

        // Each command can have at most one component's worth of component data.
        const cmd_bytes_cap = (cap.avg_cmd_bytes + zcs.TypeInfo.max_align) * cap.cmds;

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
            .any_bytes = cmd_bytes_cap,
            .reserved = reserved_cap,
        };
    }
};

/// A batch of sequential commands that all have the same entity bound.
pub const Batch = union(enum) {
    ext: Any,
    arch_change: ArchChange,

    pub const ArchChange = struct {
        /// A description of delta over all archetype change operations.
        pub const Delta = struct {
            add: CompFlag.Set = .{},
            remove: CompFlag.Set = .{},
            destroy: bool = false,

            /// Updates the delta for a given operation.
            pub fn updateImmediate(self: *@This(), op: Op) void {
                switch (op) {
                    .add => |comp| {
                        const flag = CompFlag.registerImmediate(comp.id);
                        self.add.insert(flag);
                        self.remove.remove(flag);
                    },
                    .remove => |id| {
                        const flag = CompFlag.registerImmediate(id);
                        self.add.remove(flag);
                        self.remove.insert(flag);
                    },
                    .destroy => self.destroy = true,
                }
            }
        };

        /// The bound entity.
        entity: Entity,
        decoder: Subcmd.Decoder,

        /// Returns the delta over all archetype change operations.
        pub fn deltaImmediate(self: @This()) Delta {
            var delta: Delta = .{};
            var ops = self.iterator();
            while (ops.next()) |op| delta.updateImmediate(op);
            return delta;
        }

        /// An iterator over this batch's commands.
        pub fn iterator(self: @This()) @This().Iterator {
            return .{
                .decoder = self.decoder,
            };
        }

        /// Executes the batch. Returns true if the entity exists before the command is run, false
        /// otherwise.
        ///
        /// See `getArchChangeImmediate` to get the default archetype change argument.
        pub fn execImmediate(self: @This(), es: *Entities, delta: Delta) bool {
            return self.execImmediateOrErr(es, delta) catch |err|
                @panic(@errorName(err));
        }

        /// Similar to `execImmediate`, but returns an error on overflow instead of panicking.
        pub fn execImmediateOrErr(
            self: @This(),
            es: *Entities,
            delta: Delta,
        ) error{ ZcsCompOverflow, ZcsArchOverflow, ZcsChunkOverflow }!bool {
            if (delta.destroy) return self.entity.destroyImmediate(es);

            // Issue the change archetype command.  If no changes were requested, this will
            // still commit the entity. If the entity doesn't exist, early out.
            if (!try self.entity.changeArchUninitImmediateOrErr(es, .{
                .add = delta.add,
                .remove = delta.remove,
            })) {
                return false;
            }

            // Initialize any new components. Note that we check for existence on each because they
            // could have been subsequently removed.
            {
                var ops = self.iterator();
                while (ops.next()) |op| {
                    switch (op) {
                        .add => |comp| if (self.entity.getId(es, comp.id)) |dest| {
                            @memcpy(dest, comp.bytes());
                        },
                        .remove,
                        .destroy,
                        => {},
                    }
                }
            }

            return true;
        }

        /// An archetype change operation.
        pub const Op = union(enum) {
            add: Any,
            remove: TypeId,
            destroy: void,
        };

        /// An iterator over this batch's commands.
        ///
        /// Note that the encoder will elide operations immediately following a destroy. This is
        /// intended to simplify writing extensions.
        pub const Iterator = struct {
            decoder: Subcmd.Decoder,

            /// Returns the next operation, or `null` if there are none.
            pub fn next(self: *@This()) ?Op {
                while (self.decoder.peekTag()) |tag| {
                    const op: Op = switch (tag) {
                        .add_val => .{ .add = self.decoder.next().?.add_val },
                        .add_ptr => .{ .add = self.decoder.next().?.add_ptr },
                        .remove => .{ .remove = self.decoder.next().?.remove },
                        .destroy => b: {
                            _ = self.decoder.next().?.destroy;
                            break :b .destroy;
                        },
                        .bind_entity, .ext_val, .ext_ptr => break,
                    };

                    // Return the operation.
                    return op;
                }
                return null;
            }
        };
    };
};

/// An iterator over batches of encoded commands.
pub const Iterator = struct {
    decoder: Subcmd.Decoder,

    /// Returns the next command batch, or `null` if there is none.
    pub fn next(self: *@This()) ?Batch {
        _ = Subcmd.rename_when_changing_encoding;

        // We just return bind operations here, `Subcmd` handles the add/remove commands.
        while (self.decoder.next()) |cmd| {
            switch (cmd) {
                // We buffer all ops on a given entity into a single command
                .bind_entity => |entity| return .{ .arch_change = .{
                    .entity = entity,
                    .decoder = self.decoder,
                } },
                .ext_val, .ext_ptr => |payload| return .{ .ext = payload },
                // These are handled by archetype change. We always start archetype change with a
                // bind so this will never miss ops.
                .add_ptr,
                .add_val,
                .remove,
                .destroy,
                => {},
            }
        }

        return null;
    }
};
