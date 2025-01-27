//! Component data typed at runtime.
//!
//! It's recommended to use the typed methods when possible, but this API offers additional
//! flexibility.

const std = @import("std");
const assert = std.debug.assert;

const zcs = @import("root.zig");
const Entities = zcs.Entities;

const Component = @This();

/// The component type's ID.
id: Id,
/// A pointer to the component data.
ptr: *const anyopaque,
/// If true, `ptr` points to constant. If false, it points to a temporary value.
interned: bool,

/// An optional `Component`.
pub const Optional = struct {
    pub const none: @This() = .{
        .id_or_undef = undefined,
        .ptr = null,
        .interned_or_undef = undefined,
    };

    id_or_undef: Id,
    ptr: ?*const anyopaque,
    interned_or_undef: bool,

    /// Similar to `Component.init`, but `ptr` may point to an optional.
    pub fn init(es: *Entities, ptr: anytype) @This() {
        return @This().initMaybeInterned(es, ptr, false);
    }

    /// Similar to `Component.initInterned`, but `ptr` may point to an optional.
    pub fn initInterned(es: *Entities, ptr: anytype) @This() {
        return @This().initMaybeInterned(es, ptr, true);
    }

    fn initMaybeInterned(es: *Entities, ptr: anytype, interned: bool) @This() {
        const pointer = @typeInfo(@TypeOf(ptr)).pointer;
        comptime assert(pointer.size == .one);
        comptime assert(pointer.sentinel_ptr == null);

        switch (@typeInfo(pointer.child)) {
            .optional => |opt| {
                const id = es.registerComponentType(opt.child);
                const some = if (ptr.*) |*some| some else return .none;
                return .{
                    .id_or_undef = id,
                    .ptr = @ptrCast(some),
                    .interned_or_undef = interned,
                };
            },
            else => return .{
                .id_or_undef = es.registerComponentType(pointer.child),
                .ptr = @ptrCast(ptr),
                .interned_or_undef = interned,
            },
        }
    }

    /// Unwrap as `?Component`.
    pub fn unwrap(self: @This()) ?Component {
        if (self.ptr) |ptr| {
            return .{
                .id = self.id_or_undef,
                .ptr = ptr,
                .interned = self.interned_or_undef,
            };
        }
        return null;
    }
};

/// Initialize a component from a pointer to a registered component type.
pub fn init(es: *Entities, value: anytype) @This() {
    return initMaybeInterned(es, value, false);
}

/// Similar to `init`, but interned is set to true indicating that the pointer is to a constant.
pub fn initInterned(es: *const Entities, ptr: anytype) @This() {
    return initMaybeInterned(es, ptr, true);
}

fn initMaybeInterned(es: *Entities, ptr: anytype, interned: bool) @This() {
    const T = @typeInfo(@TypeOf(ptr)).pointer.child;
    return .{
        .id = es.registerComponentType(T),
        .ptr = std.mem.asBytes(ptr),
        .interned = interned,
    };
}

/// Returns the component as an optional.
pub fn toOptional(self: @This()) Optional {
    return .{
        .id_or_undef = self.id,
        .ptr = self.ptr,
        .interned_or_undef = self.interned,
    };
}

/// Returns the component's bytes. Size can be retrieved from `Entities` given the ID if necessary.
pub fn bytes(self: @This()) [*]const u8 {
    return @ptrCast(self.ptr);
}

/// Returns the component as the given type if it matches its ID, or null otherwise.
pub fn as(self: @This(), es: *const Entities, T: anytype) ?*const T {
    if (self.id != es.findComponentId(T)) return null;
    return @alignCast(@ptrCast(self.ptr));
}

/// An ID for a registered component type.
pub const Id = enum(u6) {
    pub const max = std.math.maxInt(@typeInfo(@This()).@"enum".tag_type);
    _,
};

/// A set of component IDs.
pub const Flags = std.enums.EnumSet(Id);

/// Initialize a set of component IDs from a list of component types.
pub fn flags(es: *Entities, types: []const type) Flags {
    var result: Flags = .{};
    inline for (types) |ty| {
        result.insert(es.registerComponentType(ty));
    }
    return result;
}
