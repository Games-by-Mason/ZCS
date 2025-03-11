//! Interprets random bytes as user requested types.

const std = @import("std");
const assert = std.debug.assert;

input: []const u8,
index: usize = 0,
empty: bool = false,

pub fn init(input: []const u8) @This() {
    // See https://github.com/Games-by-Mason/ZCS/issues/20
    const max_consecutive_zeroes = 64;
    var consecutive_zeros: usize = 0;
    var len: usize = input.len;
    for (input, 0..) |n, i| {
        if (n == 0) {
            consecutive_zeros += 1;
        } else {
            consecutive_zeros = 0;
        }

        if (consecutive_zeros > max_consecutive_zeroes) {
            len = i - max_consecutive_zeroes;
            break;
        }
    }
    return .{ .input = input[0..len] };
}

pub fn isEmpty(self: @This()) bool {
    return self.input.len == 0 or self.empty;
}

pub fn next(self: *@This(), T: type) T {
    switch (@typeInfo(T)) {
        .void => return {},
        .bool => return (self.nextRaw(u8)) % 2 == 0,
        .int => return self.nextRaw(T),
        .float => {
            const val = self.nextRaw(T);
            // https://github.com/ziglang/zig/pull/22621
            if (std.math.isNan(val)) return 0.0;
            return val;
        },
        .array => |array| {
            var result: T = undefined;
            for (&result) |*item| {
                item.* = self.next(array.child);
            }
            return result;
        },
        .@"struct" => |@"struct"| {
            var result: T = undefined;
            inline for (@"struct".fields) |field| {
                @field(result, field.name) = self.next(field.type);
            }
            return result;
        },
        .null => return null,
        .optional => |optional| {
            if (self.next(bool)) {
                return self.next(optional.child);
            } else {
                return null;
            }
        },
        .@"enum" => |@"enum"| {
            // If we can, just treat the enum like a number
            if (!@"enum".is_exhaustive) return @enumFromInt(self.next(@"enum".tag_type));

            // Otherwise, we pick a random field. We may use a larger type than strictly necessary
            // for a more even distribution.
            const n = self.next(std.meta.Int(.unsigned, @max(@typeInfo(@"enum".tag_type).int.bits * 2, 16)));
            const m = n % @"enum".fields.len;
            inline for (@"enum".fields, 0..) |field, i| {
                if (i == m) return @enumFromInt(field.value);
            }
            unreachable;
        },
        .@"union" => |@"union"| {
            const tag = self.next(@"union".tag_type.?);
            inline for (@"union".fields) |field| {
                if (std.mem.eql(u8, field.name, @tagName(tag))) {
                    return @unionInit(T, field.name, self.next(field.type));
                }
            }
            unreachable;
        },
        else => comptime unreachable,
    }
}

pub fn nextLessThan(self: *@This(), T: type, less_than: T) T {
    assert(std.math.maxInt(T) >= less_than);
    const n: T = self.next(T);
    return n % less_than;
}

pub fn nextBetween(self: *@This(), T: type, min: T, less_than: T) T {
    switch (@typeInfo(T)) {
        .float, .comptime_float => {
            const n: T = self.next(T);
            return min + @mod(n, less_than - min);
        },
        .int, .comptime_int => {
            assert(std.math.maxInt(T) >= less_than);
            assert(less_than >= min);
            const n: T = self.next(T);
            return min + (n % (less_than - min));
        },
        else => comptime unreachable,
    }
}

fn nextRaw(self: *@This(), T: type) T {
    var bytes: [@sizeOf(T)]u8 = .{0} ** @sizeOf(T);
    for (0..bytes.len) |i| {
        bytes[i] = if (self.input.len == 0) 0 else self.input[self.index];
        self.index += 1;
        if (self.index >= self.input.len) {
            self.empty = true;
            self.index = 0;
        }
    }

    var result: T = undefined;
    @memcpy(std.mem.asBytes(&result), &bytes);
    return result;
}

pub fn progress(self: @This()) f32 {
    if (self.isEmpty()) return 1.0;
    return @as(f32, @floatFromInt(self.index)) / @as(f32, @floatFromInt(self.input.len));
}
