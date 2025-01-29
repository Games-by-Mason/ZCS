//! Component data typed at runtime.
//!
//! It's recommended to use the typed methods when possible, but this API offers additional
//! flexibility.

const std = @import("std");
const assert = std.debug.assert;

const zcs = @import("root.zig");

const typeId = zcs.typeId;

const TypeId = zcs.TypeId;
const Entities = zcs.Entities;

const Component = @This();

/// The component's type ID.
id: TypeId,
/// The component data.
bytes: []const u8,
/// If true, `ptr` points to constant. If false, it points to a temporary value.
interned: bool,

/// The maximum alignment a component is allowed to require.
pub const max_align = 16;

/// An optional `Component`.
pub const Optional = struct {
    pub const none: @This() = .{
        .id_or_undef = undefined,
        .ptr = null,
        .interned_or_undef = undefined,
    };

    id_or_undef: TypeId,
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
                    .id_or_undef = typeId(opt.child),
                    .ptr = @ptrCast(some),
                    .interned_or_undef = interned,
                };
            },
            else => return .{
                .id_or_undef = typeId(pointer.child),
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
        .id = typeId(T),
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
    if (self.id != typeId(T)) return null;
    // XXX: does this assert size matches or should we?
    return @alignCast(@ptrCast(self.bytes));
}

/// The flag for a registered component type.
const FlagInt = u6;
pub const Flag = enum(FlagInt) {
    pub const max = std.math.maxInt(FlagInt) - 1;
    // XXX: make a toUsize function that returns null if unregistered?
    unregistered = std.math.maxInt(FlagInt),
    _,

    // XXX: name the type optional?
    pub fn unwrap(self: @This()) ?FlagInt {
        return switch (self) {
            .unregistered => null,
            else => @intFromEnum(self),
        };
    }
};

/// A set of component types.
pub const Flags = std.enums.EnumSet(Flag);

/// Initialize a set of component types from a list of component types.
pub fn flags(types: []const type) Flags {
    var result: Flags = .{};
    inline for (types) |ty| {
        // XXX: sus!! wanna be able to make flags on bg threads lol. i mean we could just make it lock
        // or be atomic or something idk.
        result.insert(typeId(ty).register());
    }
    return result;
}
