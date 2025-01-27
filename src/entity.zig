const std = @import("std");
const assert = std.debug.assert;

const zcs = @import("root.zig");
const slot_map = @import("slot_map");
const SlotMap = slot_map.SlotMap;
const Entities = zcs.Entities;
const Component = zcs.Component;
const CmdBuf = zcs.CmdBuf;
const SubCmd = @import("CmdBuf/sub_cmd.zig").SubCmd;

const meta = @import("meta.zig");

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

    key: SlotMap(Component.Flags, .{}).Key,

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
    /// Destroying an entity that has already been destroyed has no effect.
    pub fn destroyCmd(self: @This(), es: *const Entities, cmds: *CmdBuf) void {
        self.destroyCmdChecked(es, cmds) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `destroyCmd`, but returns `error.ZcsCmdBufOverflow` on failure instead of
    /// panicking.
    pub fn destroyCmdChecked(self: @This(), es: *const Entities, cmds: *CmdBuf) error{ZcsCmdBufOverflow}!void {
        // Early out if already destroyed, also checks some assertions
        if (!self.exists(es)) return;

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

    /// Returns the archetype of the entity. If it has been destroyed or is not yet committed, the
    /// empty archetype will be returned.
    pub fn getArchetype(self: @This(), es: *const Entities) Component.Flags {
        const slot = es.slots.get(self.key) orelse return .{};
        if (!slot.committed) assert(slot.archetype.eql(.{}));
        return slot.archetype;
    }

    /// Returns true if the entity has the given component type, false otherwise or if the entity
    /// has been destroyed.
    ///
    /// `Component` must be a registered component type.
    pub fn hasComponent(self: @This(), es: *const Entities, T: type) bool {
        const comp_id = es.findComponentId(T) orelse return false;
        return self.hasComponentId(es, comp_id);
    }

    /// Similar to `hasComponent`, but operates on component IDs instead of types.
    pub fn hasComponentId(
        self: @This(),
        es: *const Entities,
        comp_id: Component.Id,
    ) bool {
        const archetype = self.getArchetype(es);
        return archetype.contains(comp_id);
    }

    /// Retrieves the given component type. Returns null if the entity does not have this component
    /// or has been destroyed.
    ///
    /// `Component` must be a registered component type.
    pub fn getComponent(self: @This(), es: *const Entities, T: type) ?*T {
        const comp_id = es.findComponentId(T) orelse return null;
        const untyped = self.getComponentFromId(es, comp_id) orelse return null;
        return @alignCast(@ptrCast(untyped));
    }

    /// Similar to `getComponent`, but operates on component IDs instead of types.
    pub fn getComponentFromId(
        self: @This(),
        es: *const Entities,
        id: Component.Id,
    ) ?[]u8 {
        if (!self.hasComponentId(es, id)) return null;
        const size = es.getComponentSize(id);
        const comp_buffer = es.comps[@intFromEnum(id)];
        const comp_offset = self.key.index * size;
        const bytes = comp_buffer.ptr + comp_offset;
        return bytes[0..size];
    }

    /// Returns true if the given entities are the same entity, false otherwise.
    pub fn eql(self: @This(), other: @This()) bool {
        return self.key.eql(other.key);
    }

    /// Queues an archetype change. If the entity has been reserved but not committed, when executed
    /// the change will commit the entity.
    ///
    /// `change` is allowed to have up to two fields:
    /// * `add` is a tuple of components to add
    /// * `remove` is a `Component.Flags` instance specifying which components to remove
    ///
    /// `remove` is applied before `add`.
    ///
    /// Added components:
    /// * Must be registered component types
    /// * May be optional, if null they will be skipped
    /// * Are interned if the field is comptime and the component type is larger than a pointer
    pub fn changeArchetypeCmd(
        self: @This(),
        es: *Entities,
        cmds: *CmdBuf,
        change: anytype,
    ) void {
        self.changeArchetypeCmdChecked(es, cmds, change) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `changeArchetypeCmd`, but returns `error.ZcsCmdBufOverflow` on failure instead of
    /// panicking.
    pub fn changeArchetypeCmdChecked(
        self: @This(),
        es: *Entities,
        cmds: *CmdBuf,
        changes: anytype,
    ) error{ZcsCmdBufOverflow}!void {
        // Check the types
        const Changes = meta.ArchetypeChanges(@TypeOf(changes));
        const add = Changes.getAdd(changes);
        const remove = Changes.getRemove(changes);

        // Early out if destroyed, also checks some assertions
        if (!self.exists(es)) return;

        // Restore the state on failure
        const restore = cmds.*;
        errdefer cmds.* = restore;

        // Sort for minimal padding
        const sorted_fields = comptime meta.alignmentSort(@TypeOf(add));

        // Issue the subcommands
        try SubCmd.encode(es, &cmds.change_archetype, .{ .bind_entity = self });
        try SubCmd.encode(es, &cmds.change_archetype, .{ .remove_components = remove });
        inline for (0..add.len) |i| {
            const field = @typeInfo(@TypeOf(add)).@"struct".fields[sorted_fields[i]];

            const optional: ?meta.Unwrapped(field.type) = @field(add, field.name);
            if (optional) |some| {
                if (field.is_comptime and @sizeOf(@TypeOf(some)) > @sizeOf(usize)) {
                    try SubCmd.encode(es, &cmds.change_archetype, .{ .add_component_ptr = .{
                        .id = es.registerComponentType(@TypeOf(some)),
                        .ptr = &struct {
                            const interned = some;
                        }.interned,
                        .interned = true,
                    } });
                } else {
                    try SubCmd.encode(es, &cmds.change_archetype, .{ .add_component_val = .{
                        .id = es.registerComponentType(@TypeOf(some)),
                        .ptr = @ptrCast(&some),
                        .interned = false,
                    } });
                }
            }
        }
    }

    pub const ChangeArchetypeFromComponentsOptions = struct {
        add: []const Component.Optional = &.{},
        remove: Component.Flags = .{},
    };

    /// Similar to `changeArchetypeCmd` but does not require compile time types.
    ///
    /// Components set to `.none` have no effect.
    pub fn changeArchetypeCmdFromComponents(
        self: @This(),
        es: *const Entities,
        cmds: *CmdBuf,
        changes: ChangeArchetypeFromComponentsOptions,
    ) void {
        self.changeArchetypeCmdFromComponentsChecked(es, cmds, changes) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `changeArchetypeCmdFromComponents` but returns `error.ZcsCmdBufOverflow` on
    /// failure instead of panicking.
    pub fn changeArchetypeCmdFromComponentsChecked(
        self: @This(),
        es: *const Entities,
        cmds: *CmdBuf,
        changes: ChangeArchetypeFromComponentsOptions,
    ) error{ZcsCmdBufOverflow}!void {
        // Early out if destroyed, also checks some assertions
        if (!self.exists(es)) return;

        const restore = cmds.*;
        errdefer cmds.* = restore;

        try SubCmd.encode(es, &cmds.change_archetype, .{ .bind_entity = self });
        if (!changes.remove.eql(.{})) {
            try SubCmd.encode(es, &cmds.change_archetype, .{ .remove_components = changes.remove });
        }

        // Issue subcommands to add the listed components. Issued in reverse order, duplicates are
        // skipped.
        var added: Component.Flags = .{};
        for (0..changes.add.len) |i| {
            const comp = changes.add[changes.add.len - i - 1];
            if (comp.unwrap()) |some| {
                if (!added.contains(some.id)) {
                    added.insert(some.id);
                    if (some.interned) {
                        try SubCmd.encode(es, &cmds.change_archetype, .{ .add_component_ptr = some });
                    } else {
                        try SubCmd.encode(es, &cmds.change_archetype, .{ .add_component_val = some });
                    }
                }
            }
        }
    }

    /// Similar to `changeArchetypeCmd`, but immediately executes. Prefer `changeArchetypeCmd`.
    ///
    /// Invalidates iterators.
    pub fn changeArchetypeImmediately(
        self: @This(),
        es: *Entities,
        changes: anytype,
    ) void {
        return self.changeArchetypeImmediatelyChecked(es, changes) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `changeArchetypeImmediately`, but returns `error.ZcsEntityOverflow` on failure
    /// instead of panicking.
    pub fn changeArchetypeImmediatelyChecked(
        self: @This(),
        es: *Entities,
        changes: anytype,
    ) error{ZcsEntityOverflow}!void {
        const Changes = meta.ArchetypeChanges(@TypeOf(changes));
        const add = Changes.getAdd(changes);
        const remove = Changes.getRemove(changes);

        // Early out if the entity does not exist, also checks some assertions
        if (!self.exists(es)) return;

        // Get the component type IDs and determine the archetype. We store the type ID list
        // to avoid looking up the same values in the map multiple times.
        var comp_flags: Component.Flags = .{};
        var comp_ids: [add.len]Component.Id = undefined;
        inline for (add, 0..) |comp, i| {
            if (@typeInfo(@TypeOf(comp)) != .optional or comp != null) {
                const T = meta.Unwrapped(@TypeOf(comp));
                const comp_id = es.getComponentId(T);
                comp_flags.insert(comp_id);
                comp_ids[i] = comp_id;
            }
        }

        try self.changeArchetypeUninitializedImmediatelyChecked(es, .{
            .remove = remove,
            .add = comp_flags,
        });

        // Initialize the components
        inline for (add, 0..) |value, i| {
            // Store the component value if it's non-null
            const optional: ?meta.Unwrapped(@TypeOf(value)) = value;
            if (optional) |some| {
                const comp_id = comp_ids[i];
                const untyped = self.getComponentFromId(es, comp_id).?;
                const typed: *@TypeOf(some) = @alignCast(@ptrCast(untyped));
                typed.* = some;
            }
        }
    }

    /// Options for the uninitialized variants of change archetype.
    pub const ChangeArchetypeUninitializedImmediatelyOptions = struct {
        /// Component types to remove.
        remove: Component.Flags = .{},
        /// Component types to add.
        add: Component.Flags = .{},
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

    /// Similar to `changeArchetypeImmediately`, but does not require compile time types.
    pub fn changeArchetypeFromComponentsImmediately(
        self: @This(),
        es: *Entities,
        changes: ChangeArchetypeFromComponentsOptions,
    ) void {
        self.changeArchetypeFromComponentsImmediatelyChecked(es, changes) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `changeArchetypeFromComponentsImmediately`, but returns `error.ZcsEntityOverflow`
    /// on failure instead of panicking.
    pub fn changeArchetypeFromComponentsImmediatelyChecked(
        self: @This(),
        es: *Entities,
        changes: ChangeArchetypeFromComponentsOptions,
    ) error{ZcsEntityOverflow}!void {
        // Early out if the entity does not exist, also checks some assertions
        if (!self.exists(es)) return;

        var add_flags: Component.Flags = .{};
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

        var added: Component.Flags = .{};
        for (0..changes.add.len) |i| {
            const comp = changes.add[changes.add.len - i - 1];
            if (comp.unwrap()) |some| {
                if (!added.contains(some.id)) {
                    added.insert(some.id);
                    const src = some.bytes();
                    const dest = self.getComponentFromId(es, some.id).?;
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
        slot.archetype = slot.archetype.differenceWith(options.remove);
        slot.archetype = slot.archetype.unionWith(options.add);
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

    fn invalidateIterators(es: *Entities) void {
        if (@FieldType(Entities, "iterator_generation") != u0) {
            es.iterator_generation +%= 1;
        }
    }
};
