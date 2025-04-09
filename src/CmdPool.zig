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

const CmdBuf = zcs.CmdBuf;
const Entities = zcs.Entities;

const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

reserved: ArrayListUnmanaged(CmdBuf),
mutex: Mutex,
released: ArrayListUnmanaged(*CmdBuf),
filled: usize,
headroom: f32,

/// The capacity of the command pool.
pub const Capacity = struct {
    /// The total number of command buffers to reserve.
    reserved: usize,
    /// The size of a single command buffer.
    cb: CmdBuf.Capacity,
    /// `acquire` only returns command buffers with a `worstCaseUsage` greater than this value.
    headroom: f32 = 0.5,
};

pub fn init(
    gpa: Allocator,
    es: *Entities,
    capacity: Capacity,
) error{ OutOfMemory, ZcsEntityOverflow }!@This() {
    var reserved: ArrayListUnmanaged(CmdBuf) = try .initCapacity(gpa, capacity.reserved);
    errdefer reserved.deinit(gpa);
    errdefer for (reserved.items) |*cb| cb.deinit(gpa, es);
    for (0..reserved.capacity) |_| reserved.appendAssumeCapacity(try CmdBuf.init(gpa, es, capacity.cb));

    var released: ArrayListUnmanaged(*CmdBuf) = try .initCapacity(gpa, capacity.reserved);
    errdefer released.deinit(gpa);

    return .{
        .reserved = reserved,
        .mutex = .{},
        .released = released,
        .filled = 0,
        .headroom = capacity.headroom,
    };
}

/// Destroys the command pool.
pub fn deinit(self: *@This(), gpa: Allocator, es: *Entities) void {
    self.checkAssertions();
    self.reserved.items.len = self.reserved.capacity;
    for (self.reserved.items) |*cb| cb.deinit(gpa, es);
    self.reserved.deinit(gpa);
    self.released.deinit(gpa);
}

/// Acquire a command buffer with at least `Capacity.headroom` capacity remaining. Call `release`
/// when done.
pub fn acquire(self: *@This()) *CmdBuf {
    return self.acquireOrErr() catch |err|
        @panic(@errorName(err));
}

pub fn acquireOrErr(self: *@This()) error{ZcsCmdPoolUnderflow}!*CmdBuf {
    self.mutex.lock();
    defer self.mutex.unlock();

    // Try to get a recently released command buffer
    if (self.released.pop()) |popped| return popped;

    // Try to get a reserved command buffer
    if (self.reserved.items.len > 0) {
        const new_len = self.reserved.items.len - 1;
        const result = &self.reserved.items[new_len];
        self.reserved.items.len = new_len;
        return result;
    }

    // We're out of command buffers, return an error
    return error.ZcsCmdPoolUnderflow;
}

/// Releases a previously acquired command buffer.
pub fn release(self: *@This(), cb: *CmdBuf) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (cb.worstCaseUsage() >= self.headroom) {
        self.released.appendAssumeCapacity(cb);
    } else {
        self.filled += 1;
    }
}

/// Gets a slice of all command buffers acquired and released since the last reset.
pub fn written(self: *@This()) []CmdBuf {
    self.checkAssertions();
    return self.reserved.items.ptr[self.reserved.items.len..self.reserved.capacity];
}

/// Resets the command pool. Asserts that all command buffers have already been reset.
pub fn reset(self: *@This()) void {
    self.checkAssertions();
    if (std.debug.runtime_safety) for (self.written()) |cb| assert(cb.isEmpty());
    self.reserved.items.len = self.reserved.capacity;
    self.released.items.len = 0;
    self.filled = 0;
}

/// Asserts that all command buffers have been released.
pub fn checkAssertions(self: *@This()) void {
    assert(self.released.items.len + self.filled == self.reserved.capacity - self.reserved.items.len);
}
