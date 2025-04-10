const std = @import("std");
const zcs = @import("zcs");

const Entity = zcs.Entity;

pub fn expectEqualEntity(expected: anytype, actual: anytype) !void {
    const e = if (@TypeOf(expected) == Entity.Optional) expected else expected.toOptional();
    const a = if (@TypeOf(actual) == Entity.Optional) actual else actual.toOptional();
    if (e != a) {
        if (std.testing.backend_can_print) {
            std.debug.print("expected {}, found {}\n", .{ e, a });
        }
        return error.TestExpectedEqual;
    }
}

test {
    _ = @import("unit.zig");
    _ = @import("fuzz_entities.zig");
    _ = @import("fuzz_entities_threaded.zig");
    _ = @import("fuzz_cmdbuf_encoding.zig");
    _ = @import("events.zig");
    _ = @import("ext.zig");
}
