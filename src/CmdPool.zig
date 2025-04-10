//! A pool of command buffers. Intended for multithreaded use cases where each thread needs its own
//! command buffer.
//!
//! # Problem Statement
//!
//! The key issue this abstraction solves is how much space to allocate per command buffer.
//!
//! The naive approach of dividing the capacity evenly across the threads will fail if the workload
//! is lopsided or the users machine has more cores than expected.
//!
//! The alternative naive approach of allocating a fixed command buffer size per thread will
//! increase the likelihood of overflowing command buffers on machines with low core counts, or
//! overflowing entities on machines with high core counts.
//!
//! # Solution
//!
//! `CmdPool` allocates a fixed number of command buffers of fixed sizes. Once per chunk, you call
//! `acquire` to get a command buffer with more than `headroom` capacity`. When done processing a
//! chunk, you call `release`.
//!
//! This distribution of load results in comparable command buffer usage regardless of core counts,
//! lessening the Q&A burden when tuning your game.

const std = @import("std");
const zcs = @import("root.zig");
const tracy = @import("tracy");

const log = std.log;
const assert = std.debug.assert;

const Mutex = std.Thread.Mutex;
const Condition = std.Thread.Condition;

const CmdBuf = zcs.CmdBuf;
const Entities = zcs.Entities;

const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

/// The debug name for this command pool. See `InitOptions.name`.
name: ?[:0]const u8,
/// Reserved command buffers that have not yet been acquired.
buffers: ArrayListUnmanaged(CmdBuf),
/// Locked when modifying internal state.
mutex: Mutex,
/// Signaled when command buffers are returned, broadcasted when all command buffers have been
/// retired.
condition: Condition,
/// Command buffers that have been released.
released: ArrayListUnmanaged(*CmdBuf),
/// The number of retired command buffers. Command buffers are retired when they are returned with
/// with less than the requested headroom available.
retired: usize,
/// Measured in units of `CmdBuf.worstCastUsage`, ranges from `0` to `1`.
headroom: f32,
/// See `InitOptions.warn_ratio`.
warn_ratio: f32,

/// The capacity of a command pool.
pub const Capacity = struct {
    /// The capacity of a single command buffer.
    buffer: CmdBuf.Capacity = .{
        .cmds = 100000 / 256,
    },
    /// The total number of command buffers to reserve.
    buffers: usize = 256,
};

/// Options for `init`.
pub const InitOptions = struct {
    /// The debug name for this command pool.
    ///
    /// If non-null and Tracy is enabled, this command pool's usage is graphed under this name on
    /// reset.
    name: ?[:0]const u8,
    /// Used to allocate the command pool.
    gpa: Allocator,
    /// Entities are reserved from here.
    es: *Entities,
    /// The capacity.
    cap: Capacity = .{},
    /// `acquire` only returns command buffers with a `worstCaseUsage` greater than this value.
    headroom: f32 = 0.5,
    /// Warn if a single acquire exceeds this ratio of the headroom, or if more than this ratio of the
    /// total command buffers are written.
    warn_ratio: f32 = 0.2,
};

/// Initializes a command pool.
pub fn init(options: InitOptions) error{ OutOfMemory, ZcsEntityOverflow }!@This() {
    // Reserve the command buffers
    var buffers: ArrayListUnmanaged(CmdBuf) = try .initCapacity(options.gpa, options.cap.buffers);
    errdefer buffers.deinit(options.gpa);
    errdefer for (buffers.items) |*cb| cb.deinit(options.gpa, options.es);
    for (0..options.cap.buffers) |_| {
        const cb: CmdBuf = try .init(.{
            .name = null,
            .gpa = options.gpa,
            .es = options.es,
            .cap = options.cap.buffer,
            // We handle the warnings ourselves
            .warn_ratio = 1.0,
        });
        buffers.appendAssumeCapacity(cb);
    }

    // Reserve the released list
    var released: ArrayListUnmanaged(*CmdBuf) = try .initCapacity(options.gpa, options.cap.buffers);
    errdefer released.deinit(options.gpa);

    // If Tracy is enabled and we have a name, configure our plot.
    if (tracy.enabled) {
        if (options.name) |name| {
            tracy.plotConfig(.{
                .name = name,
                .format = .percentage,
                .mode = .line,
                .fill = true,
            });
        }
    }

    return .{
        .buffers = buffers,
        .mutex = .{},
        .condition = .{},
        .released = released,
        .retired = 0,
        .headroom = options.headroom,
        .name = options.name,
        .warn_ratio = options.warn_ratio,
    };
}

/// Destroys the command pool.
pub fn deinit(self: *@This(), gpa: Allocator, es: *Entities) void {
    self.checkAssertions();
    self.buffers.items.len = self.buffers.capacity;
    for (self.buffers.items) |*cb| cb.deinit(gpa, es);
    self.buffers.deinit(gpa);
    self.released.deinit(gpa);
}

/// The result of `acquire`.
pub const AcquireResult = struct {
    /// The initial usage ratio.
    usage: f32,
    /// The command buffer.
    cb: *CmdBuf,

    /// Initializes an acquire result with the starting usage.
    fn init(cb: *CmdBuf) @This() {
        return .{
            .usage = cb.worstCaseUsage(),
            .cb = cb,
        };
    }
};

/// Acquire a command buffer with at least `Capacity.headroom` capacity remaining. Call `release`
/// when done. Thread safe.
///
/// This function may block if all command buffers are currently in use. You can mitigate this by
/// reserving more command buffers up front.
pub fn acquire(self: *@This()) AcquireResult {
    return self.acquireOrErr() catch |err|
        @panic(@errorName(err));
}

/// Similar to `acquire`, but returns an error when out of command buffers.
pub fn acquireOrErr(self: *@This()) error{ZcsCmdPoolUnderflow}!AcquireResult {
    self.mutex.lock();
    defer self.mutex.unlock();

    // Try to get a recently released command buffer
    if (self.released.pop()) |popped| return .init(popped);

    // Try to get a reserved command buffer
    if (self.buffers.items.len > 0) {
        const new_len = self.buffers.items.len - 1;
        const result = &self.buffers.items[new_len];
        self.buffers.items.len = new_len;
        return .init(result);
    }

    // There are no command buffers available. Wait until one becomes available, or all are
    // retired.
    while (self.released.items.len == 0 and self.retired < self.buffers.capacity) {
        self.condition.wait(&self.mutex);
    }

    // Try to reacquire the released command buffer
    if (self.released.pop()) |cb| {
        assert(self.retired < self.buffers.capacity);
        return .init(cb);
    }

    // If no command buffer was released, we're out of command buffers, return an error
    assert(self.retired == self.buffers.capacity);
    return error.ZcsCmdPoolUnderflow;
}

/// Releases a previously acquired command buffer. Thread safe.
pub fn release(self: *@This(), ar: AcquireResult) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    // Optionally warn if a single acquire used too much headroom, this is a sign that the command
    // buffers are too small
    const usage = ar.cb.worstCaseUsage();
    if (ar.cb.worstCaseUsage() - ar.usage > (1.0 - self.headroom) * self.warn_ratio) {
        log.warn(
            "acquire used > {d}% headroom, consider increasing command buffer size",
            .{self.warn_ratio * 100.0},
        );
    }

    // Release the command buffer if it has enough headroom left, otherwise retire it
    if (usage < self.headroom) {
        self.released.appendAssumeCapacity(ar.cb);
    } else {
        self.retired += 1;
    }

    // If all command buffers are retired, broadcast our condition so all pending acquires return an
    // error. Otherwise signal at least one pending acquire to continue.
    if (self.retired == self.buffers.capacity) {
        self.condition.broadcast();
    } else {
        self.condition.signal();
    }
}

/// Gets a slice of all command buffers that may have been written to since the last reset.
pub fn written(self: *@This()) []CmdBuf {
    self.checkAssertions();
    return self.buffers.items.ptr[self.buffers.items.len..self.buffers.capacity];
}

/// Resets the command pool. Asserts that all command buffers have already been reset.
pub fn reset(self: *@This()) void {
    // Check assertions
    self.checkAssertions();
    if (std.debug.runtime_safety) for (self.written()) |cb| assert(cb.isEmpty());

    // Warn if we used too many command buffers
    const cap: f32 = @floatFromInt(self.buffers.capacity);
    const used: f32 = @floatFromInt(self.written().len);
    const usage = used / cap;
    if (usage > self.warn_ratio) {
        log.warn(
            "more than {d}% command pool buffers used, consider incresing reserved count",
            .{self.warn_ratio},
        );
    }

    // If a name is configured, emit a Tracy plot
    if (self.name) |name| {
        tracy.plot(.{
            .name = name,
            .value = .{ .f32 = usage * 100.0 },
        });
    }

    // Reset the command pool
    self.buffers.items.len = self.buffers.capacity;
    self.released.items.len = 0;
    self.retired = 0;
}

/// Asserts that all command buffers have been released.
pub fn checkAssertions(self: *@This()) void {
    assert(self.released.items.len + self.retired == self.buffers.capacity - self.buffers.items.len);
}
