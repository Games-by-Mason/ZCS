//! A Tracy Zone that begins/ends inside of a command buffer. Unlike most extensions, this
//! extension's `Exec` is automatically called from the default exec implementation provided that
//! Tracy is enabled.

const std = @import("std");
const zcs = @import("../root.zig");
const tracy = @import("tracy");

const assert = std.debug.assert;

const Zone = tracy.Zone;

const CmdBuf = zcs.CmdBuf;
const Entities = zcs.Entities;
const Any = zcs.Any;

const SourceLocation = tracy.SourceLocation;

loc: *const SourceLocation,

pub const BeginOptions = Zone.BeginOptions;

/// Emits a begin zone command to the command buffer if Tracy is enabled.
pub fn begin(cb: *CmdBuf, comptime opt: SourceLocation.InitOptions) @This() {
    if (tracy.enabled) {
        const loc: *const SourceLocation = .init(opt);
        cb.ext(BeginCmd, .{ .loc = loc });
        return .{ .loc = loc };
    }
}

/// Emits an end zone command to the command buffer if Tracy is enabled.
pub fn end(self: @This(), cb: *CmdBuf) void {
    if (tracy.enabled) {
        cb.ext(EndCmd, .{ .loc = self.loc });
    }
}

/// A begin zone command.
pub const BeginCmd = struct { loc: *const SourceLocation };

/// An end zone command.
pub const EndCmd = struct { loc: *const SourceLocation };

/// `Exec` provides helpers for beginning/ending Tracy zones while executing the command buffer.
/// Unlike most extensions this extension is called automatically by the default exec, provided that
/// Tracy is enabled.
///
/// By convention, `exec` only calls into the stable public interface of the types it's working
/// with. As such, documentation is sparse. You are welcome to call these methods directly, or
/// use them as reference for implementing your own command buffer iterator.
pub const Exec = struct {
    const Stack = if (tracy.enabled) b: {
        break :b std.BoundedArray(struct { zone: Zone, loc: *const SourceLocation }, 32);
    } else struct {};

    stack: Stack = .{},

    /// Executes an extension command.
    pub inline fn extImmediate(self: *@This(), payload: Any) void {
        if (tracy.enabled) {
            if (payload.as(BeginCmd)) |b| {
                const zone = Zone.beginFromPtr(b.loc);
                self.stack.append(.{ .zone = zone, .loc = b.loc }) catch @panic("OOB");
            } else if (payload.as(EndCmd)) |e| {
                const frame = self.stack.pop() orelse @panic("OOB");
                assert(frame.loc == e.loc);
                frame.zone.end();
            }
        }
    }

    pub fn deinit(self: *@This()) void {
        if (tracy.enabled) {
            assert(self.stack.len == 0);
        }
    }
};
