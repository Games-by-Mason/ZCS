//! Metaprogramming helpers.

const std = @import("std");
const zcs = @import("root.zig");
const Component = zcs.Component;

// XXX: can probably remove this soon
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

// XXX: can probably remove this soon
pub fn ArchetypeChanges(T: type) type {
    for (@typeInfo(T).@"struct".fields) |field| {
        if (std.mem.eql(u8, "add", field.name)) continue;
        if (std.mem.eql(u8, "remove", field.name)) continue;
        @compileError(std.fmt.comptimePrint(
            "unexpected field {}",
            .{std.zig.fmtId(field.name)},
        ));
    }

    if (@hasField(T, "add")) {
        if (DuplicateComponentType(@FieldType(T, "add"))) |C| {
            @compileError("component type listed twice: " ++ @typeName(C));
        }
    }

    return struct {
        const Add = if (@hasField(T, "add")) @FieldType(T, "add") else @TypeOf(.{});

        pub inline fn getAdd(from: T) Add {
            if (@hasField(T, "add")) {
                return from.add;
            }
            return .{};
        }

        pub inline fn getRemove(from: T) Component.Flags {
            if (@hasField(T, "remove")) {
                return from.remove;
            }
            return .{};
        }
    };
}

// XXX: can probably remove this soon
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

// XXX: can probably remove this soon
test "ArchetypeChanges" {
    try std.testing.expectEqual(i32, DuplicateComponentType(struct { i32, f32, i32 }));
    try std.testing.expectEqual(i32, DuplicateComponentType(struct { i32, f32, ?i32 }));
    try std.testing.expectEqual(null, DuplicateComponentType(struct { i32, f32, u32 }));
    try std.testing.expectEqual(null, DuplicateComponentType(struct { i32, f32, ?u32 }));
}

// XXX: can move this to the file where it's used if everything else here is removed, add tests for
// it
pub inline fn isComptimeKnown(value: anytype) bool {
    return @typeInfo(@TypeOf(.{value})).@"struct".fields[0].is_comptime;
}
