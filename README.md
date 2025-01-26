# ZCS

An entity component system written in Zig.

# Status

Functional, but not yet performant. Check back soon.

Components are currently stored as a struct of arrays. This is simple, and allows me to validate the interface and test suite.

I'm currently migrating [2Pew](https://github.com/masonRemaley/2pew). If I'm still happy with the API when this is done, I'll replace the simple SoA backend with a memory layout that indexes on archetype.

Indexing on archetype will allow iterating scenes with millions of entities, and skipping everything that doesn't match the given archetype query for free. Once this is implemented, I'll remove the "not yet performant" warning.

# Key Features

## Persistent Keys

Games often feature objects whose lifetimes depend on user input.

ZCS features persistent keys for entities, so they're never dangling even after being destroyed:

```zig
assert(fireball.exists(es));
assert(fireball.getComponent(es, Sprite) != null);

fireball.destroyImmediately(es);

assert(!fireball.exists(es));
assert(fireball.getComponent(es, Sprite) == null);
```

## Archetype Based Iteration

Games often feature behavior that is conditional on the runtime properties of objects.

Archetype based iteration allows you to conveniently process only entities that match a given query.

```zig
var iter = es.viewIterator(struct {
    mesh: *const Mesh,
    transform: *const Transform,
    effects: ?*const Effects,
});
while (iter.next()) |vw| {
    vw.mesh.render(vw.transform, vw.effects);
}
```

## Command Buffers

Taking advantage of modern hardware requires utilizing multiple cores, but this is challenging when object lifetimes are dynamic and dependent on user input.

By doing destructive operations through command buffers, you can efficiently queue up work on multiple threads simultaneously in a safe manner. You can also do this on a single thread while iterating to avoid invalidating your iterator.

```zig

// Allocate a command buffer
var cmds = try CmdBuf.init(gpa, &es, 1000);
defer cmds.deinit(gpa, &es);

// Get the next reserved entity. By reserving entities up front, the command buffer allows you to
// create entities on background threads safely.
const e = Entity.nextReserved(&cmds);

// Schedule an archetype change for the reserved entity, this will assign it storage when the
// command buffer executes.
e.changeArchetypeCmd(&es, &cmds, .{
    .add = .{
        RigidBody { .mass = 20 },
        Sprite { .index = .cat },
    },
});

// Execute the command buffer, and then clear it for reuse. This would be done from the main thread.
cmds.execute(&es);
cmds.clear(&es);
```

## Command Buffer Iteration

It's common for game systems to need to do work when objects are created or destroyed. For example, you may need to make adjustments to parent child relationships in a scene graph when an object is deleted.

This use case is often served via callbacks, but callbacks have some major downsides:
* They're hard to write, the caller needs a clear understanding of the context in which the callback will run, and if multiple are present on the same event, they need to understand the order
* They're hard to debug, because control flow is taken away from the caller
* They're hard to optimize, they're run one at a time not in batch

Instead, since all work is typically done via command buffers, this use case is served much more simply via command buffer iterators:

```zig
fn updateTransforms(es: *const Entities, cmds: *const CmdBuf) {
    for (cmds.destroy) |entity| {
        // Process each entity scheduled for destruction
    }

    var iter = cmds.change_archetype.iterator(es);
    while (iter.next()) |change_archetype| {
        // Process each archetype change
    }
}
```

## Generics

Most ECS implementations use some form of generics to provide a friendly interface. ZCS is no exception, and Zig makes this easier than ever.

However, when important types become generic, it infects the whole code base--everything that needs to interact with the ECS also needs to become generic, or at least depend on an instantiation of a generic type. This makes it hard to write modular/library code, and presumably will hurt incremental compile times in the near future.

As such, ZCS leans heavily on generic methods but errs against generic types at API boundaries. For example, while `Entities.init` is a generic method, `Entities` is not a generic type:
```zig
var es: Entities = try .init(gpa, 1000, &.{ RigidBody, Mesh });
defer es.deinit(gpa);
```

# Examples & Documentation

You can generate documentation with `zig build docs`.

This library is very new, and as such there are not high quality examples yet. You may be able to find some example code on the branch where I'm porting [2Pew](https://github.com/MasonRemaley/2Pew/tree/zcs) to use this library, but it's currently incomplete.
