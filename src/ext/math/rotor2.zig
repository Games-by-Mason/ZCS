const std = @import("std");
const math = std.math;
const zcs = @import("../../root.zig");
const Vec2 = zcs.ext.Vec2;
const Bivec2 = zcs.ext.Bivec2;
const Mat2x3 = zcs.ext.Mat2x3;

pub const Rotor2 = extern struct {
    xy: f32,
    a: f32,

    pub const identity: Rotor2 = .{ .xy = 0.0, .a = 1.0 };

    pub fn plus(lhs: Rotor2, rhs: Rotor2) Rotor2 {
        return .{
            .xy = lhs.xy + rhs.xy,
            .a = lhs.a + rhs.a,
        };
    }

    pub fn add(self: *Rotor2, other: Rotor2) void {
        self.* = self.plus(other);
    }

    pub fn minus(lhs: Rotor2, rhs: Rotor2) Rotor2 {
        return .{
            .xy = lhs.xy - rhs.xy,
            .a = lhs.a - rhs.a,
        };
    }

    pub fn sub(self: *Rotor2, other: Rotor2) void {
        self.* = self.minux(other);
    }

    pub fn scaled(self: Rotor2, factor: f32) Rotor2 {
        return .{
            .xy = self.xy * factor,
            .a = self.a * factor,
        };
    }

    pub fn scale(self: *Rotor2, factor: f32) void {
        self.* = self.scaled(factor);
    }

    /// Creates a rotor that rotates from `from` to `to`, `from` and `to` must be normalized. If
    /// `from` and to are parallel in opposite directions, it rotates 180 degrees in an arbitrary
    /// direction.
    pub fn fromTo(from: Vec2, to: Vec2) Rotor2 {
        const result = from.geomProd(to);
        const res_mag = result.mag();
        if (res_mag == 0.0) {
            return .fromAngle(math.pi);
        } else {
            return result.scaled(1.0 / res_mag);
        }
    }

    /// Creates a rotor that from the given angle.
    pub fn fromAngle(rad: f32) Rotor2 {
        return .{
            .xy = @sin(rad / 2.0),
            .a = @cos(rad / 2.0),
        };
    }

    pub fn magSq(self: Rotor2) f32 {
        return self.a * self.a + self.xy * self.xy;
    }

    pub fn mag(self: Rotor2) f32 {
        return @sqrt(self.magSq());
    }

    pub fn inverse(self: Rotor2) Rotor2 {
        return .{
            .xy = -self.xy,
            .w = self.w,
        };
    }

    pub fn invert(self: *Rotor2) void {
        self.* = self.inverse();
    }

    /// Returns a normalized rotor. If the magnitude is 0 the result will be a rotor filled with
    /// NaNs.
    pub fn normalized(self: Rotor2) Rotor2 {
        return self.scaled(1.0 / self.mag());
    }

    pub fn normalize(self: *Rotor2) void {
        self.* = self.normalized();
    }

    pub fn rotateVec2(self: Rotor2, v: Vec2) Vec2 {
        // Rotor * V (results in a trivector, just stored as locals for speed)
        const x = self.a * v.x - self.xy * v.y;
        const y = self.a * v.y + self.xy * v.x;

        // V * -Rotor
        return .{
            .x = x * self.a - y * self.xy,
            .y = x * self.xy + y * self.a,
        };
    }

    pub fn times(lhs: Rotor2, rhs: Rotor2) Rotor2 {
        return .{
            .a = -lhs.xy * rhs.xy + lhs.a * rhs.a,
            .xy = lhs.xy * rhs.a + lhs.a * rhs.xy,
        };
    }

    pub fn mul(self: *Rotor2, other: Rotor2) void {
        self.* = self.times(other);
    }

    /// Takes the natural log of the given rotor, resulting in a bivector representing the plane the
    /// rotation occurs on with a magnitude of half the angle of rotation in radians. The rotor must be
    /// normalized.
    pub fn ln(self: Rotor2) Bivec2 {
        const bivec: Bivec2 = .{ .xy = self.xy };
        const cos = self.a;
        const sin = bivec.mag();

        if (sin == 0.0) {
            // If sin is 0, cos must be either -1 or 1. We check with gt to avoid rounding errors.
            if (cos > 0.0) {
                // 0 degree rotation
                return .{ .xy = 0.0 };
            } else {
                // 360 degree rotation (around an arbitrary plane, but there's only one plane in 2D)
                return .{ .xy = std.math.pi };
            }
        } else {
            // Normalize the bivector by dividing by its current magnitude (sin) and then scale it by the
            // half angle.
            const half_angle = std.math.atan2(sin, cos);
            return bivec.scaled(half_angle / sin);
        }
    }

    /// Returns the cosine of the half angle between the two given normalized rotors. If the result
    /// is negative, they are more than a full rotation apart. If it is positive they are not.
    pub fn neighborhood(self: Rotor2, other: Rotor2) f32 {
        return self.a * other.a + self.xy * other.xy;
    }

    // Adds a full rotation to the given rotor. Agnostic to normalization.
    pub fn negated(self: Rotor2) Rotor2 {
        return .{
            .xy = -self.xy,
            .a = -self.a,
        };
    }

    pub fn negate(self: *Rotor2) void {
        self.* = self.negated();
    }

    /// Spherically linearly interpolates between two rotors.
    ///
    /// Interpolates a constant velocity, but is computationally heavy and is not commutative. If `t` is
    /// outside of the [0, 1] range, the rotation will continue past the start or end.
    pub fn slerp(start: Rotor2, end: Rotor2, t: f32) Rotor2 {
        start.mul(start.inverse().mul(end).ln().scaled(t).exp());
    }

    /// Linearly interpolates between the two rotors, then normalizes the result.
    ///
    /// Interpolation speed is not entirely constant, but it is computationally cheap and
    /// commutative. Behaves well in the [0, 1] range for t, and the velocity remains close to
    /// constant within the 0 to PI/2 range, it gets worse the closer the angle is to 2PI.
    pub fn nlerp(start: Rotor2, end: Rotor2, t: f32) Rotor2 {
        var result: Rotor2 = .{
            .xy = std.math.lerp(start.xy, end.xy, t),
            .a = std.math.lerp(start.a, end.a, t),
        };

        const res_mag = result.mag();
        if (res_mag == 0.0) {
            return start;
        } else {
            return result.scaled(1.0 / res_mag);
        }
    }

    pub fn toMat2x3(self: Rotor2) Mat2x3 {
        // Rotate the axis vectors by the rotor, and then form a matrix from them.

        const xx = self.a * self.a - self.xy * self.xy;
        const xy = 2.0 * (self.a * self.xy);

        const yx = 2.0 * (-self.xy * self.a);
        const yy = -self.xy * self.xy + self.a * self.a;

        return .{
            // zig fmt: off
            .xx = xx, .xy = yx, .xw = 0.0,
            .yx = xy, .yy = yy, .yw = 0.0,
            // zig fmt: on
        };
    }
};
