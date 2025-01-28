//! Tracks information on registered component types.

const std = @import("std");
const zcs = @import("root.zig");

const assert = std.debug.assert;

const Allocator = std.mem.Allocator;
const Component = zcs.Component;
const Entities = zcs.Entities;
const TypeId = zcs.TypeId;
const typeId = zcs.typeId;

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
    try map.ensureTotalCapacity(gpa, Component.Index.max);

    return .{ .map = map };
}

/// Destroys the set of component types.
pub fn deinit(self: *@This(), gpa: Allocator) void {
    self.map.deinit(gpa);
}

/// Gets the index associated with the given component type, or null if it is not registered.
pub fn getIndex(self: @This(), T: type) ?Component.Index {
    assertAllowedAsComponentType(T);
    return self.getIndexFromId(typeId(T));
}

// XXX: naming? or maybe JUST expose this and expect the user to call typeid idk kinda annoying to do that? but actually
// if you expose the typed version and that version the in between one is not really needed right?
/// Gets the index associated with the given component ID, or null if it is not registered.
pub fn getIndexFromId(self: @This(), id: TypeId) ?Component.Index {
    const index = self.map.getIndex(id) orelse return null;
    return @enumFromInt(index);
}

/// Registers a new component type. Noop if already present.
pub fn registerIndex(self: *@This(), T: type) Component.Index {
    // Check the type
    assertAllowedAsComponentType(T);

    // Early out if we're already registered
    if (self.getIndex(T)) |index| return index;

    // Check if we've registered too many components
    const i = self.map.count();
    if (i == Component.Index.max / 2) {
        std.log.warn("{} component types registered, you're at 50% the fatal capacity!", .{i});
    }
    if (i >= Component.Index.max) {
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
pub fn getSize(self: @This(), id: Component.Index) usize {
    return self.map.values()[@intFromEnum(id)].size;
}

/// Returns the alignment of the component type with the given ID.
pub fn getAlignment(self: @This(), id: Component.Index) u8 {
    return self.map.values()[@intFromEnum(id)].alignment;
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
