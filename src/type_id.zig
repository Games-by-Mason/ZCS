const std = @import("std");
const zcs = @import("root.zig");
const assert = std.debug.assert;
const Component = zcs.Component;

// XXX: document...
var registered: usize = 0;

/// An unspecified but unique value per type.
pub const TypeId = *struct {
    size: usize,
    alignment: u8,
    index: ?Component.Index = null,

    // XXX: document...
    pub fn register(self: *@This()) Component.Index {
        // Early out if we're already registered
        if (self.index) |index| return index;

        // XXX: move index type onto type id? move both onto component or no? remember weird naming conflict and not wanting init etc, can always alias but idk
        // Check if we've registered too many components
        const index = registered;
        if (index == Component.Index.max / 2) {
            std.log.warn("{} component types registered, you're at 50% the fatal capacity!", .{index});
        }
        if (index >= Component.Index.max) {
            @panic("component type overflow");
        }

        // Register the ID
        registered += 1;

        self.index = @enumFromInt(index);

        return @enumFromInt(index);
    }
};

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
