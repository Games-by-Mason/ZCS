# ZCS

An archetype based entity component system written in Zig.

# Status

ZCS is beta software. Once I've shipped a commercial game using ZCS, I'll start to stabilize the API and no longer consider it a beta.

# Key Features

## Persistent Keys

Games often feature objects whose lifetimes depend on user input.

ZCS features persistent keys for entities, so they're never dangling even after being destroyed:

```zig
assert(fireball.exists(es));
assert(fireball.get(es, Sprite) != null);

fireball.destroyImmediately(es);

assert(!fireball.exists(es));
assert(fireball.get(es, Sprite) == null);
```

## Archetype Based Iteration

Games often feature behavior that is conditional on the runtime properties of objects.

Archetype based iteration allows you to conveniently process only entities that match a given query.

```zig
var iter = es.iterator(struct {
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
var cb = try CmdBuf.init(gpa, &es, 1000);
defer cb.deinit(gpa, &es);

// Get the next reserved entity. By reserving entities up front, the command buffer allows you to
// create entities on background threads safely.
const e = Entity.reserve(&cb);

// Schedule an archetype change for the reserved entity, this will assign it storage when the
// command buffer executes.
e.add(&cb, RigidBody, .{ .mass = 20 });
e.add(&cb, Sprite, .{ .index = .cat });

// Execute the command buffer, and then clear it for reuse. This would be done from the main thread.
cb.execImmediate(&es);
cb.clear(&es);
```

`execImmediate` only exercises ZCS's public interface. You can implement extensions to the command buffer by iterating it and executing it yourself.

## Command Buffer Iteration

It's common for game systems to need to do work when objects are created or destroyed. For example, you may need to make adjustments to parent child relationships in a scene graph when an object is deleted.

This use case is often served via callbacks, but callbacks have some major downsides:
* They're hard to write, the caller needs a clear understanding of the context in which the callback will run, and if multiple are present on the same event, they need to understand the order
* They're hard to debug, because control flow is taken away from the caller
* They're hard to optimize, they're run one at a time not in batch

Instead, since all work is typically done via command buffers, this use case is served much more simply via command buffer iterators:

```zig
fn updateTransforms(es: *const Entities, cb: *const CmdBuf) {
    for (cb.destroy.items) |entity| {
        // Process each entity scheduled for destruction
    }

    var iter = cb.arch_changes.iterator(es);
    while (iter.next()) |change| {
        // Process each archetype change
    }
}
```

## Generics

Most ECS implementations use some form of generics to provide a friendly interface. ZCS is no exception, and Zig makes this easier than ever.

However, when important types become generic, it infects the whole code base--everything that needs to interact with the ECS also needs to become generic, or at least depend on an instantiation of a generic type. This makes it hard to write modular/library code, and presumably will hurt incremental compile times in the near future.

As such, while ZCS will use generic methods where it's convenient, types at API boundaries are typically not generic. For example, `Entities` which stores all the ECS data is not a generic type:
```zig
var es: Entities = try .init(gpa, .{ .max_entities = 10000, .comp_bytes = 8192 });
defer es.deinit(gpa);
```

## Extensions

Two extensions are supplied. These only rely on the public interface of ZCS an can be ignored if you don't need them, but are demonstrations of the flexibility of the API.

### Node

`Node` allows for linking objects to other objects in parent child relationships:
```zig
cb.ext(Node.SetParent, .{ .child = thruster, .parent = ship.toOptional() });

// ...

var children = ship.get(Node).?.childrenIterator();
while (children.next()) |child| {
    // Do something with the child object
}

var parent = thruster.get(Node).?.parent;
// Do something with the parent
```

There is no maximum child count, and adding children does *not* require allocating an array. This is possible because node has links to:
* parent
* first_child
* prev_sib
* next_sib

This is an implementation detail, you do not need to keep these values in sync. You just need to either call this helper to execute your command buffer with awareness of `Node`:
```zig
Node.Exec.immediate(&fz.es, cb);
```

Or to look at the documentation of this method to see how to integrate it with your own command buffer executor.

### Transform2D

`Transform2D` represents the position and orientation of an entity in 2D space. If an entity also has a `Node`, its local space is relative to that of its parent if any.

```zig
vw.transform.move(es, cb, vw.rb.vel.scaled(delta_s));
vw.transform.rotate(es, cb, .fromAngle(vw.rb.rotation_vel * delta_s));
```

World positions are always from the last sync. To synchronize all world positions, you can call sync all:
```zig
Transform.syncAllImmediate(&es);
```

Sync all will only visit dirty entities and their children. This is possible by using ZCS as an event system. Entities that have not been moved since the last sync don't affect the performance of the sync.

Similarly to `Node`, `Transform2D` integrates with the command buffer to automatically handle parents changing, etc.

`Transform2D` depends on [geom](https://github.com/games-by-Mason/geom) for math.

# Performance & Memory Layout

ZCS is archetype based.

An "archetype" is a unique set of component types--for example, all entities that have both a `RigidBody` and a `Mesh` component share an archetype, whereas an entity that contains a `RigidBody` a `Mesh` and a `MonsterAi` has a different archetype.

Archetypes are packed tightly in memory with their components laid out `AAABBBCCC` to minimize padding, and an acceleration structure makes finding all entities matching a given archetype.

Comparing performance with something like `MultiArrayList`:
* Iterating over all data results in nearly identical performance
* Iterating over only data that contains supersets of a given archetype is nearly equivalent to iterating a `MultiArrayList` that only contains the desired data
* Inserting and removing are slightly more expensive as more bookkeeping is involved, but both operations are still O(1)
    * This book keeping allows for the aforementioned acceleration, and also for persistent handles

# Examples & Documentation

You can generate documentation with `zig build docs`.

This library is very new, and as such there are not high quality examples yet. You may be able to find some example code in [2Pew](https://github.com/MasonRemaley/2Pew/tree/zcs) which I'm porting to use this library, but it's currently incomplete.
