//! Component data with a runtime type.

const std = @import("std");
const assert = std.debug.assert;

const zcs = @import("root.zig");

const compId = zcs.compId;
const types = @import("types.zig");
const CompFlag = types.CompFlag;

const Entities = zcs.Entities;

const Comp = @This();

/// The component's type ID.
id: Id,
/// The component data.
ptr: *const anyopaque,

/// The maximum alignment a component is allowed to require.
pub const max_align = 16;

/// Initialize a component from a pointer to a component type.
pub fn init(T: type, ptr: *const T) @This() {
    return .{
        .id = compId(T),
        .ptr = ptr,
    };
}

/// Returns the component as the given type if it matches its ID, or null otherwise.
pub fn as(self: @This(), T: anytype) ?*const T {
    if (self.id != compId(T)) return null;
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

/// Gets the list of registered component types for introspection purposes. Components are
/// registered lazily, this list will grow over time. Thread safe.
pub fn getRegistered() []const Id {
    return types.registered.constSlice();
}

/// This function is intended to be used only in tests. Unregisters all component types.
pub fn unregisterAll() void {
    for (types.registered.slice()) |id| id.flag = null;
    types.registered.clear();
}

/// Metadata for a component type.
pub const Meta = struct {
    /// The component's type name.
    name: []const u8,
    /// The component type's size.
    size: usize,
    /// The component type's alignment.
    alignment: u8,
    /// For internal use, registered components are assigned tightly packed flags.
    flag: ?CompFlag = null,

    /// Returns the type ID of the given type.
    pub inline fn init(comptime T: type) *@This() {
        comptime types.assertValidComponentType(T);

        return &struct {
            var id: @typeInfo(Comp.Id).pointer.child = .{
                .name = @typeName(T),
                .size = @sizeOf(T),
                .alignment = @alignOf(T),
            };
        }.id;
    }
};

/// This pointer can be used as a unique ID identifying a component type.
pub const Id = *Meta;
