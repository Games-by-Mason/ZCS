//! Component data typed at runtime.
//!
//! It's recommended to use the typed methods when possible, but this API offers additional
//! flexibility.

const std = @import("std");
const assert = std.debug.assert;

const zcs = @import("root.zig");

const compId = zcs.compId;
const types = @import("types.zig");
const CompFlag = types.CompFlag;

const Entities = zcs.Entities;

// XXX: consider renaming this file to Comp
const Component = @This();

/// The component's type ID.
id: Id,
/// The component data.
bytes: []const u8,
/// If true, `ptr` points to constant. If false, it points to a temporary value.
interned: bool,

/// The maximum alignment a component is allowed to require.
pub const max_align = 16;

// XXX: remove?
/// An optional `Component`.
pub const Optional = struct {
    pub const none: @This() = .{
        .id_or_undef = undefined,
        .ptr = null,
        .interned_or_undef = undefined,
    };

    id_or_undef: Id,
    bytes: ?[]const u8,
    interned_or_undef: bool,

    /// Similar to `Component.init`, but `ptr` may point to an optional.
    pub fn init(ptr: anytype) @This() {
        return @This().initMaybeInterned(ptr, false);
    }

    /// Similar to `Component.initInterned`, but `ptr` may point to an optional.
    pub fn initInterned(ptr: anytype) @This() {
        return @This().initMaybeInterned(ptr, true);
    }

    fn initMaybeInterned(ptr: anytype, interned: bool) @This() {
        const pointer = @typeInfo(@TypeOf(ptr)).pointer;
        comptime assert(pointer.size == .one);
        comptime assert(pointer.sentinel_ptr == null);

        switch (@typeInfo(pointer.child)) {
            .optional => |opt| {
                const some = if (ptr.*) |*some| some else return .none;
                return .{
                    .id_or_undef = compId(opt.child),
                    .ptr = @ptrCast(some),
                    .interned_or_undef = interned,
                };
            },
            else => return .{
                .id_or_undef = compId(pointer.child),
                .ptr = @ptrCast(ptr),
                .interned_or_undef = interned,
            },
        }
    }

    /// Unwrap as `?Component`.
    pub fn unwrap(self: @This()) ?Component {
        if (self.bytes) |bytes| {
            return .{
                .id = self.id_or_undef,
                .bytes = bytes,
                .interned = self.interned_or_undef,
            };
        }
        return null;
    }
};

/// Initialize a component from a pointer to a registered component type.
pub fn init(value: anytype) @This() {
    return initMaybeInterned(value, false);
}

/// Similar to `init`, but interned is set to true indicating that the pointer is to a constant.
pub fn initInterned(ptr: anytype) @This() {
    return initMaybeInterned(ptr, true);
}

fn initMaybeInterned(ptr: anytype, interned: bool) @This() {
    const T = @typeInfo(@TypeOf(ptr)).pointer.child;
    return .{
        .id = compId(T),
        .bytes = std.mem.asBytes(ptr),
        .interned = interned,
    };
}

/// Returns the component as an optional.
pub fn toOptional(self: @This()) Optional {
    return .{
        .id_or_undef = self.id,
        .bytes = self.bytes,
        .interned_or_undef = self.interned,
    };
}

/// Returns the component as the given type if it matches its ID, or null otherwise.
pub fn as(self: @This(), T: anytype) ?*const T {
    if (self.id != compId(T)) return null;
    // XXX: does this assert size matches or should we?
    return @alignCast(@ptrCast(self.bytes));
}

/// A unique ID for each component type alongside metadata on the type.
pub const Id = *struct {
    /// The component type's size.
    size: usize,
    /// The component type's alignment.
    alignment: u8,
    flag: CompFlag = .unregistered,

    /// Returns the type ID of the given type.
    pub inline fn init(comptime T: type) *@This() {
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

        comptime assert(@alignOf(T) <= Component.max_align);

        return &struct {
            var id: @typeInfo(Component.Id).pointer.child = .{
                .size = @sizeOf(T),
                .alignment = @alignOf(T),
            };
        }.id;
    }
};
