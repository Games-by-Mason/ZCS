//! Math types used by ZCS extensions.
//!
//! This will likely be fleshed out into its own library at some point, for now it's just the bits
//! and pieces needed to make the extensions useful.

pub const Vec2 = @import("math/vec2.zig").Vec2;
pub const Bivec2 = @import("math/bivec2.zig").Bivec2;
pub const Rotor2 = @import("math/rotor2.zig").Rotor2;
pub const Mat2x3 = @import("math/mat2x3.zig").Mat2x3;
