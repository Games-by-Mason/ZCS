//! Storage for entities.
//!
//! See `SlotMap` for how handle safety works. Note that you may want to check
//! `saturated` every now and then and warn if it's nonzero.
//!
//! See `README.md` for more information.

const std = @import("std");
const assert = std.debug.assert;

const Allocator = std.mem.Allocator;

const zcs = @import("root.zig");
const typeId = zcs.typeId;
const Any = zcs.Any;
const CompFlag = zcs.CompFlag;
const Entity = zcs.Entity;
const ChunkList = zcs.storage.ChunkList;
const ChunkPool = zcs.storage.ChunkPool;
const Chunk = zcs.storage.Chunk;
const HandleTable = zcs.storage.HandleTable;
const Arches = zcs.storage.Arches;
const view = zcs.view;

const Entities = @This();

const IteratorGeneration = if (std.debug.runtime_safety) u64 else u0;

const max_align = zcs.TypeInfo.max_align;

handles: HandleTable,
comps: *[CompFlag.max][]align(max_align) u8,
max_archetypes: u16,
arches: Arches,
live: std.DynamicBitSetUnmanaged,
iterator_generation: IteratorGeneration = 0,
reserved_entities: usize = 0,
chunk_pool: ChunkPool,

/// The capacity for `Entities`.
pub const Capacity = struct {
    /// The max number of entities.
    max_entities: u32,
    /// The number of bytes per component type array.
    comp_bytes: usize,
    /// The max number of archetypes.
    max_archetypes: u16,
    /// The number of chunks to allocate.
    max_chunks: u32,
};

/// Initializes the entity storage with the given capacity.
pub fn init(gpa: Allocator, capacity: Capacity) Allocator.Error!@This() {
    var handles: HandleTable = try .init(gpa, capacity.max_entities);
    errdefer handles.deinit(gpa);

    const comps = try gpa.create([CompFlag.max][]align(max_align) u8);
    errdefer gpa.destroy(comps);

    comptime var comps_init = 0;
    errdefer for (0..comps_init) |i| gpa.free(comps[i]);
    inline for (comps) |*comp| {
        comp.* = try gpa.alignedAlloc(u8, max_align, capacity.comp_bytes);
        comps_init += 1;
    }

    var chunk_pool: ChunkPool = try .init(gpa, capacity.max_chunks);
    errdefer chunk_pool.deinit(gpa);

    var live = try std.DynamicBitSetUnmanaged.initEmpty(gpa, capacity.max_entities);
    errdefer live.deinit(gpa);

    var arches: Arches = try .init(gpa, capacity.max_archetypes);
    errdefer arches.deinit(gpa);

    return .{
        .handles = handles,
        .max_archetypes = capacity.max_archetypes,
        .arches = arches,
        .comps = comps,
        .chunk_pool = chunk_pool,
        .live = live,
    };
}

/// Destroys the entity storage.
pub fn deinit(self: *@This(), gpa: Allocator) void {
    self.arches.deinit(gpa);
    self.chunk_pool.deinit(gpa);
    self.live.deinit(gpa);
    for (self.comps) |comp| {
        gpa.free(comp);
    }
    gpa.destroy(self.comps);
    self.handles.deinit(gpa);
    self.* = undefined;
}

/// Recycles all entities with the given archetype.
pub fn recycleArchImmediate(self: *@This(), arch: CompFlag.Set) void {
    for (0..self.handles.next_index) |index| {
        if (self.live.isSet(index) and self.handles.values[index].getArch().eql(arch)) {
            const entity: Entity = .{ .key = .{
                .index = @intCast(index),
                .generation = self.handles.generations[index],
            } };
            assert(entity.recycleImmediate(self));
        }
    }
}

/// Recycles all entities.
pub fn recycleImmediate(self: *@This()) void {
    self.handles.recycleAll();
    self.reserved_entities = 0;
}

/// Returns the current number of entities.
pub fn count(self: @This()) usize {
    return self.handles.count() - self.reserved_entities;
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
        while (self.index < self.es.handles.next_index) {
            const index = self.index;
            self.index += 1;
            if (self.es.live.isSet(index)) {
                const handle_val = self.es.handles.values[index];
                if (handle_val.arch_chunks != null and
                    self.required_comps.subsetOf(handle_val.getArch()))
                {
                    return .{ .key = .{
                        .index = index,
                        .generation = self.es.handles.generations[index],
                    } };
                }
            }
        }

        return null;
    }
};

/// Similar to `iterator`, but returns a `view` with pointers to the requested components.
pub fn viewIterator(self: *const @This(), View: type) ViewIterator(View) {
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

                        // Get the handle value
                        const handle_val = self.es.handles.values[entity.key.index];
                        assert(handle_val.arch_chunks != null);

                        // Check if we have the component or not
                        const has_comp = if (@typeInfo(field.type) == .optional) b: {
                            // If the component type isn't registered, we definitely don't have it
                            const flag = typeId(T).comp_flag orelse break :b false;

                            // If it has a flag, check if we have it
                            break :b handle_val.arch_chunks.?.arch.contains(flag);
                        } else b: {
                            // If the component isn't optional, we can assume we have it
                            break :b true;
                        };

                        // Set the field's comp pointer
                        if (has_comp) {
                            // We have the component, pass it to the caller
                            const comp: *T = if (@sizeOf(T) == 0) b: {
                                // See `Entity.fromAny`.
                                const Key = @FieldType(Entity, "key");
                                const Generation = @FieldType(Key, "generation");
                                comptime assert(@intFromEnum(Generation.invalid) == 0);
                                break :b @ptrFromInt(@as(u64, @bitCast(entity)));
                            } else b: {
                                const base = @intFromPtr(@field(self.base, field.name));
                                const offset = entity.key.index * @sizeOf(T);
                                break :b @ptrFromInt(base + offset);
                            };
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
