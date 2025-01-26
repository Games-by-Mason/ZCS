const std = @import("std");
const zcs = @import("../root.zig");

const gpa = std.testing.allocator;
const assert = std.debug.assert;

const Entities = zcs.Entities;
const CmdBuf = zcs.CmdBuf;
const Entity = zcs.Entity;
const Component = zcs.Component;

test "fuzz cmdbuf" {
    try std.testing.fuzz(OracleTests.testRandomInput, .{ .corpus = &.{} });
}

const OracleTests = struct {
    const RigidBody = struct {
        const interned: [4]?@This() = .{
            .{},
            .{ .position = .{ 2.0, 3.0 }, .velocity = .{ 4.0, 5.0 }, .mass = 10.0 },
            .{ .position = .{ 24.0, 32.0 }, .velocity = .{ 42.0, 55.0 }, .mass = 103.0 },
            null,
        };
        position: [2]f32 = .{ 1.0, 2.0 },
        velocity: [2]f32 = .{ 3.0, 4.0 },
        mass: f32 = 5.0,
    };

    const Model = struct {
        const interned: [4]?@This() = .{
            .{},
            .{ .vertex_start = 1, .vertex_count = 2 },
            .{ .vertex_start = 10, .vertex_count = 20 },
            null,
        };
        vertex_start: u16 = 6,
        vertex_count: u16 = 7,
    };

    pub const Tag = struct {
        const interned: [2]?@This() = .{ .{}, null };
    };

    const ExpectedEntity = struct {
        model: ?Model = null,
        rb: ?RigidBody = null,
        tag: ?Tag = null,
    };

    const cmds_capacity = 1000;

    es: Entities,
    cmds: CmdBuf,
    bytes: RandomBytes,
    reserved: std.AutoArrayHashMapUnmanaged(Entity, void),
    committed: std.AutoArrayHashMapUnmanaged(Entity, ExpectedEntity),
    /// A sample of destroyed entities. Capped to avoid growing forever, when it reaches the cap
    /// random entities are removed from the set.
    destroyed: std.AutoArrayHashMapUnmanaged(Entity, void),

    pub fn init(input: []const u8) !@This() {
        const capacity = 100000;

        var es: Entities = try .init(gpa, capacity, &.{ RigidBody, Model, Tag });
        errdefer es.deinit(gpa);

        var cmds: CmdBuf = try .init(gpa, &es, cmds_capacity);
        errdefer cmds.deinit(gpa, &es);

        var reserved: std.AutoArrayHashMapUnmanaged(Entity, void) = .{};
        errdefer reserved.deinit(gpa);
        try reserved.ensureTotalCapacity(gpa, capacity);

        var committed: std.AutoArrayHashMapUnmanaged(Entity, ExpectedEntity) = .{};
        errdefer committed.deinit(gpa);
        try committed.ensureTotalCapacity(gpa, capacity);

        var destroyed: std.AutoArrayHashMapUnmanaged(Entity, void) = .{};
        errdefer destroyed.deinit(gpa);
        try destroyed.ensureTotalCapacity(gpa, capacity);

        const bytes: RandomBytes = .init(input);

        return .{
            .es = es,
            .cmds = cmds,
            .reserved = reserved,
            .committed = committed,
            .destroyed = destroyed,
            .bytes = bytes,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.destroyed.deinit(gpa);
        self.committed.deinit(gpa);
        self.reserved.deinit(gpa);
        self.cmds.deinit(gpa, &self.es);
        self.es.deinit(gpa);
        self.* = undefined;
    }

    /// Returns a random reserved committed or destroyed entity.
    fn randomEntity(self: *@This()) Entity {
        // Sometimes return .none
        if (self.bytes.next(u8) < 10) return .none;

        switch (self.bytes.next(enum {
            reserved,
            committed,
            destroyed,
        })) {
            .reserved => {
                if (self.reserved.count() == 0) return .none;
                const index = self.bytes.nextLessThan(usize, self.reserved.count());
                return self.reserved.keys()[index];
            },
            .committed => {
                if (self.committed.count() == 0) return .none;
                const index = self.bytes.nextLessThan(usize, self.committed.count());
                return self.committed.keys()[index];
            },
            .destroyed => {
                if (self.destroyed.count() == 0) return .none;
                const index = self.bytes.nextLessThan(usize, self.destroyed.count());
                return self.destroyed.keys()[index];
            },
        }
    }

    /// Check that the actual data matches the oracle.
    fn checkOracle(self: @This()) !void {
        // Check the total number of entities
        try std.testing.expectEqual(
            self.reserved.count() + self.cmds.reserved.items.len,
            self.es.reserved(),
        );
        try std.testing.expectEqual(self.committed.count(), self.es.count());

        // Check the reserved entities
        for (self.reserved.keys()) |e| {
            try std.testing.expect(e.exists(&self.es));
            try std.testing.expect(!e.committed(&self.es));
        }

        // Check the committed entities
        var commited_iter = self.committed.iterator();
        while (commited_iter.next()) |entry| {
            const entity = entry.key_ptr.*;
            const expected = entry.value_ptr;
            try std.testing.expect(entity.exists(&self.es));
            try std.testing.expect(entity.committed(&self.es));
            try std.testing.expectEqual(expected.rb, if (entity.getComponent(&self.es, RigidBody)) |v| v.* else null);
            try std.testing.expectEqual(expected.model, if (entity.getComponent(&self.es, Model)) |v| v.* else null);
            try std.testing.expectEqual(expected.tag, if (entity.getComponent(&self.es, Tag)) |v| v.* else null);
        }

        // Check the tracked deleted entities
        var destroyed_iter = self.destroyed.iterator();
        while (destroyed_iter.next()) |entry| {
            const entity = entry.key_ptr.*;
            try std.testing.expect(!entity.exists(&self.es));
            try std.testing.expect(!entity.committed(&self.es));
            try std.testing.expectEqual(null, if (entity.getComponent(&self.es, RigidBody)) |v| v.* else null);
            try std.testing.expectEqual(null, if (entity.getComponent(&self.es, Model)) |v| v.* else null);
            try std.testing.expectEqual(null, if (entity.getComponent(&self.es, Tag)) |v| v.* else null);
        }
    }

    /// Appends a random or interned instance of `?T` or `T` to `add`, and then returns a pointer to
    /// it. Accumulates random data in buf.
    fn addComponent(
        self: *@This(),
        T: type,
        buf: anytype,
        add: anytype,
    ) *const ?T {
        // Either get an interned component, or generate a random one
        const i = self.bytes.next(u8);
        const interned = i < 40;
        const comp = if (interned) b: {
            break :b &T.interned[i % T.interned.len];
        } else b: {
            const comp = buf.addOneAssumeCapacity();
            comp.* = self.bytes.next(?T);
            break :b comp;
        };

        // Randomly add it to the command, as either an optional or
        // unwrapped
        if (comp.*) |*some| {
            if (self.bytes.next(bool)) {
                if (interned) {
                    add.appendAssumeCapacity(.initInterned(&self.es, some));
                } else {
                    add.appendAssumeCapacity(.init(&self.es, some));
                }
            } else {
                if (interned) {
                    add.appendAssumeCapacity(.initInterned(&self.es, comp));
                } else {
                    add.appendAssumeCapacity(.init(&self.es, comp));
                }
            }
        } else {
            if (interned) {
                add.appendAssumeCapacity(.initInterned(&self.es, comp));
            } else {
                add.appendAssumeCapacity(.init(&self.es, comp));
            }
        }

        // Return the component
        return comp;
    }

    /// Runs a test on random input.
    pub fn testRandomInput(input: []const u8) !void {
        var self: @This() = try init(input);
        defer self.deinit();

        while (!self.bytes.isEmpty()) {
            for (0..self.bytes.nextLessThan(u16, cmds_capacity)) |_| {
                switch (self.bytes.next(enum {
                    reserve,
                    destroy,
                    change_archetype,
                    modify,
                })) {
                    .reserve => {
                        // Skip reserve if we already have a lot of entities to avoid overflowing
                        if (self.es.count() + self.es.reserved() > self.es.slots.capacity / 2) {
                            continue;
                        }

                        // Reserve an entity and update the oracle
                        const entity = Entity.nextReserved(&self.cmds);
                        try self.reserved.putNoClobber(gpa, entity, {});
                    },
                    .destroy => {
                        // If we're at less than half capacity, give a slight bias against destroying
                        // entities so that we don't just hover near zero entities for the whole test
                        if (self.es.count() < self.es.slots.capacity / 2 and
                            (self.bytes.next(bool)))
                        {
                            continue;
                        }

                        // Destroy a random entity
                        const entity = self.randomEntity();
                        entity.destroyCmd(&self.es, &self.cmds);

                        // Destroy the entity in the oracle as well, displacing an existing
                        // destroyed entity if there are already too many to prevent the destroyed
                        // list from growing indefinitely.
                        while (self.destroyed.count() > 1000) {
                            const index = self.bytes.nextLessThan(usize, self.destroyed.count());
                            self.destroyed.swapRemoveAt(index);
                        }
                        _ = self.reserved.swapRemove(entity);
                        _ = self.committed.swapRemove(entity);
                        try self.destroyed.put(gpa, entity, {});
                    },
                    .change_archetype => {
                        // Get a random entity
                        const entity = self.randomEntity();

                        // Pick random components to remove
                        const remove = self.bytes.next(Component.Flags);

                        // Pick random components to add, and add them to the oracle
                        const cap = 16;
                        var rbs: std.BoundedArray(?RigidBody, cap) = .{};
                        var models: std.BoundedArray(?Model, cap) = .{};
                        var tags: std.BoundedArray(?Tag, cap) = .{};
                        var add: std.BoundedArray(Component.Optional, cap) = .{};
                        var add_oracle: ExpectedEntity = .{};

                        for (0..@intCast(self.bytes.nextLessThan(u8, add.buffer.len))) |_| {
                            switch (self.bytes.next(enum {
                                rb,
                                model,
                                tag,
                            })) {
                                .rb => if (self.addComponent(RigidBody, &rbs, &add).*) |rb| {
                                    add_oracle.rb = rb;
                                },
                                .model => if (self.addComponent(Model, &models, &add).*) |model| {
                                    add_oracle.model = model;
                                },
                                .tag => if (self.addComponent(Tag, &tags, &add).*) |tag| {
                                    add_oracle.tag = tag;
                                },
                            }
                        }

                        // Emit the command
                        entity.changeArchetypeCmdFromComponents(&self.es, &self.cmds, .{
                            .add = add.constSlice(),
                            .remove = remove,
                        });

                        // Update the oracle
                        if (self.reserved.swapRemove(entity)) {
                            try self.committed.putNoClobber(gpa, entity, .{});
                        }

                        if (self.committed.getPtr(entity)) |e| {
                            if (remove.contains(self.es.getComponentId(RigidBody))) e.rb = null;
                            if (remove.contains(self.es.getComponentId(Model))) e.model = null;
                            if (remove.contains(self.es.getComponentId(Tag))) e.tag = null;
                            if (add_oracle.rb) |some| e.rb = some;
                            if (add_oracle.model) |some| e.model = some;
                            if (add_oracle.tag) |some| e.tag = some;
                        }
                    },
                    .modify => {
                        // Get a random entity
                        const entity = self.randomEntity();

                        // Generate random component values
                        const rb = self.bytes.next(RigidBody);
                        const model = self.bytes.next(Model);
                        const tag = self.bytes.next(Tag);

                        // If the entity has these components, update them
                        if (entity.getComponent(&self.es, RigidBody)) |old| old.* = rb;
                        if (entity.getComponent(&self.es, Model)) |old| old.* = model;
                        if (entity.getComponent(&self.es, Tag)) |old| old.* = tag;

                        // Update the oracle
                        if (self.committed.getPtr(entity)) |e| {
                            if (e.rb) |*old| old.* = rb;
                            if (e.model) |*old| old.* = model;
                            if (e.tag) |*old| old.* = tag;
                        }
                    },
                }
            }

            self.cmds.execute(&self.es);
            self.cmds.clear(&self.es);
            try self.checkOracle();
        }
    }
};

/// Consumes random bytes, interpreting them as provided types.
const RandomBytes = struct {
    input: []const u8,
    index: usize = 0,
    empty: bool = false,

    pub fn init(input: []const u8) @This() {
        return .{ .input = input };
    }

    pub fn isEmpty(self: @This()) bool {
        return self.index == self.input.len;
    }

    pub fn next(self: *@This(), T: type) T {
        switch (@typeInfo(T)) {
            .void => return {},
            .bool => return (self.nextRaw(u8)) % 2 == 0,
            .int => return self.nextRaw(T),
            .float => return self.nextRaw(T),
            .array => |array| {
                var result: T = undefined;
                for (&result) |*item| {
                    item.* = self.next(array.child);
                }
                return result;
            },
            .@"struct" => |@"struct"| {
                var result: T = undefined;
                inline for (@"struct".fields) |field| {
                    @field(result, field.name) = self.next(field.type);
                }
                return result;
            },
            .null => return null,
            .optional => |optional| {
                if (self.next(bool)) {
                    return self.next(optional.child);
                } else {
                    return null;
                }
            },
            .@"enum" => |@"enum"| {
                const n = self.next(@"enum".tag_type);
                if (!@"enum".is_exhaustive) {
                    return @enumFromInt(n);
                }
                const m = n % @"enum".fields.len;
                inline for (@"enum".fields, 0..) |field, i| {
                    if (i == m) return @enumFromInt(field.value);
                }
                unreachable;
            },
            .@"union" => |@"union"| {
                const tag = self.next(@"union".tag_type.?);
                inline for (@"union".fields) |field| {
                    if (std.mem.eql(u8, field.name, @tagName(tag))) {
                        return @unionInit(T, field.name, self.next(field.type));
                    }
                }
                unreachable;
            },
            else => comptime unreachable,
        }
    }

    pub fn nextLessThan(self: *@This(), T: type, less_than: T) T {
        assert(std.math.maxInt(T) >= less_than);
        const n: T = self.next(T);
        return n % less_than;
    }

    /// Reinterpret the next @sizeOf(T) bytes as T. Wraps around and sets empty when past end.
    fn nextRaw(self: *@This(), T: type) T {
        var bytes: [@sizeOf(T)]u8 = .{0} ** @sizeOf(T);
        for (0..@min(self.input.len, bytes.len)) |i| {
            bytes[i] = self.input[self.index];
            self.index += 1;
            if (self.index >= self.input.len) {
                self.empty = true;
                self.index = 0;
            }
        }

        var result: T = undefined;
        @memcpy(std.mem.asBytes(&result), &bytes);
        return result;
    }
};
