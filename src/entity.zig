const std = @import("std");
const assert = std.debug.assert;

const zcs = @import("root.zig");
const meta = @import("meta.zig");

const typeId = zcs.typeId;

const Subcmd = @import("subcmd.zig").Subcmd;

const Entities = zcs.Entities;
const Any = zcs.Any;
const CompFlag = zcs.CompFlag;
const CmdBuf = zcs.CmdBuf;
const TypeId = zcs.TypeId;
const HandleTab = zcs.storage.HandleTab;
const Chunk = zcs.storage.Chunk;

/// An entity.
///
/// Entity handles are persistent, you can check if an entity has been destroyed via
/// `Entity.exists`. This is useful for dynamic systems like games where object lifetime may depend
/// on user input.
///
/// Methods that take a command buffer append the command to a command buffer for execution at a
/// later time. Methods with `immediate` in the name are executed immediately, usage of these is
/// discouraged as they are not valid while iterating unless otherwise noted and are not thread
/// safe.
pub const Entity = packed struct {
    pub const Optional = packed struct {
        pub const none: @This() = .{ .key = .none };

        key: HandleTab.Key.Optional,

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

    key: HandleTab.Key,

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
            //
            // We also comptime assert that the invalid generation is zero, this guarantees that the
            // entity ID can never be comprised of all zeroes, which would be illegal since we are
            // storing it as a non optional pointer.
            const Key = @FieldType(Entity, "key");
            const Generation = @FieldType(Key, "generation");
            comptime assert(@intFromEnum(Generation.invalid) == 0);
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
            .generation = es.handle_tab.generations[index],
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

    /// Similar to `reserve`, but returns an error on failure instead of panicking.
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
        const key = es.handle_tab.put(.reserved) catch |err| switch (err) {
            error.Overflow => return error.ZcsEntityOverflow,
        };
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
        try Subcmd.encode(cb, .{ .bind_entity = self });
        try Subcmd.encode(cb, .destroy);
    }

    /// Similar to `destroy`, but destroys the entity immediately. Prefer `destroy`.
    ///
    /// Invalidates iterators.
    pub fn destroyImmediate(self: @This(), es: *Entities) bool {
        invalidateIterators(es);
        if (es.handle_tab.get(self.key)) |entity_loc| {
            if (entity_loc.chunk) |chunk| {
                chunk.swapRemove(es, entity_loc.index_in_chunk);
            } else {
                es.reserved_entities -= 1;
            }
            es.handle_tab.remove(self.key);
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
        if (es.handle_tab.get(self.key)) |entity_loc| {
            if (entity_loc.chunk) |chunk| {
                chunk.swapRemove(&es.handle_tab, entity_loc.index_in_chunk);
            } else {
                es.reserved_entities -= 1;
            }
            es.live.unset(self.key.index);
            es.handle_tab.recycle(self.key);
            return true;
        } else {
            return false;
        }
    }

    /// Returns true if the entity has not been destroyed.
    pub fn exists(self: @This(), es: *const Entities) bool {
        return es.handle_tab.containsKey(self.key);
    }

    /// Returns true if the entity exists and has been committed, otherwise returns false.
    pub fn committed(self: @This(), es: *const Entities) bool {
        const entity_loc = es.handle_tab.get(self.key) orelse return false;
        return entity_loc.chunk != null;
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
        return @alignCast(@ptrCast(untyped));
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
        // Don't get tempted to remove inline from here! It's required for `isComptimeKnown`.
        comptime assert(@typeInfo(@TypeOf(add)).@"fn".calling_convention == .@"inline");
        self.addOrErr(cb, T, comp) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `add`, but returns an error on failure instead of panicking.
    pub inline fn addOrErr(
        self: @This(),
        cb: *CmdBuf,
        T: type,
        comp: T,
    ) error{ZcsCmdBufOverflow}!void {
        // Don't get tempted to remove inline from here! It's required for `isComptimeKnown`.
        comptime assert(@typeInfo(@TypeOf(addOrErr)).@"fn".calling_convention == .@"inline");
        if (@sizeOf(T) > @sizeOf(*T) and meta.isComptimeKnown(comp)) {
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
        try Subcmd.encode(cb, .{ .bind_entity = self });
        try Subcmd.encode(cb, .{ .add_val = comp });
    }

    /// Similar to `addOrErr`, but doesn't require compile time types and forces the component to be
    /// copied by pointer to the command buffer. Prefer `add`.
    pub fn addAnyPtr(self: @This(), cb: *CmdBuf, comp: Any) error{ZcsCmdBufOverflow}!void {
        // Restore the state on failure
        const restore = cb.*;
        errdefer cb.* = restore;

        // Issue the commands
        try Subcmd.encode(cb, .{ .bind_entity = self });
        try Subcmd.encode(cb, .{ .add_ptr = comp });
    }

    /// Queues the given component to be removed. Has no effect if the component is not present, or
    /// the entity no longer exists.
    ///
    /// See note on `add` with regards to performance.
    pub fn remove(self: @This(), cb: *CmdBuf, T: type) void {
        self.removeId(cb, typeId(T)) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `remove`, but doesn't require compile time types and returns an error on failure
    /// instead of panicking on failure.
    pub fn removeId(self: @This(), cb: *CmdBuf, id: TypeId) error{ZcsCmdBufOverflow}!void {
        // Restore the state on failure
        const restore = cb.*;
        errdefer cb.* = restore;

        // Issue the commands
        try Subcmd.encode(cb, .{ .bind_entity = self });
        try Subcmd.encode(cb, .{ .remove = id });
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
        try Subcmd.encode(cb, .{ .bind_entity = self });
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

    /// Similar to `changeArchImmediate`, but returns an error on failure instead of panicking.
    pub fn changeArchImmediateOrErr(
        self: @This(),
        es: *Entities,
        changes: ChangeArchImmediateOptions,
    ) error{ ZcsCompOverflow, ZcsArchOverflow, ZcsChunkOverflow, ZcsChunkPoolOverflow }!bool {
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
    ///
    /// May change internal allocator state even on failure, chunk lists are not destroyed even if
    /// no chunks could be allocated for them at this time.
    pub fn changeArchUninitImmediateOrErr(
        self: @This(),
        es: *Entities,
        options: ChangeArchUninitImmediateOptions,
    ) error{ ZcsCompOverflow, ZcsArchOverflow, ZcsChunkOverflow, ZcsChunkPoolOverflow }!bool {
        invalidateIterators(es);

        // Get the handle value and figure out the new arch
        const entity_loc = es.handle_tab.get(self.key) orelse return false;
        var new_arch = entity_loc.getArch(&es.chunk_lists);
        new_arch = new_arch.unionWith(options.add);
        new_arch = new_arch.differenceWith(options.remove);

        // If the entity is committed and the arch hasn't changed, early out
        if (entity_loc.chunk) |chunk| {
            const chunk_header = chunk.getHeaderConst();
            if (chunk_header.getArch(&es.chunk_lists).eql(new_arch)) {
                return true;
            }
        }

        // Get the archetype list
        const chunk_list = try es.chunk_lists.getOrPut(new_arch);

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

        // Commit the change
        const new_loc = try chunk_list.append(es, self);
        if (entity_loc.chunk) |chunk| {
            chunk.swapRemove(es, entity_loc.index_in_chunk);
        } else {
            es.reserved_entities -= 1;
        }
        entity_loc.* = new_loc;

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
        const entity_loc = es.handle_tab.get(self.key) orelse return null;
        var view_arch: CompFlag.Set = .{};
        inline for (@typeInfo(View).@"struct".fields) |field| {
            if (field.type != Entity and @typeInfo(field.type) != .optional) {
                const Unwrapped = zcs.view.UnwrapField(field.type);
                const flag = typeId(Unwrapped).comp_flag orelse return null;
                view_arch.insert(flag);
            }
        }
        if (!entity_loc.getArch(&es.chunk_lists).supersetOf(view_arch)) return null;

        // Fill in the view and return it
        return self.viewAssumeArch(es, View);
    }

    /// Similar to `viewOrAddImmediate`, but for a single component.
    pub fn getOrAddImmediate(
        self: @This(),
        es: *Entities,
        T: type,
        default: T,
    ) ?T {
        return self.getOrAddImmediateOrErr(es, T, default) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `getOrAddImmediate`, but for a single component.
    pub fn getOrAddImmediateOrErr(
        self: @This(),
        es: *Entities,
        T: type,
        default: T,
    ) error{ ZcsCompOverflow, ZcsArchOverflow, ZcsChunkOverflow, ZcsChunkPoolOverflow }!?*T {
        const result = try self.viewOrAddImmediateOrErr(es, struct { *T }, .{&default}) orelse
            return null;
        return result[0];
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

    /// Similar to `viewOrAddImmediate` but returns, but returns an error on failure instead of
    /// panicking.
    pub fn viewOrAddImmediateOrErr(
        self: @This(),
        es: *Entities,
        View: type,
        comps: anytype,
    ) error{ ZcsCompOverflow, ZcsArchOverflow, ZcsChunkOverflow, ZcsChunkPoolOverflow }!?View {
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

    /// Similar to `viewOrAddImmediate`, but returns an error on failure instead of panicking.
    pub fn viewOrAddUninitImmediateOrErr(self: @This(), es: *Entities, View: type) error{
        ZcsCompOverflow,
        ZcsArchOverflow,
        ZcsChunkOverflow,
        ZcsChunkPoolOverflow,
    }!?VoaUninitResult(View) {
        // Figure out which components are missing
        const entity_loc = es.handle_tab.get(self.key) orelse return null;
        var view_arch: CompFlag.Set = .{};
        inline for (@typeInfo(View).@"struct".fields) |field| {
            if (field.type != Entity and @typeInfo(field.type) != .optional) {
                const Unwrapped = zcs.view.UnwrapField(field.type);
                const flag = CompFlag.registerImmediate(typeId(Unwrapped));
                view_arch.insert(flag);
            }
        }
        const arch = entity_loc.getArch(&es.chunk_lists);
        const uninitialized = view_arch.differenceWith(arch);
        if (!arch.supersetOf(view_arch)) {
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
        const entity_loc = es.handle_tab.get(self.key) orelse return .{};
        return entity_loc.getArch(&es.chunk_lists);
    }

    /// Explicitly invalidates iterators to catch bugs in debug builds.
    fn invalidateIterators(es: *Entities) void {
        if (@FieldType(Entities, "iterator_generation") != u0) {
            es.iterator_generation +%= 1;
        }
    }
};
