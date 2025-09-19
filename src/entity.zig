const std = @import("std");
const assert = std.debug.assert;

const zcs = @import("root.zig");

const typeId = zcs.typeId;

const Subcmd = @import("subcmd.zig").Subcmd;

const Entities = zcs.Entities;
const PointerLock = zcs.PointerLock;
const Any = zcs.Any;
const CompFlag = zcs.CompFlag;
const CmdBuf = zcs.CmdBuf;
const TypeId = zcs.TypeId;
const HandleTab = zcs.HandleTab;
const Chunk = zcs.Chunk;
const ChunkPool = zcs.ChunkPool;
const ChunkList = zcs.storage.ChunkList;
const meta = zcs.meta;

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
    /// An entity without its generation. Used by some lower level APIs to save space where the
    /// safety of the generation is not needed, should not be stored long term outside of the ECS.
    pub const Index = enum(HandleTab.Key.Index) {
        _,

        /// Converts the entity index to an `Entity` with the corresponding generation. Assumes that
        /// the index is not dangling, this cannot be reliably enforced without the generation.
        pub fn toEntity(self: @This(), es: *const Entities) Entity {
            const result: Entity = .{ .key = .{
                .index = @intFromEnum(self),
                .generation = es.handle_tab.slots[@intFromEnum(self)].generation,
            } };
            assert(result.key.generation != .invalid);
            assert(result.key.index < es.handle_tab.next_index);
            return result;
        }
    };

    /// The location an entity is stored.
    ///
    /// This indirection allows entities to be relocated without invalidating their handles.
    pub const Location = struct {
        /// The index of an entity in a chunk.
        pub const IndexInChunk = enum(u32) { _ };

        /// A handle that's been reserved but not committed.
        pub const reserved: @This() = .{
            .chunk = .none,
            .index_in_chunk = if (std.debug.runtime_safety)
                @enumFromInt(std.math.maxInt(@typeInfo(IndexInChunk).@"enum".tag_type))
            else
                undefined,
        };

        /// The chunk where this entity is stored, or `null` if it hasn't been committed.
        chunk: Chunk.Index = .none,
        /// The entity's index in the chunk, value is unspecified if not committed.
        index_in_chunk: IndexInChunk,

        /// Returns the archetype for this entity, or the empty archetype if it hasn't been
        /// committed.
        pub fn arch(self: @This(), es: *const Entities) CompFlag.Set {
            const chunk = self.chunk.get(&es.chunk_pool) orelse return .{};
            const header = chunk.header();
            return header.arch(&es.arches);
        }
    };

    pub const Optional = packed struct {
        pub const none: @This() = .{ .key = .none };

        key: HandleTab.Key.Optional,

        /// Unwraps the optional entity into `Entity`, or returns `null` if it is `.none`.
        pub fn unwrap(self: @This()) ?Entity {
            if (self.key.unwrap()) |key| return .{ .key = key };
            return null;
        }

        /// Default formatting.
        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            return self.key.format(writer);
        }

        pub fn eql(self: @This(), other: @This()) bool {
            return self.key.eql(other.key);
        }
    };

    key: HandleTab.Key,

    pub fn eql(self: @This(), other: @This()) bool {
        return self.key.eql(other.key);
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
    /// This does not invalidate pointers, but it's not thread safe.
    pub fn reserveImmediate(es: *Entities) Entity {
        return reserveImmediateOrErr(es) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `reserveImmediate`, but returns `error.ZcsEntityOverflow` on failure instead of
    /// panicking.
    ///
    /// This does not invalidate pointers, but it's not thread safe.
    pub fn reserveImmediateOrErr(es: *Entities) error{ZcsEntityOverflow}!Entity {
        const pointer_lock = es.pointer_generation.lock();
        defer pointer_lock.check(es.pointer_generation);

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
    /// panicking. The command buffer is left in an undefined state on error, see the top level
    /// documentation on `CmdBuf` for more info.
    pub fn destroyOrErr(self: @This(), cb: *CmdBuf) error{ZcsCmdBufOverflow}!void {
        try Subcmd.encodeDestroy(cb, self);
    }

    /// Similar to `destroy`, but destroys the entity immediately. Prefer `destroy`.
    ///
    /// Invalidates pointers.
    pub fn destroyImmediate(self: @This(), es: *Entities) bool {
        es.pointer_generation.increment();
        if (es.handle_tab.get(self.key)) |entity_loc| {
            if (entity_loc.chunk.get(&es.chunk_pool)) |chunk| {
                chunk.swapRemove(es, entity_loc.index_in_chunk);
            } else {
                es.reserved_entities -= 1;
            }
            es.handle_tab.remove(self.key);
            entity_loc.* = undefined;
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
        return entity_loc.chunk != .none;
    }

    /// Returns true if the entity has the given component type, false otherwise or if the entity
    /// has been destroyed.
    pub fn has(self: @This(), es: *const Entities, T: type) bool {
        return self.hasId(es, typeId(T));
    }

    /// Similar to `has`, but operates on component IDs instead of types.
    pub fn hasId(self: @This(), es: *const Entities, id: TypeId) bool {
        const flag = id.comp_flag orelse return false;
        return self.arch(es).contains(flag);
    }

    /// Retrieves the given component type. Returns null if the entity does not have this component
    /// or has been destroyed. See also `Entities.getComp`.
    pub fn get(self: @This(), es: *const Entities, T: type) ?*T {
        // We could use `compsFromId` here, but we a measurable performance improvement in
        // benchmarks by calculating the result directly
        const entity_loc = es.handle_tab.get(self.key) orelse return null;
        const chunk = entity_loc.chunk.get(&es.chunk_pool) orelse return null;
        const flag = typeId(T).comp_flag orelse return null;
        // https://github.com/Games-by-Mason/ZCS/issues/24
        const offset = chunk.header().comp_buf_offsets.values[@intFromEnum(flag)];
        if (offset == 0) return null;
        const comps_addr = @intFromPtr(chunk) + offset;
        const comp_addr = comps_addr + @sizeOf(T) * @intFromEnum(entity_loc.index_in_chunk);
        return @ptrFromInt(comp_addr);
    }

    /// Similar to `get`, but operates on component IDs instead of types.
    pub fn getId(self: @This(), es: *const Entities, id: TypeId) ?[]u8 {
        const entity_loc = es.handle_tab.get(self.key) orelse return null;
        const chunk = entity_loc.chunk.get(&es.chunk_pool) orelse return null;
        const comps = chunk.compsFromId(id) orelse return null;
        return comps[@intFromEnum(entity_loc.index_in_chunk) * id.size ..][0..id.size];
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

    /// Similar to `add`, but returns an error on failure instead of panicking. The command buffer
    /// is left in an undefined state on error, see the top level documentation on `CmdBuf` for more
    /// info.
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
            try self.addPtr(cb, T, comptime &Interned.value);
        } else {
            try self.addVal(cb, T, comp);
        }
    }

    /// Similar to `addOrErr`, but forces the component to be copied by value to the command buffer.
    /// Prefer `add`.
    pub fn addVal(self: @This(), cb: *CmdBuf, T: type, comp: T) error{ZcsCmdBufOverflow}!void {
        try Subcmd.encodeAddVal(cb, self, T, comp);
    }

    /// Similar to `addOrErr`, forces the component to be copied by pointer to the command buffer.
    /// Prefer `add`.
    pub fn addPtr(
        self: @This(),
        cb: *CmdBuf,
        T: type,
        comp: *const T,
    ) error{ZcsCmdBufOverflow}!void {
        try Subcmd.encodeAddPtr(cb, self, T, comp);
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
    /// instead of panicking on failure. The command buffer is left in an undefined state on error,
    /// see the top level documentation on `CmdBuf` for more info.
    pub fn removeId(self: @This(), cb: *CmdBuf, id: TypeId) error{ZcsCmdBufOverflow}!void {
        try Subcmd.encodeRemove(cb, self, id);
    }

    /// Queues the entity to be committed. Has no effect if it has already been committed, called
    /// implicitly on add/remove/cmd. In practice only necessary when creating an empty entity.
    pub fn commit(self: @This(), cb: *CmdBuf) void {
        self.commitOrErr(cb) catch |err|
            @panic(@errorName(err));
    }
    /// Similar to `commit`, but returns `error.ZcsCmdBufOverflow` on failure instead of
    /// panicking. The command buffer is left in an undefined state on error, see the top level
    /// documentation on `CmdBuf` for more info.
    pub fn commitOrErr(self: @This(), cb: *CmdBuf) error{ZcsCmdBufOverflow}!void {
        try Subcmd.encodeCommit(cb, self);
    }

    /// Options for `changeArchImmediate`.
    pub fn ChangeArchImmediateOptions(Add: type) type {
        comptime var has_defaults = true;
        for (@typeInfo(Add).@"struct".fields) |field| {
            if (field.default_value_ptr == null) {
                has_defaults = false;
                break;
            }
        }
        if (has_defaults) {
            return struct {
                add: Add = .{},
                remove: CompFlag.Set = .{},
            };
        } else {
            return struct {
                add: Add,
                remove: CompFlag.Set = .{},
            };
        }
    }

    /// Adds the listed components and then removes the listed component IDs.
    ///
    /// `Add` is a tuple or struct of components that may be added by `changes`. They may be
    /// optional types to allow deciding whether or not to add them at runtime.
    ///
    /// Returns `true` if the change was made, returns `false` if it couldn't be made because the
    /// entity doesn't exist.
    ///
    /// Invalidates pointers.
    pub fn changeArchImmediate(
        self: @This(),
        es: *Entities,
        Add: type,
        changes: ChangeArchImmediateOptions(Add),
    ) bool {
        return self.changeArchImmediateOrErr(es, Add, changes) catch |err|
            @panic(@errorName(err));
    }

    /// Similar to `changeArchImmediate`, but returns an error on failure instead of panicking.
    pub fn changeArchImmediateOrErr(
        self: @This(),
        es: *Entities,
        Add: type,
        changes: ChangeArchImmediateOptions(Add),
    ) error{ ZcsArchOverflow, ZcsChunkOverflow, ZcsChunkPoolOverflow }!bool {
        es.pointer_generation.increment();

        // Build a set of component types to add/remove
        var add_comps: CompFlag.Set = .{};
        inline for (@typeInfo(Add).@"struct".fields) |field| {
            const Comp = zcs.view.Unwrap(field.type);
            if (@typeInfo(field.type) != .optional or @field(changes.add, field.name) != null) {
                add_comps.insert(CompFlag.registerImmediate(typeId(Comp)));
            }
        }

        // Apply the archetype change, early out if the entity doesn't exist
        if (!try self.changeArchUninitImmediateOrErr(es, .{
            .add = add_comps,
            .remove = changes.remove,
        })) return false;

        const entity_loc = es.handle_tab.get(self.key).?;
        const new_chunk = entity_loc.chunk.get(&es.chunk_pool).?;
        inline for (@typeInfo(Add).@"struct".fields) |field| {
            const Comp = zcs.view.Unwrap(field.type);
            if (@typeInfo(field.type) != .optional or @field(changes.add, field.name) != null) {
                // Unwrapping the flag is safe because we already registered it above
                const flag = typeId(Comp).comp_flag.?;
                if (!changes.remove.contains(flag)) {
                    // https://github.com/Games-by-Mason/ZCS/issues/24
                    const offset = new_chunk.header().comp_buf_offsets.values[@intFromEnum(flag)];
                    // Safe because we added it above
                    assert(offset != 0);
                    const comp: *Comp = @ptrFromInt(@intFromPtr(new_chunk) +
                        offset +
                        @intFromEnum(entity_loc.index_in_chunk) * @sizeOf(Comp));
                    comp.* = @as(?Comp, @field(changes.add, field.name)).?;
                }
            }
        }

        return true;
    }

    /// Options for `changeArchAnyImmediate`.
    pub const ChangeArchAnyImmediateOptions = struct {
        add: []const Any = &.{},
        remove: CompFlag.Set = .initEmpty(),
    };

    /// Similar to `changeArchImmediateOrErr`, but doesn't require comptime types.
    pub fn changeArchAnyImmediate(
        self: @This(),
        es: *Entities,
        changes: ChangeArchAnyImmediateOptions,
    ) error{ ZcsArchOverflow, ZcsChunkOverflow, ZcsChunkPoolOverflow }!bool {
        es.pointer_generation.increment();

        // Build a set of component types to add/remove
        var add_comps: CompFlag.Set = .{};
        for (changes.add) |comp| {
            add_comps.insert(CompFlag.registerImmediate(comp.id));
        }

        // Apply the archetype change, early out if the entity doesn't exist
        if (!try self.changeArchUninitImmediateOrErr(es, .{
            .add = add_comps,
            .remove = changes.remove,
        })) return false;

        // Initialize the components
        const entity_loc = es.handle_tab.get(self.key).?;
        const chunk = entity_loc.chunk.get(&es.chunk_pool).?;
        for (changes.add) |comp| {
            // Unwrapping the flag is safe because we already registered it above
            const flag = comp.id.comp_flag.?;
            if (!changes.remove.contains(flag)) {
                // Unwrap okay because registered above
                // https://github.com/Games-by-Mason/ZCS/issues/24
                const offset = chunk.header().comp_buf_offsets.values[@intFromEnum(flag)];
                assert(offset != 0);
                const dest_unsized: [*]u8 = @ptrFromInt(@intFromPtr(chunk) +
                    offset +
                    @intFromEnum(entity_loc.index_in_chunk) * comp.id.size);
                const dest = dest_unsized[0..comp.id.size];
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
    ///
    /// Technically we could go slightly faster with compile time known types, similar to
    /// `changeArchImmediate` vs `changeArchAnyImmediate`. This works because `@memcpy` with a
    /// comptime known length tends to be a bit faster. However, in practice, these sorts of
    /// immediate arch changes are only done (or only done in bulk) when loading a level, which
    /// means this function is essentially a noop anyway since there won't be any data to move.
    pub fn changeArchUninitImmediateOrErr(
        self: @This(),
        es: *Entities,
        options: ChangeArchUninitImmediateOptions,
    ) error{ ZcsArchOverflow, ZcsChunkOverflow, ZcsChunkPoolOverflow }!bool {
        es.pointer_generation.increment();

        // Get the handle value and figure out the new arch
        const entity_loc = es.handle_tab.get(self.key) orelse return false;
        const old_chunk = entity_loc.chunk.get(&es.chunk_pool);
        const prev_arch = entity_loc.arch(es);
        var new_arch = prev_arch;
        new_arch = new_arch.unionWith(options.add);
        new_arch = new_arch.differenceWith(options.remove);

        // If the entity is committed and the arch hasn't changed, early out
        if (old_chunk) |chunk| {
            const chunk_header = chunk.header();
            if (chunk_header.arch(&es.arches).eql(new_arch)) {
                @branchHint(.unlikely);
                return true;
            }
        }

        // Get the new location. As mentioned in the doc comment, it's possible that we'll end up
        // creating a new chunk list but not be able to allocate any chunks for it.
        const chunk_list = try es.arches.getOrPut(&es.chunk_pool, new_arch);
        const new_loc = try chunk_list.append(es, self);
        const new_chunk = new_loc.chunk.get(&es.chunk_pool).?;
        errdefer comptime unreachable;

        // Initialize the new components to undefined
        if (std.debug.runtime_safety) {
            var added = options.add.differenceWith(options.remove).iterator();
            while (added.next()) |flag| {
                const id = flag.getId();
                const comp_buffer = new_chunk.compsFromId(id).?;
                const comp_offset = @intFromEnum(new_loc.index_in_chunk) * id.size;
                const comp = comp_buffer[comp_offset..][0..id.size];
                @memset(comp, undefined);
            }
        }

        // Copy components that aren't being overwritten from the old arch to the new one
        if (old_chunk) |prev_chunk| {
            var move = prev_arch.differenceWith(options.remove)
                .differenceWith(options.add).iterator();
            while (move.next()) |flag| {
                const id = flag.getId();

                const new_comp_buffer = new_chunk.compsFromId(id).?;
                const new_comp_offset = @intFromEnum(new_loc.index_in_chunk) * id.size;
                const new_comp = new_comp_buffer[new_comp_offset..][0..id.size];

                const prev_comp_buffer = prev_chunk.compsFromId(id).?;
                const prev_comp_offset = @intFromEnum(entity_loc.index_in_chunk) * id.size;
                const prev_comp = prev_comp_buffer[prev_comp_offset..][0..id.size];

                @memcpy(new_comp, prev_comp);
            }
        }

        // Commit the entity to the new location
        if (old_chunk) |chunk| {
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
        // Check if the entity has the requested components. If the number of components in the view
        // is very large, this measurably improves performance. The cost of the check when not
        // necessary doesn't appear to be measurable.
        const entity_loc = es.handle_tab.get(self.key) orelse return null;
        const chunk = entity_loc.chunk.get(&es.chunk_pool) orelse return null;
        const view_arch = zcs.view.comps(View, .{ .size = .one }) orelse return null;
        const entity_arch = chunk.header().list.arch(&es.arches);
        if (!entity_arch.supersetOf(view_arch)) return null;

        // Fill in the view and return it
        var result: View = undefined;
        inline for (@typeInfo(View).@"struct".fields) |field| {
            const Unwrapped = zcs.view.UnwrapField(field.type, .{ .size = .one });
            if (Unwrapped == Entity) {
                @field(result, field.name) = self;
            } else {
                // https://github.com/Games-by-Mason/ZCS/issues/24
                const offset = if (typeId(Unwrapped).comp_flag) |flag|
                    chunk.header().comp_buf_offsets.values[@intFromEnum(flag)]
                else
                    0;
                if (@typeInfo(field.type) == .optional and offset == 0) {
                    @field(result, field.name) = null;
                } else {
                    assert(offset != 0); // Archetype already checked
                    const comps_addr = @intFromPtr(chunk) + offset;
                    const comp_addr = comps_addr +
                        @intFromEnum(entity_loc.index_in_chunk) * @sizeOf(Unwrapped);
                    @field(result, field.name) = @ptrFromInt(comp_addr);
                }
            }
        }
        return result;
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
    ) error{ ZcsArchOverflow, ZcsChunkOverflow, ZcsChunkPoolOverflow }!?*T {
        const result = try self.viewOrAddImmediateOrErr(es, struct { *T }, .{&default}) orelse
            return null;
        return result[0];
    }

    /// Similar to `view`, but will attempt to fill in any non-optional missing components with
    /// the defaults from the `comps` view if present.
    ///
    /// Invalidates pointers.
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
    ) error{ ZcsArchOverflow, ZcsChunkOverflow, ZcsChunkPoolOverflow }!?View {
        // Create the view, possibly leaving some components uninitialized
        const result = (try self.viewOrAddUninitImmediateOrErr(es, View)) orelse return null;

        // Fill in any uninitialized components and return the view
        inline for (@typeInfo(View).@"struct".fields) |field| {
            const Unwrapped = zcs.view.UnwrapField(field.type, .{ .size = .one });
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
    pub fn viewOrAddUninitImmediateOrErr(
        self: @This(),
        es: *Entities,
        View: type,
    ) error{ ZcsArchOverflow, ZcsChunkOverflow, ZcsChunkPoolOverflow }!?VoaUninitResult(View) {
        es.pointer_generation.increment();

        // Figure out which components are missing
        const entity_loc = es.handle_tab.get(self.key) orelse return null;
        var view_arch: CompFlag.Set = .{};
        inline for (@typeInfo(View).@"struct".fields) |field| {
            if (field.type != Entity and @typeInfo(field.type) != .optional) {
                const Unwrapped = zcs.view.UnwrapField(field.type, .{ .size = .one });
                const flag = CompFlag.registerImmediate(typeId(Unwrapped));
                view_arch.insert(flag);
            }
        }
        const curr_arch = entity_loc.arch(es);
        const uninitialized = view_arch.differenceWith(curr_arch);
        if (!curr_arch.supersetOf(view_arch)) {
            assert(try self.changeArchUninitImmediateOrErr(es, .{ .add = uninitialized }));
        }

        // Create and return the view
        return .{
            .view = self.view(es, View).?,
            .uninitialized = uninitialized,
        };
    }

    /// Default formatting.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return self.key.format(writer);
    }

    /// Returns the archetype of the entity. If it has been destroyed or is not yet committed, the
    /// empty archetype will be returned.
    pub fn arch(self: @This(), es: *const Entities) CompFlag.Set {
        const entity_loc = es.handle_tab.get(self.key) orelse return .{};
        return entity_loc.arch(es);
    }
};
