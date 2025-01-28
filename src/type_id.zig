const std = @import("std");
const zcs = @import("root.zig");
const assert = std.debug.assert;
const Component = zcs.Component;

/// An unspecified but unique value per type.
pub const TypeId = *const struct { size: usize, alignment: u8 };

/// Returns the type ID of the given type.
pub inline fn typeId(comptime T: type) TypeId {
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

    // XXX: move def of max align to root?
    comptime assert(@alignOf(T) <= Component.max_align);

    return &struct {
        var id: @typeInfo(TypeId).pointer.child = .{
            .size = @sizeOf(T),
            .alignment = @alignOf(T),
        };
    }.id;
}
