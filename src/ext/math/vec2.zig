const std = @import("std");
const zcs = @import("../../root.zig");

const math = std.math;

const Bivec2 = zcs.ext.math.Bivec2;
const Rotor2 = zcs.ext.math.Rotor2;

pub const Vec2 = packed struct {
    x: f32,
    y: f32,

    pub const zero: Vec2 = .{ .x = 0, .y = 0 };
    pub const y_pos: Vec2 = .{ .x = 0, .y = 1 };
    pub const y_neg: Vec2 = .{ .x = 0, .y = -1 };
    pub const x_pos: Vec2 = .{ .x = 1, .y = 0 };
    pub const x_neg: Vec2 = .{ .x = -1, .y = 0 };

    pub fn unit(rad: f32) Vec2 {
        return .{
            .x = @cos(rad),
            .y = @sin(rad),
        };
    }

    pub fn scaled(self: Vec2, factor: f32) Vec2 {
        return .{
            .x = self.x * factor,
            .y = self.y * factor,
        };
    }

    pub fn scale(self: *Vec2, factor: f32) Vec2 {
        self.* = self.scaled(factor);
    }

    pub fn plus(self: Vec2, other: Vec2) Vec2 {
        return .{
            .x = self.x + other.x,
            .y = self.y + other.y,
        };
    }

    pub fn add(self: *Vec2, other: Vec2) void {
        self.* = self.plus(other);
    }

    pub fn plusScaled(self: Vec2, other: Vec2, factor: f32) Vec2 {
        return .{
            .x = self.x + other.x * factor,
            .y = self.y + other.y * factor,
        };
    }

    pub fn addScaled(self: *Vec2, other: Vec2, factor: f32) void {
        self.* = self.plus(other, factor);
    }

    pub fn minus(self: Vec2, other: Vec2) Vec2 {
        return .{
            .x = self.x - other.x,
            .y = self.y - other.y,
        };
    }

    pub fn sub(self: *Vec2, other: Vec2) void {
        self.* = self.minus(other);
    }

    pub fn floored(self: Vec2) Vec2 {
        return .{
            .x = @floor(self.x),
            .y = @floor(self.y),
        };
    }

    pub fn floor(self: *Vec2) Vec2 {
        self.* = self.floored();
    }

    pub fn negated(self: Vec2) Vec2 {
        return .{
            .x = -self.x,
            .y = -self.y,
        };
    }

    pub fn negate(self: *Vec2) void {
        self.* = self.negated();
    }

    pub fn angle(self: Vec2) f32 {
        if (self.magSq() == 0) {
            return 0;
        } else {
            return math.atan2(self.y, self.x);
        }
    }

    pub fn magSq(self: Vec2) f32 {
        return self.x * self.x + self.y * self.y;
    }

    pub fn mag(self: Vec2) f32 {
        return @sqrt(self.magSq());
    }

    pub fn distSq(self: Vec2, other: Vec2) f32 {
        return self.minus(other).magSq();
    }

    pub fn dist(self: Vec2, other: Vec2) f32 {
        return @sqrt(self.distSq(other));
    }

    pub fn normalized(self: Vec2) Vec2 {
        const len = self.mag();
        if (len == 0) return self;
        return self.scaled(1.0 / len);
    }

    pub fn normalize(self: *Vec2) Vec2 {
        self.* = self.normalized();
    }

    pub fn compProd(self: Vec2, other: Vec2) Vec2 {
        return .{
            .x = self.x * other.x,
            .y = self.y * other.y,
        };
    }

    pub fn times(self: *Vec2, other: Vec2) void {
        self.* = self.mul(other);
    }

    /// Equivalent to the dot product.
    pub fn innerProd(self: Vec2, other: Vec2) f32 {
        return self.x * other.x + self.y * other.y;
    }

    /// Generalized form of the cross product.
    pub fn outerProd(lhs: Vec2, rhs: Vec2) Bivec2 {
        return .{
            .xy = lhs.x * rhs.y - lhs.y * rhs.x,
        };
    }

    pub fn geomProd(lhs: Vec2, rhs: Vec2) Rotor2 {
        return .{
            .xy = lhs.outerProd(rhs).xy,
            .a = lhs.innerProd(rhs) + 1.0,
        };
    }

    pub fn normal(self: Vec2) Vec2 {
        const result: Vec2 = .{
            .x = -self.y,
            .y = self.x,
        };
        return result.normalized();
    }
};
