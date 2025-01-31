//! Support structure for oracle based fuzz tests.

const std = @import("std");
const zcs = @import("zcs");

const gpa = std.testing.allocator;
const assert = std.debug.assert;
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

const Parser = @import("Parser.zig");

const Entities = zcs.Entities;
const CmdBuf = zcs.CmdBuf;
const Entity = zcs.Entity;
const Comp = zcs.Comp;
const typeId = zcs.typeId;

pub const RigidBody = struct {
    pub const interned: [3]@This() = .{
        .{},
        .{ .position = .{ 2.0, 3.0 }, .velocity = .{ 4.0, 5.0 }, .mass = 10.0 },
        .{ .position = .{ 24.0, 32.0 }, .velocity = .{ 42.0, 55.0 }, .mass = 103.0 },
    };
    position: [2]f32 = .{ 1.0, 2.0 },
    velocity: [2]f32 = .{ 3.0, 4.0 },
    mass: f32 = 5.0,
};

pub const Model = struct {
    pub const interned: [3]@This() = .{
        .{},
        .{ .vertex_start = 1, .vertex_count = 2 },
        .{ .vertex_start = 10, .vertex_count = 20 },
    };
    vertex_start: u16 = 6,
    vertex_count: u16 = 7,
};

pub const Tag = struct {
    pub const interned: [2]@This() = .{
        .{},
        .{},
    };
};

pub const ExpectedEntity = struct {
    model: ?Model = null,
    rb: ?RigidBody = null,
    tag: ?Tag = null,
};

/// Tests random command buffers against an oracle.
pub const max_entities = 100000;
pub const comp_bytes = 100000;

es: Entities,
parser: Parser,
reserved: std.AutoArrayHashMapUnmanaged(Entity, void),
committed: std.AutoArrayHashMapUnmanaged(Entity, ExpectedEntity),
/// A sample of destroyed entities. Capped to avoid growing forever, when it reaches the cap
/// random entities are removed from the set.
destroyed: std.AutoArrayHashMapUnmanaged(Entity, void),
found_buf: std.AutoArrayHashMapUnmanaged(Entity, void),

pub fn init(input: []const u8) !@This() {
    var es: Entities = try .init(gpa, .{
        .max_entities = max_entities,
        .comp_bytes = comp_bytes,
    });
    errdefer es.deinit(gpa);

    var reserved: std.AutoArrayHashMapUnmanaged(Entity, void) = .{};
    errdefer reserved.deinit(gpa);
    try reserved.ensureTotalCapacity(gpa, max_entities);

    var committed: std.AutoArrayHashMapUnmanaged(Entity, ExpectedEntity) = .{};
    errdefer committed.deinit(gpa);
    try committed.ensureTotalCapacity(gpa, max_entities);

    var destroyed: std.AutoArrayHashMapUnmanaged(Entity, void) = .{};
    errdefer destroyed.deinit(gpa);
    try destroyed.ensureTotalCapacity(gpa, max_entities);

    var found_buf: std.AutoArrayHashMapUnmanaged(Entity, void) = .{};
    errdefer found_buf.deinit(gpa);
    try found_buf.ensureTotalCapacity(gpa, max_entities);

    const parser: Parser = .init(input);

    return .{
        .es = es,
        .reserved = reserved,
        .committed = committed,
        .destroyed = destroyed,
        .parser = parser,
        .found_buf = found_buf,
    };
}

pub fn deinit(self: *@This()) void {
    self.found_buf.deinit(gpa);
    self.destroyed.deinit(gpa);
    self.committed.deinit(gpa);
    self.reserved.deinit(gpa);
    self.es.deinit(gpa);
    self.* = undefined;
}

pub fn checkIterators(self: *@This()) !void {
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
            self.expectedOfArch(.{ .rb = true }),
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
            self.expectedOfArch(.{ .rb = true }),
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
            self.expectedOfArch(.{ .model = true }),
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
            self.expectedOfArch(.{ .tag = true }),
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
            self.expectedOfArch(.{ .rb = true, .model = true, .tag = true }),
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
            self.expectedOfArch(.{ .rb = true, .tag = true }),
            self.found_buf.count(),
        );
    }
}

pub const Arch = packed struct {
    rb: bool = false,
    model: bool = false,
    tag: bool = false,
};

pub fn expectedOfArch(self: *@This(), arch: Arch) usize {
    var count: usize = 0;
    var iter = self.committed.iterator();
    while (iter.next()) |entry| {
        if (arch.rb) {
            if (entry.value_ptr.rb == null) continue;
        }
        if (arch.model) {
            if (entry.value_ptr.model == null) continue;
        }
        if (arch.tag) {
            if (entry.value_ptr.tag == null) continue;
        }
        count += 1;
    }
    return count;
}

pub fn reserveImmediate(self: *@This()) !Entity {
    // Skip reserve if we already have a lot of entities to avoid overflowing
    if (self.es.count() + self.es.reserved() > self.es.slots.capacity / 2) {
        return .none;
    }

    // Reserve an entity and update the oracle
    const entity = Entity.reserveImmediate(&self.es);
    try self.reserved.putNoClobber(gpa, entity, {});
    return entity;
}

pub fn modifyImmediate(self: *@This()) !void {
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

pub fn randomEntity(self: *@This()) Entity {
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

// If we're at less than half capacity, give a slight bias against destroying
// entities so that we don't just hover near zero entities for the whole test
pub fn shouldSkipDestroy(self: *@This()) bool {
    return (self.es.count() < self.es.slots.capacity / 2 and (self.parser.next(bool)));
}

pub fn destroyInOracle(self: *@This(), entity: Entity) !void {
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
