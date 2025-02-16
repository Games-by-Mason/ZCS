const std = @import("std");

const math = std.math;

pub const Vec2 = extern struct {
    x: f32,
    y: f32,

    pub const zero: Vec2 = .{ .x = 0, .y = 0 };

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

    pub fn mul(self: Vec2, other: Vec2) Vec2 {
        return .{
            .x = self.x * other.x,
            .y = self.y * other.y,
        };
    }

    pub fn times(self: *Vec2, other: Vec2) void {
        self.* = self.mul(other);
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

    pub fn dot(self: Vec2, other: Vec2) f32 {
        return self.x * other.x + self.y * other.y;
    }
};
