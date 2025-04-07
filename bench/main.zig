const std = @import("std");
const zcs = @import("zcs");
const tracy = @import("tracy");

const assert = std.debug.assert;

const Entities = zcs.Entities;
const Entity = zcs.Entity;
const CmdBuf = zcs.CmdBuf;
const Transform2D = zcs.ext.Transform2D;
const ZoneCmd = zcs.ext.ZoneCmd;

const Zone = tracy.Zone;

const max_entities = 1000000;
const iterations = 10;

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub const tracy_impl = @import("tracy_impl");
pub const tracy_options: tracy.Options = .{
    .default_callstack_depth = 8,
};

const small = false;
const A = if (small) u2 else u64;
const B = if (small) u4 else u128;
const C = if (small) u8 else u256;

// Eventually we may make reusable benchmarks for comparing releases. Right now this is just a
// dumping ground for testing performance tweaks.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = false }){};
    const allocator = gpa.allocator();

    var expected_total: ?u256 = null;
    var expected_ra_total: ?u256 = null;

    for (0..iterations) |_| {
        var es: Entities = try .init(allocator, .{
            .max_entities = max_entities,
            .max_archetypes = 1,
            .max_chunks = 4096,
            .chunk_size = 65536,
        });
        defer es.deinit(allocator);

        // also compare interning vs not etc
        {
            const fill_zone = Zone.begin(.{ .name = "fill immediate any", .src = @src() });
            for (0..max_entities) |i| {
                const e = Entity.reserveImmediate(&es);
                const a: A = @intCast(i);
                const b: B = @intCast(i);
                const c: C = @intCast(i);
                assert(e.changeArchAnyImmediate(&es, .{ .add = &.{
                    .init(A, &a),
                    .init(B, &b),
                    .init(C, &c),
                } }) catch |err| @panic(@errorName(err)));
            }
            fill_zone.end();
        }
    }

    for (0..iterations) |_| {
        var es: Entities = try .init(allocator, .{
            .max_entities = max_entities,
            .max_archetypes = 1,
            .max_chunks = 4096,
            .chunk_size = 65536,
        });
        defer es.deinit(allocator);

        // also compare interning vs not etc
        {
            es.updateStats(.{ .emit_warnings = false });
            const fill_zone = Zone.begin(.{ .name = "fill immediate", .src = @src() });
            for (0..max_entities) |i| {
                const e = Entity.reserveImmediate(&es);
                assert(e.changeArchImmediate(
                    &es,
                    struct { A, B, C },
                    .{
                        .add = .{ @intCast(i), @intCast(i), @intCast(i) },
                    },
                ));
            }
            fill_zone.end();
            es.updateStats(.{ .emit_warnings = false });
        }
    }

    for (0..iterations) |_| {
        var tags: std.ArrayListUnmanaged(u8) = try .initCapacity(allocator, max_entities * 4);
        defer tags.deinit(allocator);
        var args: std.ArrayListUnmanaged(u64) = try .initCapacity(allocator, max_entities * 4);
        defer args.deinit(allocator);
        var bytes: std.ArrayListUnmanaged(u8) = try .initCapacity(allocator, max_entities * @sizeOf(C) * 3);
        defer bytes.deinit(allocator);

        {
            var last: ?usize = null;
            const fill_zone = Zone.begin(.{ .name = "baseline fill separate", .src = @src() });
            for (0..max_entities) |i| {
                const a: A = @intCast(i);
                const b: B = @intCast(i);
                const c: C = @intCast(i);

                if (i != last) {
                    // assert(args.items.len < args.capacity) implied by tags check
                    if (tags.items.len >= tags.capacity) @panic("OOB");
                    last = i;
                    tags.appendAssumeCapacity(10);
                    args.appendAssumeCapacity(i);
                }

                if (tags.items.len >= tags.capacity) @panic("OOB");
                tags.appendAssumeCapacity(0);
                // if (args.items.len >= args.capacity) @panic("OOB"); // Implied by tags check
                args.appendAssumeCapacity(@intFromPtr(zcs.typeId(A)));
                bytes.items.len = std.mem.alignForward(
                    usize,
                    bytes.items.len,
                    @alignOf(A),
                );
                if (bytes.items.len + @sizeOf(A) > bytes.capacity) @panic("OOB");
                bytes.appendSliceAssumeCapacity(std.mem.asBytes(&a));

                if (tags.items.len >= tags.capacity) @panic("OOB");
                tags.appendAssumeCapacity(0);
                // if (args.items.len >= args.capacity) @panic("OOB"); // Implied by tags check
                args.appendAssumeCapacity(@intFromPtr(zcs.typeId(B)));
                bytes.items.len = std.mem.alignForward(
                    usize,
                    bytes.items.len,
                    @alignOf(B),
                );
                if (bytes.items.len + @sizeOf(B) > bytes.capacity) @panic("OOB");
                bytes.appendSliceAssumeCapacity(std.mem.asBytes(&b));

                if (tags.items.len >= tags.capacity) @panic("OOB");
                tags.appendAssumeCapacity(0);
                // if (args.items.len >= args.capacity) @panic("OOB"); // Implied by tags check
                args.appendAssumeCapacity(@intFromPtr(zcs.typeId(C)));
                bytes.items.len = std.mem.alignForward(
                    usize,
                    bytes.items.len,
                    @alignOf(C),
                );
                if (bytes.items.len + @sizeOf(C) > bytes.capacity) @panic("OOB");
                bytes.appendSliceAssumeCapacity(std.mem.asBytes(&c));
            }
            fill_zone.end();
        }
    }

    for (0..iterations) |_| {
        var es: Entities = try .init(allocator, .{
            .max_entities = max_entities,
            .max_archetypes = 64,
            .max_chunks = 4096,
            .chunk_size = 65536,
        });
        defer es.deinit(allocator);

        var cb: CmdBuf = try .init(allocator, &es, .{
            .cmds = max_entities * 3,
            .reserved_entities = max_entities,
        });
        defer cb.deinit(allocator, &es);

        {
            const fill_fast_zone = Zone.begin(.{ .name = "fill cb", .src = @src() });
            defer fill_fast_zone.end();
            for (0..max_entities) |i| {
                const e = Entity.reserve(&cb);
                e.add(&cb, A, @intCast(i));
                e.add(&cb, B, @intCast(i));
                e.add(&cb, C, @intCast(i));
            }
        }
    }

    for (0..iterations) |_| {
        const alloc_zone = Zone.begin(.{ .name = "alloc", .src = @src() });

        const alloc_es_zone = Zone.begin(.{ .name = "es", .src = @src() });
        var es: Entities = try .init(allocator, .{
            .max_entities = max_entities,
            .max_archetypes = 64,
            .max_chunks = 4096,
            .chunk_size = 65536,
        });
        defer es.deinit(allocator);
        alloc_es_zone.end();

        const alloc_cb_zone = Zone.begin(.{ .name = "cb", .src = @src() });
        var cb: CmdBuf = try .init(allocator, &es, .{
            .cmds = max_entities * 3,
            .reserved_entities = max_entities,
        });
        defer cb.deinit(allocator, &es);
        alloc_cb_zone.end();

        alloc_zone.end();

        {
            const cmdbuf_zone = Zone.begin(.{ .name = "cb", .src = @src() });
            defer cmdbuf_zone.end();
            {
                const fill_zone = Zone.begin(.{ .name = "fill", .src = @src() });
                defer fill_zone.end();

                // Divided into two parts to test exec zones
                const exec_zone = ZoneCmd.begin(&cb, .{
                    .src = @src(),
                    .name = "exec zone",
                });
                defer exec_zone.end(&cb);

                {
                    const first_half_zone = ZoneCmd.begin(&cb, .{
                        .src = @src(),
                        .name = "first half",
                    });
                    defer first_half_zone.end(&cb);
                    for (0..max_entities / 2) |i| {
                        const e = Entity.reserve(&cb);
                        e.add(&cb, A, @intCast(i));
                        e.add(&cb, B, @intCast(i));
                        e.add(&cb, C, @intCast(i));
                    }
                }
                {
                    const second_half_zone = ZoneCmd.begin(&cb, .{
                        .src = @src(),
                        .name = "second half",
                    });
                    defer second_half_zone.end(&cb);
                    for (max_entities / 2..max_entities) |i| {
                        const e = Entity.reserve(&cb);
                        e.add(&cb, A, @intCast(i));
                        e.add(&cb, B, @intCast(i));
                        e.add(&cb, C, @intCast(i));
                    }
                }
            }
            CmdBuf.Exec.immediate(&es, &cb, .{ .name = "exec fill" });
        }

        {
            var total: u256 = 0;
            {
                const iter_zone = Zone.begin(.{ .name = "iter.fast", .src = @src() });
                defer iter_zone.end();
                var iter = es.iterator(struct { a: *const A, b: *const B, c: *const C });
                while (iter.next(&es)) |vw| {
                    total +%= vw.a.*;
                    total +%= vw.b.*;
                    total +%= vw.c.*;
                }
            }
            std.debug.print("{}\n", .{total});
            if (expected_total == null) expected_total = total;
            if (expected_total != total) @panic("inconsistent result");
        }

        {
            var total: u256 = 0;
            es.forEach("sum", sum, .{ .total = &total });
            std.debug.print("{}\n", .{total});
            if (expected_total == null) expected_total = total;
            if (expected_total != total) @panic("inconsistent result");
        }

        {
            var total: u256 = 0;
            {
                const iter_zone = Zone.begin(.{ .name = "iter.view", .src = @src() });
                defer iter_zone.end();
                var iter = es.iterator(struct { e: Entity });
                while (iter.next(&es)) |vw| {
                    const comps = vw.e.view(&es, struct {
                        a: *const A,
                        b: *const B,
                        c: *const C,
                    }).?;
                    total +%= comps.a.*;
                    total +%= comps.b.*;
                    total +%= comps.c.*;
                }
            }
            std.debug.print("{}\n", .{total});
            if (expected_total == null) expected_total = total;
            if (expected_total != total) @panic("inconsistent result");
        }

        {
            var total: u256 = 0;
            {
                const iter_zone = Zone.begin(.{ .name = "iter.get", .src = @src() });
                defer iter_zone.end();
                var iter = es.iterator(struct { e: Entity });
                while (iter.next(&es)) |vw| {
                    total +%= vw.e.get(&es, A).?.*;
                    total +%= vw.e.get(&es, B).?.*;
                    total +%= vw.e.get(&es, C).?.*;
                }
            }
            std.debug.print("{}\n", .{total});
            if (expected_total == null) expected_total = total;
            if (expected_total != total) @panic("inconsistent result");
        }

        {
            var total: u256 = 0;
            var default_rng: std.Random.DefaultPrng = .init(0);
            const rand = default_rng.random();
            {
                const iter_zone = Zone.begin(.{ .name = "es.random access", .src = @src() });
                defer iter_zone.end();
                for (0..max_entities) |_| {
                    const ei: Entity.Index = @enumFromInt(rand.uintLessThan(u32, max_entities));
                    const e = ei.toEntity(&es);
                    const comps = e.view(&es, struct {
                        a: *const A,
                        b: *const B,
                        c: *const C,
                    }).?;
                    total +%= comps.a.*;
                    total +%= comps.b.*;
                    total +%= comps.c.*;
                }
            }
            std.debug.print("ecs ra: {}\n", .{total});
            if (expected_ra_total == null) expected_ra_total = total;
            if (expected_ra_total != total) @panic("inconsistent result");
        }
    }

    for (0..iterations) |_| {
        const zone = Zone.begin(.{ .name = "transform", .src = @src() });
        defer zone.end();

        var tp: std.Thread.Pool = undefined;
        try std.Thread.Pool.init(&tp, .{
            .allocator = allocator,
        });
        defer tp.deinit();

        const es_init_zone = Zone.begin(.{ .name = "es init", .src = @src() });
        var es: Entities = try .init(allocator, .{
            .max_entities = max_entities,
            .max_archetypes = 64,
            .max_chunks = 4096,
            .chunk_size = 65536,
        });
        defer es.deinit(allocator);
        es_init_zone.end();

        {
            const entity_init_zone = Zone.begin(.{ .name = "entity init", .src = @src() });
            defer entity_init_zone.end();
            for (0..max_entities) |_| {
                assert(Entity.reserveImmediate(&es).changeArchImmediate(
                    &es,
                    struct { Transform2D },
                    .{ .add = .{.{}} },
                ));
            }
        }

        {
            const queue_zone = Zone.begin(.{ .name = "move", .src = @src() });
            defer queue_zone.end();
            var iter = es.iterator(struct { transform: *Transform2D });
            var f: f32 = 0;
            while (iter.next(&es)) |vw| {
                vw.transform.move(&es, .{ .x = f, .y = f });
                f += 0.01;
            }
        }
    }

    for (0..iterations) |_| {
        const alloc_zone = Zone.begin(.{ .name = "mal.alloc", .src = @src() });
        var es: std.MultiArrayList(struct {
            a: A,
            b: B,
            c: C,
        }) = .empty;
        defer es.deinit(std.heap.page_allocator);
        try es.setCapacity(std.heap.page_allocator, max_entities);
        alloc_zone.end();

        {
            const fill_zone = Zone.begin(.{ .name = "mal.fill", .src = @src() });
            defer fill_zone.end();
            for (0..max_entities) |i| {
                es.appendAssumeCapacity(.{
                    .a = @intCast(i),
                    .b = @intCast(i),
                    .c = @intCast(i),
                });
            }
        }

        {
            var total: u256 = 0;
            {
                const iter_zone = Zone.begin(.{ .name = "mal.iter", .src = @src() });
                defer iter_zone.end();
                for (es.items(.a), es.items(.b), es.items(.c)) |*a, *b, *c| {
                    total +%= a.*;
                    total +%= b.*;
                    total +%= c.*;
                }
            }
            std.debug.print("{}\n", .{total});
            if (expected_total == null) expected_total = total;
            if (expected_total != total) @panic("inconsistent result");
        }

        {
            var total: u256 = 0;
            var default_rng: std.Random.DefaultPrng = .init(0);
            const rand = default_rng.random();
            {
                const iter_zone = Zone.begin(.{ .name = "mal.random access", .src = @src() });
                defer iter_zone.end();
                for (0..max_entities) |_| {
                    const i = max_entities - rand.uintLessThan(u32, max_entities);
                    const comps = es.get(i);
                    total +%= comps.a;
                    total +%= comps.b;
                    total +%= comps.c;
                }
            }
            std.debug.print("mal ra: {}\n", .{total});
        }
    }
}

fn sum(ctx: struct { total: *u256 }, a: *const A, b: *const B, c: *const C) void {
    const total = ctx.total;
    total.* +%= a.*;
    total.* +%= b.*;
    total.* +%= c.*;
}
