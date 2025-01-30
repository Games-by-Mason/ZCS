const std = @import("std");
const zcs = @import("zcs");

const gpa = std.testing.allocator;
const assert = std.debug.assert;
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

const FuzzParser = @import("FuzzParser.zig");

const Entities = zcs.Entities;
const CmdBuf = zcs.CmdBuf;
const Entity = zcs.Entity;
const Comp = zcs.Comp;
const typeId = zcs.typeId;

test "fuzz cmdbuf" {
    try std.testing.fuzz(FuzzCmdBuf.run, .{ .corpus = &.{} });
}

test "rand cmdbuf" {
    var xoshiro_256: std.Random.Xoshiro256 = .init(0);
    const rand = xoshiro_256.random();
    const input: []u8 = try gpa.alloc(u8, 8192);
    defer gpa.free(input);
    rand.bytes(input);
    try FuzzCmdBuf.run(input);
}

const RigidBody = struct {
    const interned: [3]@This() = .{
        .{},
        .{ .position = .{ 2.0, 3.0 }, .velocity = .{ 4.0, 5.0 }, .mass = 10.0 },
        .{ .position = .{ 24.0, 32.0 }, .velocity = .{ 42.0, 55.0 }, .mass = 103.0 },
    };
    position: [2]f32 = .{ 1.0, 2.0 },
    velocity: [2]f32 = .{ 3.0, 4.0 },
    mass: f32 = 5.0,
};

const Model = struct {
    const interned: [3]@This() = .{
        .{},
        .{ .vertex_start = 1, .vertex_count = 2 },
        .{ .vertex_start = 10, .vertex_count = 20 },
    };
    vertex_start: u16 = 6,
    vertex_count: u16 = 7,
};

pub const Tag = struct {
    const interned: [2]@This() = .{
        .{},
        .{},
    };
};

const ExpectedEntity = struct {
    model: ?Model = null,
    rb: ?RigidBody = null,
    tag: ?Tag = null,
};

/// Tests random command buffers against an oracle.
const FuzzCmdBuf = struct {
    const capacity = 100000;
    const cmds_capacity = 1000;
    const change_cap = 16;

    es: Entities,
    cmds: CmdBuf,
    parser: FuzzParser,
    reserved: std.AutoArrayHashMapUnmanaged(Entity, void),
    committed: std.AutoArrayHashMapUnmanaged(Entity, ExpectedEntity),
    /// A sample of destroyed entities. Capped to avoid growing forever, when it reaches the cap
    /// random entities are removed from the set.
    destroyed: std.AutoArrayHashMapUnmanaged(Entity, void),
    found_buf: std.AutoArrayHashMapUnmanaged(Entity, void),

    fn init(input: []const u8) !@This() {
        var es: Entities = try .init(gpa, capacity);
        errdefer es.deinit(gpa);

        var cmds: CmdBuf = try .init(gpa, &es, .{ .cmds = cmds_capacity, .comp_bytes = @sizeOf(RigidBody) });
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

        var found_buf: std.AutoArrayHashMapUnmanaged(Entity, void) = .{};
        errdefer found_buf.deinit(gpa);
        try found_buf.ensureTotalCapacity(gpa, capacity);

        const parser: FuzzParser = .init(input);

        return .{
            .es = es,
            .cmds = cmds,
            .reserved = reserved,
            .committed = committed,
            .destroyed = destroyed,
            .parser = parser,
            .found_buf = found_buf,
        };
    }

    fn deinit(self: *@This()) void {
        self.found_buf.deinit(gpa);
        self.destroyed.deinit(gpa);
        self.committed.deinit(gpa);
        self.reserved.deinit(gpa);
        self.cmds.deinit(gpa, &self.es);
        self.es.deinit(gpa);
        self.* = undefined;
    }

    fn run(input: []const u8) !void {
        defer Comp.unregisterAll();

        var self: @This() = try init(input);
        defer self.deinit();

        var i = self.parser.index;
        while (!self.parser.isEmpty()) {
            // Modify the entities via a command buffer
            for (0..self.parser.nextLessThan(u16, cmds_capacity)) |_| {
                if (self.parser.isEmpty()) break;
                i = self.parser.index;
                switch (self.parser.next(enum {
                    reserve,
                    destroy,
                    change_archetype,
                })) {
                    .reserve => try self.reserve(),
                    .destroy => try self.destroy(),
                    .change_archetype => try self.changeArchetype(),
                }
            }

            self.cmds.execute(&self.es);
            self.cmds.clear(&self.es);
            try self.checkOracle();

            // Modify the entities directly. We do this later since interspersing it with the
            // command buffer will get incorrect results since the oracle applies everything
            // instantly. We only do a few iterations because this test is easily exhausted.
            for (0..self.parser.nextLessThan(u16, 100)) |_| {
                if (self.parser.isEmpty()) break;
                try self.modify();
            }
            try self.checkOracle();
        }
    }

    fn checkOracle(self: *@This()) !void {
        // Check the total number of entities
        try expectEqual(
            self.reserved.count() + self.cmds.reserved.items.len,
            self.es.reserved(),
        );
        try expectEqual(self.committed.count(), self.es.count());

        // Check the reserved entities
        for (self.reserved.keys()) |e| {
            try expect(e.exists(&self.es));
            try expect(!e.committed(&self.es));
        }

        // Check the committed entities
        var commited_iter = self.committed.iterator();
        while (commited_iter.next()) |entry| {
            const entity = entry.key_ptr.*;
            const expected = entry.value_ptr;
            try expect(entity.exists(&self.es));
            try expect(entity.committed(&self.es));
            try expectEqual(expected.rb, if (entity.getComp(&self.es, RigidBody)) |v| v.* else null);
            try expectEqual(expected.model, if (entity.getComp(&self.es, Model)) |v| v.* else null);
            try expectEqual(expected.tag, if (entity.getComp(&self.es, Tag)) |v| v.* else null);
        }

        // Check the tracked deleted entities
        var destroyed_iter = self.destroyed.iterator();
        while (destroyed_iter.next()) |entry| {
            const entity = entry.key_ptr.*;
            try expect(!entity.exists(&self.es));
            try expect(!entity.committed(&self.es));
            try expectEqual(null, if (entity.getComp(&self.es, RigidBody)) |v| v.* else null);
            try expectEqual(null, if (entity.getComp(&self.es, Model)) |v| v.* else null);
            try expectEqual(null, if (entity.getComp(&self.es, Tag)) |v| v.* else null);
        }

        // Check the iterators
        try self.checkIterators();
    }

    fn checkIterators(self: *@This()) !void {
        // All entities, no handle
        {
            // Get the actual count, checking the entities along the way
            var count: usize = 0;
            var iter = self.es.viewIterator(struct {});
            while (iter.next()) |_| {
                count += 1;
            }

            // Compare them
            try expectEqual(self.committed.count(), count);
        }

        // All entities, with handle
        {
            // Get the actual count, checking the entities along the way
            defer self.found_buf.clearRetainingCapacity();
            var iter = self.es.viewIterator(struct { e: Entity });
            while (iter.next()) |vw| {
                try self.found_buf.putNoClobber(gpa, vw.e, {});
            }

            // Compare them
            try expectEqual(self.committed.count(), self.found_buf.count());
        }

        // Rigid bodies, without handle
        {
            // Get the actual count, checking the entities along the way
            var count: usize = 0;
            var iter = self.es.viewIterator(struct { rb: *const RigidBody });
            while (iter.next()) |_| {
                count += 1;
            }

            // Compare them
            try expectEqual(
                self.expectedOfArchetype(.{ .rb = true }),
                count,
            );
        }

        // Rigid bodies, with handle
        {
            // Get the actual count, checking the entities along the way
            defer self.found_buf.clearRetainingCapacity();
            var iter = self.es.viewIterator(struct { rb: *RigidBody, e: Entity });
            while (iter.next()) |vw| {
                try expectEqual(vw.rb, vw.e.getComp(&self.es, RigidBody).?);
                try self.found_buf.putNoClobber(gpa, vw.e, {});
            }

            // Compare them
            try expectEqual(
                self.expectedOfArchetype(.{ .rb = true }),
                self.found_buf.count(),
            );
        }

        // Models, with handle
        {
            // Get the actual count, checking the entities along the way
            defer self.found_buf.clearRetainingCapacity();
            var iter = self.es.viewIterator(struct { model: *Model, e: Entity });
            while (iter.next()) |vw| {
                try expectEqual(vw.model, vw.e.getComp(&self.es, Model).?);
                try self.found_buf.putNoClobber(gpa, vw.e, {});
            }

            // Compare to the expected count
            try expectEqual(
                self.expectedOfArchetype(.{ .model = true }),
                self.found_buf.count(),
            );
        }

        // Tags, with handle
        {
            // Get the actual count, checking the entities along the way
            defer self.found_buf.clearRetainingCapacity();
            var iter = self.es.viewIterator(struct { tag: *const Tag, e: Entity });
            while (iter.next()) |vw| {
                try expectEqual(vw.tag, vw.e.getComp(&self.es, Tag).?);
                try self.found_buf.putNoClobber(gpa, vw.e, {});
            }

            // Compare to the expected count
            try expectEqual(
                self.expectedOfArchetype(.{ .tag = true }),
                self.found_buf.count(),
            );
        }

        // All three, with handle
        {
            // Get the actual count, checking the entities along the way
            defer self.found_buf.clearRetainingCapacity();
            var iter = self.es.viewIterator(struct {
                rb: *const RigidBody,
                model: *const Model,
                tag: *const Tag,
                e: Entity,
            });
            while (iter.next()) |vw| {
                try expectEqual(vw.rb, vw.e.getComp(&self.es, RigidBody).?);
                try expectEqual(vw.model, vw.e.getComp(&self.es, Model).?);
                try expectEqual(vw.tag, vw.e.getComp(&self.es, Tag).?);
                try self.found_buf.putNoClobber(gpa, vw.e, {});
            }

            // Compare to the expected count
            try expectEqual(
                self.expectedOfArchetype(.{ .rb = true, .model = true, .tag = true }),
                self.found_buf.count(),
            );
        }

        // All optional
        {
            // Get the actual count, checking the entities along the way
            defer self.found_buf.clearRetainingCapacity();
            var iter = self.es.viewIterator(struct {
                rb: ?*const RigidBody,
                model: ?*Model,
                tag: ?*Tag,
                e: Entity,
            });
            while (iter.next()) |vw| {
                try expectEqual(vw.rb, vw.e.getComp(&self.es, RigidBody));
                try expectEqual(vw.model, vw.e.getComp(&self.es, Model));
                try expectEqual(vw.tag, vw.e.getComp(&self.es, Tag));
                try self.found_buf.putNoClobber(gpa, vw.e, {});
            }

            // Compare to the expected count
            try expectEqual(self.committed.count(), self.found_buf.count());
        }

        // Some optional
        {
            // Get the actual count, checking the entities along the way
            defer self.found_buf.clearRetainingCapacity();
            var iter = self.es.viewIterator(struct {
                rb: *const RigidBody,
                model: ?*Model,
                tag: *Tag,
                e: Entity,
            });
            while (iter.next()) |vw| {
                try expectEqual(vw.rb, vw.e.getComp(&self.es, RigidBody));
                try expectEqual(vw.model, vw.e.getComp(&self.es, Model));
                try expectEqual(vw.tag, vw.e.getComp(&self.es, Tag));
                try self.found_buf.putNoClobber(gpa, vw.e, {});
            }

            // Compare to the expected count
            try expectEqual(
                self.expectedOfArchetype(.{ .rb = true, .tag = true }),
                self.found_buf.count(),
            );
        }
    }

    const Archetype = packed struct {
        rb: bool = false,
        model: bool = false,
        tag: bool = false,
    };

    fn expectedOfArchetype(self: *@This(), archetype: Archetype) usize {
        var count: usize = 0;
        var iter = self.committed.iterator();
        while (iter.next()) |entry| {
            if (archetype.rb) {
                if (entry.value_ptr.rb == null) continue;
            }
            if (archetype.model) {
                if (entry.value_ptr.model == null) continue;
            }
            if (archetype.tag) {
                if (entry.value_ptr.tag == null) continue;
            }
            count += 1;
        }
        return count;
    }

    fn reserve(self: *@This()) !void {
        // Skip reserve if we already have a lot of entities to avoid overflowing
        if (self.es.count() + self.es.reserved() > self.es.slots.capacity / 2) {
            return;
        }

        // Reserve an entity and update the oracle
        const entity = Entity.nextReserved(&self.cmds);
        try self.reserved.putNoClobber(gpa, entity, {});
    }

    fn destroy(self: *@This()) !void {
        // If we're at less than half capacity, give a slight bias against destroying
        // entities so that we don't just hover near zero entities for the whole test
        if (self.es.count() < self.es.slots.capacity / 2 and
            (self.parser.next(bool)))
        {
            return;
        }

        // Destroy a random entity
        const entity = self.randomEntity();
        entity.destroyCmd(&self.cmds);

        // Destroy the entity in the oracle as well, displacing an existing
        // destroyed entity if there are already too many to prevent the destroyed
        // list from growing indefinitely.
        while (self.destroyed.count() > 1000) {
            const index = self.parser.nextLessThan(usize, self.destroyed.count());
            self.destroyed.swapRemoveAt(index);
        }
        _ = self.reserved.swapRemove(entity);
        _ = self.committed.swapRemove(entity);
        try self.destroyed.put(gpa, entity, {});
    }

    fn changeArchetype(self: *@This()) !void {
        // Get a random entity
        const entity = self.randomEntity();

        // Get the oracle if any, committing it if needed
        if (self.reserved.swapRemove(entity)) {
            try self.committed.putNoClobber(gpa, entity, .{});
        }
        const expected = self.committed.getPtr(entity);

        // Issue commands to add/remove N random components, updating the oracle along the way
        for (0..@intCast(self.parser.nextBetween(u8, 1, change_cap))) |_| {
            if (self.parser.next(bool)) {
                switch (self.parser.next(enum {
                    rb,
                    model,
                    tag,
                })) {
                    .rb => {
                        const rb = self.addRandomComp(entity, RigidBody);
                        if (expected) |e| e.rb = rb;
                    },
                    .model => {
                        const model = self.addRandomComp(entity, Model);
                        if (expected) |e| e.model = model;
                    },
                    .tag => {
                        const tag = self.addRandomComp(entity, Tag);
                        if (expected) |e| e.tag = tag;
                    },
                }
            } else {
                switch (self.parser.next(enum {
                    rb,
                    model,
                    tag,
                    commit,
                })) {
                    .rb => {
                        entity.removeCompCmd(&self.cmds, RigidBody);
                        if (expected) |e| e.rb = null;
                    },
                    .model => {
                        entity.removeCompCmd(&self.cmds, Model);
                        if (expected) |e| e.model = null;
                    },
                    .tag => {
                        entity.removeCompCmd(&self.cmds, Tag);
                        if (expected) |e| e.tag = null;
                    },
                    .commit => {
                        entity.commitCmd(&self.cmds);
                    },
                }
            }
        }
    }

    fn modify(self: *@This()) !void {
        // Get a random entity
        const entity = self.randomEntity();

        // Generate random component values
        const rb = self.parser.next(RigidBody);
        const model = self.parser.next(Model);
        const tag = self.parser.next(Tag);

        // If the entity has these components, update them
        if (entity.getComp(&self.es, RigidBody)) |old| old.* = rb;
        if (entity.getComp(&self.es, Model)) |old| old.* = model;
        if (entity.getComp(&self.es, Tag)) |old| old.* = tag;

        // Update the oracle
        if (self.committed.getPtr(entity)) |e| {
            if (e.rb) |*old| old.* = rb;
            if (e.model) |*old| old.* = model;
            if (e.tag) |*old| old.* = tag;
        }
    }

    fn randomEntity(self: *@This()) Entity {
        // Sometimes return .none
        if (self.parser.next(u8) < 10) return .none;

        switch (self.parser.next(enum {
            reserved,
            committed,
            destroyed,
        })) {
            .reserved => {
                if (self.reserved.count() == 0) return .none;
                const index = self.parser.nextLessThan(usize, self.reserved.count());
                return self.reserved.keys()[index];
            },
            .committed => {
                if (self.committed.count() == 0) return .none;
                const index = self.parser.nextLessThan(usize, self.committed.count());
                return self.committed.keys()[index];
            },
            .destroyed => {
                if (self.destroyed.count() == 0) return .none;
                const index = self.parser.nextLessThan(usize, self.destroyed.count());
                return self.destroyed.keys()[index];
            },
        }
    }

    /// Adds a random value for the given component by value, or a random value from it's interned
    /// list by pointer. Returns the value.
    fn addRandomComp(self: *@This(), e: Entity, T: type) T {
        const i = self.parser.next(u8);
        const by_ptr = i < 40;
        if (by_ptr) {
            switch (i % T.interned.len) {
                inline 0...(T.interned.len - 1) => |n| {
                    const val = T.interned[n];
                    e.addCompPtrCmd(&self.cmds, .init(T, &val));
                    return val;
                },
                else => unreachable,
            }
        } else {
            const val = self.parser.next(T);
            e.addCompCmd(&self.cmds, T, val);
            return val;
        }
    }
};
