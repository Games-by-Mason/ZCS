/// Pointer stability assertions for builds with runtime safety enabled.
const std = @import("std");
const assert = std.debug.assert;

const PointerLock = @This();

/// The current pointer generation.
pub const Generation = enum(if (std.debug.runtime_safety) u64 else u0) {
    init = 0,
    _,

    /// Increments the pointer generation.
    pub fn increment(self: *@This()) void {
        if (std.debug.runtime_safety) {
            self.* = @enumFromInt(@intFromEnum(self.*) +% 1);
        }
    }

    /// Returns a pointer lock with the current generation.
    pub fn lock(self: @This()) PointerLock {
        return .{ .generation = self };
    }
};

/// The pointer generation from when this lock was created.
generation: Generation,

/// Asserts that pointers have not been invalidated since this lock was created.
pub fn check(self: @This(), generation: Generation) void {
    if (self.generation != generation) {
        @panic("pointers invalidated");
    }
}
