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
