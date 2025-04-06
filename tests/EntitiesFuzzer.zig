//! Support structure for oracle based fuzz tests.

const std = @import("std");
const zcs = @import("zcs");

const gpa = std.testing.allocator;
const assert = std.debug.assert;
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

const Smith = @import("Smith.zig");

const Entities = zcs.Entities;
const CmdBuf = zcs.CmdBuf;
const Entity = zcs.Entity;
const typeId = zcs.typeId;

const types = @import("types.zig");

const RigidBody = types.RigidBody;
const Model = types.Model;
const Tag = types.Tag;

pub const ExpectedEntity = struct {
    model: ?Model = null,
    rb: ?RigidBody = null,
    tag: ?Tag = null,
};

/// Tests random command buffers against an oracle.
pub const max_entities = 100000;

es: Entities,
smith: Smith,
reserved: std.AutoArrayHashMapUnmanaged(Entity, void),
committed: std.AutoArrayHashMapUnmanaged(Entity, ExpectedEntity),
/// A sample of destroyed entities. Capped to avoid growing forever, when it reaches the cap
/// random entities are removed from the set.
destroyed: std.AutoArrayHashMapUnmanaged(Entity, void),
found_buf: std.AutoArrayHashMapUnmanaged(Entity, void),

pub fn init(input: []const u8) !@This() {
    var es: Entities = try .init(gpa, .{
        .max_entities = max_entities,
        .max_archetypes = 32,
        .max_chunks = 2048,
        // We set a fairly small chunk size for better test coverage
        .chunk_size = 512,
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

    const smith: Smith = .init(input);

    return .{
        .es = es,
        .reserved = reserved,
        .committed = committed,
        .destroyed = destroyed,
        .smith = smith,
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

fn countEntities(count: *usize) void {
    count.* += 1;
}

fn countEntitiesChunkedWithHandles(
    self: *@This(),
    entity_indices: []const Entity.Index,
) void {
    for (entity_indices) |entity_index| {
        const entity = entity_index.toEntity(&self.es);
        assert(entity.exists(&self.es));
        assert(entity.committed(&self.es));
        self.found_buf.putNoClobber(gpa, entity, {}) catch |err|
            @panic(@errorName(err));
    }
}

fn countEntitiesWithHandle(
    self: *@This(),
    entity: Entity,
) void {
    assert(entity.exists(&self.es));
    assert(entity.committed(&self.es));
    self.found_buf.putNoClobber(gpa, entity, {}) catch |err|
        @panic(@errorName(err));
}

fn checkRigidBodies(
    self: *@This(),
    rb: *const RigidBody,
) void {
    const entity = self.es.getEntity(rb);
    assert(entity.get(&self.es, RigidBody).? == rb);
    self.found_buf.putNoClobber(gpa, entity, {}) catch |err|
        @panic(@errorName(err));
}

fn checkRigidBodiesWithHandle(
    self: *@This(),
    rb: *const RigidBody,
    entity: Entity,
) void {
    assert(entity == self.es.getEntity(rb));
    assert(entity.get(&self.es, RigidBody).? == rb);
    self.found_buf.putNoClobber(gpa, entity, {}) catch |err|
        @panic(@errorName(err));
}

fn checkRigidBodiesChunked(
    self: *@This(),
    rbs: []const RigidBody,
) void {
    for (rbs) |*rb| {
        const entity = self.es.getEntity(rb);
        assert(entity.get(&self.es, RigidBody).? == rb);
        self.found_buf.putNoClobber(gpa, entity, {}) catch |err|
            @panic(@errorName(err));
    }
}

fn checkRigidBodiesChunkedWithHandles(
    self: *@This(),
    rbs: []const RigidBody,
    entity_indices: []const Entity.Index,
) void {
    for (rbs, entity_indices) |*rb, entity_index| {
        const entity = entity_index.toEntity(&self.es);
        assert(entity == self.es.getEntity(rb));
        assert(entity.get(&self.es, RigidBody).? == rb);
        self.found_buf.putNoClobber(gpa, entity, {}) catch |err|
            @panic(@errorName(err));
    }
}

fn checkModelsWithHandle(
    self: *@This(),
    model: *Model,
    entity: Entity,
) void {
    assert(entity == self.es.getEntity(model));
    assert(entity.get(&self.es, Model).? == model);
    self.found_buf.putNoClobber(gpa, entity, {}) catch |err|
        @panic(@errorName(err));
}

fn checkTagsWithHandle(
    self: *@This(),
    tag: *Tag,
    entity: Entity,
) void {
    // https://github.com/ziglang/zig/issues/23405
    // assert(entity.get(&self.es, Tag).? == tag);
    _ = tag;
    self.found_buf.putNoClobber(gpa, entity, {}) catch |err|
        @panic(@errorName(err));
}

fn checkAllWithHandle(
    self: *@This(),
    tag: *const Tag,
    rb: *const RigidBody,
    model: *const Model,
    entity: Entity,
) void {
    _ = tag;
    assert(rb == entity.get(&self.es, RigidBody).?);
    assert(model == entity.get(&self.es, Model).?);
    // https://github.com/ziglang/zig/issues/23405
    // assert(tag == entity.get(&self.es, Tag).?);
    assert(entity == self.es.getEntity(rb));
    assert(entity == self.es.getEntity(model));
    self.found_buf.putNoClobber(gpa, entity, {}) catch |err|
        @panic(@errorName(err));

    assert(self.es.getComp(rb, RigidBody) == rb);
    assert(self.es.getComp(rb, Model) == model);
    // https://github.com/ziglang/zig/issues/23405
    // assert(self.es.getComp(rb, Tag) == tag);
}

fn checkAllOptionalWithHandle(
    self: *@This(),
    tag: ?*Tag,
    rb_opt: ?*const RigidBody,
    model_opt: ?*Model,
    entity: Entity,
) void {
    _ = tag;
    assert(rb_opt == entity.get(&self.es, RigidBody));
    assert(model_opt == entity.get(&self.es, Model));
    // https://github.com/ziglang/zig/issues/23405
    // try expectEqual(tag_opt, e.get(&self.es, Tag));
    if (rb_opt) |rb| assert(entity == self.es.getEntity(rb));
    if (model_opt) |model| assert(entity == self.es.getEntity(model));
    self.found_buf.putNoClobber(gpa, entity, {}) catch |err|
        @panic(@errorName(err));

    if (model_opt) |model| {
        assert(self.es.getComp(model, RigidBody) == rb_opt);
        assert(self.es.getComp(model, Model) == model);
        // https://github.com/ziglang/zig/issues/23405
        // assert(self.es.getComp(rb, Tag) == tag);
    }
}

fn checkSomeOptional(
    self: *@This(),
    tag: ?*Tag,
    rb: *const RigidBody,
    model: *Model,
) void {
    const entity = self.es.getEntity(rb);
    assert(entity == self.es.getEntity(model));
    assert(rb == entity.get(&self.es, RigidBody));
    assert(model == entity.get(&self.es, Model));
    // https://github.com/ziglang/zig/issues/23405
    // try expectEqual(tag, e.get(&self.es, Tag));
    _ = tag;
    assert(entity == self.es.getEntity(model));
    self.found_buf.putNoClobber(gpa, entity, {}) catch |err|
        @panic(@errorName(err));
}

fn checkSomeOptionalWithHandle(
    self: *@This(),
    tag: *Tag,
    rb: *const RigidBody,
    model_opt: ?*Model,
    entity: Entity,
) void {
    assert(rb == entity.get(&self.es, RigidBody));
    assert(model_opt == entity.get(&self.es, Model));
    // https://github.com/ziglang/zig/issues/23405
    // try expectEqual(tag_opt, e.get(&self.es, Tag));
    _ = tag;
    assert(entity == self.es.getEntity(rb));
    if (model_opt) |model| assert(entity == self.es.getEntity(model));
    self.found_buf.putNoClobber(gpa, entity, {}) catch |err|
        @panic(@errorName(err));
}

fn checkSomeOptionalChunked(
    self: *@This(),
    tags_opt: ?[]Tag,
    rbs: []const RigidBody,
    models: []Model,
) void {
    for (rbs, models, 0..) |*rb, *model, i| {
        const entity = self.es.getEntity(rb);
        assert(entity == self.es.getEntity(model));
        assert(rb == entity.get(&self.es, RigidBody));
        assert(model == entity.get(&self.es, Model));
        // https://github.com/ziglang/zig/issues/23405
        // if (tags_opt) |tags| assert(&tags[i] == entity.get(&self.es, Tag).?);
        _ = tags_opt;
        _ = i;
        assert(entity == self.es.getEntity(model));
        self.found_buf.putNoClobber(gpa, entity, {}) catch |err|
            @panic(@errorName(err));
    }
}

fn checkSomeOptionalChunkedWithHandles(
    self: *@This(),
    tags: ?[]Tag,
    rbs: []const RigidBody,
    models: []Model,
    entity_indices: []const Entity.Index,
) void {
    for (rbs, models, entity_indices, 0..) |*rb, *model, entity_index, i| {
        const entity = entity_index.toEntity(&self.es);
        assert(entity == self.es.getEntity(rb));
        assert(entity == self.es.getEntity(model));
        assert(rb == entity.get(&self.es, RigidBody));
        assert(model == entity.get(&self.es, Model));
        // https://github.com/ziglang/zig/issues/23405
        // try expectEqual(tag_opt, e.get(&self.es, Tag));
        _ = tags;
        _ = i;
        assert(entity == self.es.getEntity(model));
        self.found_buf.putNoClobber(gpa, entity, {}) catch |err|
            @panic(@errorName(err));
    }
}

pub fn checkIterators(self: *@This()) !void {
    // All entities
    {
        // Per entity, no handle
        {
            var count: usize = 0;
            self.es.forEach(countEntities, &count);
            try expectEqual(self.committed.count(), count);
        }

        // Per chunk, with handles
        {
            defer self.found_buf.clearRetainingCapacity();
            self.es.forEachChunk(countEntitiesChunkedWithHandles, self);
            try expectEqual(self.committed.count(), self.found_buf.count());
        }

        // Per entity, with handles
        {
            defer self.found_buf.clearRetainingCapacity();
            self.es.forEach(countEntitiesWithHandle, self);
            try expectEqual(self.committed.count(), self.found_buf.count());
        }
    }

    // Rigid bodies
    {
        // Per entity, no handle
        {
            defer self.found_buf.clearRetainingCapacity();
            self.es.forEach(checkRigidBodies, self);
            try expectEqual(self.expectedOfArch(.{ .rb = true }), self.found_buf.count());
        }

        // Per entity, with handle
        {
            defer self.found_buf.clearRetainingCapacity();
            self.es.forEach(checkRigidBodiesWithHandle, self);
            try expectEqual(self.expectedOfArch(.{ .rb = true }), self.found_buf.count());
        }

        // Per chunk, without handles
        {
            defer self.found_buf.clearRetainingCapacity();
            self.es.forEachChunk(checkRigidBodiesChunked, self);
            try expectEqual(self.expectedOfArch(.{ .rb = true }), self.found_buf.count());
        }

        // Per chunk, with handles
        {
            defer self.found_buf.clearRetainingCapacity();
            self.es.forEachChunk(checkRigidBodiesChunkedWithHandles, self);
            try expectEqual(self.expectedOfArch(.{ .rb = true }), self.found_buf.count());
        }
    }

    // Models
    {
        defer self.found_buf.clearRetainingCapacity();
        self.es.forEach(checkModelsWithHandle, self);
        try expectEqual(self.expectedOfArch(.{ .model = true }), self.found_buf.count());
        try expectEqual(
            self.expectedOfArch(.{ .model = true }),
            self.found_buf.count(),
        );
    }

    // Tags, with handle
    {
        defer self.found_buf.clearRetainingCapacity();
        self.es.forEach(checkTagsWithHandle, self);
        try expectEqual(self.expectedOfArch(.{ .tag = true }), self.found_buf.count());
        try expectEqual(
            self.expectedOfArch(.{ .tag = true }),
            self.found_buf.count(),
        );
    }

    // All three, with handle
    {
        defer self.found_buf.clearRetainingCapacity();
        self.es.forEach(checkAllWithHandle, self);
        try expectEqual(
            self.expectedOfArch(.{ .rb = true, .model = true, .tag = true }),
            self.found_buf.count(),
        );
    }

    // All optional
    {
        defer self.found_buf.clearRetainingCapacity();
        self.es.forEach(checkAllOptionalWithHandle, self);
        try expectEqual(self.committed.count(), self.found_buf.count());
    }

    // Some optional
    {
        // Per entity, without handle
        {
            defer self.found_buf.clearRetainingCapacity();
            self.es.forEach(checkSomeOptional, self);
            try expectEqual(
                self.expectedOfArch(.{ .rb = true, .model = true }),
                self.found_buf.count(),
            );
        }

        // Per entity, with handle
        {
            defer self.found_buf.clearRetainingCapacity();
            self.es.forEach(checkSomeOptionalWithHandle, self);
            try expectEqual(
                self.expectedOfArch(.{ .rb = true, .tag = true }),
                self.found_buf.count(),
            );
        }

        // Per entity, without handles chunked
        {
            defer self.found_buf.clearRetainingCapacity();
            self.es.forEachChunk(checkSomeOptionalChunked, self);
            try expectEqual(
                self.expectedOfArch(.{ .rb = true, .model = true }),
                self.found_buf.count(),
            );
        }

        // Per entity, with handles chunked
        {
            defer self.found_buf.clearRetainingCapacity();
            self.es.forEachChunk(checkSomeOptionalChunkedWithHandles, self);
            try expectEqual(
                self.expectedOfArch(.{ .rb = true, .model = true }),
                self.found_buf.count(),
            );
        }
    }

    // Regression test, optional unregistered components
    {
        const Unregistered = struct { foo: u8 };
        var iter = self.es.iterator(struct { foo: ?*Unregistered, e: Entity });
        if (iter.next(&self.es)) |vw| {
            _ = vw.e.view(&self.es, struct { foo: ?*Unregistered });
        }
        try expectEqual(null, typeId(Unregistered).comp_flag);
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

pub fn reserveImmediate(self: *@This()) !Entity.Optional {
    // Skip reserve if we already have a lot of entities to avoid overflowing
    if (self.es.count() + self.es.reserved() > self.es.handle_tab.capacity / 2) {
        return .none;
    }

    // Reserve an entity and update the oracle
    const entity = Entity.reserveImmediate(&self.es);
    try self.reserved.putNoClobber(gpa, entity, {});
    return entity.toOptional();
}

pub fn modifyImmediate(self: *@This()) !void {
    // Get a random entity
    const entity = self.randomEntity().unwrap() orelse return;

    // Generate random component values
    const rb = self.smith.next(RigidBody);
    const model = self.smith.next(Model);
    const tag = self.smith.next(Tag);

    // If the entity has these components, update them
    if (entity.get(&self.es, RigidBody)) |old| old.* = rb;
    if (entity.get(&self.es, Model)) |old| old.* = model;
    if (entity.get(&self.es, Tag)) |old| old.* = tag;

    // Update the oracle
    if (self.committed.getPtr(entity)) |e| {
        if (e.rb) |*old| old.* = rb;
        if (e.model) |*old| old.* = model;
        if (e.tag) |*old| old.* = tag;
    }
}

pub fn randomEntity(self: *@This()) Entity.Optional {
    // Sometimes return .none
    if (self.smith.next(u8) < 10) return .none;

    switch (self.smith.next(enum {
        reserved,
        committed,
        destroyed,
    })) {
        .reserved => {
            if (self.reserved.count() == 0) return .none;
            const index = self.smith.nextLessThan(usize, self.reserved.count());
            return self.reserved.keys()[index].toOptional();
        },
        .committed => {
            if (self.committed.count() == 0) return .none;
            const index = self.smith.nextLessThan(usize, self.committed.count());
            return self.committed.keys()[index].toOptional();
        },
        .destroyed => {
            if (self.destroyed.count() == 0) return .none;
            const index = self.smith.nextLessThan(usize, self.destroyed.count());
            return self.destroyed.keys()[index].toOptional();
        },
    }
}

// If we're at less than half capacity, give a slight bias against destroying
// entities so that we don't just hover near zero entities for the whole test
pub fn shouldSkipDestroy(self: *@This()) bool {
    return (self.es.count() < self.es.handle_tab.capacity / 2 and (self.smith.next(bool)));
}

pub fn destroyInOracle(self: *@This(), entity: Entity) !void {
    // Destroy the entity in the oracle as well, displacing an existing
    // destroyed entity if there are already too many to prevent the destroyed
    // list from growing indefinitely.
    while (self.destroyed.count() > 1000) {
        const index = self.smith.nextLessThan(usize, self.destroyed.count());
        self.destroyed.swapRemoveAt(index);
    }
    _ = self.reserved.swapRemove(entity);
    _ = self.committed.swapRemove(entity);
    try self.destroyed.put(gpa, entity, {});
}
