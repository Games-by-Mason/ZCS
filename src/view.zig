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
const typeId = zcs.typeId;
const Entities = zcs.Entities;
const Entity = zcs.Entity;
const Any = zcs.Any;
const CompFlag = zcs.CompFlag;
const EntityIndex = zcs.storage.EntityIndex;

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

/// If `T` is an optional type, returns its child. Otherwise returns it unchanged.
pub fn Unwrap(T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |optional| optional.child,
        else => T,
    };
}

/// Given a field type from a view struct, returns the underlying component type or
/// `Entity`/`EntityIndex` as appropriate.
///
/// If the view is of a single entity, `size` should be set to `.one`, and entities are expected to
/// be passed as `Entity`. If the view is of multiple entities, `size` should be set to something
/// other than `.one`, and entities are passed as the corresponding pointer type to `EntityIndex`s.
pub fn UnwrapField(T: type, size: std.builtin.Type.Pointer.Size) type {
    // If we're looking for a single element and `T` is an entity, return it directly
    if (size == .one and T == Entity) {
        return Entity;
    }

    // Get the component pointer
    const Some = Unwrap(T);
    comptime assert(@typeInfo(Some).pointer.size == size);

    // If we're looking for multiple elements and `T` points to entity indices, return them directly
    if (size != .one and Some == EntityIndex) {
        comptime assert(@typeInfo(T) != .optional);
        return T;
    }

    // Get the component type, assert it's a valid component type and return it
    const C = @typeInfo(Some).pointer.child;
    zcs.TypeInfo.checkType(C);
    return C;
}

/// Given a view type for multiple entities, returns a view type for a single entity.
pub fn IndexView(T: type) type {
    const input_fields = @typeInfo(T).@"struct".fields;
    comptime var fields: [input_fields.len]std.builtin.Type.StructField = undefined;
    inline for (&fields, input_fields, 0..) |*field, slice, i| {
        const Field = b: {
            const pointer = @typeInfo(Unwrap(slice.type)).pointer;
            comptime assert(pointer.size != .one);
            if (pointer.child == EntityIndex) break :b Entity;
            const Field = if (pointer.is_const) *const pointer.child else *pointer.child;
            break :b if (@typeInfo(slice.type) == .optional) ?Field else Field;
        };
        field.* = .{
            .name = std.fmt.comptimePrint("{}", .{i}),
            .type = Field,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(Field),
        };
    }
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = true,
    } });
}

/// Given a view of multiple entities, returns a view of the entity at index `i` relative to the
/// beginning of the view.
pub fn index(es: *const Entities, slices: anytype, i: u32) IndexView(@TypeOf(slices)) {
    var result: IndexView(@TypeOf(slices)) = undefined;
    inline for (&result, slices) |*field, slice| {
        if (UnwrapField(@TypeOf(slice), .slice) == EntityIndex) {
            const entity_index = slice[i];
            field.* = .{ .key = .{
                .index = entity_index,
                .generation = es.handle_tab.generations[entity_index],
            } };
        } else {
            field.* = switch (@typeInfo(@TypeOf(slice))) {
                .optional => if (slice) |unwrapped| &unwrapped[i] else null,
                else => &slice[i],
            };
        }
    }
    return result;
}

/// Returns the list of parameter types for a function type.
pub fn params(T: type) []type {
    var results: [@typeInfo(T).@"fn".params.len]type = undefined;
    inline for (&results, @typeInfo(T).@"fn".params) |*result, param| {
        result.* = if (param.type) |Param| Param else {
            @compileError("cannot get type of `anytype` parameter");
        };
    }
    return &results;
}

/// Converts a list of types into a comp flag set, or `null` if any of them are unregistered.
/// Ignores `Entity`.
pub inline fn requiredComps(types: []const type) ?CompFlag.Set {
    var result: CompFlag.Set = .{};
    inline for (types) |T| {
        // Skip optional comps and `Entity`
        if (@typeInfo(T) == .optional or T == Entity) continue;

        // Early out if any types aren't registered
        const Comp = @typeInfo(T).pointer.child;

        if (Comp == EntityIndex) continue;

        zcs.TypeInfo.checkType(Comp);
        const flag = typeId(Comp).comp_flag orelse return null;

        // Insert the required comp
        result.insert(flag);
    }
    return result;
}

/// Converts a list of types into a comp flag set, or `null` if any of them are unregistered.
/// Ignores `Entity`.
pub inline fn requiredCompsFromStruct(T: type) ?CompFlag.Set {
    var arch: CompFlag.Set = .{};
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (field.type != Entity and @typeInfo(field.type) != .optional) {
            const Unwrapped = zcs.view.UnwrapField(field.type, .one);
            const flag = typeId(Unwrapped).comp_flag orelse return null;
            arch.insert(flag);
        }
    }
    return arch;
}

/// Given a list of pointer types, returns a tuple of slices of the child types. If a child type is
/// optional, its slice becomes optional instead. If a pointer is constant, its slice becomes
/// constant. `Entity` becomes `[]const EntityIndex`.
pub fn Slices(types: []const type) type {
    comptime var fields: [types.len]std.builtin.Type.StructField = undefined;
    inline for (&fields, types, 0..) |*field, T, i| {
        const Slice = b: {
            if (T == Entity) break :b []const EntityIndex;

            const Ptr = switch (@typeInfo(T)) {
                .optional => |optional| optional.child,
                .pointer => T,
                else => comptime unreachable,
            };
            const Child = @typeInfo(Ptr).pointer.child;
            const Slice = if (@typeInfo(Ptr).pointer.is_const) []const Child else []Child;
            break :b if (@typeInfo(T) == .optional) ?Slice else Slice;
        };
        field.* = .{
            .name = std.fmt.comptimePrint("{}", .{i}),
            .type = Slice,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(Slice),
        };
    }
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = true,
    } });
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
