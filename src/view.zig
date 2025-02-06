//! An entity view is a user defined struct or tuple used as a temporary view of an entity. It may
//! contain any number of fields, where each field is either of type `Entity`, an optional single
//! item pointer to a component, or a single item pointer to a component.
//!
//! These views are temporary, as immediate operations on entity's are allowed to move component
//! memory.
//!
//! This file provides infrastructure to support entity views.

const std = @import("std");
const assert = std.debug.assert;
const zcs = @import("root.zig");
const types = @import("types.zig");
const Entities = zcs.Entities;
const Entity = zcs.Entity;
const Comp = zcs.Comp;
const compId = zcs.compId;

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
    types.assertValidComponentType(C);
    return C;
}

/// Mixins for use with views.
///
/// Here's an example of how to use a mixin:
/// ```
/// const MyView = struct {
///     pub const init = zcs.view.Mixins(@This()).init; // Add an init function!
///     foo: *Foo,
/// };
/// ```
pub fn Mixins(View: type) type {
    return struct {
        /// Initializes the view, or returns `null` if the entity does not exist or is missing any
        /// required components.
        pub fn init(es: *const Entities, e: Entity) ?View {
            // Check if entity has the required components
            const slot = es.slots.get(e.key) orelse return null;
            var view_arch: types.CompFlag.Set = .{};
            inline for (@typeInfo(View).@"struct".fields) |field| {
                if (field.type != Entity and @typeInfo(field.type) != .optional) {
                    const Unwrapped = UnwrapField(field.type);
                    const flag = compId(Unwrapped).flag orelse return null;
                    view_arch.insert(flag);
                }
            }
            if (!slot.arch.supersetOf(view_arch)) return null;

            // Fill in the view
            var result: View = undefined;
            inline for (@typeInfo(View).@"struct".fields) |field| {
                const Unwrapped = UnwrapField(field.type);
                if (Unwrapped == Entity) {
                    @field(result, field.name) = e;
                    continue;
                }

                const comp = e.getComp(es, Unwrapped);
                if (@typeInfo(field.type) == .optional) {
                    @field(result, field.name) = comp;
                } else {
                    @field(result, field.name) = comp.?;
                }
            }
            return result;
        }
    };
}
