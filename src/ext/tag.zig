const zcs = @import("../root.zig");
const typeId = zcs.typeId;
const TypeId = zcs.TypeId;
const Entities = zcs.Entities;
const Entity = zcs.Entity;
const Node = zcs.ext.Node;

/// A component for storing the type of an entity.
///
/// A simpler way to achieve this would be to store a zero sized struct as a component identifying
/// the entity's type. This works, but leads to needless fragmentation.
///
/// This fragmentation could be avoided with an enum, but enums aren't open to extension, so
/// dependencies would need their own type enums, leading to needless fragmentation again.
///
/// Instead, this tag component tags entities with a type ID. This solves both the extension and the
/// fragmentation issue.
pub const Tag = packed struct {
    id: TypeId,

    /// Initializes a tag from a type, most often an empty struct.
    pub fn init(T: type) @This() {
        return .{ .id = typeId(T) };
    }

    /// Returns the nearest ancestor of `node` containing this tag, or `none` if there is none.
    pub fn findAncestorOf(self: @This(), es: *const Entities, node: *Node) Entity.Optional {
        var ancestors = node.ancestorIterator();
        while (ancestors.next(es)) |ancestor| {
            if (ancestor.entity.get(es, Tag)) |tag| {
                if (tag.* == self) {
                    return ancestor.entity.toOptional();
                }
            }
        }
        return .none;
    }
};
