//! See `Oracle`.

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const zcs = @import("../root.zig");
const gpa = std.testing.allocator;

/// Wraps `Entities` with correctness checks for testing. Registered components must have `name`
/// fields set to unique strings.
pub fn Oracle(Components: []const type) type {
    comptime assert(builtin.is_test);

    return struct {
        /// The ground truth for each entity is stored as a struct where each component is an
        /// optional field.
        const EntityStorage = b: {
            var fields: [Components.len]std.builtin.Type.StructField = undefined;
            for (&fields, Components) |*field, T| {
                field.* = .{
                    .name = T.name,
                    .type = ?T,
                    .default_value_ptr = &@as(?T, null),
                    .is_comptime = false,
                    .alignment = @alignOf(?T),
                };
            }
            break :b @Type(.{ .@"struct" = .{
                .layout = .auto,
                .fields = &fields,
                .decls = &.{},
                .is_tuple = false,
            } });
        };

        pub const ComponentFlags = b: {
            var fields: [Components.len]std.builtin.Type.StructField = undefined;
            for (&fields, Components) |*field, T| {
                field.* = .{
                    .name = T.name,
                    .type = bool,
                    .default_value_ptr = &false,
                    .is_comptime = false,
                    .alignment = @alignOf(bool),
                };
            }
            break :b @Type(.{ .@"struct" = .{
                .layout = .auto,
                .fields = &fields,
                .decls = &.{},
                .is_tuple = false,
            } });
        };

        /// Wraps `zcs.Component.Optional`.
        pub const OptionalComponent = struct {
            pub const none: @This() = .{
                .actual = .none,
                .expected_name = "",
            };
            actual: zcs.Component.Optional,
            expected_name: []const u8,
        };

        /// The handle is just a wrapper around `zcs.Entity`, with helpers that check their results
        /// against the ground truth.
        pub const Entity = struct {
            actual: zcs.Entity,

            /// Creates a new entity in both the ground truth data and the real ECS.
            pub fn create(es: *Entities, comps: anytype) !Entity {
                es.checked = false;

                // If the ground truth overflows, make sure the real ECS does too.
                if (try es.count() + try es.reserved() == es.capacity) {
                    const result = zcs.Entity.createChecked(&es.actual, comps);
                    try std.testing.expectError(error.ZcsEntityOverflow, result);
                    return error.ZcsEntityOverflow;
                }

                // Create the actual entity. This may overflow due to fragmentation even if the
                // ground truth didn't, that's okay. Exact allocation patterns are implementation
                // defined.
                const actual = try zcs.Entity.createChecked(&es.actual, comps);

                // Create the ground truth entity.
                var storage: EntityStorage = .{};
                inline for (comps) |comp| {
                    const T = switch (@typeInfo(@TypeOf(comp))) {
                        .optional => |opt| opt.child,
                        else => @TypeOf(comp),
                    };
                    if (@typeInfo(@TypeOf(comp)) != .optional or comp != null) {
                        @field(storage, T.name) = comp;
                    }
                }
                const entity: Entity = .{ .actual = actual };
                try es.expected_live.put(gpa, entity, storage);

                // Return the wrapper to the caller.
                return entity;
            }

            /// Reserves an entity without committing it in both the ground truth and the ECS.
            pub fn reserve(es: *Entities) !Entity {
                es.checked = false;

                // If the ground truth overflows, make sure the real ECS does too.
                if (try es.count() + try es.reserved() == es.capacity) {
                    const result = zcs.Entity.reserveChecked(&es.actual);
                    try std.testing.expectError(error.ZcsEntityOverflow, result);
                    return error.ZcsEntityOverflow;
                }

                // Create the actual entity. This should always succeed if the ground truth
                // succeeded since no space for components was allocated.
                const actual = zcs.Entity.reserve(&es.actual);

                // Create the ground truth entity.
                const entity: Entity = .{ .actual = actual };
                try es.expected_reserved.put(gpa, entity, {});

                // Return the wrapper to the caller.
                return entity;
            }

            /// Creates a new entity from IDs in both the ground truth data and the real ECS.
            pub fn createFromComponents(
                es: *Entities,
                comps: []const OptionalComponent,
            ) !Entity {
                es.checked = false;

                // Create the actual components buffer
                var actual_comps: std.BoundedArray(zcs.Component.Optional, 32) = .{};
                for (comps) |comp| try actual_comps.append(comp.actual);

                // If the ground truth overflows, make sure the real ECS does too.
                if (try es.count() == es.capacity) {
                    const result = zcs.Entity.createFromComponentsChecked(
                        &es.actual,
                        actual_comps.constSlice(),
                    );
                    try std.testing.expectError(error.ZcsEntityOverflow, result);
                    return error.ZcsEntityOverflow;
                }

                // Create the actual entity. This may overflow due to fragmentation even if the
                // ground truth didn't, that's okay. Exact allocation patterns are implementation
                // defined.
                const actual = try zcs.Entity.createFromComponentsChecked(
                    &es.actual,
                    actual_comps.constSlice(),
                );

                // Create the ground truth entity.
                var storage: EntityStorage = .{};
                for (comps) |comp| {
                    if (comp.actual.unwrap()) |some| {
                        inline for (@typeInfo(EntityStorage).@"struct".fields, 0..) |field, i| {
                            if (std.mem.eql(u8, field.name, comp.expected_name)) {
                                const T = Components[i];
                                @field(storage, field.name) = some.as(&es.actual, T).?.*;
                                break;
                            }
                        }
                    }
                }
                const entity: Entity = .{ .actual = actual };
                try es.expected_live.put(gpa, entity, storage);

                // Return the wrapper to the caller.
                return entity;
            }

            /// Destroy the entity both in the ground truth and in the ECS. Tests that it was
            /// successfully destroyed.
            pub fn destroy(self: @This(), es: *Entities) !void {
                es.checked = false;

                _ = es.expected_live.swapRemove(self);
                _ = es.expected_reserved.swapRemove(self);
                try es.expected_destroyed.put(gpa, self, {});
                self.actual.destroy(&es.actual);
                try std.testing.expect(!try self.exists(es));
            }

            /// Checks if the entity exists. Tests that the result is the same in ground truth and
            /// actual.
            pub fn exists(self: @This(), es: *const Entities) !bool {
                const expected = es.expected_live.contains(self) or es.expected_reserved.contains(self);
                const actual = self.actual.exists(&es.actual);
                try std.testing.expectEqual(expected, actual);
                return actual;
            }

            /// Checks if the entity has been committed. Tests that the result is the same in ground
            /// truth and actual.
            pub fn committed(self: @This(), es: *const Entities) !bool {
                const expected = try self.exists(es) and !es.expected_reserved.contains(self);
                const actual = self.actual.committed(&es.actual);
                try std.testing.expectEqual(expected, actual);
                return actual;
            }

            /// Returns a random valid entity, or null if there are none. May return a reserved or
            /// committed entity.
            pub fn random(es: *const Entities, rand: std.Random) ?Entity {
                if (rand.boolean()) {
                    if (randomCommitted(es, rand)) |e| return e;
                    return randomReserved(es, rand);
                } else {
                    if (randomReserved(es, rand)) |e| return e;
                    return randomCommitted(es, rand);
                }
            }

            /// Returns a random committed entity, or null if there are none.
            pub fn randomCommitted(es: *const Entities, rand: std.Random) ?Entity {
                const count = es.expected_live.count();
                if (count == 0) return null;
                const index = rand.uintLessThan(usize, count);
                return es.expected_live.keys()[index];
            }

            /// Returns a random reserved but not committed entity, or null if there are none.
            pub fn randomReserved(es: *const Entities, rand: std.Random) ?Entity {
                const count = es.expected_reserved.count();
                if (count == 0) return null;
                const index = rand.uintLessThan(usize, count);
                return es.expected_reserved.keys()[index];
            }

            /// Returns a random destroyed entity, or null if there are none.
            pub fn randomDestroyed(es: *const Entities, rand: std.Random) ?Entity {
                const count = es.expected_destroyed.count();
                if (count == 0) return null;
                const index = rand.uintLessThan(usize, count);
                return es.expected_destroyed.keys()[index];
            }

            /// Checks if the entity has a component. Tests that the result is the same in ground
            // truth and actual.
            pub fn hasComponent(self: @This(), es: *Entities, T: type) !bool {
                const expected = (try self.getComponent(es, T)) != null;
                const actual = self.actual.hasComponent(&es.actual, T);
                try std.testing.expectEqual(expected, actual);
                return actual;
            }

            /// Gets a pointer to the ground truth component if it exists, and to the actual value.
            /// Tests that they are the same. Both are returned so that the caller can modify both
            /// if desired.
            pub fn getComponent(
                self: @This(),
                es: *Entities,
                T: type,
            ) !?struct { expected: *T, actual: *T } {
                es.checked = false; // Could be used to modify the component

                // Get the expected value
                var expected: ?*T = null;
                if (es.expected_live.getPtr(self)) |storage| {
                    if (@field(storage, T.name)) |*comp| {
                        expected = comp;
                    }
                }

                // Get the actual value
                const actual = self.actual.getComponent(&es.actual, T);

                // Check that neither or both are null, return null if both are null
                try std.testing.expectEqual(expected == null, actual == null);
                if (actual == null) return null;

                // Check that both are equal, return both
                try std.testing.expectEqual(expected.?.*, actual.?.*);
                return .{ .expected = expected.?, .actual = actual.? };
            }

            /// Changes the archetype of both the ground truth and actual entity. Tests that both
            /// are identical after the transformation.
            pub fn changeArchetype(
                self: @This(),
                es: *Entities,
                remove: ComponentFlags,
                comps: anytype,
            ) !void {
                es.checked = false;

                // Change the archetype of the actual entity
                var actual_remove: zcs.Component.Flags = .{};
                inline for (@typeInfo(ComponentFlags).@"struct".fields, 0..) |field, i| {
                    if (@field(remove, field.name)) {
                        actual_remove.insert(es.actual.getComponentId(Components[i]));
                    }
                }
                try self.actual.changeArchetypeChecked(&es.actual, actual_remove, comps);

                // Change the archetype of the expected entity
                if (try self.exists(es)) {
                    if (es.expected_reserved.swapRemove(self)) {
                        try es.expected_live.put(gpa, self, .{});
                    }
                    const storage = es.expected_live.getPtr(self).?;

                    inline for (@typeInfo(ComponentFlags).@"struct".fields) |field| {
                        if (@field(remove, field.name)) {
                            @field(storage, field.name) = null;
                        }
                    }

                    inline for (comps) |comp| {
                        const T = switch (@typeInfo(@TypeOf(comp))) {
                            .optional => |opt| opt.child,
                            else => @TypeOf(comp),
                        };
                        if (@typeInfo(@TypeOf(comp)) != .optional or comp != null) {
                            @field(storage, T.name) = comp;
                        }
                    }
                }

                // Test that all components remain equal
                inline for (Components) |T| {
                    _ = try self.getComponent(es, T);
                }
            }

            /// Changes the archetype of both the ground truth and actual entity using IDs instead
            /// of types. Tests that both are identical after the transformation.
            pub fn changeArchetypeFromComponents(
                self: @This(),
                es: *Entities,
                remove: ComponentFlags,
                comps: []const OptionalComponent,
            ) !void {
                es.checked = false;

                // Change the archetype of the actual entity
                var actual_remove: zcs.Component.Flags = .{};
                inline for (@typeInfo(ComponentFlags).@"struct".fields, 0..) |field, i| {
                    if (@field(remove, field.name)) {
                        actual_remove.insert(es.actual.getComponentId(Components[i]));
                    }
                }
                var actual_comps: std.BoundedArray(zcs.Component.Optional, 32) = .{};
                for (comps) |comp| try actual_comps.append(comp.actual);
                try self.actual.changeArchetypeFromComponentsChecked(
                    &es.actual,
                    actual_remove,
                    actual_comps.constSlice(),
                );

                // Change the archetype of the expected entity
                if (try self.exists(es)) {
                    if (es.expected_reserved.swapRemove(self)) {
                        try es.expected_live.put(gpa, self, .{});
                    }
                    const storage = es.expected_live.getPtr(self).?;

                    inline for (@typeInfo(ComponentFlags).@"struct".fields) |field| {
                        if (@field(remove, field.name)) {
                            @field(storage, field.name) = null;
                        }
                    }
                    for (comps) |comp| {
                        if (comp.actual.unwrap()) |some| {
                            inline for (@typeInfo(EntityStorage).@"struct".fields, 0..) |field, i| {
                                if (std.mem.eql(u8, field.name, comp.expected_name)) {
                                    const T = Components[i];
                                    @field(storage, field.name) = some.as(&es.actual, T).?.*;
                                    break;
                                }
                            }
                        }
                    }
                }

                // Test that all components remain equal
                inline for (Components) |T| {
                    _ = try self.getComponent(es, T);
                }
            }
        };

        pub const Entities = struct {
            const Entities = @This();

            /// The actual entities.
            actual: zcs.Entities,

            /// The set of currently valid entities.
            expected_live: std.AutoArrayHashMapUnmanaged(Entity, EntityStorage),

            /// The set of destroyed entities.
            expected_destroyed: std.AutoArrayHashMapUnmanaged(Entity, void),

            /// The set of reserved but not committed entities.
            expected_reserved: std.AutoArrayHashMapUnmanaged(Entity, void),

            /// Store the actual freed count and capacity.
            capacity: usize,

            /// Whether or not we've had full check run since the last modification.
            checked: bool = false,

            /// Initialize the expected and actual entities with the given capacity.
            pub fn init(capacity: usize) !@This() {
                var actual: zcs.Entities = try .init(gpa, capacity, Components);
                errdefer actual.deinit(gpa);

                var expected_live: std.AutoArrayHashMapUnmanaged(Entity, EntityStorage) = .{};
                errdefer expected_live.deinit(gpa);
                try expected_live.ensureTotalCapacity(gpa, capacity);

                var expected_destroyed: std.AutoArrayHashMapUnmanaged(Entity, void) = .{};
                errdefer expected_destroyed.deinit(gpa);
                try expected_destroyed.ensureTotalCapacity(gpa, capacity);

                var expected_reserved: std.AutoArrayHashMapUnmanaged(Entity, void) = .{};
                errdefer expected_reserved.deinit(gpa);
                try expected_reserved.ensureTotalCapacity(gpa, capacity);

                return .{
                    .actual = actual,
                    .expected_live = expected_live,
                    .expected_destroyed = expected_destroyed,
                    .expected_reserved = expected_reserved,
                    .capacity = capacity,
                };
            }

            /// Deinitialize the expected and actual entities.
            pub fn deinit(self: *@This()) void {
                if (!self.checked) std.log.err("not checked before exit", .{});
                self.actual.deinit(gpa);
                self.expected_live.deinit(gpa);
                self.expected_destroyed.deinit(gpa);
                self.expected_reserved.deinit(gpa);
                self.* = undefined;
            }

            /// Reset the expected and actual entities.
            pub fn reset(self: *@This()) !void {
                self.checked = false;

                self.actual.reset();
                self.expected_live.clearRetainingCapacity();
                self.expected_destroyed.clearRetainingCapacity();
                self.expected_reserved.clearRetainingCapacity();
                try std.testing.expectEqual(0, try self.count());
            }

            /// Test that the count of the expected and actual entities is the same, and then return
            /// it.
            pub fn count(self: @This()) !usize {
                const expected = self.expected_live.count();
                const actual = self.actual.count();
                try std.testing.expectEqual(expected, actual);
                return expected;
            }

            /// Test that the reserved count of the expected and actual entities is the same, and
            /// then return it.
            pub fn reserved(self: @This()) !usize {
                const expected = self.expected_reserved.count();
                const actual = self.actual.reserved();
                try std.testing.expectEqual(expected, actual);
                return expected;
            }

            /// Check that all entities in expected and actual are equal.
            pub fn fullCheck(self: *@This(), rand: std.Random) !void {
                _ = try self.count();
                _ = try self.reserved();

                for (self.expected_live.keys()) |entity| {
                    try std.testing.expect(try entity.exists(self));
                    try std.testing.expect(try entity.committed(self));
                    inline for (Components) |T| {
                        _ = try entity.getComponent(self, T);
                    }
                }

                for (self.expected_reserved.keys()) |entity| {
                    try std.testing.expect(try entity.exists(self));
                    try std.testing.expect(!try entity.committed(self));
                    inline for (Components) |T| {
                        try std.testing.expectEqual(null, try entity.getComponent(self, T));
                    }
                }

                // Checking all of these would be very slow as time goes on, so we check a random
                // sampling of them instead
                for (0..@min(100, self.expected_destroyed.count())) |_| {
                    if (Entity.randomDestroyed(self, rand)) |entity| {
                        try std.testing.expect(!try entity.exists(self));
                        try std.testing.expect(!try entity.committed(self));
                        inline for (Components) |T| {
                            try std.testing.expectEqual(null, try entity.getComponent(self, T));
                        }
                    } else break;
                }

                self.checked = true;
            }

            /// Check that accumulating results from the view iterator over the actual data gets the
            /// same results as filtering the expected entities. Order is not checked since it's
            /// implementation defined.
            ///
            /// `destroy` is the chance of calling `destroyCurrent` on each cycle of the iterator.
            /// If set to zero it's never called, one it's called every time.
            pub fn checkViewIterator(
                self: *@This(),
                rand: std.Random,
                View: type,
                destroy: f32,
            ) !void {
                comptime assert(@hasField(View, "entity"));
                comptime assert(@TypeOf(@as(View, undefined).entity) == zcs.Entity);

                var destroyed: std.AutoArrayHashMapUnmanaged(Entity, void) = .empty;
                defer destroyed.deinit(gpa);

                // Accumulate the expected results
                const capacity = try self.count();
                var expected: std.ArrayListUnmanaged(Entity) = try .initCapacity(gpa, capacity);
                defer expected.deinit(gpa);
                {
                    var i: usize = 0;
                    iter: while (i < self.expected_live.count()) {
                        const entity = self.expected_live.keys()[i];
                        inline for (@typeInfo(View).@"struct".fields) |field| {
                            if (field.type != zcs.Entity) {
                                const T = switch (@typeInfo(field.type)) {
                                    .pointer => |ptr| ptr.child,
                                    .optional => |opt| @typeInfo(opt.child).pointer.child,
                                    else => @compileError("invalid view type: " ++ @typeName(View)),
                                };
                                if (!try entity.hasComponent(self, T)) {
                                    if (@typeInfo(field.type) != .optional) {
                                        i += 1;
                                        continue :iter;
                                    }
                                }
                            }
                        }
                        expected.appendAssumeCapacity(entity);
                        try std.testing.expect(try entity.exists(self));
                        try std.testing.expect(try entity.committed(self));
                        if (destroy > 0 and (destroy == 1 or rand.float(f32) < destroy)) {
                            // We don't call remove directly, as we only want to remove it from the
                            // expected data. We're testing that the real iterator successfully removes
                            // the entity as well.
                            _ = self.expected_live.swapRemove(entity);
                            try self.expected_destroyed.put(gpa, entity, {});
                            try destroyed.put(gpa, entity, {});
                        } else {
                            i += 1;
                        }
                    }
                }

                // Accumulate the actual results
                var actual: std.AutoArrayHashMapUnmanaged(zcs.Entity, View) = .empty;
                try actual.ensureTotalCapacity(gpa, capacity);
                defer actual.deinit(gpa);
                var iter = self.actual.viewIterator(View);
                while (iter.next()) |view| {
                    const entity: Entity = .{ .actual = view.entity };
                    try actual.putNoClobber(gpa, view.entity, view);
                    if (destroyed.contains(entity)) {
                        iter.destroyCurrent(&self.actual);
                    }
                }

                // Compare the them
                try std.testing.expectEqual(expected.items.len, actual.count());
                for (expected.items) |expected_entity| {
                    if (try expected_entity.exists(self)) {
                        const actual_view = actual.get(expected_entity.actual).?;
                        inline for (@typeInfo(View).@"struct".fields) |field| {
                            if (field.type == zcs.Entity) {
                                try std.testing.expectEqual(expected_entity.actual, actual_view.entity);
                            } else switch (@typeInfo(field.type)) {
                                .pointer => |ptr| {
                                    const T = ptr.child;
                                    const expected_comp = (try expected_entity.getComponent(self, T)).?.expected.*;
                                    const actual_comp = @field(actual_view, field.name).*;
                                    try std.testing.expectEqual(expected_comp, actual_comp);
                                },
                                .optional => |opt| {
                                    const T = @typeInfo(opt.child).pointer.child;
                                    const expected_comp: ?T = if (try expected_entity.getComponent(self, T)) |comp| b: {
                                        break :b comp.expected.*;
                                    } else null;
                                    const actual_comp = if (@field(actual_view, field.name)) |c| c.* else null;
                                    try std.testing.expectEqual(expected_comp, actual_comp);
                                },
                                else => @compileError("invalid view type: " ++ @typeName(View)),
                            }
                        }
                    }
                }

                for (destroyed.keys()) |entity| {
                    try std.testing.expect(!try entity.exists(self));
                }
                _ = try self.count();
            }
        };
    };
}
