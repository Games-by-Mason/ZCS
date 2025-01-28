/// An unspecified but unique value per type.
pub const TypeId = *const struct { size: usize, alignment: u8 };

/// Returns the type ID of the given type.
pub inline fn typeId(comptime T: type) TypeId {
    return &struct {
        var id: @typeInfo(TypeId).pointer.child = .{
            .size = @sizeOf(T),
            .alignment = @alignOf(T),
        };
    }.id;
}
