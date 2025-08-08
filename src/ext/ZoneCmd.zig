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
    const tracy_stack_max = if (tracy.enabled) 32 else 0;

    tracy_stack: [tracy_stack_max]struct { zone: Zone, loc: *const SourceLocation } = undefined,
    tracy_stack_len: if (tracy.enabled) u8 else u0 = 0,

    /// Executes an extension command.
    pub inline fn extImmediate(self: *@This(), payload: Any) void {
        if (tracy.enabled) {
            if (payload.as(BeginCmd)) |b| {
                const zone = Zone.beginFromPtr(b.loc);
                if (self.tracy_stack_len >= tracy_stack_max) @panic("OOB");
                self.tracy_stack[self.tracy_stack_len] = .{ .zone = zone, .loc = b.loc };
                self.tracy_stack_len += 1;
            } else if (payload.as(EndCmd)) |e| {
                self.tracy_stack_len -= 1;
                const frame = self.tracy_stack[self.tracy_stack_len];
                assert(frame.loc == e.loc);
                frame.zone.end();
            }
        }
    }

    pub fn finish(self: *@This()) void {
        if (tracy.enabled) {
            assert(self.tracy_stack_len == 0);
        }
    }
};
