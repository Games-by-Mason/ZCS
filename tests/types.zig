const std = @import("std");

pub const RigidBody = struct {
    pub const interned: [3]@This() = .{
        .{},
        .{ .position = .{ 2.0, 3.0 }, .velocity = .{ 4.0, 5.0 }, .mass = 10.0 },
        .{ .position = .{ 24.0, 32.0 }, .velocity = .{ 42.0, 55.0 }, .mass = 103.0 },
    };
    position: [2]f32 = .{ 1.0, 2.0 },
    velocity: [2]f32 = .{ 3.0, 4.0 },
    mass: f32 = 5.0,

    pub fn random(rand: std.Random) @This() {
        return .{
            .position = .{ rand.float(f32), rand.float(f32) },
            .velocity = .{ rand.float(f32), rand.float(f32) },
            .mass = rand.float(f32),
        };
    }

    pub fn randomOrNull(rand: std.Random) ?@This() {
        if (rand.boolean()) return null;
        return @This().random(rand);
    }
};

pub const Model = struct {
    pub const interned: [3]@This() = .{
        .{},
        .{ .vertex_start = 1, .vertex_count = 2 },
        .{ .vertex_start = 10, .vertex_count = 20 },
    };
    vertex_start: u16 = 6,
    vertex_count: u16 = 7,

    pub fn random(rand: std.Random) @This() {
        return .{
            .vertex_start = rand.int(u16),
            .vertex_count = rand.int(u16),
        };
    }

    pub fn randomOrNull(rand: std.Random) ?@This() {
        if (rand.boolean()) return null;
        return @This().random(rand);
    }
};

pub const Tag = struct {
    pub const interned: [2]@This() = .{
        .{},
        .{},
    };

    pub fn random(rand: std.Random) @This() {
        _ = rand;
        return .{};
    }

    pub fn randomOrNull(rand: std.Random) ?@This() {
        if (rand.boolean()) return null;
        return @This().random(rand);
    }
};

pub const FooEv = struct {
    pub const interned: [3]@This() = .{
        .{ .foo = .{ 1.0, 2.0, 3.0 } },
        .{ .foo = .{ 1.1, 2.1, 3.1 } },
        .{ .foo = .{ 1.2, 2.2, 3.2 } },
    };

    foo: struct { f32, f32, f32 },

    pub fn random(rand: std.Random) @This() {
        return .{
            .foo = .{ rand.float(f32), rand.float(f32), rand.float(f32) },
        };
    }

    pub fn randomOrNull(rand: std.Random) ?@This() {
        if (rand.boolean()) return null;
        return @This().random(rand);
    }
};

pub const BarEv = struct {
    pub const interned: [3]@This() = .{
        .{ .bar = 101 },
        .{ .bar = 102 },
        .{ .bar = 103 },
    };

    bar: u32,

    pub fn random(rand: std.Random) @This() {
        return .{
            .bar = rand.int(u32),
        };
    }

    pub fn randomOrNull(rand: std.Random) ?@This() {
        if (rand.boolean()) return null;
        return @This().random(rand);
    }
};

pub const BazEv = struct {
    pub const interned: [2]@This() = .{
        .{},
        .{},
    };

    pub fn random(rand: std.Random) @This() {
        _ = rand;
        return .{};
    }

    pub fn randomOrNull(rand: std.Random) ?@This() {
        if (rand.boolean()) return null;
        return @This().random(rand);
    }
};
