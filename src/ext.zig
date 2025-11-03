//! Optional extensions not part of the core ECS.

const std = @import("std");

const Transform = @import("ext/transform.zig").Transform;

pub const Node = @import("ext/Node.zig");
pub const ZoneCmd = @import("ext/ZoneCmd.zig");
pub const Tag = @import("ext/tag.zig").Tag;
pub const Transform2D = Transform(.@"2");
pub const Transform3D = Transform(.@"3");
pub const geom = @import("geom");

test {
    std.testing.refAllDecls(@This());
}
