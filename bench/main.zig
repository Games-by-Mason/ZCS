const std = @import("std");
const zcs = @import("zcs");
const tracy = @import("tracy");

const assert = std.debug.assert;

const Entities = zcs.Entities;
const Entity = zcs.Entity;
const CmdBuf = zcs.CmdBuf;

const Zone = tracy.Zone;

const max_entities = 1000000;
const iterations = 10;

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub const tracy_impl = @import("tracy_impl");

const small = false;
const A = if (small) u2 else u64;
const B = if (small) u4 else u128;
const C = if (small) u8 else u256;

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
            const fill_zone = Zone.begin(.{ .name = "fill immediate", .src = @src() });
            for (0..max_entities) |i| {
                const e = Entity.reserveImmediate(&es);
                const a: A = @intCast(i);
                const b: B = @intCast(i);
                const c: C = @intCast(i);
                assert(e.changeArchImmediate(&es, .{ .add = &.{
                    .init(A, &a),
                    .init(B, &b),
                    .init(C, &c),
                } }));
            }
            fill_zone.end();
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
        var capacity: CmdBuf.GranularCapacity = .init(.{
            .cmds = max_entities * 3,
            .avg_cmd_bytes = 16,
        });
        capacity.reserved = max_entities;
        var cb: CmdBuf = try .initGranularCapacity(allocator, &es, capacity);
        defer cb.deinit(allocator, &es);
        alloc_cb_zone.end();

        alloc_zone.end();

        // also compare interning vs not etc
        {
            const cmdbuf_zone = Zone.begin(.{ .name = "cb", .src = @src() });
            defer cmdbuf_zone.end();
            {
                const fill_zone = Zone.begin(.{ .name = "fill", .src = @src() });
                defer fill_zone.end();
                for (0..max_entities) |i| {
                    const e = Entity.reserve(&cb);
                    e.add(&cb, A, @intCast(i));
                    e.add(&cb, B, @intCast(i));
                    e.add(&cb, C, @intCast(i));
                }
            }
            const exec_zone = Zone.begin(.{ .name = "exec", .src = @src() });
            defer exec_zone.end();
            cb.execImmediate(&es);
        }

        // orig: 1.41 + 1.46 + 1.45 -> 1.44
        // typed: 1.43 + 1.44 + 1.43 -> 1.43
        // cached: 1.49 + 1.42 + 1.43 -> 1.4466666666666665
        // debug mode cached: 27.59
        // debug mode orig: 26.7
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
