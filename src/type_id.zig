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
    flag: Component.Flag = .unregistered,

    // XXX: document...
    pub fn register(self: *@This()) Component.Flag {
        // Early out if we're already registered
        if (self.flag != .unregistered) return self.flag;

        // XXX: move flag type onto type id? move both onto component or no? remember weird naming conflict and not wanting init etc, can always alias but idk
        // Check if we've registered too many components
        if (registered == Component.Flag.max / 2) {
            std.log.warn("{} component types registered, you're at 50% the fatal capacity!", .{registered});
        }
        if (registered >= Component.Flag.max) {
            @panic("component type overflow");
        }

        // Register the ID
        const flag: Component.Flag = @enumFromInt(registered);
        registered += 1;
        // @atomicStore(Component.Flag, &self.flag, flag, .unordered);
        self.flag = flag;
        return flag;
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
