//! A pointer to arbitrary data with a runtime known type.

const std = @import("std");
const assert = std.debug.assert;

const zcs = @import("root.zig");

const typeId = zcs.typeId;

const Entities = zcs.Entities;
const CompFlag = zcs.CompFlag;
const TypeId = zcs.TypeId;

id: TypeId,
ptr: *const anyopaque,

/// Initialize a component from a pointer to a component type.
pub fn init(T: type, ptr: *const T) @This() {
    return .{
        .id = typeId(T),
        .ptr = ptr,
    };
}

/// Returns the component as the given type if it matches its ID, or null otherwise.
pub fn as(self: @This(), T: anytype) ?*const T {
    if (self.id != typeId(T)) return null;
    return @alignCast(@ptrCast(self.ptr));
}

/// Returns the component as a constant slice of `u8`s.
pub fn constSlice(self: @This()) []const u8 {
    return self.bytes()[0..self.id.size];
}

/// Similar to `constSlice`, but returns the data as a many item pointer.
pub fn bytes(self: @This()) [*]const u8 {
    return @ptrCast(self.ptr);
}
