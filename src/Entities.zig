//! Storage for entities.
//!
//! See `SlotMap` for how handle safety works. Note that you may want to check
//! `saturated_generations` every now and then and warn if it's nonzero.
//!
//! # Example
//! ```zig
//! var es: Entities = try .init(&gpa, 100, &.{RigidBody, Mesh, Fire});
//! defer es.deinit(gpa);
//!
//! const e = Entity.create(.{RigidBody { .mass = 0.5 }, Mesh { .vertices = player });
//! const mesh = e.getComponent(Mesh).?;
//!
//! var iter = es.viewIterator(struct {rb: RigidBody, mesh: Mesh});
//! while (iter.next()) |entity| {
//!     std.debug.print("mesh: {}\n", .{entity.mesh});
//! }
//! ```

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const zcs = @import("root.zig");
const Component = zcs.Component;
const slot_map = @import("slot_map");
const SlotMap = slot_map.SlotMap;
const Entity = zcs.Entity;

const Entities = @This();

/// An unspecified but unique value per type.
const TypeId = *const struct { _: u8 };

/// Returns the type ID of the given type.
inline fn typeId(comptime T: type) TypeId {
    return &struct {
        comptime {
            _ = T;
        }
        var id: @typeInfo(TypeId).pointer.child = undefined;
    }.id;
}

const IteratorGeneration = if (std.debug.runtime_safety) u64 else u0;

/// The maximum alignment a component is allowed to have.
pub const max_align = 16;

const ComponentInfo = struct {
    size: usize,
    alignment: u8,
};

const Slot = struct {
    archetype: Component.Flags,
    committed: bool,
};

comp_types: std.AutoArrayHashMapUnmanaged(TypeId, void),
comp_info: []ComponentInfo,
slots: SlotMap(Slot, .{}),
comps: *[Component.Id.max][]align(max_align) u8,
live: std.DynamicBitSetUnmanaged,
iterator_generation: IteratorGeneration = 0,
reserved_entities: usize = 0,

/// Initializes the entity storage with the given capacity, and registers the given component types.
pub fn init(
    gpa: Allocator,
    capacity: usize,
    comptime Components: []const type,
) Allocator.Error!@This() {
    // Check the component types
    comptime assert(Components.len < Component.Id.max);
    inline for (Components) |T| {
        if (@typeInfo(T) == .optional) {
            // There's nothing technically wrong with this, but if we allowed it then the
            // `create` and `changeArchetype` functions couldn't use optionals to allow deciding
            // at runtime whether or not to create a component.
            //
            // Furthermore, it would be difficult to distinguish syntactically whether an
            // optional component was missing or null.
            //
            // Instead, optional components should be represented by a struct with an optional
            // field, or a tagged union.
            @compileError("component types may not be optional: " ++ @typeName(T));
        }
    }

    // Register the component types
    var comp_types: std.AutoArrayHashMapUnmanaged(TypeId, void) = .empty;
    errdefer comp_types.deinit(gpa);
    try comp_types.ensureTotalCapacity(gpa, Components.len);

    inline for (Components) |T| {
        const entry = comp_types.getOrPutAssumeCapacity(typeId(T));
        if (entry.found_existing) {
            @panic("component registered twice: " ++ @typeName(T));
        }
    }

    // Register the component sizes
    const comp_info = try gpa.alloc(ComponentInfo, Components.len);
    errdefer gpa.free(comp_info);
    inline for (Components, comp_info) |T, *size| {
        comptime assert(@alignOf(T) <= max_align);
        size.* = .{
            .size = @sizeOf(T),
            .alignment = @alignOf(T),
        };
    }

    var slots = try SlotMap(Slot, .{}).init(gpa, capacity);
    errdefer slots.deinit(gpa);

    const comps = try gpa.create([Component.Id.max][]align(max_align) u8);
    errdefer gpa.destroy(comps);

    comptime var comps_init = 0;
    errdefer for (0..comps_init) |id| gpa.free(comps[id]);
    inline for (Components) |T| {
        const id = comp_types.getIndex(typeId(T)).?;
        comps[id] = try gpa.alignedAlloc(
            u8,
            max_align,
            @sizeOf(T) * capacity,
        );
        comps_init += 1;
    }

    const live = try std.DynamicBitSetUnmanaged.initEmpty(gpa, capacity);
    errdefer live.deinit(gpa);

    return .{
        .slots = slots,
        .comp_types = comp_types,
        .comp_info = comp_info,
        .comps = comps,
        .live = live,
    };
}

/// Destroys the entity storage.
pub fn deinit(self: *@This(), gpa: Allocator) void {
    self.live.deinit(gpa);
    for (0..self.comp_types.count()) |id| {
        gpa.free(self.comps[id]);
    }
    self.comp_types.deinit(gpa);
    gpa.free(self.comp_info);
    gpa.destroy(self.comps);
    self.slots.deinit(gpa);
    self.* = undefined;
}

/// Invalidates all entities, leaving all `Entity`s dangling and all generations reset. This cannot
/// be detected by `Entity.exists`.
pub fn reset(self: *@This()) void {
    self.slots.reset();
    self.reserved_entities = 0;
}

/// Returns the component ID for the given component type. Panics if the given type was not
/// registered.
pub fn getComponentId(self: @This(), T: type) Component.Id {
    return self.findComponentId(T) orelse {
        @panic("component type not registered: " ++ @typeName(T));
    };
}

/// Returns the size of the component type with the given ID.
pub fn getComponentSize(self: @This(), id: Component.Id) usize {
    return self.comp_info[@intFromEnum(id)].size;
}

/// Returns the alignment of the component type with the given ID.
pub fn getComponentAlignment(self: @This(), id: Component.Id) u8 {
    return self.comp_info[@intFromEnum(id)].alignment;
}

/// Similar to `componentId`, but returns null if the component type was not registered.
pub fn findComponentId(self: @This(), T: type) ?Component.Id {
    const id = self.comp_types.getIndex(typeId(T)) orelse return null;
    return @enumFromInt(id);
}

/// Returns the current number of entities.
pub fn count(self: @This()) usize {
    return self.slots.count() - self.reserved_entities;
}

/// Returns the number of reserved but not committed entities that currently exist.
pub fn reserved(self: @This()) usize {
    return self.reserved_entities;
}

/// If `T` is a pointer to a component, returns the component type. Otherwise returns null.
fn ComponentFromPointer(T: type) ?type {
    const pointer = switch (@typeInfo(T)) {
        .pointer => |pointer| pointer,
        .optional => |optional| switch (@typeInfo(optional.child)) {
            .pointer => |pointer| pointer,
            else => return null,
        },
        else => return null,
    };

    if (pointer.size != .one) return null;
    if (pointer.alignment != @alignOf(pointer.child)) return null;
    if (pointer.sentinel() != null) return null;
    if (@typeInfo(pointer.child) == .optional) return null;

    return pointer.child;
}

/// Returns an iterator over all entities that have at least the components in `required_comps` in
/// an implementation defined order.
pub fn iterator(
    self: *const @This(),
    required_comps: Component.Flags,
) Iterator {
    return .{
        .es = self,
        .required_comps = required_comps,
        .index = 0,
        .generation = self.iterator_generation,
    };
}

/// See `iterator`.
pub const Iterator = struct {
    es: *const Entities,
    required_comps: Component.Flags,
    index: u32,
    generation: IteratorGeneration,

    /// Advances the iterator, returning the next entity.
    pub fn next(self: *@This()) ?Entity {
        if (self.generation != self.es.iterator_generation) {
            @panic("called next after iterator was invalidated");
        }
        while (self.index < self.es.slots.next_index) {
            const index = self.index;
            self.index += 1;
            if (self.es.live.isSet(index)) {
                const slot = self.es.slots.values[index];
                if (slot.committed and self.required_comps.subsetOf(slot.archetype)) {
                    return .{ .key = .{
                        .index = index,
                        .generation = self.es.slots.generations[index],
                    } };
                }
            }
        }

        return null;
    }

    /// Destroys the current entity without invalidating this iterator. May invalidate other
    /// iterators.
    pub fn destroyCurrentImmediately(self: *@This(), es: *Entities) void {
        assert(self.index > 0);
        const index = self.index - 1;
        const entity: Entity = .{ .key = .{
            .index = index,
            .generation = es.slots.generations[index],
        } };
        entity.destroyImmediately(es);
        self.generation +%= 1;
    }
};

/// Similar to `iterator`, but returns a view with pointers to the requested components.
///
/// `View` must be a struct whose fields are all either type `Entity` or are pointers to registered
/// component types. Pointers can be set to optional to make a component type optional.
pub fn viewIterator(self: *const @This(), View: type) ViewIterator(View) {
    var base: View = undefined;
    var required_comps: Component.Flags = .{};
    var comp_ids: [@typeInfo(View).@"struct".fields.len]Component.Id = undefined;
    inline for (@typeInfo(View).@"struct".fields, 0..) |field, i| {
        if (field.type == Entity) {
            @field(base, field.name).key.index = 0;
        } else {
            const T = ComponentFromPointer(field.type) orelse {
                @compileError("view field is not Entity or pointer to a component: " ++ @typeName(field.type));
            };

            const comp_id = self.getComponentId(T);
            comp_ids[i] = comp_id;
            if (@typeInfo(field.type) != .optional) {
                required_comps.insert(comp_id);
            }
            @field(base, field.name) = @ptrCast(self.comps[@intFromEnum(comp_id)]);
        }
    }

    return .{
        .es = self,
        .entity_iterator = .{
            .es = self,
            .required_comps = required_comps,
            .index = 0,
            .generation = self.iterator_generation,
        },
        .base = base,
        .comp_ids = comp_ids,
    };
}

/// See `viewIterator`.
pub fn ViewIterator(View: type) type {
    return struct {
        es: *const Entities,
        entity_iterator: Iterator,
        comp_ids: [@typeInfo(View).@"struct".fields.len]Component.Id,
        base: View,

        /// Advances the iterator, returning the next view.
        pub fn next(self: *@This()) ?View {
            while (self.entity_iterator.next()) |entity| {
                var view: View = self.base;
                inline for (@typeInfo(View).@"struct".fields, 0..) |field, i| {
                    if (field.type == Entity) {
                        @field(view, field.name) = entity;
                    } else {
                        const T = ComponentFromPointer(field.type) orelse {
                            unreachable; // Checked in init
                        };
                        const slot = self.es.slots.values[entity.key.index];
                        assert(slot.committed);
                        const archetype = slot.archetype;
                        if (@typeInfo(field.type) != .optional or
                            archetype.contains(self.comp_ids[i]))
                        {
                            const base = @intFromPtr(@field(view, field.name));
                            const offset = entity.key.index * @sizeOf(T);
                            @field(view, field.name) = @ptrFromInt(base + offset);
                        } else {
                            @field(view, field.name) = null;
                        }
                    }
                }
                return view;
            }

            return null;
        }

        /// Destroys the current entity without invalidating this iterator. May invalidate other
        /// iterators.
        pub fn destroyCurrentImmediately(self: *@This(), es: *Entities) void {
            self.entity_iterator.destroyCurrentImmediately(es);
        }
    };
}
