const std = @import("std");
const zcs = @import("../../root.zig");

const Vec2 = zcs.ext.math.Vec2;
const Rotor2 = zcs.ext.math.Rotor2;

pub const Mat2x3 = packed struct {
    x: Col,
    y: Col,

    const Col = packed struct {
        x: f32,
        y: f32,
        a: f32,
    };

    pub const identity: @This() = .{
        .x = .{ .x = 1, .y = 0, .a = 0 },
        .y = .{ .x = 0, .y = 1, .a = 0 },
    };

    pub fn fromBasis(x: Vec2, y: Vec2) Mat2x3 {
        return .{
            .x = .{ .x = x.x, .y = x.y, .a = 0.0 },
            .y = .{ .x = y.x, .y = y.y, .a = 0.0 },
        };
    }

    pub fn rotation(rotor: Rotor2) @This() {
        const inverse = rotor.inverse();
        const x = inverse.timesPoint(.x_pos);
        const y = inverse.timesPoint(.y_pos);
        return .fromBasis(x, y);
    }

    pub fn translation(delta: Vec2) @This() {
        return .{
            .x = .{ .x = 1, .y = 0, .a = delta.x },
            .y = .{ .x = 0, .y = 1, .a = delta.y },
        };
    }

    pub fn rotationTranslation(angle: f32, delta: Vec2) @This() {
        const sin = @sin(angle);
        const cos = @cos(angle);
        return .{
            .x = .{ .x = cos, .y = sin, .a = delta.x },
            .y = .{ .x = -sin, .y = cos, .a = delta.y },
        };
    }

    pub fn times(lhs: @This(), rhs: @This()) @This() {
        return .{
            .x = .{
                .x = lhs.x.x * rhs.x.x + lhs.x.y * rhs.y.x,
                .y = lhs.x.x * rhs.x.y + lhs.x.y * rhs.y.y,
                .a = lhs.x.x * rhs.x.a + lhs.x.y * rhs.y.a + lhs.x.a,
            },
            .y = .{
                .x = lhs.y.x * rhs.x.x + lhs.y.y * rhs.y.x,
                .y = lhs.y.x * rhs.x.y + lhs.y.y * rhs.y.y,
                .a = lhs.y.x * rhs.x.a + lhs.y.y * rhs.y.a + lhs.y.a,
            },
        };
    }

    pub fn mul(self: *@This(), other: @This()) @This() {
        self.* = self.times(other);
    }

    pub fn getTranslation(self: @This()) Vec2 {
        return .{ .x = self.x.a, .y = self.y.a };
    }

    pub fn getAngle(self: @This()) f32 {
        const cos = self.x.x;
        const sin = self.x.y;
        return std.math.atan2(sin, cos);
    }

    pub fn timesPoint(self: @This(), point: Vec2) Vec2 {
        return .{
            .x = self.x.x * point.x + self.x.y * point.y + self.x.a,
            .y = self.y.x * point.x + self.y.y * point.y + self.y.a,
        };
    }

    pub fn timesDir(self: @This(), point: Vec2) Vec2 {
        return .{
            .x = self.x.x * point.x + self.x.y * point.y,
            .y = self.y.x * point.x + self.y.y * point.y,
        };
    }
};
