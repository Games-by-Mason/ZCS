//! Metaprogramming helpers. See also `view`.

const std = @import("std");

/// Returns true if the given value is comptime known, false otherwise.
pub inline fn isComptimeKnown(value: anytype) bool {
    return @typeInfo(@TypeOf(.{value})).@"struct".fields[0].is_comptime;
}

test isComptimeKnown {
    try std.testing.expect(isComptimeKnown(123));
    const foo = 456;
    try std.testing.expect(isComptimeKnown(foo));
    var bar: u8 = 123;
    bar += 1;
    try std.testing.expect(!isComptimeKnown(bar));
}
