//! An entity component system.
//!
//! See `Entities` for entity storage and iteration, `Entity` for entity creation and modification,
//! and `CmdBuf` for queuing commands during iteration or from multiple threads.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub const tracy = @import("tracy");

pub const Entities = @import("Entities.zig");
pub const Entity = @import("entity.zig").Entity;
pub const Any = @import("Any.zig");
pub const CompFlag = @import("comp_flag.zig").CompFlag;
pub const CmdBuf = @import("CmdBuf.zig");
pub const TypeInfo = @import("type_id.zig").TypeInfo;
pub const TypeId = @import("type_id.zig").TypeId;
pub const PointerLock = @import("PointerLock.zig");
pub const storage = @import("storage.zig");
pub const view = @import("view.zig");
pub const ext = @import("ext.zig");

/// Returns the component ID for the given type.
pub const typeId = TypeInfo.init;

test {
    std.testing.refAllDecls(@This());
}
