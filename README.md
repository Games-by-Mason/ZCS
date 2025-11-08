# ZCS

An archetype based entity component system written in Zig.

# Zig Version

[`main`](https://github.com/Games-by-Mason/zcs/tree/main) loosely tracks Zig master. For support for previous Zig versions, see [releases](https://github.com/Games-by-Mason/ZCS/releases).

# Status

ZCS is beta software. Once I've shipped a commercial game using ZCS, I'll start to stabilize the API and remove this disclaimer.

If there are no recent commits at the time you're reading this, the project isn't dead--I'm just working on a game!

# Getting Started & Documentation

Here's a quick look at what code using ZCS looks like:

```zig
const std = @import("std");
const zcs = @import("zcs");

const Entities = zcs.Entities;
const Entity = zcs.Entity;
const CmdBuf = zcs.CmdBuf;
const Transform = zcs.ext.Transform2;
const Node = zcs.ext.Node;

pub fn main() !void {
    // Reserve space for the game objects and for a command buffer.
    // ZCS doesn't allocate any memory after initialization, but you
    // can change the default capacities here if you like--or leave
    // them at their defaults as in this example. If you ever exceed
    // 20% capacity you'll get a warning by default.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var es: Entities = try .init(.{ .gpa = gpa.allocator() });
    defer es.deinit(gpa.allocator());

    var cb = try CmdBuf.init(.{
        .name = "cb",
        .gpa = gpa.allocator(),
        .es = &es,
    });
    defer cb.deinit(gpa.allocator(), &es);

    // Create an entity and associate some component data with it.
    // We could do this directly, but instead we're demonstrating the
    // command buffer API.
    const e: Entity = .reserve(&cb);
    e.add(&cb, Transform, .{});
    e.add(&cb, Node, .{});

    // Execute the command buffer
    // We're using a helper from the `transform` extension here instead of
    // executing it directly. This is part of ZCS's support for command
    // buffer extensions, we'll touch more on this later.
    Transform.Exec.immediate(&es, &cb);

    // Iterate over entities that contain both transform and node
    var iter = es.iterator(struct {
        transform: *Transform,
        node: *Node,
    });
    while (iter.next(&es)) |vw| {
        // You can operate on `vw.transform.*` and `vw.node.*` here!
        std.debug.print("transform: {any}\n", .{vw.transform.pos});
    }
}
```

Full documentation available [here](https://docs.gamesbymason.com/zcs/), you can generate up to date docs yourself with `zig build docs`.

I'll add example projects to the repo as soon as I've set up a renderer that's easy to build without requiring various system libraries be installed etc, tracking issue [here](https://github.com/Games-by-Mason/ZCS/issues/34).

For now, you're welcome to reference [2Pew](https://github.com/MasonRemaley/2Pew/). Just keep in mind that 2Pew is a side project I don't have a lot of time for right now, it's a decent reference but not a full game.

# Philosophy

An entity component system (or "ECS") is a way to manage your game objects that often resembles a relational database.

An entity is an object in your game, a component is a piece of data that's associated with an entity (for example a sprite), and a system is a piece of code that iterates over entities with a set of components and processes them.

A simple alternative to working with an ECS would be something like [`std.MultiArrayList`](https://ziglang.org/documentation/master/std/#std.MultiArrayList); a growable struct of arrays.

A well implemented ECS is more complex than `MultiArrayList`, but that complexity buys you a lot of convenience. Performance will be comparable.

For a discussion of what features are provided by this ECS see [Key Features](#Key-Features), for performance information see [Performance](#Performance), and for further elaboration on my philosophy on game engines and abstraction see my talk [It's Not About The Technology - Game Engines are Art Tools](https://gamesbymason.com/blog/2023/game-engines-are-art-tools/).

# Key Features

## Persistent Keys

Games often feature objects whose lifetimes are not only dynamic, but depend on user input. ZCS provides persistent keys for entities, so they're never dangling:

```zig
assert(laser.exists(es));
assert(laser.get(es, Sprite) != null);

laser.destroyImmediately(es);

assert(!laser.exists(es));
assert(laser.get(es, Sprite) == null);
```

This is achieved through a 32 bit generation counter on each entity slot. Slots are retired when their generations are saturated to prevent false negatives, see [SlotMap](https://github.com/Games-by-Mason/SlotMap) for more info.

This strategy allows you to safely and easily store entity handles across frames or in component data.

For all allowed operations on an entity handle, see [`Entity`](https://docs.gamesbymason.com/zcs/#zcs.entity.Entity).

## Archetype Based Iteration

Gameplay systems often end up coupled not due to bad coding practice, but because these interdependencies often lead to dynamic and interesting gameplay.

Archetype based iteration via [`Entities.iterator`](https://docs.gamesbymason.com/zcs/#zcs.Entities.iterator) allows you to efficiently query for entities with a given set of components. This can be a convenient way to express this kind of coupling:

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

If you prefer, [`forEach`](https://docs.gamesbymason.com/zcs/#zcs.Entities.forEach) syntax sugar is also provided. The string argument is only used if Tracy is enabled:
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

[`Entities.chunkIterator`](https://docs.gamesbymason.com/zcs/#zcs.Entities.chunkIterator) is also provided for iterating over contiguous chunks of component data instead of individual entities. This can be useful e.g. to optimize your systems with SIMD.

### Optional Thread Pool Integration

If you're already making use of [`std.Thread.Pool`](https://ziglang.org/documentation/master/std/#std.Thread.Pool), you can operate on your chunks in parallel with [`forEachThreaded`](https://docs.gamesbymason.com/zcs/#zcs.Entities.forEachThreaded).

Have your own job system? No problem. [`forEachThreaded`](https://docs.gamesbymason.com/zcs/#zcs.Entities.forEachThreaded) is implemented on top of ZCS's public interface, wiring it up to your own threading model won't require a fork.

## Command Buffers

Games often want to make destructive changes to the game state while processing a frame.

Command buffers allow you to make destructive changes without invalidating iterators, including in a multithreaded context.

```zig
// Allocate a command buffer
var cb: CmdBuf = try .init(.{ .gpa = gpa, .es = &es });
defer cb.deinit(allocator, &es);

// Get the next reserved entity. By reserving entities up front, the
// command buffer allows you to create entities from background threads
// without contention.
const e = Entity.reserve(&cb);

// Schedule an archetype change for the reserved entity, this will
// assign it storage when the command buffer executes. If the component
// is comptime known and larger than pointer sized, it will
// automatically be stored by pointer instead of by value.
e.add(&cb, RigidBody, .{ .mass = 20 });
e.add(&cb, Sprite, .{ .index = .cat });

// Execute the command buffer, and then clear it for reuse. This would
// be done from the main thread.
CmdBuf.Exec.immediate(&es, &cb);
```

For more information, see [`CmdBuf`](https://docs.gamesbymason.com/zcs/#zcs.CmdBuf).

When working with multiple threads, you'll likely want to use [`CmdPool`](https://docs.gamesbymason.com/zcs/#zcs.CmdPool) to manage your command buffer allocations instead of creating them directly. This will allocate a large number of smaller command buffers, and hand them out on a per chunk basis.

This saves you from needing to adjust the number of command buffers you allocate or their capacities based on core count or workload distribution.

If you need to bypass the command buffer system and make changes directly, you can. Invalidating an iterator while it's in use due to having bypassed the command buffer system is safety checked illegal behavior.

## Command Buffer Extensions

Entities often have relationships to one another. As such, operations like destroying an entity may have side effects on other entities. In ZCS this is achieved through command buffer extensions.

The key idea is that external code can add [extension commands](https://docs.gamesbymason.com/zcs/#zcs.CmdBuf.ext) with arbitrary payloads to the command buffer, and then later [iterate the command buffer](https://docs.gamesbymason.com/zcs/#zcs.CmdBuf.iterator) to execute those commands or react to the standard ones.

This allows extending the behavior of the command buffer executor without callbacks. This is important because the order of operation between various extensions and the default behavior is often important and very difficult to manage in a callback based system.

To avoid iterating the same command buffer multiple times--and to allow extension commands to change the behavior of the built in commands--you're expected to compose extension code with the default execution functions provided under [`CmdBuf.Exec`](https://docs.gamesbymason.com/zcs/#zcs.CmdBuf.Exec).

As an example of this pattern, [`zcs.ext`](https://docs.gamesbymason.com/zcs/#zcs.ext) provides a number of useful components and command buffer extensions that rely only on ZCS's public API...


### Node

The [`Node`](https://docs.gamesbymason.com/zcs/#zcs.ext.Node) component allows for linking objects to other objects in parent child relationships. You can modify these relationships directly, or via command buffers:

```zig
cb.ext(Node.SetParent, .{
    .child = thruster,
    .parent = ship.toOptional(),
});
```

Helper methods are provided to query parents, iterate children, etc:

```zig
var children = ship.get(Node).?.childIterator();
while (children.next()) |child| {
    // Do something with `child`
}

if (thruster.get(Node).?.parent.get(&es)) |parent| {
    // Do something with `parent`
}
```

*The full list of supported features can be found in [the docs](https://docs.gamesbymason.com/zcs/#zcs.ext.Node).*

Node doesn't have a maximum child count, and adding children does not allocate an array. This is possible because each node has the following fields:
* `parent`
* `first_child`
* `prev_sib`
* `next_sib`


Deletion of child objects, cycle prevention, etc are all handled for you. You just need to use the provided helpers or command buffer extension command for setting the parent, and to call into [`Node.Exec.immediate`](https://docs.gamesbymason.com/zcs/#zcs.ext.Node.Exec.immediate) to execute your command buffer:
```zig
Node.Exec.immediate(&es, &cb);
```

Keep in mind that this will call the default exec behavior as well as implement the extended behavior provided by `Node`. If you're also integrating other unrelated extensions, a lower level composable API is provided in [`Node.Exec`](https://docs.gamesbymason.com/zcs/#zcs.ext.Node.Exec) for building your own executor.

### Transform

A few transform variations are provided:
* [`Transform2`](https://docs.gamesbymason.com/zcs/#zcs.ext.Transform2)
* [`Transform2Ordered`](https://docs.gamesbymason.com/zcs/#zcs.ext.Transform2Ordered)
* [`Transform3`](https://docs.gamesbymason.com/zcs/#zcs.ext.Transform3)
* [`Transform3Ordered`](https://docs.gamesbymason.com/zcs/#zcs.ext.Transform3)

A transform component represents the position and orientation of an entity in space. If an entity also has a [`Node`](https://docs.gamesbymason.com/zcs/#zcs.ext.Node) and `relative` is `true`, its local space is relative to that of its parent.

```zig
vw.transform.move(es, vw.rb.vel.scaled(delta_s));
vw.transform.rotate(es, .fromAngle(vw.rb.rotation_vel * delta_s));
```

Transform children are immediately synchronized by these helpers, but you can defer synchronization until a later point by bypassing the helpers and then later calling `transform.sync(es)`.

The ordered variants also expose an `order` field of type `f32`. This field is unused internally, but may be set by users to store sort order, e.g. to break depth ties when using painter's algorithm. This is often preferable over breaking ties by offsetting layers along the Z axis as it prevents visual issues where intersecting objects can have some but not all layers occluded.

Transform depends on [geom](https://github.com/games-by-Mason/geom) for math.

### ZoneCmd

Deferred work can be hard to profile. As such, ZCS provides an extension [`ZoneCmd`](https://docs.gamesbymason.com/zcs/#zcs.ext.ZoneCmd) that allows you to start and end Tracy zones from within a command buffer:
```zig
const exec_zone = ZoneCmd.begin(&cb, .{
    .src = @src(),
    .name = "zombie pathfinding",
});
defer exec_zone.end(&cb);
```

## Tracy Integration

ZCS integrates with [Tracy](https://github.com/wolfpld/tracy) via [tracy_zig](https://github.com/Games-by-Mason/tracy_zig/). ZCS shouldn't be your bottleneck, but with this integration you can be sure of it--and you can track down where the bottleneck is.

In particular, ZCS...
* Emits its own Tracy Zones
* Supports attaching zones to sections of command buffers via the [`ZoneCmd`](https://docs.gamesbymason.com/zcs/#zcs.ext.ZoneCmd) extension
* Emits plots to Tracy, including information on command buffer utilization

## Generics

Most ECS implementations use some form of generics to provide a friendly interface. ZCS is no exception, and Zig makes this easier than ever.

However, when important types become generic, it infects the whole code base--everything that needs to interact with the ECS also needs to become generic, or at least depend on an instantiation of a generic type. This makes it hard to write modular/library code, and presumably will hurt incremental compile times in the near future.

As such, while ZCS uses generic methods where it's convenient, types at API boundaries are typically not generic. For example, [`Entities`](https://docs.gamesbymason.com/zcs/#zcs.Entities) which stores all the ECS data is not a generic type, and libraries are free to add new component types to entities without an explicit registration step.

# Performance

ZCS is archetype based.

An "archetype" is a unique set of component types--for example, all entities that have both a `RigidBody` and a `Mesh` component share an archetype, whereas an entity that contains a `RigidBody` a `Mesh` and a `MonsterAi` has a different archetype.

Archetypes are packed tightly in memory into [chunks](https://docs.gamesbymason.com/zcs/#zcs.chunk.Chunk) with the following layout:
1. Chunk header
2. Entity indices
3. Component data

Component data is laid out in `AAABBBCCC` order within the chunk, sorted from greatest to least alignment requirements to minimize padding. Chunks size is configurable but must be a power of two, in practice this results in chunk sizes that are a multiple of the cache line size which prevents false sharing when operating on chunks in parallel.

A simple [acceleration structure](https://docs.gamesbymason.com/zcs/#zcs.Arches) is provided to make finding all chunks compatible with a given archetype efficient.

Comparing performance with something like [`MultiArrayList`](https://ziglang.org/documentation/master/std/#std.MultiArrayList):
* Iterating over all data results in nearly identical performance
* Iterating over only data that contains supersets of a given archetype is nearly identical to if the [`MultiArrayList`](https://ziglang.org/documentation/master/std/#std.MultiArrayList) was somehow preprocessed to remove all the undesired results and then tightly packed before starting the timer
* Inserting and removing entities is O(1), but more expensive than appending/popping from a [`MultiArrayList`](https://ziglang.org/documentation/master/std/#std.MultiArrayList) or leaving a hole in it since more bookkeeping is involved for the aforementioned acceleration and persistent handles
* Random access is O(1), but more expensive than random access to a [`MultiArrayList`](https://ziglang.org/documentation/master/std/#std.MultiArrayList) as the persistent handles introduce a layer of indirection

No dynamic allocation is done after initialization.

# Contributing

Contributions are welcome! If you'd like to add a major feature, please file a proposal or leave a comment on the relevant issue first.
