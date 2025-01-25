const std = @import("std");
const assert = std.debug.assert;

const zcs = @import("root.zig");
const slot_map = @import("slot_map");
const SlotMap = slot_map.SlotMap;
const Entities = zcs.Entities;
const Component = zcs.Component;

const meta = @import("meta.zig");

/// An entity.
///
/// Entity handles are persistent. You can check if an entity has been destroyed via
/// `Entity.exists`. This is convenient for dynamic systems like games where object lifetime often
/// depends on user input.
pub const Entity = packed struct {
    /// An entity that has never existed, and never will.
    pub const none: @This() = .{ .key = .none };

    key: SlotMap(Component.Flags, .{}).Key,

    /// Reserves an entity key, but doesn't set up storage for it.
    ///
    /// Until committed, the entity will behave identically to an entity with no components, but
    /// will not show up in iteration or factor into `count`.
    ///
    /// Does not invalidate iterators.
    pub fn reserve(es: *Entities) Entity {
        return reserveChecked(es) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `reserve`, but returns `error.ZcsEntityOverflow` on failure instead of panicking.
    pub fn reserveChecked(es: *Entities) error{ZcsEntityOverflow}!Entity {
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

    /// Destroys the entity. May invalidate iterators.
    ///
    /// Has no effect if the entity has already been destroyed.
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

    /// Returns the archetype of the entity. If it has been destroyed, the archetype will be empty.
    pub fn getArchetype(self: @This(), es: *const Entities) Component.Flags {
        const slot = es.slots.get(self.key) orelse return .{};
        if (!slot.committed) assert(slot.archetype.eql(.{}));
        return slot.archetype;
    }

    /// Returns true if the entity has the given component type, false otherwise.
    ///
    /// Returns false if the entity has been destroyed.
    ///
    /// `Component` must be a registered component type.
    pub fn hasComponent(self: @This(), es: *const Entities, T: type) bool {
        const comp_id = es.getComponentId(T);
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
        const comp_id = es.getComponentId(T);
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

    /// Removes the components in `remove`, and then adds `components`.  May invalidate component
    /// pointers and iterators.
    ///
    /// `comps` must be a tuple where each field is a registered component type. Duplicates are not
    /// allowed.
    ///
    /// Fields may be optional to allow deciding whether or not to include a component at runtime.
    ///
    /// Has no effect if the entity has been destroyed.
    ///
    /// # Example
    /// ```zig
    /// try entity.changeArchetypeImmediately(&es, Component.flags(&.{Fire}), .{
    ///     RigidBody {
    ///         .mass = 10,
    ///     },
    ///     Transform {
    ///         position = .{ .x = 10, .y = 10 },
    ///         velocity = .{ .x = 0, .y = 0 },
    ///     },
    ///     if (condition) mesh else null,
    /// });
    /// ```
    pub fn changeArchetypeImmediately(
        self: @This(),
        es: *Entities,
        remove: Component.Flags,
        add: anytype,
    ) void {
        return self.changeArchetypeImmediatelyChecked(es, remove, add) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `changeArchetypeImmediately`, but returns `error.ZcsEntityOverflow` on failure instead of
    /// panicking.
    pub fn changeArchetypeImmediatelyChecked(
        self: @This(),
        es: *Entities,
        remove: Component.Flags,
        add: anytype,
    ) error{ZcsEntityOverflow}!void {
        meta.checkComponents(@TypeOf(add));

        // Early out if the entity does not exist
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
    pub fn changeArchetypeFromComponents(
        self: @This(),
        es: *Entities,
        remove: Component.Flags,
        add: []const Component.Optional,
    ) void {
        self.changeArchetypeFromComponentsImmediatelyChecked(es, remove, add) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `changeArchetypeFromComponents`, but returns `error.ZcsEntityOverflow` on failure
    /// instead of panicking.
    pub fn changeArchetypeFromComponentsImmediatelyChecked(
        self: @This(),
        es: *Entities,
        remove: Component.Flags,
        add: []const Component.Optional,
    ) error{ZcsEntityOverflow}!void {
        if (!self.exists(es)) return;

        var add_flags: Component.Flags = .{};
        for (add) |comp| {
            if (comp.unwrap()) |some| {
                add_flags.insert(some.id);
            }
        }
        try self.changeArchetypeUninitializedImmediatelyChecked(
            es,
            .{
                .remove = remove,
                .add = add_flags,
            },
        );

        var added: Component.Flags = .{};
        for (0..add.len) |i| {
            const comp = add[add.len - i - 1];
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

    /// Similar to `changeArchetypeUnintializedImmediately`, but returns `error.ZcsEntityOverflow` on failure
    /// instead of panicking.
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

    /// Returns true if the given entities are identical, false otherwise.
    pub fn eql(self: @This(), other: @This()) bool {
        return self.key.eql(other.key);
    }

    fn invalidateIterators(es: *Entities) void {
        es.iterator_generation +%= 1;
    }
};
