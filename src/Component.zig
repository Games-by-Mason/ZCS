//! Component data typed at runtime.
//!
//! It's recommended to use the typed methods when possible, but this API offers additional
//! flexibility.

const std = @import("std");
const assert = std.debug.assert;

const zcs = @import("root.zig");
const Entities = zcs.Entities;

const Component = @This();

/// The component type's index.
index: Index,
/// A pointer to the component data.
ptr: *const anyopaque,
/// If true, `ptr` points to constant. If false, it points to a temporary value.
interned: bool,

/// An optional `Component`.
pub const Optional = struct {
    pub const none: @This() = .{
        .index_or_undef = undefined,
        .ptr = null,
        .interned_or_undef = undefined,
    };

    index_or_undef: Index,
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
                const index = es.registerComponentType(opt.child);
                const some = if (ptr.*) |*some| some else return .none;
                return .{
                    .index_or_undef = index,
                    .ptr = @ptrCast(some),
                    .interned_or_undef = interned,
                };
            },
            else => return .{
                .index_or_undef = es.registerComponentType(pointer.child),
                .ptr = @ptrCast(ptr),
                .interned_or_undef = interned,
            },
        }
    }

    /// Unwrap as `?Component`.
    pub fn unwrap(self: @This()) ?Component {
        if (self.ptr) |ptr| {
            return .{
                .index = self.index_or_undef,
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
        .index = es.comp_types.registerIndex(T),
        .ptr = std.mem.asBytes(ptr),
        .interned = interned,
    };
}

/// Returns the component as an optional.
pub fn toOptional(self: @This()) Optional {
    return .{
        .index_or_undef = self.index,
        .ptr = self.ptr,
        .interned_or_undef = self.interned,
    };
}

/// Returns the component's bytes.
pub fn bytes(self: @This()) [*]const u8 {
    return @ptrCast(self.ptr);
}

/// Returns the component as the given type if it matches its ID, or null otherwise.
pub fn as(self: @This(), es: *const Entities, T: anytype) ?*const T {
    if (self.index != es.comp_types.getIndex(T)) return null;
    return @alignCast(@ptrCast(self.ptr));
}

/// The index of a registered component type.
pub const Index = enum(u6) {
    pub const max = std.math.maxInt(@typeInfo(@This()).@"enum".tag_type);
    _,
};

/// A set of component types.
pub const Flags = std.enums.EnumSet(Index);

/// Initialize a set of component types from a list of component types.
pub fn flags(es: *Entities, types: []const type) Flags {
    var result: Flags = .{};
    inline for (types) |ty| {
        result.insert(es.comp_types.registerIndex(ty));
    }
    return result;
}

/// An unspecified but unique value per type.
pub const Id = *const struct { _: u8 };

/// Returns the type ID of the given type.
pub inline fn id(comptime T: type) Id {
    return &struct {
        comptime {
            _ = T;
        }
        var id: @typeInfo(Id).pointer.child = undefined;
    }.id;
}
