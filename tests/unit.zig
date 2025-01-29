//! Normal unit tests.

const std = @import("std");
const zcs = @import("zcs");
const assert = std.debug.assert;
const gpa = std.testing.allocator;
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;
const expectError = std.testing.expectError;

const Entities = zcs.Entities;
const Entity = zcs.Entity;
const CmdBuf = zcs.CmdBuf;
const Comp = zcs.Comp;

const RigidBody = struct {
    position: [2]f32 = .{ 1.0, 2.0 },
    velocity: [2]f32 = .{ 3.0, 4.0 },
    mass: f32 = 5.0,

    pub fn random(rand: std.Random) @This() {
        return .{
            .position = .{ rand.float(f32), rand.float(f32) },
            .velocity = .{ rand.float(f32), rand.float(f32) },
            .mass = rand.float(f32),
        };
    }

    pub fn randomOrNull(rand: std.Random) ?@This() {
        if (rand.boolean()) return null;
        return @This().random(rand);
    }
};

const Model = struct {
    vertex_start: u16 = 6,
    vertex_count: u16 = 7,

    pub fn random(rand: std.Random) @This() {
        return .{
            .vertex_start = rand.int(u16),
            .vertex_count = rand.int(u16),
        };
    }

    pub fn randomOrNull(rand: std.Random) ?@This() {
        if (rand.boolean()) return null;
        return @This().random(rand);
    }
};

/// A zero sized component type
pub const Tag = struct {
    pub fn random(rand: std.Random) @This() {
        _ = rand;
        return .{};
    }

    pub fn randomOrNull(rand: std.Random) ?@This() {
        if (rand.boolean()) return null;
        return @This().random(rand);
    }
};

const Components = struct {
    model: ?Model = null,
    rb: ?RigidBody = null,
    tag: ?Tag = null,
};

test "command buffer some test decode" {
    defer Comp.unregisterAll();

    var xoshiro_256: std.Random.Xoshiro256 = .init(0);
    const rand = xoshiro_256.random();

    var es = try Entities.init(gpa, 100);
    defer es.deinit(gpa);

    // Check some entity equality stuff not tested elsewhere, checked more extensively in slot map
    try expect(Entity.none.eql(.none));
    try expect(!Entity.none.exists(&es));

    // // Make sure we exercise the `toOptional` API and such
    // const comp: Comp = .init(&Tag{});
    // const comp_interned: Comp = .init(&Tag{});
    // XXX: ...
    // const comp_optional = comp.toOptional();
    // const comp_optional_interned = comp.toOptional();
    // try expect(!comp.interned);
    // try expect(!comp_interned.interned);
    // XXX: ...
    // try expectEqual(comp, comp_optional.unwrap().?);
    // try expectEqual(comp, comp_optional_interned.unwrap().?);

    var capacity: CmdBuf.GranularCapacity = .init(.{
        .cmds = 4,
        .comp_bytes = @sizeOf(RigidBody),
    });
    capacity.reserved = 0;
    var cmds = try CmdBuf.initGranularCapacity(gpa, &es, capacity);
    defer cmds.deinit(gpa, &es);

    try expectEqual(0, es.count());

    const e0 = Entity.reserveImmediately(&es);
    const e1 = Entity.reserveImmediately(&es);
    const e2 = Entity.reserveImmediately(&es);
    e0.commitCmd(&cmds);
    e1.commitCmd(&cmds);
    const rb = RigidBody.random(rand);
    const model = Model.random(rand);
    e2.addCompCmd(&cmds, RigidBody, rb);
    try expectEqual(3, es.reserved());
    try expectEqual(0, es.count());
    cmds.execute(&es);
    try expectEqual(0, es.reserved());
    try expectEqual(3, es.count());
    cmds.clear(&es);

    var iter = es.iterator(.{});

    try expect(iter.next().?.eql(e0));
    try expectEqual(null, e0.getComp(&es, RigidBody));
    try expectEqual(null, e0.getComp(&es, Model));
    try expectEqual(null, e0.getComp(&es, Tag));

    try expect(e1.eql(iter.next().?));
    try expectEqual(null, e1.getComp(&es, RigidBody));
    try expectEqual(null, e1.getComp(&es, Model));
    try expectEqual(null, e1.getComp(&es, Tag));

    try expect(e2.eql(iter.next().?));
    try expectEqual(rb, e2.getComp(&es, RigidBody).?.*);
    try expectEqual(null, e2.getComp(&es, Model));
    try expectEqual(null, e2.getComp(&es, Tag));

    try expectEqual(null, iter.next());

    // We don't check eql anywhere else, quickly check it here. The details are tested more
    // extensively on slot map.
    try expect(e1.eql(e1));
    try expect(!e1.eql(e2));
    try expect(!e1.eql(.none));

    e0.removeCompCmd(&cmds, RigidBody);
    e1.removeCompCmd(&cmds, RigidBody);
    e2.addCompCmd(&cmds, Model, model);
    e2.removeCompCmd(&cmds, RigidBody);
    cmds.execute(&es);
    cmds.clear(&es);

    try expectEqual(3, es.count());

    try expectEqual(null, e0.getComp(&es, RigidBody));
    try expectEqual(null, e0.getComp(&es, Model));
    try expectEqual(null, e0.getComp(&es, Tag));

    try expectEqual(null, e1.getComp(&es, RigidBody));
    try expectEqual(null, e1.getComp(&es, Model));
    try expectEqual(null, e1.getComp(&es, Tag));

    try expectEqual(null, e2.getComp(&es, RigidBody));
    try expectEqual(model, e2.getComp(&es, Model).?.*);
    try expectEqual(null, e2.getComp(&es, Tag));
}

// XXX: ...
// // Verify that fromComponents methods don't pass duplicate component data, this allows us to make
// // our capacity guarantees
// test "command buffer skip dups" {
//     defer Comp.unregisterAll();
//     var es = try Entities.init(gpa, 100);
//     defer es.deinit(gpa);

//     var cmds = try CmdBuf.init(gpa, &es, .{ .cmds = 24, .comp_bytes = @sizeOf(RigidBody) });
//     defer cmds.deinit(gpa, &es);

//     const model1: Model = .{
//         .vertex_start = 1,
//         .vertex_count = 2,
//     };
//     const model2: Model = .{
//         .vertex_start = 3,
//         .vertex_count = 4,
//     };

//     const e0: Entity = Entity.reserveImmediately(&es);

//     {
//         defer cmds.clear(&es);
//         e0.changeArchetypeCmdFromComponents(&es, &cmds, .{
//             .remove = Comp.flags(&.{}),
//             .add = &.{
//                 .init(&es, &model1),
//                 .init(&es, &RigidBody{}),
//                 .init(&es, &model2),
//                 .none,
//             },
//         });
//         var iter = cmds.change_archetype.iterator(&es);
//         const change_archetype = iter.next().?;
//         try expectEqual(
//             Comp.Flags{},
//             change_archetype.remove,
//         );
//         var comps = change_archetype.componentIterator();
//         const comp1 = comps.next().?;
//         try expect(!comp1.interned);
//         try expectEqual(model2, comp1.as(Model).?.*);
//         const comp2 = comps.next().?;
//         try expect(!comp2.interned);
//         try expectEqual(RigidBody{}, comp2.as(RigidBody).?.*);
//     }
// }

// XXX: ...
// // Verify that components are interned appropriately
// test "command buffer interning" {
//     defer Comp.unregisterAll();
//     // Assumed by this test (affects cmds submission order.) If this fails, just adjust the types to
//     // make it true and the rest of the test should pass.
//     comptime assert(@alignOf(RigidBody) > @alignOf(Model));
//     comptime assert(@alignOf(Model) > @alignOf(Tag));

//     var xoshiro_256: std.Random.Xoshiro256 = .init(0);
//     const rand = xoshiro_256.random();

//     var es = try Entities.init(gpa, 100);
//     defer es.deinit(gpa);

//     var cmds = try CmdBuf.init(gpa, &es, .{ .cmds = 24, .comp_bytes = @sizeOf(RigidBody) });
//     defer cmds.deinit(gpa, &es);

//     const rb_interned: RigidBody = .{
//         .position = .{ 0.5, 1.5 },
//         .velocity = .{ 2.5, 3.5 },
//         .mass = 4.5,
//     };
//     const rb_value = RigidBody.random(rand);
//     const model_interned: Model = .{
//         .vertex_start = 1,
//         .vertex_count = 2,
//     };
//     const model_value = Model.random(rand);

//     const e0: Entity = .reserveImmediately(&es);
//     const e1: Entity = .reserveImmediately(&es);

//     // Automatic interning
//     e0.addCompCmd(&cmds, Model, model_value);
//     e0.addCompCmd(&cmds, RigidBody, rb_interned);
//     e0.removeCompCmd(&cmds, Tag);

//     e1.addCompCmd(&cmds, Model, model_interned);
//     e1.addCompCmd(&cmds, RigidBody, rb_value);
//     e1.removeCompCmd(&cmds, Tag);

//     // Explicit by value
//     e0.addComponentByValueCmd(&cmds, Model, model_value);
//     e0.addComponentByValueCmd(&cmds, RigidBody, rb_interned);

//     e1.addComponentByValueCmd(&cmds, Model, model_interned);
//     e1.addComponentByValueCmd(&cmds, RigidBody, rb_value);
//     e1.removeCompCmd(&cmds, Tag);

//     // Explicit interning
//     e0.addComponentByPtrCmd(&cmds, RigidBody, rb_interned);
//     e0.addComponentByPtrCmd(&cmds, Model, model_interned);
//     e0.removeCompCmd(&cmds, Tag);

//     // Test the results
//     var iter = cmds.change_archetype.iterator(&es);

//     {
//         const cmd = iter.next().?;
//         try expectEqual(e0, cmd.entity);
//         try expectEqual(
//             Comp.flags(&.{Tag}),
//             cmd.remove,
//         );
//         // Components reordered due to alignment
//         var comps = cmd.componentIterator();
//         const comp1 = comps.next().?;
//         try expect(!comp1.interned);
//         try expectEqual(model_value, comp1.as(Model).?.*);
//         const comp2 = comps.next().?;
//         try expect(comp2.interned);
//         try expectEqual(rb_interned, comp2.as(RigidBody).?.*);
//         try expectEqual(null, comps.next());
//     }
//     {
//         const cmd = iter.next().?;
//         try expectEqual(e1, cmd.entity);
//         try expectEqual(
//             Comp.flags(&.{Tag}),
//             cmd.remove,
//         );
//         var comps = cmd.componentIterator();
//         const comp1 = comps.next().?;
//         try expect(!comp1.interned); // Not interned because it's too small!
//         try expectEqual(model_interned, comp1.as(Model).?.*);
//         const comp2 = comps.next().?;
//         try expect(!comp2.interned);
//         try expectEqual(rb_value, comp2.as(RigidBody).?.*);
//         try expectEqual(null, comps.next());
//     }
//     {
//         const cmd = iter.next().?;
//         try expectEqual(e0, cmd.entity);
//         try expectEqual(Comp.Flags{}, cmd.remove);
//         // Comps are encoded in reverse order by *fromComponents methods
//         var comps = cmd.componentIterator();
//         const comp1 = comps.next().?;
//         try expect(!comp1.interned);
//         try expectEqual(model_value, comp1.as(Model).?.*);
//         const comp2 = comps.next().?;
//         try expect(!comp2.interned);
//         try expectEqual(rb_interned, comp2.as(RigidBody).?.*);
//         try expectEqual(null, comps.next());
//     }
//     {
//         const cmd = iter.next().?;
//         try expectEqual(e1, cmd.entity);
//         try expectEqual(
//             Comp.flags(&.{Tag}),
//             cmd.remove,
//         );
//         var comps = cmd.componentIterator();
//         const comp1 = comps.next().?;
//         try expect(!comp1.interned);
//         try expectEqual(model_interned, comp1.as(Model).?.*);
//         const comp2 = comps.next().?;
//         try expect(!comp2.interned);
//         try expectEqual(rb_value, comp2.as(RigidBody).?.*);
//         try expectEqual(null, comps.next());
//     }
//     {
//         const cmd = iter.next().?;
//         try expectEqual(e0, cmd.entity);
//         try expectEqual(
//             Comp.flags(&.{Tag}),
//             cmd.remove,
//         );
//         var comps = cmd.componentIterator();
//         const comp1 = comps.next().?;
//         try expect(comp1.interned);
//         try expectEqual(rb_interned, comp1.as(RigidBody).?.*);
//         const comp2 = comps.next().?;
//         try expect(comp2.interned);
//         try expectEqual(model_interned, comp2.as(Model).?.*);
//         try expectEqual(null, comps.next());
//     }

//     try expectEqual(null, iter.next());
// }

// XXX: ...
// test "command buffer overflow" {
//     defer Comp.unregisterAll();
//     // Not very exhaustive, but checks that command buffers return the overflow error on failure to
//     // append, and on submits that fail.

//     var xoshiro_256: std.Random.Xoshiro256 = .init(0);
//     const rand = xoshiro_256.random();

//     var es = try Entities.init(gpa, 100);
//     defer es.deinit(gpa);

//     // Tag/destroy overflow
//     {
//         var cmds = try CmdBuf.initGranularCapacity(gpa, &es, .{
//             .tags = 0,
//             .args = 100,
//             .comp_bytes = 100,
//             .destroy = 0,
//             .reserved = 0,
//         });
//         defer cmds.deinit(gpa, &es);

//         try expectError(error.ZcsCmdBufOverflow, Entity.reserveImmediately(&es).commitCmdChecked(&es, &cmds, .{}));
//         try expectError(error.ZcsCmdBufOverflow, Entity.reserveImmediately(&es).destroyCmdChecked(&es, &cmds));

//         try expectEqual(1.0, cmds.worstCaseUsage());

//         var iter = cmds.change_archetype.iterator(&es);
//         try expectEqual(null, iter.next());
//     }

//     // Arg overflow
//     {
//         var cmds = try CmdBuf.initGranularCapacity(gpa, &es, .{
//             .tags = 100,
//             .args = 0,
//             .comp_bytes = 100,
//             .destroy = 100,
//             .reserved = 0,
//         });
//         defer cmds.deinit(gpa, &es);

//         try expectError(error.ZcsCmdBufOverflow, Entity.reserveImmediately(&es).changeArchetypeCmdChecked(
//             &es,
//             &cmds,
//             .{},
//         ));
//         const e = Entity.reserveImmediately(&es);
//         e.destroyCmd(&es, &cmds);

//         try expectEqual(1.0, cmds.worstCaseUsage());

//         try expectEqual(1, cmds.destroy.items.len);
//         try expectEqual(e, cmds.destroy.items[0]);
//         var iter = cmds.change_archetype.iterator(&es);
//         try expectEqual(null, iter.next());
//     }

//     // Comp data overflow
//     {
//         var cmds = try CmdBuf.initGranularCapacity(gpa, &es, .{
//             .tags = 100,
//             .args = 100,
//             .comp_bytes = @sizeOf(RigidBody) * 2 - 1,
//             .destroy = 100,
//             .reserved = 0,
//         });
//         defer cmds.deinit(gpa, &es);

//         const e: Entity = Entity.reserveImmediately(&es);
//         const rb = RigidBody.random(rand);

//         _ = Entity.reserveImmediately(&es).changeArchetypeCmd(&es, &cmds, .{ .add = .{rb} });
//         e.destroyCmd(&es, &cmds);
//         try expectError(error.ZcsCmdBufOverflow, e.changeArchetypeCmdChecked(
//             &es,
//             &cmds,
//             .{ .add = .{RigidBody.random(rand)} },
//         ));

//         try expectEqual(@as(f32, @sizeOf(RigidBody)) / @as(f32, @sizeOf(RigidBody) * 2 - 1), cmds.worstCaseUsage());

//         try expectEqual(1, cmds.destroy.items.len);
//         try expectEqual(e, cmds.destroy.items[0]);
//         var iter = cmds.change_archetype.iterator(&es);
//         const change_archetype = iter.next().?;
//         var add_comps = change_archetype.componentIterator();
//         const create_rb = add_comps.next().?;
//         try expectEqual(es.registerComponentType(RigidBody), create_rb.id);
//         try expectEqual(rb, create_rb.as(&es, RigidBody).?.*);
//         try expectEqual(null, add_comps.next());
//         try expectEqual(null, iter.next());
//     }
// }

// test "command buffer worst case capacity" {
//     defer Comp.unregisterAll();
//     // XXX: ...
//     if (true) return error.SkipZigTest;

//     const cb_capacity = 100;

//     var es = try Entities.init(gpa, cb_capacity * 10);
//     defer es.deinit(gpa);

//     var cmds = try CmdBuf.init(gpa, &es, .{ .cmds = cb_capacity, .comp_bytes = 16 });
//     defer cmds.deinit(gpa, &es);

//     // Change archetype
//     {
//         // Non interned
//         for (0..cb_capacity) |_| {
//             _ = try Entity.reserveImmediately(&es).changeArchetypeCmdFromComponentsChecked(
//                 &es,
//                 &cmds,
//                 .{ .add = &.{
//                     .init(&es, &@as(u0, 0)),
//                     .init(&es, &@as(u8, 0)),
//                     .init(&es, &@as(u16, 0)),
//                     .init(&es, &@as(u32, 0)),
//                     .init(&es, &@as(u64, 0)),
//                     .init(&es, &@as(u128, 0)),
//                 } },
//             );
//         }

//         try expect(cmds.worstCaseUsage() > 0.8);
//         cmds.clear(&es);

//         // Interned
//         for (0..cb_capacity) |_| {
//             _ = try Entity.reserveImmediately(&es).changeArchetypeCmdFromComponentsChecked(
//                 &es,
//                 &cmds,
//                 .{ .add = &.{
//                     .initInterned(&es, &@as(u0, 0)),
//                     .initInterned(&es, &@as(u8, 0)),
//                     .initInterned(&es, &@as(u16, 0)),
//                     .initInterned(&es, &@as(u32, 0)),
//                     .initInterned(&es, &@as(u64, 0)),
//                     .initInterned(&es, &@as(u128, 0)),
//                 } },
//             );
//         }

//         try expect(cmds.worstCaseUsage() > 0.8);
//         cmds.clear(&es);

//         // Duplicates don't take up extra space
//         var dups: std.BoundedArray(Comp.Optional, cb_capacity * 4) = .{};
//         for (0..dups.buffer.len) |i| {
//             dups.appendAssumeCapacity(.init(&es, &@as(u128, i)));
//         }
//         _ = try Entity.reserveImmediately(&es).changeArchetypeCmdFromComponentsChecked(
//             &es,
//             &cmds,
//             .{ .add = dups.constSlice() },
//         );
//         cmds.clear(&es);
//     }

//     // Destroy
//     {
//         for (0..cb_capacity) |i| {
//             const e: Entity = .{ .key = .{
//                 .index = @intCast(i),
//                 .generation = @enumFromInt(0),
//             } };
//             try e.destroyCmdChecked(&es, &cmds);
//         }

//         try expect(cmds.worstCaseUsage() == 1.0);
//         cmds.clear(&es);
//     }
// }
