//! See `CompFlag`.

const std = @import("std");
const assert = std.debug.assert;

const zcs = @import("root.zig");
const Any = zcs.Any;
const TypeId = zcs.TypeId;
const Meta = Any.Meta;

/// The tag type for `Flag`.
const FlagInt = u6;

/// A tightly packed index for each registered component type.
pub const CompFlag = enum(FlagInt) {
    /// The maximum registered component flags.
    pub const max = std.math.maxInt(FlagInt) - 1;

    /// A set of component flags.
    pub const Set = std.enums.EnumSet(CompFlag);

    /// The list of registered components.
    var registered: std.BoundedArray(TypeId, CompFlag.max) = .{};

    /// Assigns the given ID the next flag index if it doesn't have one, and then returns its flag.
    /// Not thread safe.
    pub fn registerImmediate(id: TypeId) CompFlag {
        // Early out if we're already registered
        if (id.comp_flag) |f| return f;

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
        id.comp_flag = flag;

        // This function is not thread safe, but reading from `registered` is, so we update the
        // registered list, and then increment the counter atomically.
        registered.buffer[registered.len] = id;
        _ = @atomicRmw(usize, &registered.len, .Add, 1, .release);

        // Return the registered flag
        return flag;
    }

    /// Gets the list of registered component types for introspection purposes. Components are
    /// registered lazily, this list will grow over time. Thread safe.
    pub fn getAll() []const TypeId {
        return registered.constSlice();
    }

    /// This function is intended to be used only in tests. Unregisters all component types.
    pub fn unregisterAll() void {
        for (registered.slice()) |id| id.comp_flag = null;
        registered.clear();
    }

    /// Returns the ID for this flag.
    pub fn getId(self: @This()) TypeId {
        return registered.get(@intFromEnum(self));
    }

    _,
};
