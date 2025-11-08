//! Optional extensions not part of the core ECS.

const std = @import("std");

pub const Node = @import("ext/Node.zig");
pub const ZoneCmd = @import("ext/ZoneCmd.zig");
pub const Tag = @import("ext/tag.zig").Tag;
pub const Transform = @import("ext/transform.zig").Transform;
pub const Transform2 = Transform(.{ .dimensions = .@"2", .Layer = u0, .Order = u0 });
pub const Transform3 = Transform(.{ .dimensions = .@"3", .Layer = u0, .Order = u0 });
pub const geom = @import("geom");

test {
    std.testing.refAllDecls(@This());
}
