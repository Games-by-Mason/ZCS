//! Runtime type information.

const std = @import("std");
const assert = std.debug.assert;

const zcs = @import("root.zig");
const CompFlag = zcs.CompFlag;

/// Runtime information for a type.
pub const TypeInfo = struct {
    /// The maximum allowed alignment.
    pub const max_align: std.mem.Alignment = .@"16";

    /// The component's type name.
    name: [:0]const u8,
    /// The component type's size.
    size: usize,
    /// The component type's alignment.
    alignment: u8,
    /// If this type has been registered as a component, this holds the component flag. Component
    /// types are registered as they become needed.
    comp_flag: ?CompFlag = null,

    /// Returns the type ID for the given type.
    pub inline fn init(comptime T: type) *@This() {
        comptime checkType(T);

        return &struct {
            var info: TypeInfo = .{
                .name = @typeName(T),
                .size = @sizeOf(T),
                .alignment = @alignOf(T),
            };
        }.info;
    }

    /// Asserts at compile time that ZCS's runtime type information supports this type.
    pub fn checkType(T: type) void {
        // Storing optionals, pointers, and `Entity` directly as components would create
        // ambiguities when creating entity views. It's unfortunate that we have to disallow
        // them, but the extra typing to wrap them in the rare case that you need this ability
        // is expected to be well worth it for the convenience views provide.
        //
        // There's no reason these couldn't be allowed for `Any` in general, but we want to get
        // compile time errors when trying to use bad types, so we just rule them out for any use of
        // `Any` instead.
        //
        // `Entity.Index` and `CmdBuf` are likely indicative of a mistake and so are ruled
        // out.
        if (@typeInfo(T) == .optional or
            T == zcs.Entity or
            T == zcs.Entity.Index or
            T == zcs.CmdBuf)
        {
            @compileError("unsupported component type '" ++ @typeName(T) ++ "'; consider wrapping in struct");
        }

        comptime assert(@alignOf(T) <= max_align.toByteUnits());
    }
};

/// This pointer can be used as a unique ID identifying a component type.
pub const TypeId = *TypeInfo;
