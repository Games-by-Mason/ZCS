//! Metaprogramming helpers.

const std = @import("std");

/// Returns the field indices for `Comps` sorted in descending alignment.
pub fn alignmentSort(Comps: type) [@typeInfo(Comps).@"struct".fields.len]u8 {
    const fields = @typeInfo(Comps).@"struct".fields;
    comptime var sorted: [fields.len]u8 = undefined;
    inline for (&sorted, 0..) |*v, i| v.* = i;
    // PDQ appears to result in the least comptime branches, alternatively a bucket sort would be
    // simple.
    comptime std.sort.pdq(u8, &sorted, Comps, compareComponentAlignment);
    return sorted;
}

test "alignmentSort" {
    {
        const A = struct { a: u8 align(1) };
        const B = struct { a: u8 align(2) };
        const C = struct { a: u8 align(4) };

        try std.testing.expectEqual(1, @alignOf(A));
        try std.testing.expectEqual(2, @alignOf(B));
        try std.testing.expectEqual(4, @alignOf(C));

        try std.testing.expectEqual(.{ 2, 1, 0 }, alignmentSort(struct { A, B, C }));
        try std.testing.expectEqual(.{ 2, 1, 0 }, alignmentSort(struct { A, ?B, C }));
        try std.testing.expectEqual(.{ 2, 1, 0 }, alignmentSort(struct { ?A, ?B, ?C }));

        try std.testing.expectEqual(.{ 0, 1, 2 }, alignmentSort(struct { C, B, A }));
        try std.testing.expectEqual(.{ 0, 1, 2 }, alignmentSort(struct { C, ?B, A }));
        try std.testing.expectEqual(.{ 0, 1, 2 }, alignmentSort(struct { ?C, ?B, ?A }));

        try std.testing.expectEqual(.{ 1, 0, 2 }, alignmentSort(struct { B, C, A }));
        try std.testing.expectEqual(.{ 1, 0, 2 }, alignmentSort(struct { B, ?C, A }));
        try std.testing.expectEqual(.{ 1, 0, 2 }, alignmentSort(struct { ?B, ?C, ?A }));

        // Test a large number of components to make sure we don't get too many comptime branches
        _ = alignmentSort(struct { u8, u16, u32, u64, u128, u256, u512, u8, u16, u32, u64, u128, u256, u512, u8, u16, u32, u64, u128, u256, u512, u8, u16, u32, u64, u128, u256, u512, u8, u16, u32, u64, u128, u256, u512 });
    }
}

/// If the type is optional, returns the child. Otherwise returns the type.
pub fn Unwrapped(T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |opt| opt.child,
        else => T,
    };
}

test "Unwrapped" {
    try std.testing.expectEqual(u32, Unwrapped(u32));
    try std.testing.expectEqual(u32, Unwrapped(?u32));
}

/// Checks that components don't contain any duplicates. ?Component is considered equivalent to
/// Component.
pub fn checkComponents(Components: type) void {
    if (DuplicateComponentType(Components)) |Component| {
        @compileError("component type listed twice: " ++ @typeName(Component));
    }
}

test "checkComponents" {
    try std.testing.expectEqual(i32, DuplicateComponentType(struct { i32, f32, i32 }));
    try std.testing.expectEqual(i32, DuplicateComponentType(struct { i32, f32, ?i32 }));
    try std.testing.expectEqual(null, DuplicateComponentType(struct { i32, f32, u32 }));
    try std.testing.expectEqual(null, DuplicateComponentType(struct { i32, f32, ?u32 }));
}

fn DuplicateComponentType(T: type) ?type {
    if (!@typeInfo(T).@"struct".is_tuple) {
        @compileError("expected tuple, found " ++ @typeName(T));
    }
    const fields = @typeInfo(T).@"struct".fields;
    inline for (0..fields.len) |i| {
        inline for ((i + 1)..fields.len) |j| {
            if (Unwrapped(fields[i].type) == Unwrapped(fields[j].type)) {
                return Unwrapped(fields[i].type);
            }
        }
    }
    return null;
}

fn compareComponentAlignment(Comps: type, lhs: u8, rhs: u8) bool {
    const fields = @typeInfo(Comps).@"struct".fields;
    const Lhs = Unwrapped(fields[lhs].type);
    const Rhs = Unwrapped(fields[rhs].type);
    return @alignOf(Lhs) > @alignOf(Rhs);
}
