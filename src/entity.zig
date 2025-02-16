const std = @import("std");
const assert = std.debug.assert;

const zcs = @import("root.zig");
const slot_map = @import("slot_map");

const typeId = zcs.typeId;

const Cmd = @import("cmd.zig").Cmd;

const SlotMap = slot_map.SlotMap;
const Entities = zcs.Entities;
const Any = zcs.Any;
const CompFlag = zcs.CompFlag;
const CmdBuf = zcs.CmdBuf;
const TypeId = zcs.TypeId;

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
    pub const Optional = packed struct {
        pub const none: @This() = .{ .key = .none };

        key: SlotMap(Entities.Slot, .{}).Key.Optional,

        /// Unwraps the optional entity into `Entity`, or returns `null` if it is `.none`.
        pub fn unwrap(self: @This()) ?Entity {
            if (self.key.unwrap()) |key| return .{ .key = key };
            return null;
        }

        /// Default formatting.
        pub fn format(
            self: @This(),
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            return self.key.format(fmt, options, writer);
        }
    };

    key: SlotMap(Entities.Slot, .{}).Key,

    /// Given a pointer to a component, returns the corresponding entity.
    pub fn from(es: *const Entities, comp: anytype) @This() {
        return fromAny(es, .init(@typeInfo(@TypeOf(comp)).pointer.child, comp));
    }

    /// Similar to `from`, but does not require compile time types.
    pub fn fromAny(es: *const Entities, comp: Any) @This() {
        if (comp.id.size == 0) {
            // Our pointer math doesn't work on zero bit types, since they may all occupy the same
            // address. To work around this, zero sized types are "allocated" at the address of the
            // entity ID they're attached to. Without this strategy, we'd have to make zero bit
            // types take up a byte to make the math work.
            return @bitCast(@intFromPtr(comp.ptr));
        }

        const flag = comp.id.comp_flag.?;
        const comp_array = es.comps[@intFromEnum(flag)];

        const loc = @intFromPtr(comp.ptr);
        const start = @intFromPtr(comp_array.ptr);
        const end = @intFromPtr(comp_array.ptr) + comp_array.len + comp.id.size;
        assert(loc >= start and loc <= end);

        const index = (loc - start) / comp.id.size;
        return .{ .key = .{
            .index = @intCast(index),
            .generation = es.slots.generations[index],
        } };
    }

    /// Pops a reserved entity.
    ///
    /// A reserved entity is given a persistent key, but no storage. As such, it will behave like
    /// an empty entity, but not show up in iteration.
    ///
    /// You can commit a reserved entity explicitly with `commit`, but this isn't usually
    /// necessary as adding or attempting to remove a component implicitly commits the entity.
    pub fn reserve(cb: *CmdBuf) Entity {
        return reserveOrErr(cb) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `reserve`, but returns `error.ZcsReservedEntityUnderflow` if there are no
    /// more reserved entities instead of panicking.
    pub fn reserveOrErr(cb: *CmdBuf) error{ZcsReservedEntityUnderflow}!Entity {
        return cb.reserved.pop() orelse error.ZcsReservedEntityUnderflow;
    }

    /// Similar to `reserve`, but reserves a new entity instead of popping one from a command
    /// buffers reserve. Prefer `reserve`.
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
    pub fn destroy(self: @This(), cb: *CmdBuf) void {
        self.destroyOrErr(cb) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `destroy`, but returns `error.ZcsCmdBufOverflow` on failure instead of
    /// panicking.
    pub fn destroyOrErr(self: @This(), cb: *CmdBuf) error{ZcsCmdBufOverflow}!void {
        // Restore the state on failure
        const restore = cb.*;
        errdefer cb.* = restore;
        try Cmd.encode(cb, .{ .bind_entity = self });
        try Cmd.encode(cb, .destroy);
    }

    /// Similar to `destroy`, but destroys the entity immediately. Prefer `destroy`.
    ///
    /// Invalidates iterators.
    pub fn destroyImmediate(self: @This(), es: *Entities) bool {
        invalidateIterators(es);
        if (es.slots.get(self.key)) |slot| {
            if (!slot.committed) es.reserved_entities -= 1;
            es.live.unset(self.key.index);
            es.slots.remove(self.key);
            return true;
        } else {
            return false;
        }
    }

    /// Similar to `destroyImmediate`, allows the key to be reused.
    ///
    /// Invalidates iterators.
    pub fn recycleImmediate(self: @This(), es: *Entities) bool {
        invalidateIterators(es);
        if (es.slots.get(self.key)) |slot| {
            if (!slot.committed) es.reserved_entities -= 1;
            es.live.unset(self.key.index);
            es.slots.recycle(self.key);
            return true;
        } else {
            return false;
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
    pub fn has(self: @This(), es: *const Entities, T: type) bool {
        return self.hasId(es, typeId(T));
    }

    /// Similar to `has`, but operates on component IDs instead of types.
    pub fn hasId(self: @This(), es: *const Entities, id: TypeId) bool {
        const flag = id.comp_flag orelse return false;
        const arch = self.getArch(es);
        return arch.contains(flag);
    }

    /// Retrieves the given component type. Returns null if the entity does not have this component
    /// or has been destroyed.
    pub fn get(self: @This(), es: *const Entities, T: type) ?*T {
        const untyped = self.getId(es, typeId(T)) orelse return null;
        // Don't need `.ptr` once this is merged: https://github.com/ziglang/zig/pull/22706
        return @alignCast(@ptrCast(untyped.ptr));
    }

    /// Similar to `get`, but operates on component IDs instead of types.
    pub fn getId(self: @This(), es: *const Entities, id: TypeId) ?[]u8 {
        const flag = id.comp_flag orelse return null;
        if (!self.hasId(es, id)) return null;

        // See `Entity.from`.
        if (id.size == 0) return @as([*]u8, @ptrFromInt(@as(u64, @bitCast(self))))[0..0];

        const comp_buffer = es.comps[@intFromEnum(flag)];
        const comp_offset = self.key.index * id.size;
        const bytes = comp_buffer.ptr + comp_offset;
        return bytes[0..id.size];
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
    pub inline fn add(self: @This(), cb: *CmdBuf, T: type, comp: T) void {
        self.addOrErr(cb, T, comp) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `add`, but returns `error.ZcsCmdBufOverflow` on error instead of panicking.
    pub inline fn addOrErr(
        self: @This(),
        cb: *CmdBuf,
        T: type,
        comp: T,
    ) error{ZcsCmdBufOverflow}!void {
        if (@sizeOf(T) > @sizeOf(*T) and isComptimeKnown(comp)) {
            const Interned = struct {
                const value = comp;
            };
            try self.addAnyPtr(cb, .init(T, comptime &Interned.value));
        } else {
            try self.addAnyVal(cb, .init(T, &comp));
        }
    }

    /// Similar to `addOrErr`, but doesn't require compile time types and forces the component to be
    /// copied by value to the command buffer. Prefer `add`.
    pub fn addAnyVal(self: @This(), cb: *CmdBuf, comp: Any) error{ZcsCmdBufOverflow}!void {
        // Restore the state on failure
        const restore = cb.*;
        errdefer cb.* = restore;

        // Issue the commands
        try Cmd.encode(cb, .{ .bind_entity = self });
        try Cmd.encode(cb, .{ .add_comp_val = comp });
    }

    /// Similar to `addOrErr`, but doesn't require compile time types and forces the component to be
    /// copied by pointer to the command buffer. Prefer `add`.
    pub fn addAnyPtr(self: @This(), cb: *CmdBuf, comp: Any) error{ZcsCmdBufOverflow}!void {
        // Restore the state on failure
        const restore = cb.*;
        errdefer cb.* = restore;

        // Issue the commands
        try Cmd.encode(cb, .{ .bind_entity = self });
        try Cmd.encode(cb, .{ .add_comp_ptr = comp });
    }

    /// Queues an extension command.
    ///
    /// Adding commands to an entity that no longer exists has no effect.
    ///
    /// See notes on `add` with regards to performance and pass by value vs pointer.
    pub inline fn cmd(self: @This(), cb: *CmdBuf, T: type, payload: T) void {
        self.cmdOrErr(cb, T, payload) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `cmd`, but returns `error.ZcsCmdBufOverflow` on failure instead of
    /// panicking.
    pub inline fn cmdOrErr(
        self: @This(),
        cb: *CmdBuf,
        T: type,
        payload: T,
    ) error{ZcsCmdBufOverflow}!void {
        if (@sizeOf(T) > @sizeOf(*T) and isComptimeKnown(payload)) {
            const Interned = struct {
                const value = payload;
            };
            try self.cmdAnyPtr(cb, .init(T, comptime &Interned.value));
        } else {
            try self.cmdAnyVal(cb, .init(T, &payload));
        }
    }

    /// Similar to `cmdOrErr`, but doesn't require compile time types and forces the command to be
    /// copied by value to the command buffer. Prefer `cmd`.
    pub fn cmdAnyVal(self: @This(), cb: *CmdBuf, payload: Any) error{ZcsCmdBufOverflow}!void {
        // Restore the state on failure
        const restore = cb.*;
        errdefer cb.* = restore;

        // Issue the commands
        try Cmd.encode(cb, .{ .bind_entity = self });
        try Cmd.encode(cb, .{ .ext_val = payload });
    }

    /// Similar to `cmdOrErr`, but doesn't require compile time types and forces the command to be
    /// copied by pointer to the command buffer. Prefer `cmd`.
    pub fn cmdAnyPtr(self: @This(), cb: *CmdBuf, payload: Any) error{ZcsCmdBufOverflow}!void {
        // Restore the state on failure
        const restore = cb.*;
        errdefer cb.* = restore;

        // Issue the commands
        try Cmd.encode(cb, .{ .bind_entity = self });
        try Cmd.encode(cb, .{ .ext_ptr = payload });
    }

    /// Queues the given component to be removed. Has no effect if the component is not present, or
    /// the entity no longer exists.
    ///
    /// See note on `add` with regards to performance.
    pub fn remove(
        self: @This(),
        cb: *CmdBuf,
        T: type,
    ) void {
        self.removeId(cb, typeId(T)) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `remove`, but doesn't require compile time types and returns
    /// `error.ZcsCmdBufOverflow` instead of panicking on failure.
    pub fn removeId(
        self: @This(),
        cb: *CmdBuf,
        id: TypeId,
    ) error{ZcsCmdBufOverflow}!void {
        // Restore the state on failure
        const restore = cb.*;
        errdefer cb.* = restore;

        // Issue the commands
        try Cmd.encode(cb, .{ .bind_entity = self });
        try Cmd.encode(cb, .{ .remove_comp = id });
    }

    /// Queues the entity to be committed. Has no effect if it has already been committed, called
    /// implicitly on add/remove/cmd. In practice only necessary when creating an empty entity.
    pub fn commit(self: @This(), cb: *CmdBuf) void {
        self.commitOrErr(cb) catch |err|
            @panic(@errorName(err));
    }
    /// Similar to `commit`, but returns `error.ZcsCmdBufOverflow` on failure instead of
    /// panicking.
    pub fn commitOrErr(self: @This(), cb: *CmdBuf) error{ZcsCmdBufOverflow}!void {
        // Restore the state on failure
        const restore = cb.*;
        errdefer cb.* = restore;

        // Issue the subcommand
        try Cmd.encode(cb, .{ .bind_entity = self });
    }

    pub const ChangeArchImmediateOptions = struct {
        add: []const Any = &.{},
        remove: CompFlag.Set = .initEmpty(),
    };

    /// Adds the listed components and then removes the listed component IDs.
    ///
    /// Returns `true` if the change was made, returns `false` if it couldn't be made because the
    /// entity doesn't exist.
    pub fn changeArchImmediate(
        self: @This(),
        es: *Entities,
        changes: ChangeArchImmediateOptions,
    ) bool {
        return self.changeArchImmediateOrErr(es, changes) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `changeArchImmediate`, but returns `error.ZcsCompOverflow` on failure instead
    /// of panicking.
    pub fn changeArchImmediateOrErr(
        self: @This(),
        es: *Entities,
        changes: ChangeArchImmediateOptions,
    ) error{ZcsCompOverflow}!bool {
        // Early out if the entity does not exist, also checks some assertions
        if (!self.exists(es)) return false;

        // Build a set of component types to add/remove
        var add_comps: CompFlag.Set = .{};
        for (changes.add) |comp| {
            add_comps.insert(CompFlag.registerImmediate(comp.id));
        }

        // Apply the archetype change. We already verified the entity exists.
        assert(try self.changeArchUninitImmediateOrErr(es, .{
            .add = add_comps,
            .remove = changes.remove,
        }));

        // Initialize the components
        for (changes.add) |comp| {
            // Unwrapping the flag is safe because we already registered it above
            const flag = comp.id.comp_flag.?;
            if (!changes.remove.contains(flag)) {
                // Unwrapping the component is safe because we added it above
                const dest = self.getId(es, comp.id).?;
                @memcpy(dest, comp.bytes());
            }
        }

        return true;
    }

    /// Options for the uninitialized variants of change archetype.
    pub const ChangeArchUninitImmediateOptions = struct {
        /// Component types to remove.
        remove: CompFlag.Set = .{},
        /// Component types to add.
        add: CompFlag.Set = .{},
    };

    /// Similar to `changeArchetypeOrErr`, but does not initialize the components. Furthermore, any
    /// added component's values are considered undefined after this call, even if they were
    /// previously initialized.
    pub fn changeArchUninitImmediateOrErr(
        self: @This(),
        es: *Entities,
        options: ChangeArchUninitImmediateOptions,
    ) error{ZcsCompOverflow}!bool {
        invalidateIterators(es);

        // Get the slot
        const slot = es.slots.get(self.key) orelse return false;

        // Check if we have enough space
        var added = options.add.differenceWith(options.remove).iterator();
        while (added.next()) |flag| {
            const id = flag.getId();
            const comp_buffer = es.comps[@intFromEnum(flag)];
            const comp_offset = self.key.index * id.size;
            if (id.size > 0 and comp_offset + id.size > comp_buffer.len) {
                return error.ZcsCompOverflow;
            }
            @memset(comp_buffer[comp_offset .. comp_offset + id.size], undefined);
        }

        // Commit the slot and change the archetype
        if (!slot.committed) {
            es.reserved_entities -= 1;
            slot.committed = true;
        }
        slot.arch = slot.arch.unionWith(options.add);
        slot.arch = slot.arch.differenceWith(options.remove);

        return true;
    }

    /// Returns this entity as an optional.
    pub fn toOptional(self: @This()) Optional {
        return .{ .key = self.key.toOptional() };
    }

    /// Initializes a `view`, returning `null` if this entity does not exist or is missing any
    /// required components.
    pub fn view(self: @This(), es: *const Entities, View: type) ?View {
        // Check if entity has the required components
        const slot = es.slots.get(self.key) orelse return null;
        var view_arch: CompFlag.Set = .{};
        inline for (@typeInfo(View).@"struct".fields) |field| {
            if (field.type != Entity and @typeInfo(field.type) != .optional) {
                const Unwrapped = zcs.view.UnwrapField(field.type);
                const flag = typeId(Unwrapped).comp_flag orelse return null;
                view_arch.insert(flag);
            }
        }
        if (!slot.arch.supersetOf(view_arch)) return null;

        // Fill in the view and return it
        return self.viewAssumeArch(es, View);
    }

    /// Similar to `view`, but will attempt to fill in any non-optional missing components with
    /// the defaults from the `comps` view if present.
    pub fn viewOrAddImmediate(
        self: @This(),
        es: *Entities,
        View: type,
        comps: anytype,
    ) ?View {
        return self.viewOrAddImmediateOrErr(es, View, comps) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `viewOrAddImmediate` but returns, but returns `error.ZcsCompOverflow`
    /// on failure instead of panicking.
    pub fn viewOrAddImmediateOrErr(
        self: @This(),
        es: *Entities,
        View: type,
        comps: anytype,
    ) error{ZcsCompOverflow}!?View {
        // Create the view, possibly leaving some components uninitialized
        const result = (try self.viewOrAddUninitImmediateOrErr(es, View)) orelse return null;

        // Fill in any uninitialized components and return the view
        inline for (@typeInfo(View).@"struct".fields) |field| {
            const Unwrapped = zcs.view.UnwrapField(field.type);
            if (@hasField(@TypeOf(comps), field.name) and
                result.uninitialized.contains(typeId(Unwrapped).comp_flag.?))
            {
                @field(result.view, field.name).* = @field(comps, field.name).*;
            }
        }
        return result.view;
    }

    /// The result of a `viewOrAddUninit*` call.
    pub fn VoaUninitResult(View: type) type {
        return struct {
            uninitialized: CompFlag.Set,
            view: View,
        };
    }

    /// Similar to `viewOrAddImmediate`, but leaves the added components uninitialized.
    pub fn viewOrAddUninitImmediate(
        self: @This(),
        es: *Entities,
        View: type,
    ) ?VoaUninitResult(View) {
        return self.viewOrAddUninitImmediate(es, View) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `viewOrAddImmediate`, but returns `error.ZcsCompOverflow` on failure instead
    /// of panicking.
    pub fn viewOrAddUninitImmediateOrErr(
        self: @This(),
        es: *Entities,
        View: type,
    ) error{ZcsCompOverflow}!?VoaUninitResult(View) {
        // Figure out which components are missing
        const slot = es.slots.get(self.key) orelse return null;
        var view_arch: CompFlag.Set = .{};
        inline for (@typeInfo(View).@"struct".fields) |field| {
            if (field.type != Entity and @typeInfo(field.type) != .optional) {
                const Unwrapped = zcs.view.UnwrapField(field.type);
                const flag = CompFlag.registerImmediate(typeId(Unwrapped));
                view_arch.insert(flag);
            }
        }
        const uninitialized = view_arch.differenceWith(slot.arch);
        if (!slot.arch.supersetOf(view_arch)) {
            assert(try self.changeArchUninitImmediateOrErr(es, .{ .add = uninitialized }));
        }

        // Create and return the view
        return .{
            .view = self.viewAssumeArch(es, View),
            .uninitialized = uninitialized,
        };
    }

    /// Returns a view, asserts that the archetype is compatible.
    fn viewAssumeArch(self: @This(), es: *const Entities, View: type) View {
        var result: View = undefined;
        inline for (@typeInfo(View).@"struct".fields) |field| {
            const Unwrapped = zcs.view.UnwrapField(field.type);
            if (Unwrapped == Entity) {
                @field(result, field.name) = self;
                continue;
            }

            const comp = self.get(es, Unwrapped);
            if (@typeInfo(field.type) == .optional) {
                @field(result, field.name) = comp;
            } else {
                @field(result, field.name) = comp.?;
            }
        }
        return result;
    }

    /// Default formatting.
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
    pub fn getArch(self: @This(), es: *const Entities) CompFlag.Set {
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
