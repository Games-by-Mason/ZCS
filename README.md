# ZCS

An archetype based entity component system written in Zig.

# Status

ZCS is beta software. Once I've shipped a commercial game using ZCS, I'll start to stabilize the API and remove this disclaimer.

If at the time of reading you're not seeing any recent commits, this project isn't dead--I'm just working on a game!

# Key Features

## Persistent Keys

Games often feature objects with very dynamic lifetimes.

ZCS features persistent keys for entities, so they're never dangling:

```zig
assert(fireball.exists(es));
assert(fireball.get(es, Sprite) != null);

fireball.destroyImmediately(es);

assert(!fireball.exists(es));
assert(fireball.get(es, Sprite) == null);
```

## Archetype Based Iteration

Games often feature cross cutting concerns. Archetype based iteration allows you to conveniently and efficiently process entities with a given set of components:

```zig
var iter = es.iterator(struct {
    mesh: *const Mesh,
    transform: *const Transform,
    effect: ?*const Effect,
});
while (iter.next()) |vw| {
    vw.mesh.render(vw.transform, vw.effect);
}
```

The following syntax sugar is also provided, where the string is used as the name of a Tracy zone if Tracy is enabled:
```zig
fn updateMeshWithEffect(
    ctx: void,
    mesh: *const Mesh,
    transform: *const Transform,
    effect: ?*const Effect,
) void {
    // ...
}

es.forEach("updateMeshWithEffect", updateMeshWithEffect, {});
```

*Lower level iterators for operating on chunks of contiguous entities instead of individual entities are also provided.*

## Optional Thread Pool Integration

Games sometimes feature expensive game logic. If you're already making use of `std.Thread.Pool`, you can operate on your chunks in parallel with `forEachThreaded`:

```zig
es.forEachThreaded("updateTurret", updateTurret, .{
    .game = game,
    .cb = cb,
    .delta_s = delta_s,
});
```

*The name string is used in debug builds for profiling, and otherwise ignored.*

*If you prefer a different threading model, the primitives necessary to wire up ZCS to your threading model of choice are exposed by the API.*

## Command Buffers

Games often want to make sweeping, destructive changes to the game state while processing a frame. These changes are allowed while iterating, including in a multithreaded context, via command buffers.

```zig

// Allocate a command buffer
var cb: CmdBuf = try .init(.{ .gpa = gpa, .es = &es });
defer cb.deinit(allocator, &es);

// Get the next reserved entity. By reserving entities up front, the command buffer allows you to
// create entities on background threads safely.
const e = Entity.reserve(&cb);

// Schedule an archetype change for the reserved entity, this will assign it storage when the
// command buffer executes.
e.add(&cb, RigidBody, .{ .mass = 20 });
e.add(&cb, Sprite, .{ .index = .cat });

// Execute the command buffer, and then clear it for reuse. This would be done from the main thread.
CmdBuf.Exec.immediate(&es);
```

## Command Buffer Extensions

Games often feature entities that form relationships. Operations like destroying an entity may have side effects on other entities.

Command buffers support extension commands, and iteration via the public API. This allows your game to interpret operations like entity destruction in game specific ways, and to add new commands.


### Node

`Node` allows for linking objects to other objects in parent child relationships:
```zig
cb.ext(Node.SetParent, .{ .child = thruster, .parent = ship.toOptional() });

// ...

var children = ship.get(Node).?.childIterator();
while (children.next()) |child| {
    // Do something with the child object
}

var parent = thruster.get(Node).?.parent;
// Do something with the parent
```

There is no maximum child count, and adding children does *not* require allocating an array. This is possible because node has links to:
* `parent`
* `first_child`
* `prev_sib`
* `next_sib`

This is an implementation detail, you do not need to keep these values in sync. You just need to either call this helper to execute your command buffer with awareness of `Node`:
```zig
Node.Exec.immediate(&fz.es, cb);
```

Or to look at the documentation of this method to see how to integrate it with your own command buffer executor.

### Transform2D

`Transform2D` represents the position and orientation of an entity in 2D space. If an entity also has a `Node` and `relative` is `true`, its local space is relative to that of its parent if any.

```zig
vw.transform.move(es, vw.rb.vel.scaled(delta_s));
vw.transform.rotate(es, .fromAngle(vw.rb.rotation_vel * delta_s));
```

Transform children are immediately synchronized by these helpers, but you can defer synchronization until a later point by bypassing the helpers and then later calling `transform.sync(es)`.

`Transform2D` depends on [geom](https://github.com/games-by-Mason/geom) for math.

*It's possible to implement a multithreaded transform sync in ZCS, in fact early prototypes worked this way. However, for typical usage, it's easily 100x more costly to read this data into the cache on the background thread than it is to just do the matrix multiply immediately.*

## Tracy Integration

Buffering commands is a convenient way to mutate data while iterating or from multiple threads, but it can make profiling challenging.

ZCS integrates with [Tracy](https://github.com/wolfpld/tracy) via [tracy_zig](https://github.com/Games-by-Mason/tracy_zig/). ZCS shouldn't be your bottleneck, but with this integration you can be sure of it--and you can track down where the bottleneck is.

## Generics

Most ECS implementations use some form of generics to provide a friendly interface. ZCS is no exception, and Zig makes this easier than ever.

However, when important types become generic, it infects the whole code base--everything that needs to interact with the ECS also needs to become generic, or at least depend on an instantiation of a generic type. This makes it hard to write modular/library code, and presumably will hurt incremental compile times in the near future.

As such, while ZCS will use generic methods where it's convenient, types at API boundaries are typically not generic. For example, `Entities` which stores all the ECS data is not a generic type.

# Performance & Memory Layout

ZCS is archetype based.

An "archetype" is a unique set of component types--for example, all entities that have both a `RigidBody` and a `Mesh` component share an archetype, whereas an entity that contains a `RigidBody` a `Mesh` and a `MonsterAi` has a different archetype.

Archetypes are packed tightly in memory with their components laid out `AAABBBCCC` to minimize padding, and an acceleration structure makes finding all entities matching a given archetype.

Comparing performance with something like `MultiArrayList`:
* Iterating over all data results in nearly identical performance
* Iterating over only data that contains supersets of a given archetype is nearly equivalent to iterating a `MultiArrayList` that only contains the desired data
* Inserting and removing entities is O(1), but more expensive than appending/popping from a `std.MultiArrayList` since more bookkeeping is involved for the aforementioned acceleration and persistent handles
* Random access is O(1), but more expensive than random access to `std.MultiArrayList` as the persistent handles introduce a layer of indirection

No dynamic allocation is done after initialization. I recommend using `std.cleanExit` to avoid unnecessary clean up in release mode.

# Examples & Documentation

You can generate documentation with `zig build docs`.

I'll add examples to this repo [eventually](https://github.com/Games-by-Mason/ZCS/issues/34), for now see [2Pew](https://github.com/MasonRemaley/2Pew/tree/zcs).

# Contributing

Contributions are welcome! If you'd like to add a major feature, please file a proposal or leave a comment on the relevant issue first.
