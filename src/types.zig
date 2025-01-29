//! Internal types for managing registered component types.

const std = @import("std");
const zcs = @import("root.zig");
const Component = zcs.Component;

/// The tag type for `CompFlag`.
const CompFlagInt = u6;

/// A tightly packed index representing a registered component type.
///
/// Not exposed publicly since components are currently registered on first use, and this results in
/// a hard to work with API. May be exposed if we can register components at compile time in the
/// future without making `Entities` generic:
///
/// https://github.com/games-by-Mason/zcs/issues/11
pub const CompFlag = enum(CompFlagInt) {
    /// The maximum registered component flags.
    pub const max = std.math.maxInt(CompFlagInt);

    /// A set of component flags.
    pub const Set = std.enums.EnumSet(CompFlag);

    _,
};

/// The number of registered component types.
var registered: usize = 0;

/// Assigns the given ID the next flag index if it doesn't have one, and then returns its flag.
///
/// Not thread safe.
pub fn register(self: Component.Id) CompFlag {
    // Early out if we're already registered
    if (self.flag) |f| return f;

    // Check if we've registered too many components
    if (registered == CompFlag.max / 2) {
        std.log.warn(
            "{} component types registered, you're at 50% the fatal capacity!",
            .{registered},
        );
    }
    if (registered >= CompFlag.max) {
        @panic("component type overflow");
    }

    // Register the ID and return it
    const flag: CompFlag = @enumFromInt(registered);
    registered += 1;
    self.flag = flag;
    return flag;
}
