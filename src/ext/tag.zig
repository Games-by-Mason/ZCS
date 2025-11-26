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
pub const Tag = struct {
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
                if (self.eql(tag.*)) {
                    return ancestor.entity.toOptional();
                }
            }
        }
        return .none;
    }

    /// Returns true if the given entity matches this tag.
    pub fn matches(self: @This(), es: *const Entities, entity: Entity) bool {
        const tag = entity.get(es, Tag) orelse return false;
        return self.eql(tag.*);
    }

    /// Returns true if the tags match.
    ///
    /// Don't get tempted to sidestep this by changing this type to be a packed struct, see the
    /// discussion [here](https://github.com/ziglang/zig/issues/26044).
    pub fn eql(lhs: @This(), rhs: @This()) bool {
        return lhs.id == rhs.id;
    }
};
