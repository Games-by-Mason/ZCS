const std = @import("std");
const zcs = @import("../../root.zig");

const Vec2 = zcs.ext.math.Vec2;

pub const Mat2x3 = extern struct {
    // zig fmt: off
    xx: f32, xy: f32, xw: f32,
    yx: f32, yy: f32, yw: f32,
    // zig fmt: on

    pub const identity: @This() = .{
        // zig fmt: off
        .xx = 1, .xy = 0, .xw = 0,
        .yx = 0, .yy = 1, .yw = 0,
        // zig fmt: on
    };

    pub fn rotation(angle: f32) @This() {
        const sin = @sin(angle);
        const cos = @cos(angle);
        return .{
            // zig fmt: off
            .xx = cos, .xy = -sin, .xw = 0,
            .yx = sin, .yy =  cos, .yw = 0,
            // zig fmt: on
        };
    }

    pub fn translation(delta: Vec2) @This() {
        return .{
            // zig fmt: off
            .xx = 1, .xy = 0, .xw = delta.x,
            .yx = 0, .yy = 1, .yw = delta.y,
            // zig fmt: on
        };
    }

    pub fn rotationTranslation(angle: f32, delta: Vec2) @This() {
        const sin = @sin(angle);
        const cos = @cos(angle);
        return .{
            // zig fmt: off
            .xx = cos, .xy = -sin, .xw = delta.x,
            .yx = sin, .yy =  cos, .yw = delta.y,
            // zig fmt: on
        };
    }

    pub fn times(lhs: @This(), rhs: @This()) @This() {
        const xx = lhs.xx * rhs.xx + lhs.xy * rhs.yx;
        const xy = lhs.xx * rhs.xy + lhs.xy * rhs.yy;
        const xw = lhs.xx * rhs.xw + lhs.xy * rhs.yw + lhs.xw;

        const yx = lhs.yx * rhs.xx + lhs.yy * rhs.yx;
        const yy = lhs.yx * rhs.xy + lhs.yy * rhs.yy;
        const yw = lhs.yx * rhs.xw + lhs.yy * rhs.yw + lhs.yw;

        return .{
            // zig fmt: off
            .xx = xx, .xy = xy, .xw = xw,
            .yx = yx, .yy = yy, .yw = yw,
            // zig fmt: on
        };
    }

    pub fn mul(self: *@This(), other: @This()) @This() {
        self.* = self.times(other);
    }

    pub fn getTranslation(self: @This()) Vec2 {
        return .{ .x = self.xw, .y = self.yw };
    }

    pub fn getRotation(self: @This()) f32 {
        const cos = self.xx;
        const sin = self.yx;
        return std.math.atan2(sin, cos);
    }
};
