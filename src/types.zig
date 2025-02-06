//! For internal use. Types and functions for managing component type registration.

const std = @import("std");
const assert = std.debug.assert;

const zcs = @import("root.zig");
const Comp = zcs.Comp;

/// The tag type for `CompFlag`.
const CompFlagInt = u6;

/// For internal use.
///
/// A tightly packed index representing a registered component type.
///
/// Not part of public interface because components are currently registered on first use, and this
/// results in a hard to work with API. May be exposed if we can register components at compile time
/// in the future without making `Entities` generic:
///
/// https://github.com/games-by-Mason/zcs/issues/11
pub const CompFlag = enum(CompFlagInt) {
    /// The maximum registered component flags.
    pub const max = std.math.maxInt(CompFlagInt);

    /// A set of component flags.
    pub const Set = std.enums.EnumSet(CompFlag);

    _,
};

/// For internal use. The list of registered components.
pub var registered: std.BoundedArray(Comp.Id, CompFlag.max) = .{};

/// For internal use.
///
/// Assigns the given ID the next flag index if it doesn't have one, and then returns its flag. Not
/// thread safe.
pub fn register(id: Comp.Id) CompFlag {
    // Early out if we're already registered
    if (id.flag) |f| return f;

    // Debug log that we're registering the component
    std.log.scoped(.zcs).debug("register comp: {s}", .{id.name});

    // Warn if we've registered a large number of components
    if (registered.len == CompFlag.max / 2) {
        std.log.warn(
            "{} component types registered, you're at 50% the fatal capacity!",
            .{registered.len},
        );
    }

    // Fail if we're out of component types
    if (registered.len >= registered.buffer.len) {
        @panic("component type overflow");
    }

    // Pick the next sequential flag
    const flag: CompFlag = @enumFromInt(registered.len);
    id.flag = flag;

    // This function is not thread safe, but reading from `registered` is, so we update the
    // registered list, and then increment the counter atomically.
    registered.buffer[registered.len] = id;
    _ = @atomicRmw(usize, &registered.len, .Add, 1, .release);

    // Return the registered flag
    return flag;
}

/// Asserts at comptime that the given type is valid as a component type.
pub fn assertValidComponentType(T: type) void {
    // Storing optionals, pointers, and Entities directly as components would create
    // ambiguities when creating entity views. It's unfortunate that we have to disallow
    // them, but the extra typing to wrap them in the rare case that you need this ability
    // is expected to be well worth it for the convenience views provide.
    if (@typeInfo(T) == .optional or T == zcs.Entity) {
        @compileError("unsupported component type '" ++ @typeName(T) ++ "'; consider wrapping in struct");
    }

    comptime assert(@alignOf(T) <= Comp.max_align);
}
