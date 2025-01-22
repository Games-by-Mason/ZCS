//! An entity component system.
//!
//! See `Entities` for entity storage and iteration, `Entity` for entity creation and modification,
//! and `CommandBuffer` for queuing commands during iteration or from multiple threads.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub const Entities = @import("Entities.zig");
pub const Entity = @import("entity.zig").Entity;
pub const Component = @import("Component.zig");
pub const CommandBuffer = @import("CommandBuffer.zig");

test {
    _ = @import("tests/index.zig");
}

test "foo" {
    const x = 10;
    _ = x;
}
