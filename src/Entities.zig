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
const typeId = zcs.typeId;
const Any = zcs.Any;
const CompFlag = zcs.CompFlag;
const slot_map = @import("slot_map");
const SlotMap = slot_map.SlotMap;
const Entity = zcs.Entity;
const view = zcs.view;

const Entities = @This();

const IteratorGeneration = if (std.debug.runtime_safety) u64 else u0;

const max_align = zcs.TypeInfo.max_align;

pub const Slot = struct {
    arch: CompFlag.Set,
    committed: bool,
};

slots: SlotMap(Slot, .{}),
comps: *[CompFlag.max][]align(max_align) u8,
live: std.DynamicBitSetUnmanaged,
iterator_generation: IteratorGeneration = 0,
reserved_entities: usize = 0,

/// The capacity for `Entities`.
pub const Capacity = struct {
    /// The max number of entities.
    max_entities: u32,
    /// The number of bytes per component type array.
    comp_bytes: usize,
};

/// Initializes the entity storage with the given capacity.
pub fn init(gpa: Allocator, capacity: Capacity) Allocator.Error!@This() {
    var slots = try SlotMap(Slot, .{}).init(gpa, capacity.max_entities);
    errdefer slots.deinit(gpa);

    const comps = try gpa.create([CompFlag.max][]align(max_align) u8);
    errdefer gpa.destroy(comps);

    comptime var comps_init = 0;
    errdefer for (0..comps_init) |i| gpa.free(comps[i]);
    inline for (comps) |*comp| {
        comp.* = try gpa.alignedAlloc(u8, max_align, capacity.comp_bytes);
        comps_init += 1;
    }

    const live = try std.DynamicBitSetUnmanaged.initEmpty(gpa, capacity.max_entities);
    errdefer live.deinit(gpa);

    return .{
        .slots = slots,
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

/// Returns an iterator over all entities that have at least the components in `required_comps` in
/// an implementation defined order.
pub fn iterator(
    self: *const @This(),
    required_comps: CompFlag.Set,
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
    required_comps: CompFlag.Set,
    index: u32,
    generation: IteratorGeneration,

    /// Advances the iterator, returning the next entity.
    pub fn next(self: *@This()) ?Entity {
        if (self.generation != self.es.iterator_generation) {
            @panic("called next after iterator was invalidated");
        }
        // Keep in mind that in view iterator, we're using max index to indicate that the iterator
        // is invalid.
        while (self.index < self.es.slots.next_index) {
            const index = self.index;
            self.index += 1;
            if (self.es.live.isSet(index)) {
                const slot = self.es.slots.values[index];
                if (slot.committed and self.required_comps.subsetOf(slot.arch)) {
                    return .{ .key = .{
                        .index = index,
                        .generation = self.es.slots.generations[index],
                    } };
                }
            }
        }

        return null;
    }
};

/// Similar to `iterator`, but returns a `view` with pointers to the requested components.
pub fn viewIterator(self: *@This(), View: type) ViewIterator(View) {
    var base: view.Comps(View) = undefined;
    var required_comps: CompFlag.Set = .{};
    const valid = inline for (@typeInfo(view.Comps(View)).@"struct".fields) |field| {
        const T = view.UnwrapField(field.type);
        if (@typeInfo(field.type) != .optional) {
            if (typeId(T).comp_flag) |flag| {
                required_comps.insert(flag);
            } else break false;
        }

        if (typeId(T).comp_flag) |flag| {
            // Don't need `.ptr` once this is merged: https://github.com/ziglang/zig/pull/22706
            @field(base, field.name) = @ptrCast(self.comps[@intFromEnum(flag)].ptr);
        }
    } else true;

    return .{
        .es = self,
        .entity_iterator = .{
            .es = self,
            .required_comps = required_comps,
            .index = if (valid) 0 else std.math.maxInt(@FieldType(Iterator, "index")),
            .generation = self.iterator_generation,
        },
        .base = base,
    };
}

/// See `Entities.viewIterator`.
pub fn ViewIterator(View: type) type {
    return struct {
        es: *const Entities,
        entity_iterator: Iterator,
        base: view.Comps(View),

        /// Advances the iterator, returning the next view.
        pub fn next(self: *@This()) ?View {
            while (self.entity_iterator.next()) |entity| {
                var result: View = undefined;
                inline for (@typeInfo(View).@"struct".fields) |field| {
                    if (field.type == Entity) {
                        @field(result, field.name) = entity;
                    } else {
                        // Get the component type
                        const T = view.UnwrapField(field.type);

                        // Get the slot
                        const slot = self.es.slots.values[entity.key.index];
                        assert(slot.committed);

                        // Check if we have the component or not
                        const has_comp = if (@typeInfo(field.type) == .optional) b: {
                            // If the component type isn't registered, we definitely don't have it
                            const flag = typeId(T).comp_flag orelse break :b false;

                            // If it has a flag, check if we have it
                            break :b slot.arch.contains(flag);
                        } else b: {
                            // If the component isn't optional, we can assume we have it
                            break :b true;
                        };

                        // Set the field's comp pointer
                        if (has_comp) {
                            // We have the component, pass it to the caller
                            const base = @intFromPtr(@field(self.base, field.name));
                            const offset = entity.key.index * @sizeOf(T);
                            const comp: *T = @ptrFromInt(base + offset);
                            @field(result, field.name) = comp;
                        } else {
                            // This component is optional and we don't have it, set our result to
                            // null
                            @field(result, field.name) = null;
                        }
                    }
                }
                return result;
            }

            return null;
        }
    };
}
