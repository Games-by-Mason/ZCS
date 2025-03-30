/// Pointer stability assertions for builds with runtime safety enabled.
const std = @import("std");
const assert = std.debug.assert;

const PointerLock = @This();

const enabled = std.debug.runtime_safety;

/// The current pointer generation.
pub const Generation = struct {
    n: if (enabled) u64 else u0 = 0,

    /// Increments the pointer generation.
    pub inline fn increment(self: *@This()) void {
        if (enabled) {
            self.n +%= 1;
        }
    }

    /// Returns a pointer lock with the current generation.
    pub inline fn lock(self: @This()) PointerLock {
        return .{ .generation = self };
    }
};

/// The pointer generation from when this lock was created.
generation: Generation,

/// Asserts that pointers have not been invalidated since this lock was created.
pub fn check(self: @This(), generation: Generation) void {
    if (self.generation.n != generation.n) {
        @panic("pointers invalidated");
    }
}
