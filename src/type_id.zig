/// An unspecified but unique value per type.
pub const TypeId = *const struct { _: u8 };

/// Returns the type ID of the given type.
pub inline fn typeId(comptime T: type) TypeId {
    return &struct {
        comptime {
            _ = T;
        }
        var id: @typeInfo(TypeId).pointer.child = undefined;
    }.id;
}
