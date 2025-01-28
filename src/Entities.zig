//! Storage for entities.
//!
//! See `SlotMap` for how handle safety works. Note that you may want to check
//! `saturated_generations` every now and then and warn if it's nonzero.
//!
//! See `README.md` for more information.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const zcs = @import("root.zig");
const Component = zcs.Component;
const slot_map = @import("slot_map");
const SlotMap = slot_map.SlotMap;
const Entity = zcs.Entity;
const CompTypes = zcs.CompTypes;

const Entities = @This();

const IteratorGeneration = if (std.debug.runtime_safety) u64 else u0;

/// The maximum alignment a component is allowed to have.
pub const max_align = 16;

const Slot = struct {
    archetype: Component.Flags,
    committed: bool,
};

comp_types: CompTypes,
slots: SlotMap(Slot, .{}),
comps: *[Component.Index.max][]align(max_align) u8,
live: std.DynamicBitSetUnmanaged,
iterator_generation: IteratorGeneration = 0,
reserved_entities: usize = 0,

/// Initializes the entity storage with the given capacity.
pub fn init(gpa: Allocator, capacity: usize) Allocator.Error!@This() {
    var slots = try SlotMap(Slot, .{}).init(gpa, capacity);
    errdefer slots.deinit(gpa);

    var comp_types: CompTypes = try .init(gpa);
    errdefer comp_types.deinit(gpa);

    const comps = try gpa.create([Component.Index.max][]align(max_align) u8);
    errdefer gpa.destroy(comps);

    comptime var comps_init = 0;
    errdefer for (0..comps_init) |i| gpa.free(comps[i]);
    inline for (comps) |*comp| {
        comp.* = try gpa.alignedAlloc(u8, max_align, capacity);
        comps_init += 1;
    }

    const live = try std.DynamicBitSetUnmanaged.initEmpty(gpa, capacity);
    errdefer live.deinit(gpa);

    return .{
        .slots = slots,
        .comp_types = comp_types,
        .comps = comps,
        .live = live,
    };
}

/// Destroys the entity storage.
pub fn deinit(self: *@This(), gpa: Allocator) void {
    self.live.deinit(gpa);
    for (self.comps) |comp| {
        gpa.free(comp);
    }
    self.comp_types.deinit(gpa);
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
pub fn viewIterator(self: *@This(), View: type) ViewIterator(View) {
    var base: View = undefined;
    var required_comps: Component.Flags = .{};
    var comp_indices: [@typeInfo(View).@"struct".fields.len]Component.Index = undefined;
    inline for (@typeInfo(View).@"struct".fields, 0..) |field, i| {
        if (field.type == Entity) {
            @field(base, field.name).key.index = 0;
        } else {
            const T = ComponentFromPointer(field.type) orelse {
                @compileError("view field is not Entity or pointer to a component: " ++ @typeName(field.type));
            };

            const comp_index = self.comp_types.registerIndex(T);
            comp_indices[i] = comp_index;
            if (@typeInfo(field.type) != .optional) {
                required_comps.insert(comp_index);
            }
            @field(base, field.name) = @ptrCast(self.comps[@intFromEnum(comp_index)]);
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
        .comp_indices = comp_indices,
    };
}

/// See `Entities.viewIterator`.
pub fn ViewIterator(View: type) type {
    return struct {
        es: *const Entities,
        entity_iterator: Iterator,
        comp_indices: [@typeInfo(View).@"struct".fields.len]Component.Index,
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
                            archetype.contains(self.comp_indices[i]))
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
