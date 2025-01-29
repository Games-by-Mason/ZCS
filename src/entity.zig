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
/// time. Methods with `immediately` in the name are executed immediately, usage of these is
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
    /// To commit a reserved entity, use one of the `changeArchetype*` methods.
    pub fn nextReserved(cmds: *CmdBuf) Entity {
        return nextReservedChecked(cmds) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `nextReserved`, but returns `error.ZcsReservedEntityUnderflow` if there are no
    /// more reserved entities instead of panicking.
    pub fn nextReservedChecked(cmds: *CmdBuf) error{ZcsReservedEntityUnderflow}!Entity {
        return cmds.reserved.popOrNull() orelse error.ZcsReservedEntityUnderflow;
    }

    /// Similar to `nextReserved`, but reserves a new entity instead of popping one from a command
    /// buffers reserve. Prefer `nextReserved`.
    ///
    /// This does not invalidate iterators, but it's not thread safe.
    pub fn reserveImmediately(es: *Entities) Entity {
        return reserveImmediatelyChecked(es) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `reserveImmediately`, but returns `error.ZcsEntityOverflow` on failure instead of
    /// panicking.
    pub fn reserveImmediatelyChecked(es: *Entities) error{ZcsEntityOverflow}!Entity {
        const key = es.slots.put(.{
            .archetype = .{},
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
        self.destroyCmdChecked(cmds) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `destroyCmd`, but returns `error.ZcsCmdBufOverflow` on failure instead of
    /// panicking.
    pub fn destroyCmdChecked(self: @This(), cmds: *CmdBuf) error{ZcsCmdBufOverflow}!void {
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
    pub fn destroyImmediately(self: @This(), es: *Entities) void {
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
        const archetype = self.getArchetype(es);
        return archetype.contains(flag);
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
    /// Will automatically pass the data by pointer if it's comptime known and larger than pointer
    /// sized.
    ///
    /// Adding components to an entity that no longer exists has no effect.
    pub inline fn addCompCmd(self: @This(), cmds: *CmdBuf, T: type, comp: T) void {
        self.addCompCmdChecked(cmds, T, comp) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `addCompCmd`, but returns `error.ZcsCmdBufOverflow` on failure instead of
    /// panicking.
    pub inline fn addCompCmdChecked(
        self: @This(),
        cmds: *CmdBuf,
        T: type,
        comp: T,
    ) error{ZcsCmdBufOverflow}!void {
        if (@sizeOf(T) > @sizeOf(*T) and isComptimeKnown(comp)) {
            try self.addCompPtrCmdChecked(cmds, T, comp);
        } else {
            try self.addCompValCmdChecked(cmds, T, comp);
        }
    }

    /// Similar to `addCompCmd` but forces the data to be passed by value.
    pub fn addCompValCmd(self: @This(), cmds: *CmdBuf, T: type, comp: T) void {
        self.addCompValCmdChecked(cmds, T, comp) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `addCompValCmd`, but returns `error.ZcsCmdBufOverflow` on failure
    /// instead of panicking.
    pub fn addCompValCmdChecked(
        self: @This(),
        cmds: *CmdBuf,
        T: type,
        comp: T,
    ) error{ZcsCmdBufOverflow}!void {
        // Restore the state on failure
        const restore = cmds.*;
        errdefer cmds.* = restore;

        // Issue the subcommands
        try SubCmd.encode(&cmds.archetype_changes, .{ .bind_entity = self });
        try SubCmd.encode(&cmds.archetype_changes, .{ .add_comp_val = .init(T, &comp) });
    }

    /// Similar to `addCompCmd` but forces the data to be passed by pointer. Only available for
    /// comptime known arguments.
    pub fn addCompPtrCmd(self: @This(), cmds: *CmdBuf, T: type, comptime comp: T) void {
        self.addCompPtrCmdChecked(cmds, T, comp) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `addCompPtrCmd`, but returns `error.ZcsCmdBufOverflow` on failure instead
    /// of panicking.
    pub fn addCompPtrCmdChecked(
        self: @This(),
        cmds: *CmdBuf,
        T: type,
        comptime comp: T,
    ) error{ZcsCmdBufOverflow}!void {
        // Restore the state on failure
        const restore = cmds.*;
        errdefer cmds.* = restore;

        // Issue the subcommands
        const Interned = struct {
            const value = comp;
        };
        try SubCmd.encode(&cmds.archetype_changes, .{ .bind_entity = self });
        try SubCmd.encode(&cmds.archetype_changes, .{ .add_comp_ptr = .init(T, &Interned.value) });
    }

    /// Queues the given component to be removed. Has no effect if the component is not present, or
    /// the entity no longer exists.
    pub fn removeCompCmd(
        self: @This(),
        cmds: *CmdBuf,
        T: type,
    ) void {
        self.removeCompCmdChecked(cmds, T) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `removeCompCmd`, but returns `error.ZcsCmdBufOverflow` on failure instead of
    /// panicking.
    pub fn removeCompCmdChecked(
        self: @This(),
        cmds: *CmdBuf,
        T: type,
    ) error{ZcsCmdBufOverflow}!void {
        try self.removeCompIdCmdChecked(cmds, compId(T));
    }

    /// Similar to `removeCompCmd`, but doesn't require compile time types.
    pub fn removeCompIdCmd(
        self: @This(),
        cmds: *CmdBuf,
        id: Comp.Id,
    ) void {
        self.removeCompIdCmdChecked(cmds, id) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `removeCompCmd`, but returns `error.ZcsCmdBufOverflow` on failure instead of
    /// panicking.
    pub fn removeCompIdCmdChecked(
        self: @This(),
        cmds: *CmdBuf,
        id: Comp.Id,
    ) error{ZcsCmdBufOverflow}!void {
        // Restore the state on failure
        const restore = cmds.*;
        errdefer cmds.* = restore;

        // Issue the subcommands
        try SubCmd.encode(&cmds.archetype_changes, .{ .bind_entity = self });
        try SubCmd.encode(&cmds.archetype_changes, .{ .remove_comp = id });
    }

    /// Queues the entity to be committed. Has no effect if it has already been committed, called
    /// implicitly on add/remove. In practice only necessary when creating an empty entity.
    pub fn commitCmd(self: @This(), cmds: *CmdBuf) void {
        self.commitCmdChecked(cmds) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `commitCmd`, but returns `error.ZcsCmdBufOverflow` on failure instead of
    /// panicking.
    pub fn commitCmdChecked(self: @This(), cmds: *CmdBuf) error{ZcsCmdBufOverflow}!void {
        // Restore the state on failure
        const restore = cmds.*;
        errdefer cmds.* = restore;

        // Issue the subcommand
        try SubCmd.encode(&cmds.archetype_changes, .{ .bind_entity = self });
    }

    /// Options for the uninitialized variants of change archetype.
    pub const ChangeArchetypeUninitializedImmediatelyOptions = struct {
        /// Comp types to remove.
        remove: CompFlag.Set = .{},
        /// Comp types to add.
        add: CompFlag.Set = .{},
    };

    /// Similar to `changeArchetypeImmediately`, but does not initialize any added components.
    ///
    /// May invalidate removed components even if they are also present in `add`.
    pub fn changeArchetypeUnintializedImmediately(
        self: @This(),
        es: *Entities,
        options: ChangeArchetypeUninitializedImmediatelyOptions,
    ) void {
        self.changeArchetypeUninitializedImmediatelyChecked(es, options) catch |err|
            @panic(@errorName(err));
    }

    pub const ChangeArchetypeImmediatelyOptions = struct {
        add: []const Comp.Optional = &.{},
        remove: CompFlag.Set = .{},
    };

    /// Similar to `changeArchetypeImmediately`, but does not require compile time types.
    pub fn changeArchetypeImmediately(
        self: @This(),
        es: *Entities,
        changes: ChangeArchetypeImmediatelyOptions,
    ) void {
        self.changeArchetypeImmediatelyChecked(es, changes) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `changeArchetypeImmediately`, but returns `error.ZcsEntityOverflow`
    /// on failure instead of panicking.
    pub fn changeArchetypeImmediatelyChecked(
        self: @This(),
        es: *Entities,
        changes: ChangeArchetypeImmediatelyOptions,
    ) error{ZcsEntityOverflow}!void {
        // Early out if the entity does not exist, also checks some assertions
        if (!self.exists(es)) return;

        var add_flags: CompFlag.Set = .{};
        for (changes.add) |comp| {
            if (comp.unwrap()) |some| {
                add_flags.insert(some.id);
            }
        }
        try self.changeArchetypeUninitializedImmediatelyChecked(
            es,
            .{
                .remove = changes.remove,
                .add = add_flags,
            },
        );

        var skip = changes.remove;
        for (0..changes.add.len) |i| {
            const comp = changes.add[changes.add.len - i - 1];
            if (comp.unwrap()) |some| {
                if (!skip.contains(some.id)) {
                    skip.insert(some.id);
                    const src = some.bytes;
                    const dest = self.getCompFromId(es, some.id).?;
                    @memcpy(dest, src);
                }
            }
        }
    }

    /// Similar to `changeArchetypeUnintializedImmediately`, but returns `error.ZcsEntityOverflow`
    /// on failure instead of panicking.
    pub fn changeArchetypeUninitializedImmediatelyChecked(
        self: @This(),
        es: *Entities,
        options: ChangeArchetypeUninitializedImmediatelyOptions,
    ) error{ZcsEntityOverflow}!void {
        invalidateIterators(es);
        const slot = es.slots.get(self.key) orelse return;
        if (!slot.committed) {
            es.reserved_entities -= 1;
            slot.committed = true;
        }
        slot.archetype = slot.archetype.unionWith(options.add);
        slot.archetype = slot.archetype.differenceWith(options.remove);
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
    fn getArchetype(self: @This(), es: *const Entities) CompFlag.Set {
        const slot = es.slots.get(self.key) orelse return .{};
        if (!slot.committed) assert(slot.archetype.eql(.{}));
        return slot.archetype;
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
