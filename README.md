# ZCS

An entity component system written in Zig.

# Status

Functional, but not yet performant. Check back soon.

Components are currently stored as a struct of arrays. This is simple, and allows me to validate the interface and test suite.

I'm currently migrating [2Pew](https://github.com/masonRemaley/2pew). If I'm still happy with the API when this is done, I'll replace the simple SoA backend with a memory layout that indexes on archetype.

Indexing on archetype will allow iterating scenes with millions of entities, and skipping everything that doesn't match the given archetype query for free. Once this is implemented, I'll remove the "not yet performant" warning.

# Key Features

## Persistent Keys
Games often feature objects whose lifetimes depend on user input. Entities with persistent keys are never dangling, even after they're destroyed.

## Archetype Based Iteration
Archetype based iteration lets you conveniently process only the entities of interest.

## Command buffers
Taking advantage of modern hardware requires utilizing multiple cores. Command buffers allow you to efficiently queue up destructive ECS modifications for later execution from multiple threads, while iterating, without invalidating your iterators.

Since keys are persistent, doing this safely is trivial.

# Examples

```zig
var es: Entities = try .init(&gpa, 100, &.{RigidBody, Mesh, Fire, Hammer});
defer es.deinit(gpa);

const e = Entity.create(.{RigidBody { .mass = 0.5 }, Mesh { .vertices = player });
const mesh = e.getComponent(Mesh).?;

var iter = es.viewIterator(struct {rb: RigidBody, mesh: Mesh});
while (iter.next()) |entity| {
    std.debug.print("mesh: {}\n", .{entity.mesh});
}

// ...

var cb = try CommandBuffer.init(gpa, &es, 4);
defer cb.deinit(gpa);

cb.create(&es, .{RigidBody { .mass = 0.5 }, Mesh { .model = player });
cb.destroy(e);
cb.changeArchetype(&es, e2, Component.flags(&es, &.{Fire}), .{ Hammer{} });

cb.submit(&es);
cb.clear();
```
