//! Buffers ECS commands for later execution.
//!
//! This allows queuing destructive operations while iterating, or from multiple threads safely by
//! assigning each thread its own command buffer. All commands are noops if the entity in question
//! is destroyed before the time of execution.
//!
//! `CmdBuf` allocates at init time, and then never again. It should be cleared and reused when
//! possible.
//!
//! All exec methods may invalidate iterators, but by convention only the high level
//! `execImmediate*` explicitly calls `es.pointer_generation.increment()`. If you are writing your
//! own exec function, you should call this yourself.
//!
//! Some command buffer modifications leave the command buffer in an undefined state on failure, this
//! is documented on the relevant functions. Trying to execute a command buffer invalidated in this
//! way results in safety checked illegal behavior. This design means that these functions are
//! typically not useful in real applications since you can't recover the CB after the error, rather
//! they're intended for tests. While it would be possible to preserve valid state by restoring the
//! lengths, this doesn't tend to be useful for real applications and substantially affects
//! performance in benchmarks.

const std = @import("std");
const tracy = @import("tracy");
const zcs = @import("root.zig");

const log = std.log;

const meta = zcs.meta;

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Zone = tracy.Zone;

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

name: ?[:0]const u8,
tags: std.ArrayListUnmanaged(Subcmd.Tag),
args: std.ArrayListUnmanaged(u64),
data: std.ArrayListAlignedUnmanaged(u8, zcs.TypeInfo.max_align),
binding: Binding = .{ .entity = .none },
reserved: std.ArrayListUnmanaged(Entity),
invalid: if (std.debug.runtime_safety) bool else void,
warn_ratio: f32,

/// Options for `init`.
pub const InitOptions = struct {
    /// The debug name for this command buffer.
    ///
    /// Used in warnings and plots, see `updateStats`.
    name: ?[:0]const u8,
    /// Used to allocate the command buffer.
    gpa: Allocator,
    /// Entities are reserved from here.
    es: *Entities,
    /// The capacity of the buffer.
    cap: Capacity,
    /// If more than this ratio of the command buffer is used as measured by `worstCaseUsage`, a
    /// warning will be emitted by `Exec.checkStats`.
    warn_ratio: f32 = 0.2,
};

/// The capacity of a command buffer.
pub const Capacity = struct {
    /// Space for at least this many commands will be reserved.
    cmds: usize,
    /// Space for at least this much command data will be reserved. Keep in mind that padding may
    /// vary per platform.
    data: union(enum) {
        bytes: usize,
        bytes_per_cmd: u32,
    } = .{ .bytes_per_cmd = 2 * 16 * @sizeOf(f32) },
    /// Sets the number of entities to reserve up front. If `null`, `cmds` entities are reserved.
    reserved_entities: ?usize = null,

    /// Returns the number of data bytes requested.
    fn dataBytes(self: @This()) usize {
        return switch (self.data) {
            .bytes => |bytes| bytes,
            .bytes_per_cmd => |bytes_per_cmd| self.cmds * bytes_per_cmd,
        };
    }

    /// Returns the number of reserved entities requested.
    fn reservedEntities(self: @This()) usize {
        return self.reserved_entities orelse self.cmds;
    }
};

/// Initializes a command buffer.
pub fn init(options: InitOptions) error{ OutOfMemory, ZcsEntityOverflow }!@This() {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();
    comptime assert(CompFlag.max < std.math.maxInt(u64));

    // Each command can have at most two tags
    _ = Subcmd.rename_when_changing_encoding;
    const cmds_cap = options.cap.cmds * 2;
    const tags_zone = Zone.begin(.{ .name = "tags", .src = @src() });
    var tags: std.ArrayListUnmanaged(Subcmd.Tag) = try .initCapacity(options.gpa, cmds_cap);
    errdefer tags.deinit(options.gpa);
    tags_zone.end();

    // Each command can have at most 3 args (the add ptr subcommand does a bind which has one
    // arg if it's not skipped, and then it also passes the component ID and pointer as args as
    // well.
    _ = Subcmd.rename_when_changing_encoding;
    const args_zone = Zone.begin(.{ .name = "args", .src = @src() });
    const args_cap = cmds_cap * 3;
    var args: std.ArrayListUnmanaged(u64) = try .initCapacity(options.gpa, args_cap);
    errdefer args.deinit(options.gpa);
    args_zone.end();

    const any_bytes_zone = Zone.begin(.{ .name = "any bytes", .src = @src() });
    var data: std.ArrayListAlignedUnmanaged(u8, zcs.TypeInfo.max_align) = try .initCapacity(
        options.gpa,
        options.cap.dataBytes(),
    );
    errdefer data.deinit(options.gpa);
    any_bytes_zone.end();

    const reserved_zone = Zone.begin(.{ .name = "reserved", .src = @src() });
    var reserved: std.ArrayListUnmanaged(Entity) = try .initCapacity(
        options.gpa,
        options.cap.reservedEntities(),
    );
    errdefer reserved.deinit(options.gpa);
    for (0..reserved.capacity) |_| {
        reserved.appendAssumeCapacity(try Entity.reserveImmediateOrErr(options.es));
    }
    reserved_zone.end();

    if (tracy.enabled) {
        if (options.name) |name| {
            tracy.plotConfig(.{
                .name = name,
                .format = .percentage,
                .mode = .line,
                .fill = true,
            });
        }
    }

    return .{
        .name = options.name,
        .reserved = reserved,
        .tags = tags,
        .args = args,
        .data = data,
        .invalid = if (std.debug.runtime_safety) false else {},
        .warn_ratio = options.warn_ratio,
    };
}

/// Destroys the command buffer.
pub fn deinit(self: *@This(), gpa: Allocator, es: *Entities) void {
    for (self.reserved.items) |entity| assert(entity.destroyImmediate(es));
    self.reserved.deinit(gpa);
    self.data.deinit(gpa);
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

/// Similar to `ext`, but returns an error on failure instead of panicking. The command buffer is
/// left in an undefined state on error, see the top level documentation for more detail.
pub inline fn extOrErr(self: *@This(), T: type, payload: T) error{ZcsCmdBufOverflow}!void {
    // Don't get tempted to remove inline from here! It's required for `isComptimeKnown`.
    comptime assert(@typeInfo(@TypeOf(extOrErr)).@"fn".calling_convention == .@"inline");
    if (@sizeOf(T) > @sizeOf(*T) and meta.isComptimeKnown(payload)) {
        const Interned = struct {
            const value = payload;
        };
        try self.extPtr(T, comptime &Interned.value);
    } else {
        try self.extVal(T, payload);
    }
}

/// Similar to `extOrErr`, but forces the command to be copied by value to the command buffer.
/// Prefer `ext`.
pub fn extVal(self: *@This(), T: type, payload: T) error{ZcsCmdBufOverflow}!void {
    try Subcmd.encodeExtVal(self, T, payload);
}

/// Similar to `extOrErr`, but forces the command to be copied by pointer to the command buffer.
/// Prefer `ext`.
pub fn extPtr(self: *@This(), T: type, payload: *const T) error{ZcsCmdBufOverflow}!void {
    try Subcmd.encodeExtPtr(self, T, payload);
}

/// Clears the command buffer for reuse and then refills the reserved entity list to capacity.
/// Called automatically from `Exec.immediate`.
pub fn clear(self: *@This(), es: *Entities) void {
    self.clearOrErr(es) catch |err|
        @panic(@errorName(err));
}

/// Similar to `clear`, but returns `error.ZcsEntityOverflow` when failing to refill the reserved
/// entity list instead of panicking.
pub fn clearOrErr(self: *@This(), es: *Entities) error{ZcsEntityOverflow}!void {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.data.clearRetainingCapacity();
    self.args.clearRetainingCapacity();
    self.tags.clearRetainingCapacity();
    self.binding = .none;
    while (self.reserved.items.len < self.reserved.capacity) {
        self.reserved.appendAssumeCapacity(try Entity.reserveImmediateOrErr(es));
    }
}

/// Returns true if this command buffer is empty.
pub fn isEmpty(self: @This()) bool {
    return self.tags.items.len == 0 and self.reserved.items.len == self.reserved.capacity;
}

/// Returns the ratio of length to capacity for the internal buffer that is the nearest to being
/// full. Ignores buffers explicitly initialized with 0 capacity.
pub fn worstCaseUsage(self: @This()) f32 {
    const reserved_used: f32 = @floatFromInt(self.reserved.capacity - self.reserved.items.len);
    const reserved_usage = if (self.reserved.capacity == 0)
        0.0
    else
        reserved_used / @as(f32, @floatFromInt(self.reserved.capacity));
    return @max(
        usage(self.data),
        usage(self.args),
        usage(self.tags),
        reserved_usage,
    );
}

/// Calculates the usage of a list as a ratio.
fn usage(list: anytype) f32 {
    if (list.capacity == 0) return 0.0;
    return @as(f32, @floatFromInt(list.items.len)) / @as(f32, @floatFromInt(list.capacity));
}

/// Returns an iterator over the encoded commands.
pub fn iterator(self: *const @This()) Iterator {
    if (std.debug.runtime_safety) assert(!self.invalid);
    return .{ .decoder = .{ .cb = self } };
}

/// Emits a warning if over `warn_ratio`. If Tracy is enabled and this command buffer has a name,
/// update its plots. Called automatically by `Exec`.
pub fn updateStats(self: *const CmdBuf) void {
    const currentUsage = self.worstCaseUsage();

    if (tracy.enabled) {
        if (self.name) |name| {
            tracy.plot(.{
                .name = name,
                .value = .{ .f32 = currentUsage * 100.0 },
            });
        }
    }

    if (currentUsage > self.warn_ratio) {
        log.warn("command buffer past 50% capacity (buffer name = {?s})", .{self.name});
    }
}

pub const Exec = struct {
    zone: Zone,
    zone_cmd_exec: zcs.ext.ZoneCmd.Exec = .{},

    pub fn init() @This() {
        return .{
            .zone = Zone.begin(.{
                .src = @src(),
            }),
        };
    }

    /// Executes the command buffer and then clears it.
    ///
    /// Invalidates pointers.
    pub fn immediate(es: *Entities, cb: *CmdBuf) void {
        immediateOrErr(es, cb) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `execImmediate`, but returns an error on failure instead of panicking. On error, the
    /// command buffer will be partially executed.
    pub fn immediateOrErr(
        es: *Entities,
        cb: *CmdBuf,
    ) error{ ZcsArchOverflow, ZcsChunkOverflow, ZcsChunkPoolOverflow, ZcsEntityOverflow }!void {
        var self: @This() = .init();

        es.pointer_generation.increment();
        var iter = cb.iterator();
        while (iter.next()) |batch| {
            switch (batch) {
                .arch_change => |arch_change| {
                    const delta = arch_change.deltaImmediate();
                    _ = try arch_change.execImmediateOrErr(es, delta);
                },
                .ext => |payload| self.extImmediateOrErr(payload),
            }
        }

        try self.finish(cb, es);
    }

    pub fn extImmediateOrErr(self: *@This(), payload: Any) void {
        self.zone_cmd_exec.extImmediate(payload);
    }

    pub fn finish(self: *@This(), cb: *CmdBuf, es: *Entities) error{ZcsEntityOverflow}!void {
        cb.updateStats();
        cb.clear(es);
        self.zone_cmd_exec.finish();
        self.zone.end();
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
            pub inline fn updateImmediate(self: *@This(), op: Op) void {
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
        pub inline fn deltaImmediate(self: @This()) Delta {
            var delta: Delta = .{};
            var ops = self.iterator();
            while (ops.next()) |op| delta.updateImmediate(op);
            return delta;
        }

        /// An iterator over this batch's commands.
        pub inline fn iterator(self: @This()) @This().Iterator {
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
        pub inline fn execImmediateOrErr(
            self: @This(),
            es: *Entities,
            delta: Delta,
        ) error{ ZcsArchOverflow, ZcsChunkOverflow, ZcsChunkPoolOverflow }!bool {
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
                // Unwrapping these is fine since we just committed the entity if it wasn't
                // committed, or earlied out if it doesn't exist
                const entity_loc = es.handle_tab.get(self.entity.key).?;
                const chunk = entity_loc.chunk.get(&es.chunk_pool).?;
                var ops = self.iterator();
                while (ops.next()) |op| {
                    switch (op) {
                        .add => |comp| if (comp.id.comp_flag) |flag| {
                            const offset = chunk.header()
                                .comp_buf_offsets.values[@intFromEnum(flag)];
                            if (offset != 0) {
                                assert(offset != 0);
                                const dest_unsized: [*]u8 = @ptrFromInt(@intFromPtr(chunk) +
                                    offset +
                                    @intFromEnum(entity_loc.index_in_chunk) * comp.id.size);
                                const dest = dest_unsized[0..comp.id.size];
                                @memcpy(dest, comp.bytes());
                            }
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
            pub inline fn next(self: *@This()) ?Op {
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
    pub inline fn next(self: *@This()) ?Batch {
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
