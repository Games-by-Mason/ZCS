//! An entity component system.
//!
//! See `Entities` for entity storage and iteration, `Entity` for entity creation and modification,
//! and `CmdBuf` for queuing commands during iteration or from multiple threads.

const std = @import("std");
const assert = std.debug.assert;
const type_id = @import("type_id.zig");
const Allocator = std.mem.Allocator;

pub const Entities = @import("Entities.zig");
pub const Entity = @import("entity.zig").Entity;
pub const Component = @import("Component.zig");
pub const CmdBuf = @import("CmdBuf.zig");
pub const CompTypes = @import("CompTypes.zig");
pub const TypeId = type_id.TypeId;
pub const typeId = type_id.typeId;

test {
    _ = @import("meta.zig");
}
