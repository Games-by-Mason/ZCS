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
const HandleTab = zcs.storage.HandleTab;
const ChunkLists = zcs.storage.ChunkLists;
const view = zcs.view;

const Entities = @This();

const IteratorGeneration = if (std.debug.runtime_safety) u64 else u0;

const max_align = zcs.TypeInfo.max_align;

handle_tab: HandleTab,
comps: *[CompFlag.max][]align(max_align) u8,
max_archetypes: u16,
chunk_lists: ChunkLists,
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
    var handle_tab: HandleTab = try .init(gpa, capacity.max_entities);
    errdefer handle_tab.deinit(gpa);

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

    var chunk_lists: ChunkLists = try .init(gpa, capacity.max_archetypes);
    errdefer chunk_lists.deinit(gpa);

    return .{
        .handle_tab = handle_tab,
        .max_archetypes = capacity.max_archetypes,
        .chunk_lists = chunk_lists,
        .comps = comps,
        .chunk_pool = chunk_pool,
        .live = live,
    };
}

/// Destroys the entity storage.
pub fn deinit(self: *@This(), gpa: Allocator) void {
    self.chunk_lists.deinit(gpa);
    self.chunk_pool.deinit(gpa);
    self.live.deinit(gpa);
    for (self.comps) |comp| {
        gpa.free(comp);
    }
    gpa.destroy(self.comps);
    self.handle_tab.deinit(gpa);
    self.* = undefined;
}

/// Recycles all entities with the given archetype.
pub fn recycleArchImmediate(self: *@This(), arch: CompFlag.Set) void {
    for (0..self.handle_tab.next_index) |index| {
        if (self.live.isSet(index) and self.handle_tab.values[index].getArch().eql(arch)) {
            const entity: Entity = .{ .key = .{
                .index = @intCast(index),
                .generation = self.handle_tab.generations[index],
            } };
            assert(entity.recycleImmediate(self));
        }
    }
}

/// Recycles all entities.
pub fn recycleImmediate(self: *@This()) void {
    self.handle_tab.recycleAll();
    self.reserved_entities = 0;
}

/// Returns the current number of entities.
pub fn count(self: @This()) usize {
    return self.handle_tab.count() - self.reserved_entities;
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
    var arch_iter = self.chunk_lists.archIterator(required_comps);
    var chunk_list_iter: ChunkList.Iterator = if (arch_iter.next()) |chunk_list|
        chunk_list.iterator()
    else
        .empty;
    const chunk_iter: Chunk.Iterator = if (chunk_list_iter.next()) |chunk|
        chunk.iterator()
    else
        .empty;
    return .{
        .es = self,
        .generation = self.iterator_generation,
        .arch_iter = arch_iter,
        .chunk_list_iter = chunk_list_iter,
        .chunk_iter = chunk_iter,
    };
}

/// See `iterator`.
pub const Iterator = struct {
    es: *const Entities,
    arch_iter: ChunkLists.ArchIterator,
    chunk_list_iter: ChunkList.Iterator,
    chunk_iter: Chunk.Iterator,
    generation: IteratorGeneration,

    /// Advances the iterator, returning the next entity.
    pub fn next(self: *@This()) ?Entity {
        if (self.generation != self.es.iterator_generation) {
            @panic("called next after iterator was invalidated");
        }

        while (true) {
            // Get the next entity in this chunk
            if (self.chunk_iter.next(&self.es.handle_tab)) |entity| {
                return entity;
            }

            // If that fails, get the next chunk in this chunk list
            if (self.chunk_list_iter.next()) |chunk| {
                self.chunk_iter = chunk.iterator();
                continue;
            }

            // If that fails, get the next chunk list in this archetype
            if (self.arch_iter.next()) |chunk_list| {
                self.chunk_list_iter = chunk_list.iterator();
                continue;
            }

            // If that fails, return null;
            return null;
        }
    }
};

/// Similar to `iterator`, but returns a `view` with pointers to the requested components.
pub fn viewIterator(self: *const @This(), View: type) ViewIterator(View) {
    var base: view.Comps(View) = undefined;
    var required_comps: CompFlag.Set = .{};
    inline for (@typeInfo(view.Comps(View)).@"struct".fields) |field| {
        const T = view.UnwrapField(field.type);
        if (@typeInfo(field.type) != .optional) {
            if (typeId(T).comp_flag) |flag| {
                required_comps.insert(flag);
            } else {
                return .empty(self);
            }
        }

        if (typeId(T).comp_flag) |flag| {
            // Don't need `.ptr` once this is merged: https://github.com/ziglang/zig/pull/22706
            @field(base, field.name) = @ptrCast(self.comps[@intFromEnum(flag)].ptr);
        }
    }

    var arch_iter = self.chunk_lists.archIterator(required_comps);
    var chunk_list_iter: ChunkList.Iterator = if (arch_iter.next()) |chunk_list|
        chunk_list.iterator()
    else
        .empty;
    const chunk_iter: Chunk.Iterator = if (chunk_list_iter.next()) |chunk|
        chunk.iterator()
    else
        .empty;
    return .{
        .entity_iter = .{
            .es = self,
            .generation = self.iterator_generation,
            .arch_iter = arch_iter,
            .chunk_list_iter = chunk_list_iter,
            .chunk_iter = chunk_iter,
        },
        .base = base,
    };
}

/// See `Entities.viewIterator`.
pub fn ViewIterator(View: type) type {
    return struct {
        entity_iter: Iterator,
        base: view.Comps(View),

        pub fn empty(es: *const Entities) @This() {
            return .{
                .entity_iter = .{
                    .es = es,
                    .arch_iter = .empty,
                    .chunk_list_iter = .empty,
                    .chunk_iter = .empty,
                    .generation = es.iterator_generation,
                },
                .base = undefined,
            };
        }

        /// Advances the iterator, returning the next view.
        pub fn next(self: *@This()) ?View {
            while (self.entity_iter.next()) |entity| {
                var result: View = undefined;
                inline for (@typeInfo(View).@"struct".fields) |field| {
                    if (field.type == Entity) {
                        @field(result, field.name) = entity;
                    } else {
                        // Get the component type
                        const T = view.UnwrapField(field.type);

                        // Get the handle value
                        const entity_loc = self.entity_iter.es.handle_tab.values[entity.key.index];
                        assert(entity_loc.chunk != null);

                        // Check if we have the component or not
                        const has_comp = if (@typeInfo(field.type) == .optional) b: {
                            // If the component type isn't registered, we definitely don't have it
                            const flag = typeId(T).comp_flag orelse break :b false;

                            // If it has a flag, check if we have it
                            break :b entity_loc.chunk.?.arch.contains(flag);
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
