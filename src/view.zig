//! An entity view is a user defined struct or tuple used as a temporary view of an entity. It may
//! contain any number of fields, where each field is either of type `Entity`, an optional single
//! item pointer to a component, or a single item pointer to a component.
//!
//! Additionally, entity slice views are views over multiple entities. Slice views are similar to
//! normal entity views, but instead of single item pointers they have slices, and `Entity.Index` is
//! used in place of `Entity`.
//!
//! These views are temporary, as immediate operations on entity's are allowed to move component
//! memory.
//!
//! This file provides infrastructure to support entity views and entity slice views.

const std = @import("std");
const assert = std.debug.assert;
const zcs = @import("root.zig");
const typeId = zcs.typeId;
const Entities = zcs.Entities;
const Entity = zcs.Entity;
const Any = zcs.Any;
const CompFlag = zcs.CompFlag;

/// Options for a view.
pub const ViewOptions = struct {
    /// The pointer type for the view's components.
    size: std.builtin.Type.Pointer.Size,
};

/// Given a field type from an entity view or entity slice view, returns the underlying component
/// type or `Entity`/`Entity.Index` as appropriate.
///
/// For entity views, `size` should be set to `.one`. Otherwise it should be set to `.slice` (or the
/// desired pointer size.)
///
/// If `track_ids` is `true`, `ThreadId` is also allowed as a parameter.
pub fn UnwrapField(T: type, options: ViewOptions) type {
    // If we're looking for a single element and `T` is an entity, return it directly
    if (options.size == .one and T == Entity) {
        return Entity;
    }

    // Get the component pointer
    const SomePtr = Unwrap(T);
    comptime assert(@typeInfo(SomePtr).pointer.size == options.size);
    const Result = @typeInfo(SomePtr).pointer.child;

    // If we're looking for multiple elements and `T` points to entity indices, return it directly
    if (options.size != .one and Result == Entity.Index) {
        comptime assert(@typeInfo(T) != .optional);
        comptime assert(@typeInfo(T).pointer.is_const == true);
        return Result;
    }

    // Check that we have a valid component type, and then return it
    zcs.TypeInfo.checkType(Result);
    return Result;
}

/// Indexes an entity slice view, returning an entity view.
pub fn index(View: type, es: *const Entities, slices: anytype, i: u32) View {
    var view: View = undefined;
    inline for (@typeInfo(View).@"struct".fields, slices) |field, slice| {
        if (UnwrapField(@TypeOf(slice), .{ .size = .slice }) == Entity.Index) {
            const entity_index = slice[i];
            @field(view, field.name) = entity_index.toEntity(es);
        } else {
            @field(view, field.name) = switch (@typeInfo(@TypeOf(slice))) {
                .optional => if (slice) |unwrapped| &unwrapped[i] else null,
                else => &slice[i],
            };
        }
    }
    return view;
}

/// Converts an entity view or entity slice view into a comp flag set, or `null` if any of the
/// component fields are unregistered. Size should be set to `.one` for entity views, and `.slice`
/// or the desired pointer size for entity slice views.
pub inline fn comps(T: type, options: ViewOptions) ?CompFlag.Set {
    var arch: CompFlag.Set = .{};
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (field.type != Entity and @typeInfo(field.type) != .optional) {
            const Unwrapped = zcs.view.UnwrapField(field.type, options);
            if (Unwrapped == Entity.Index) continue;
            const flag = typeId(Unwrapped).comp_flag orelse return null;
            arch.insert(flag);
        }
    }
    return arch;
}

/// Converts an entity view type into an entity slice view type.
pub fn Slice(EntityView: type) type {
    const entity_view_fields = @typeInfo(EntityView).@"struct".fields;
    comptime var fields: [entity_view_fields.len]std.builtin.Type.StructField = undefined;
    inline for (&fields, entity_view_fields, 0..) |*field, entity_view_field, i| {
        const T = entity_view_field.type;
        const S = b: {
            if (T == Entity) break :b []const Entity.Index;

            const Ptr = switch (@typeInfo(T)) {
                .optional => |optional| optional.child,
                .pointer => T,
                else => @compileError("expected pointer, found " ++ @typeName(T)),
            };
            if (@typeInfo(Ptr) != .pointer) {
                @compileError("expected pointer, found " ++ @typeName(T));
            }
            const Child = @typeInfo(Ptr).pointer.child;
            const S = if (@typeInfo(Ptr).pointer.is_const) []const Child else []Child;
            break :b if (@typeInfo(T) == .optional) ?S else S;
        };
        field.* = .{
            .name = std.fmt.comptimePrint("{}", .{i}),
            .type = S,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(S),
        };
    }
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = true,
    } });
}

/// Returns the list of parameter types for a function type.
pub fn params(T: type) [@typeInfo(T).@"fn".params.len]type {
    var results: [@typeInfo(T).@"fn".params.len]type = undefined;
    inline for (&results, @typeInfo(T).@"fn".params) |*result, param| {
        result.* = if (param.type) |Param| Param else {
            @compileError("cannot get type of `anytype` parameter");
        };
    }
    return results;
}

/// Generates a tuple from a list of types. Similar to `std.meta.Tuple`, but does not call
/// `@setEvalBranchQuota`.
pub fn Tuple(types: []const type) type {
    comptime var fields: [types.len]std.builtin.Type.StructField = undefined;
    inline for (&fields, types, 0..) |*field, param, i| {
        field.* = .{
            .name = std.fmt.comptimePrint("{}", .{i}),
            .type = param,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(param),
        };
    }
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = true,
    } });
}

/// If `T` is an optional type, returns its child. Otherwise returns it unchanged.
pub fn Unwrap(T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |optional| optional.child,
        else => T,
    };
}
