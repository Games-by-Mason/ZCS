//! Submit this as a patch to Zig. Fixes comparisons for NaN.

const std = @import("std");
const expectEqualSlices = std.testing.expectEqualSlices;
const backend_can_print = std.testing.backend_can_print;

pub inline fn expectEqual(expected: anytype, actual: anytype) !void {
    const T = @TypeOf(expected, actual);
    return expectEqualInner(T, expected, actual);
}

fn expectEqualInner(comptime T: type, expected: T, actual: T) !void {
    switch (@typeInfo(@TypeOf(actual))) {
        .noreturn,
        .@"opaque",
        .frame,
        .@"anyframe",
        => @compileError("value of type " ++ @typeName(@TypeOf(actual)) ++ " encountered"),

        .undefined,
        .null,
        .void,
        => return,

        .type => {
            if (actual != expected) {
                print("expected type {s}, found type {s}\n", .{ @typeName(expected), @typeName(actual) });
                return error.TestExpectedEqual;
            }
        },

        .bool,
        .int,
        .comptime_float,
        .comptime_int,
        .enum_literal,
        .@"enum",
        .@"fn",
        .error_set,
        => {
            if (actual != expected) {
                print("expected {}, found {}\n", .{ expected, actual });
                return error.TestExpectedEqual;
            }
        },

        .float => |float| {
            const Int = std.meta.Int(.unsigned, float.bits);
            const expected_int: Int = @bitCast(expected);
            const actual_int: Int = @bitCast(actual);
            if (actual_int != expected_int) {
                if (std.math.isNan(actual) and std.math.isNan(expected)) {
                    print("expected {} (0x{x}), found {} (0x{x})\n", .{
                        expected,
                        expected_int,
                        actual,
                        actual_int,
                    });
                } else {
                    print("expected {}, found {}\n", .{ expected, actual });
                }
                return error.TestExpectedEqual;
            }
        },

        .pointer => |pointer| {
            switch (pointer.size) {
                .one, .many, .c => {
                    if (actual != expected) {
                        print("expected {*}, found {*}\n", .{ expected, actual });
                        return error.TestExpectedEqual;
                    }
                },
                .slice => {
                    if (actual.ptr != expected.ptr) {
                        print("expected slice ptr {*}, found {*}\n", .{ expected.ptr, actual.ptr });
                        return error.TestExpectedEqual;
                    }
                    if (actual.len != expected.len) {
                        print("expected slice len {}, found {}\n", .{ expected.len, actual.len });
                        return error.TestExpectedEqual;
                    }
                },
            }
        },

        .array => |array| try expectEqualSlices(array.child, &expected, &actual),

        .vector => |info| {
            var i: usize = 0;
            while (i < info.len) : (i += 1) {
                if (!std.meta.eql(expected[i], actual[i])) {
                    print("index {} incorrect. expected {}, found {}\n", .{
                        i, expected[i], actual[i],
                    });
                    return error.TestExpectedEqual;
                }
            }
        },

        .@"struct" => |structType| {
            inline for (structType.fields) |field| {
                try expectEqual(@field(expected, field.name), @field(actual, field.name));
            }
        },

        .@"union" => |union_info| {
            if (union_info.tag_type == null) {
                @compileError("Unable to compare untagged union values");
            }

            const Tag = std.meta.Tag(@TypeOf(expected));

            const expectedTag = @as(Tag, expected);
            const actualTag = @as(Tag, actual);

            try expectEqual(expectedTag, actualTag);

            // we only reach this switch if the tags are equal
            switch (expected) {
                inline else => |val, tag| try expectEqual(val, @field(actual, @tagName(tag))),
            }
        },

        .optional => {
            if (expected) |expected_payload| {
                if (actual) |actual_payload| {
                    try expectEqual(expected_payload, actual_payload);
                } else {
                    print("expected {any}, found null\n", .{expected_payload});
                    return error.TestExpectedEqual;
                }
            } else {
                if (actual) |actual_payload| {
                    print("expected null, found {any}\n", .{actual_payload});
                    return error.TestExpectedEqual;
                }
            }
        },

        .error_union => {
            if (expected) |expected_payload| {
                if (actual) |actual_payload| {
                    try expectEqual(expected_payload, actual_payload);
                } else |actual_err| {
                    print("expected {any}, found {}\n", .{ expected_payload, actual_err });
                    return error.TestExpectedEqual;
                }
            } else |expected_err| {
                if (actual) |actual_payload| {
                    print("expected {}, found {any}\n", .{ expected_err, actual_payload });
                    return error.TestExpectedEqual;
                } else |actual_err| {
                    try expectEqual(expected_err, actual_err);
                }
            }
        },
    }
}

fn print(comptime fmt: []const u8, args: anytype) void {
    if (@inComptime()) {
        @compileError(std.fmt.comptimePrint(fmt, args));
    } else if (backend_can_print) {
        std.debug.print(fmt, args);
    }
}
