//! Threaded fuzz tests for `Entities`.

const std = @import("std");
const zcs = @import("zcs");

const gpa = std.testing.allocator;
const assert = std.debug.assert;

const Fuzzer = @import("EntitiesFuzzer.zig");
const Any = zcs.Any;
const CompFlag = zcs.CompFlag;
const Entity = zcs.Entity;
const Entities = zcs.Entities;
const CmdBuf = zcs.CmdBuf;
const CmdPool = zcs.CmdPool;

const types = @import("types.zig");
const RigidBody = types.RigidBody;
const Model = types.Model;
const Tag = types.Tag;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const threaded: Options = .{};
const contention: Options = .{
    .cap = .{
        .buffers = 1,
        .buffer = .{
            .cmds = 10000,
            .reserved_entities = 1000,
        },
    },
};
const serial: Options = .{ .n_jobs = 0 };

test "fuzz threaded" {
    try std.testing.fuzz(threaded, run, .{ .corpus = &.{} });
}

test "fuzz threaded contention" {
    try std.testing.fuzz(contention, run, .{ .corpus = &.{} });
}

test "fuzz threaded serial" {
    try std.testing.fuzz(serial, run, .{ .corpus = &.{} });
}

test "rand threaded" {
    var xoshiro_256: std.Random.Xoshiro256 = .init(0);
    const rand = xoshiro_256.random();
    const input: []u8 = try gpa.alloc(u8, 32768);
    defer gpa.free(input);
    rand.bytes(input);
    try run(threaded, input);
}

test "rand threaded contention" {
    var xoshiro_256: std.Random.Xoshiro256 = .init(0);
    const rand = xoshiro_256.random();
    const input: []u8 = try gpa.alloc(u8, 32768);
    defer gpa.free(input);
    rand.bytes(input);
    try run(contention, input);
}

test "rand threaded serial" {
    var xoshiro_256: std.Random.Xoshiro256 = .init(0);
    const rand = xoshiro_256.random();
    const input: []u8 = try gpa.alloc(u8, 32768);
    defer gpa.free(input);
    rand.bytes(input);
    try run(serial, input);
}

const Cmd = union(enum) {
    destroy: void,
    add_rb: RigidBody,
    add_model: Model,
    add_tag: Tag,
    modify_rb: RigidBody,
    modify_model: Model,
    remove_rb: void,
    remove_model: void,
    remove_tag: void,
    add: void,
};

fn updateEntity(
    ctx: struct {
        fz: *Fuzzer,
        mutex: *std.Thread.Mutex,
    },
    cb: *CmdBuf,
    e: Entity,
    model: ?*Model,
    rb: ?*RigidBody,
) void {
    const cmd = b: {
        ctx.mutex.lock();
        defer ctx.mutex.unlock();
        break :b ctx.fz.smith.next(Cmd);
    };

    switch (cmd) {
        .add => {
            const new_e: Entity = .reserve(cb);
            new_e.commit(cb);
            ctx.mutex.lock();
            defer ctx.mutex.unlock();
            ctx.fz.committed.putNoClobber(gpa, new_e, .{}) catch |err| @panic(@errorName(err));
        },
        .destroy => {
            e.destroy(cb);
            ctx.mutex.lock();
            defer ctx.mutex.unlock();
            assert(ctx.fz.committed.swapRemove(e));
        },
        .add_rb => |add_rb| {
            assert(std.meta.eql(e.add(cb, RigidBody, add_rb).*, add_rb));
            ctx.mutex.lock();
            defer ctx.mutex.unlock();
            ctx.fz.committed.getPtr(e).?.rb = add_rb;
        },
        .add_tag => |add_tag| {
            assert(std.meta.eql(e.add(cb, Tag, add_tag).*, add_tag));
            ctx.mutex.lock();
            defer ctx.mutex.unlock();
            ctx.fz.committed.getPtr(e).?.tag = add_tag;
        },
        .add_model => |add_model| {
            assert(std.meta.eql(e.add(cb, Model, add_model).*, add_model));
            ctx.mutex.lock();
            defer ctx.mutex.unlock();
            ctx.fz.committed.getPtr(e).?.model = add_model;
        },
        .modify_rb => |modified| if (rb) |curr| {
            curr.* = modified;
            ctx.mutex.lock();
            defer ctx.mutex.unlock();
            ctx.fz.committed.getPtr(e).?.rb = modified;
        },
        .modify_model => |modified| if (model) |curr| {
            curr.* = modified;
            ctx.mutex.lock();
            defer ctx.mutex.unlock();
            ctx.fz.committed.getPtr(e).?.model = modified;
        },
        .remove_rb => {
            e.remove(cb, RigidBody);
            ctx.mutex.lock();
            defer ctx.mutex.unlock();
            ctx.fz.committed.getPtr(e).?.rb = null;
        },
        .remove_model => {
            e.remove(cb, Model);
            ctx.mutex.lock();
            defer ctx.mutex.unlock();
            ctx.fz.committed.getPtr(e).?.model = null;
        },
        .remove_tag => {
            e.remove(cb, Tag);
            ctx.mutex.lock();
            defer ctx.mutex.unlock();
            ctx.fz.committed.getPtr(e).?.tag = null;
        },
    }
}

const Options = struct {
    n_jobs: usize = 4,
    cap: CmdPool.Capacity = .{ .buffer = .{ .reserved_entities = 100 } },
};

fn run(opt: Options, input: []const u8) !void {
    defer CompFlag.unregisterAll();

    var fz: Fuzzer = try .init(input);
    defer fz.deinit();

    try fz.checkIterators();

    var cp: CmdPool = try .init(.{
        .name = null,
        .gpa = gpa,
        .es = &fz.es,
        .warn_ratio = 1.0,
        .cap = opt.cap,
    });
    defer cp.deinit(gpa, &fz.es);

    var tp: std.Thread.Pool = undefined;
    try std.Thread.Pool.init(&tp, .{ .allocator = gpa, .n_jobs = opt.n_jobs });
    defer tp.deinit();

    var mutex: std.Thread.Mutex = .{};

    while (!fz.smith.isEmpty()) {
        while (fz.es.count() <= 1024) {
            const e = Entity.reserveImmediate(&fz.es);
            try expect(e.changeArchImmediate(&fz.es, struct {}, .{}));
            try fz.committed.putNoClobber(gpa, e, .{});
        }

        var wg: std.Thread.WaitGroup = .{};

        fz.es.forEachThreaded("updateEntity", updateEntity, .{
            .ctx = .{ .fz = &fz, .mutex = &mutex },
            .tp = &tp,
            .wg = &wg,
            .cp = &cp,
        });
        tp.waitAndWork(&wg);

        for (cp.written()) |*cb| {
            CmdBuf.Exec.immediate(&fz.es, cb);
        }
        try checkOracle(&fz);
    }
}

fn checkOracle(fz: *Fuzzer) !void {
    try expectEqual(fz.committed.count(), fz.es.count());

    // Check the reserved entities
    for (fz.reserved.keys()) |e| {
        try expect(e.exists(&fz.es));
        try expect(!e.committed(&fz.es));
    }

    // Check the committed entities
    var commited_iter = fz.committed.iterator();
    while (commited_iter.next()) |entry| {
        const entity = entry.key_ptr.*;
        const expected = entry.value_ptr;
        try expect(entity.exists(&fz.es));
        try expect(entity.committed(&fz.es));
        try expectEqual(expected.rb, if (entity.get(&fz.es, RigidBody)) |v| v.* else null);
        try expectEqual(expected.model, if (entity.get(&fz.es, Model)) |v| v.* else null);
        try expectEqual(expected.tag, if (entity.get(&fz.es, Tag)) |v| v.* else null);
    }

    // Check the iterators
    try fz.checkIterators();
}
