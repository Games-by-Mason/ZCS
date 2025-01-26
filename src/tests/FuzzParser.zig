//! Interprets random bytes as user requested types.

const std = @import("std");
const assert = std.debug.assert;

input: []const u8,
index: usize = 0,
empty: bool = false,

pub fn init(input: []const u8) @This() {
    return .{ .input = input };
}

pub fn isEmpty(self: @This()) bool {
    return self.empty;
}

pub fn next(self: *@This(), T: type) T {
    switch (@typeInfo(T)) {
        .void => return {},
        .bool => return (self.nextRaw(u8)) % 2 == 0,
        .int => return self.nextRaw(T),
        .float => {
            // XXX: ...
            const val = self.nextRaw(T);
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
            const n = self.next(@"enum".tag_type);
            if (!@"enum".is_exhaustive) {
                return @enumFromInt(n);
            }
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
