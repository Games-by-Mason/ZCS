//! Tracks information on registered component types.

const std = @import("std");
const zcs = @import("root.zig");

const assert = std.debug.assert;

const Allocator = std.mem.Allocator;
const Component = zcs.Component;
const Entities = zcs.Entities;

map: std.AutoArrayHashMapUnmanaged(TypeId, Info),

/// Meta information on a registered type.
pub const Info = struct {
    size: usize,
    alignment: u8,
};

/// Initializes an empty set of component types.
pub fn init(gpa: Allocator) Allocator.Error!@This() {
    var map: std.AutoArrayHashMapUnmanaged(TypeId, Info) = .empty;
    errdefer map.deinit(gpa);
    try map.ensureTotalCapacity(gpa, Component.Id.max);

    return .{ .map = map };
}

/// Destroys the set of component types.
pub fn deinit(self: *@This(), gpa: Allocator) void {
    self.map.deinit(gpa);
}

/// Gets the ID associated with the given component type, or null if it is not registered.
pub fn getId(self: @This(), T: type) ?Component.Id {
    assertAllowedAsComponentType(T);
    const id = self.map.getIndex(typeId(T)) orelse return null;
    return @enumFromInt(id);
}

/// Registers a new component type. Noop if already present.
pub fn register(self: *@This(), T: type) Component.Id {
    // Check the type
    assertAllowedAsComponentType(T);

    // Early out if we're already registered
    if (self.getId(T)) |id| return id;

    // Check if we've registered too many components
    const i = self.map.count();
    if (i == Component.Id.max / 2) {
        std.log.warn("{} component types registered, you're at 50% the fatal capacity!", .{i});
    }
    if (i >= Component.Id.max) {
        @panic("component type overflow");
    }

    // Register the ID
    self.map.putAssumeCapacity(typeId(T), .{
        .size = @sizeOf(T),
        .alignment = @alignOf(T),
    });

    return @enumFromInt(i);
}

/// Returns the size of the component type with the given ID.
pub fn getSize(self: @This(), id: Component.Id) usize {
    return self.map.values()[@intFromEnum(id)].size;
}

/// Returns the alignment of the component type with the given ID.
pub fn getAlignment(self: @This(), id: Component.Id) u8 {
    return self.map.values()[@intFromEnum(id)].alignment;
}

/// An unspecified but unique value per type.
const TypeId = *const struct { _: u8 };

/// Returns the type ID of the given type.
inline fn typeId(comptime T: type) TypeId {
    return &struct {
        comptime {
            _ = T;
        }
        var id: @typeInfo(TypeId).pointer.child = undefined;
    }.id;
}

/// Comptime asserts that the given type is allowed to be registered as a component.
fn assertAllowedAsComponentType(T: type) void {
    if (@typeInfo(T) == .optional) {
        // There's nothing technically wrong with this, but if we allowed it then the change arch
        // functions couldn't use optionals to allow deciding at runtime whether or not to create a
        // component.
        //
        // Furthermore, it would be difficult to distinguish syntactically whether an
        // optional component was missing or null.
        //
        // Instead, optional components should be represented by a struct with an optional
        // field, or a tagged union.
        @compileError("component types may not be optional: " ++ @typeName(T));
    }
    comptime assert(@alignOf(T) <= Entities.max_align);
}
