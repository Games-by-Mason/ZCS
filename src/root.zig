//! An entity component system.
//!
//! See `Entities` for entity storage and iteration, `Entity` for entity creation and modification,
//! and `CmdBuf` for queuing commands during iteration or from multiple threads.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const slot_map = @import("slot_map");

pub const Entities = @import("Entities.zig");
pub const Entity = @import("entity.zig").Entity;
pub const Any = @import("Any.zig");
pub const CompFlag = @import("comp_flag.zig").CompFlag;
pub const CmdBuf = @import("CmdBuf.zig");
pub const CmdPool = @import("CmdPool.zig");
pub const TypeInfo = @import("type_id.zig").TypeInfo;
pub const TypeId = @import("type_id.zig").TypeId;
pub const PointerLock = @import("PointerLock.zig");
pub const Chunk = @import("chunk.zig").Chunk;
pub const ChunkList = @import("ChunkList.zig");
pub const ChunkPool = @import("ChunkPool.zig");
pub const Arches = @import("Arches.zig");
pub const view = @import("view.zig");
pub const ext = @import("ext.zig");
pub const meta = @import("meta.zig");

/// Returns the component ID for the given type.
pub const typeId = TypeInfo.init;

/// A handle table that associates persistent entity keys with values that point to their storage.
pub const HandleTab = slot_map.SlotMap(Entity.Location, .{});

test {
    std.testing.refAllDecls(@This());
}
