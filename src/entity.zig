const std = @import("std");
const assert = std.debug.assert;

const zcs = @import("root.zig");
const slot_map = @import("slot_map");

const compId = zcs.compId;

const SubCmd = @import("CmdBuf/sub_cmd.zig").SubCmd;

const types = @import("types.zig");
const CompFlag = types.CompFlag;

const SlotMap = slot_map.SlotMap;
const Entities = zcs.Entities;
const Comp = zcs.Comp;
const CmdBuf = zcs.CmdBuf;

/// An entity.
///
/// Entity handles are persistent, you can check if an entity has been destroyed via
/// `Entity.exists`. This is useful for dynamic systems like games where object lifetime may depend
/// on user input.
///
/// Methods with `cmd` in the name append the command to a command buffer for execution at a later
/// time. Methods with `immediate` in the name are executed immediately, usage of these is
/// discouraged as they are not valid while iterating unless otherwise noted and are not thread
/// safe.
pub const Entity = packed struct {
    /// An entity that has never existed, and never will.
    pub const none: @This() = .{ .key = .none };

    key: SlotMap(CompFlag.Set, .{}).Key,

    /// Pops a reserved entity.
    ///
    /// A reserved entity is given a persistent key, but no storage. As such, it will behave like
    /// an empty entity, but not show up in iteration.
    ///
    /// You can commit a reserved entity explicitly with `commitCmd`, but this isn't usually
    /// necessary as adding or attempting to remove a component implicitly commits the entity.
    pub fn popReserved(cmds: *CmdBuf) Entity {
        return popReservedOrErr(cmds) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `popReserved`, but returns `error.ZcsReservedEntityUnderflow` if there are no
    /// more reserved entities instead of panicking.
    pub fn popReservedOrErr(cmds: *CmdBuf) error{ZcsReservedEntityUnderflow}!Entity {
        return cmds.reserved.popOrNull() orelse error.ZcsReservedEntityUnderflow;
    }

    /// Similar to `popReserved`, but reserves a new entity instead of popping one from a command
    /// buffers reserve. Prefer `popReserved`.
    ///
    /// This does not invalidate iterators, but it's not thread safe.
    pub fn reserveImmediate(es: *Entities) Entity {
        return reserveImmediateOrErr(es) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `reserveImmediate`, but returns `error.ZcsEntityOverflow` on failure instead of
    /// panicking.
    pub fn reserveImmediateOrErr(es: *Entities) error{ZcsEntityOverflow}!Entity {
        const key = es.slots.put(.{
            .arch = .{},
            .committed = false,
        }) catch |err| switch (err) {
            error.Overflow => return error.ZcsEntityOverflow,
        };
        es.live.set(key.index);
        es.reserved_entities += 1;
        return .{ .key = key };
    }

    /// Queues an entity for destruction.
    ///
    /// Destroying an entity that no longer exists has no effect.
    pub fn destroyCmd(self: @This(), cmds: *CmdBuf) void {
        self.destroyCmdOrErr(cmds) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `destroyCmd`, but returns `error.ZcsCmdBufOverflow` on failure instead of
    /// panicking.
    pub fn destroyCmdOrErr(self: @This(), cmds: *CmdBuf) error{ZcsCmdBufOverflow}!void {
        // Check capacity
        if (cmds.destroy.items.len >= cmds.destroy.capacity) {
            return error.ZcsCmdBufOverflow;
        }

        // Queue the command
        cmds.destroy.appendAssumeCapacity(self);
    }

    /// Similar to `destroyCmd`, but destroys the entity immediately. Prefer `destroyCmd`.
    ///
    /// Invalidates iterators.
    pub fn destroyImmediate(self: @This(), es: *Entities) void {
        invalidateIterators(es);
        if (es.slots.get(self.key)) |slot| {
            if (!slot.committed) es.reserved_entities -= 1;
            es.live.unset(self.key.index);
            es.slots.remove(self.key);
        }
    }

    /// Returns true if the entity has not been destroyed.
    pub fn exists(self: @This(), es: *const Entities) bool {
        return es.slots.containsKey(self.key);
    }

    /// Returns true if the entity exists and has been committed, otherwise returns false.
    pub fn committed(self: @This(), es: *const Entities) bool {
        const slot = es.slots.get(self.key) orelse return false;
        return slot.committed;
    }

    /// Returns true if the entity has the given component type, false otherwise or if the entity
    /// has been destroyed.
    pub fn hasComp(self: @This(), es: *const Entities, T: type) bool {
        return self.hasCompId(es, compId(T));
    }

    /// Similar to `hasComp`, but operates on component IDs instead of types.
    pub fn hasCompId(self: @This(), es: *const Entities, id: Comp.Id) bool {
        const flag = id.flag orelse return false;
        const arch = self.getArch(es);
        return arch.contains(flag);
    }

    /// Retrieves the given component type. Returns null if the entity does not have this component
    /// or has been destroyed.
    pub fn getComp(self: @This(), es: *const Entities, T: type) ?*T {
        const untyped = self.getCompFromId(es, compId(T)) orelse return null;
        return @alignCast(@ptrCast(untyped));
    }

    /// Similar to `getComp`, but operates on component IDs instead of types.
    pub fn getCompFromId(self: @This(), es: *const Entities, id: Comp.Id) ?[]u8 {
        const flag = id.flag orelse return null;
        if (!self.hasCompId(es, id)) return null;
        const comp_buffer = es.comps[@intFromEnum(flag)];
        const comp_offset = self.key.index * id.size;
        const bytes = comp_buffer.ptr + comp_offset;
        return bytes[0..id.size];
    }

    /// Returns true if the given entities are the same entity, false otherwise.
    pub fn eql(self: @This(), other: @This()) bool {
        return self.key.eql(other.key);
    }

    /// Queues a component to be added.
    ///
    /// Batching add/removes on the same entity in sequence is more efficient than alternating
    /// between operations on different entities.
    ///
    /// Will automatically pass the data by pointer if it's comptime known, and larger than pointer
    /// sized.
    ///
    /// Adding components to an entity that no longer exists has no effect.
    pub inline fn addCompCmd(self: @This(), cmds: *CmdBuf, T: type, comp: T) void {
        self.addCompCmdOrErr(cmds, T, comp) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `addCompCmd`, but returns `error.ZcsCmdBufOverflow` on failure instead of
    /// panicking.
    pub inline fn addCompCmdOrErr(
        self: @This(),
        cmds: *CmdBuf,
        T: type,
        comp: T,
    ) error{ZcsCmdBufOverflow}!void {
        if (@sizeOf(T) > @sizeOf(*T) and isComptimeKnown(comp)) {
            const Interned = struct {
                const value = comp;
            };
            try self.addCompPtrCmdOrErr(cmds, .init(T, comptime &Interned.value));
        } else {
            try self.addCompValCmdOrErr(cmds, .init(T, &comp));
        }
    }

    /// Similar to `addCompCmd`, but doesn't require compile time types and forces the component to
    /// be copied by value. Prefer `addCompCmd`.
    pub fn addCompValCmd(self: @This(), cmds: *CmdBuf, comp: Comp) void {
        self.addCompValCmdOrErr(cmds, comp) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `addCompValCmd`, but returns `error.ZcsCmdBufOVerflow` on failure instead of
    /// panicking.
    pub fn addCompValCmdOrErr(
        self: @This(),
        cmds: *CmdBuf,
        comp: Comp,
    ) error{ZcsCmdBufOverflow}!void {
        // Restore the state on failure
        const restore = cmds.*;
        errdefer cmds.* = restore;

        // Issue the subcommands
        try SubCmd.encode(&cmds.arch_changes, .{ .bind_entity = self });
        try SubCmd.encode(&cmds.arch_changes, .{ .add_comp_val = comp });
    }

    /// Similar to `addCompCmd`, but doesn't require compile time types and forces the component to
    /// be copied by pointer. Prefer `addCompCmd`.
    pub fn addCompPtrCmd(self: @This(), cmds: *CmdBuf, comp: Comp) void {
        self.addCompPtrCmdOrErr(cmds, comp) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `addCompPtrCmd`, but returns `error.ZcsCmdBufOVerflow` on failure instead of
    /// panicking.
    pub fn addCompPtrCmdOrErr(
        self: @This(),
        cmds: *CmdBuf,
        comp: Comp,
    ) error{ZcsCmdBufOverflow}!void {
        // Restore the state on failure
        const restore = cmds.*;
        errdefer cmds.* = restore;

        // Issue the subcommands
        try SubCmd.encode(&cmds.arch_changes, .{ .bind_entity = self });
        try SubCmd.encode(&cmds.arch_changes, .{ .add_comp_ptr = comp });
    }

    /// Queues the given component to be removed. Has no effect if the component is not present, or
    /// the entity no longer exists.
    ///
    /// See note on `addCompCmd` with regards to performance.
    pub fn remCompCmd(
        self: @This(),
        cmds: *CmdBuf,
        T: type,
    ) void {
        self.remCompCmdOrErr(cmds, T) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `remCompCmd`, but returns `error.ZcsCmdBufOverflow` on failure instead of
    /// panicking.
    pub fn remCompCmdOrErr(
        self: @This(),
        cmds: *CmdBuf,
        T: type,
    ) error{ZcsCmdBufOverflow}!void {
        try self.remCompIdCmdOrErr(cmds, compId(T));
    }

    /// Similar to `remCompCmd`, but doesn't require compile time types.
    pub fn remCompIdCmd(
        self: @This(),
        cmds: *CmdBuf,
        id: Comp.Id,
    ) void {
        self.remCompIdCmdOrErr(cmds, id) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `remCompCmd`, but returns `error.ZcsCmdBufOverflow` on failure instead of
    /// panicking.
    pub fn remCompIdCmdOrErr(
        self: @This(),
        cmds: *CmdBuf,
        id: Comp.Id,
    ) error{ZcsCmdBufOverflow}!void {
        // Restore the state on failure
        const restore = cmds.*;
        errdefer cmds.* = restore;

        // Issue the subcommands
        try SubCmd.encode(&cmds.arch_changes, .{ .bind_entity = self });
        try SubCmd.encode(&cmds.arch_changes, .{ .remove_comp = id });
    }

    /// Queues the entity to be committed. Has no effect if it has already been committed, called
    /// implicitly on add/remove. In practice only necessary when creating an empty entity.
    pub fn commitCmd(self: @This(), cmds: *CmdBuf) void {
        self.commitCmdOrErr(cmds) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `commitCmd`, but returns `error.ZcsCmdBufOverflow` on failure instead of
    /// panicking.
    pub fn commitCmdOrErr(self: @This(), cmds: *CmdBuf) error{ZcsCmdBufOverflow}!void {
        // Restore the state on failure
        const restore = cmds.*;
        errdefer cmds.* = restore;

        // Issue the subcommand
        try SubCmd.encode(&cmds.arch_changes, .{ .bind_entity = self });
    }

    pub const ChangeArchImmediateOptions = struct {
        add: []const Comp = &.{},
        remove: []const Comp.Id = &.{},
    };

    /// Adds the listed components and then removes the listed component IDs.
    pub fn changeArchImmediate(
        self: @This(),
        es: *Entities,
        changes: ChangeArchImmediateOptions,
    ) void {
        self.changeArchImmediateOrErr(es, changes) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `changeArchImmediate`, but returns `error.ZcsCompOverflow` on failure instead
    /// of panicking.
    pub fn changeArchImmediateOrErr(
        self: @This(),
        es: *Entities,
        changes: ChangeArchImmediateOptions,
    ) error{ZcsCompOverflow}!void {
        // Early out if the entity does not exist, also checks some assertions
        if (!self.exists(es)) return;

        // Build a set of component types to add/remove
        var add: CompFlag.Set = .{};
        for (changes.add) |comp| {
            add.insert(types.register(comp.id));
        }

        var remove: CompFlag.Set = .{};
        for (changes.remove) |id| {
            remove.insert(types.register(id));
        }

        // Apply the archetype change
        try self.changeArchUninitImmediateOrErr(es, .{ .add = add, .remove = remove });

        // Initialize the components
        for (changes.add) |comp| {
            // Unwrapping the flag is safe because we already registered it above
            const flag = comp.id.flag.?;
            if (!remove.contains(flag)) {
                // Unwrapping the component is safe because we added it above
                const dest = self.getCompFromId(es, comp.id).?;
                @memcpy(dest, comp.bytes());
            }
        }
    }

    /// Options for the uninitialized variants of change archetype.
    pub const ChangeArchUninitImmediateOptions = struct {
        /// Component types to remove.
        remove: CompFlag.Set = .{},
        /// Component types to add.
        add: CompFlag.Set = .{},
    };

    /// For internal use. Similar to `changeArchUninitImmediate`, but returns
    /// `error.ZcsCompOverflow` on failure instead of panicking.
    pub fn changeArchUninitImmediateOrErr(
        self: @This(),
        es: *Entities,
        options: ChangeArchUninitImmediateOptions,
    ) error{ZcsCompOverflow}!void {
        invalidateIterators(es);

        // Get the slot
        const slot = es.slots.get(self.key) orelse return;

        // Check if we have enough space
        var added = options.add.differenceWith(options.remove).iterator();
        while (added.next()) |flag| {
            const id = types.registered.get(@intFromEnum(flag));
            const comp_buffer = es.comps[@intFromEnum(flag)];
            const comp_offset = self.key.index * id.size;
            if (id.size > 0 and comp_offset + id.size > comp_buffer.len) {
                return error.ZcsCompOverflow;
            }
        }

        // Commit the slot and change the archetype
        if (!slot.committed) {
            es.reserved_entities -= 1;
            slot.committed = true;
        }
        slot.arch = slot.arch.unionWith(options.add);
        slot.arch = slot.arch.differenceWith(options.remove);
    }

    /// Default formatting for `Entity`.
    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        return self.key.format(fmt, options, writer);
    }

    /// Returns the archetype of the entity. If it has been destroyed or is not yet committed, the
    /// empty archetype will be returned.
    fn getArch(self: @This(), es: *const Entities) CompFlag.Set {
        const slot = es.slots.get(self.key) orelse return .{};
        if (!slot.committed) assert(slot.arch.eql(.{}));
        return slot.arch;
    }

    /// Explicitly invalidates iterators to catch bugs in debug builds.
    fn invalidateIterators(es: *Entities) void {
        if (@FieldType(Entities, "iterator_generation") != u0) {
            es.iterator_generation +%= 1;
        }
    }
};

inline fn isComptimeKnown(value: anytype) bool {
    return @typeInfo(@TypeOf(.{value})).@"struct".fields[0].is_comptime;
}

test "isComptimeKnown" {
    try std.testing.expect(isComptimeKnown(123));
    const foo = 456;
    try std.testing.expect(isComptimeKnown(foo));
    var bar: u8 = 123;
    bar += 1;
    try std.testing.expect(!isComptimeKnown(bar));
}
