//! An entity view is a user defined struct or tuple used as a temporary view of an entity. It may
//! contain any number of fields, where each field is either of type `Entity`, an optional single
//! item pointer to a component, or a single item pointer to a component.
//!
//! These views are temporary, as immediate operations on entity's are allowed to move component
//! memory.
//!
//! This file provides infrastructure to support entity views.
//!
//! See `ext.Node.View.Mixins` for an example of adding methods to a view in a composable way.

const std = @import("std");
const assert = std.debug.assert;
const zcs = @import("root.zig");
const Entities = zcs.Entities;
const Entity = zcs.Entity;
const Any = zcs.Any;

/// Given a view type, returns a new view type with all the same component fields but no entity
/// fields.
pub fn Comps(View: type) type {
    const view_fields = @typeInfo(View).@"struct".fields;
    comptime var fields: std.BoundedArray(std.builtin.Type.StructField, view_fields.len) = .{};
    for (view_fields) |view_field| {
        if (view_field.type != Entity) {
            fields.appendAssumeCapacity(view_field);
        }
    }
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = fields.constSlice(),
        .decls = &.{},
        .is_tuple = false,
    } });
}

/// Given the type of a view field, returns the type of the underlying component, or `Entity` if it
/// is an entity.
pub fn UnwrapField(T: type) type {
    // If we're entity, return it directly
    if (T == Entity) return Entity;

    // Get the component pointer
    const Ptr = switch (@typeInfo(T)) {
        .optional => |optional| optional.child,
        else => T,
    };
    comptime assert(@typeInfo(Ptr).pointer.size == .one);

    // Get the component type, assert it's a valid component type and return it
    const C = @typeInfo(Ptr).pointer.child;
    zcs.TypeInfo.checkType(C);
    return C;
}

/// If the type is optional, returns it. Otherwise makes it optional and returns it.
///
/// See `makeOptional`.
pub fn AsOptional(T: type) type {
    return switch (@typeInfo(T)) {
        .optional => T,
        else => ?T,
    };
}

/// Given an optional value, returns it unchanged. Given a non-optional value, returns it as an
/// optional. Useful for referencing components on a view that may or may not be optional from a
/// mixin.
pub fn asOptional(self: anytype) AsOptional(@TypeOf(self)) {
    return self;
}
