import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createEngine, withFrozenClock } from './harness.mjs';

let lua;
before(async () => {
  lua = await createEngine();
  await withFrozenClock(lua, 1700000000000);
});
after(() => lua.global.close());

describe('Buckets', () => {
  test('allocation assigns an id in the dynamic range', async () => {
    const r = await lua.doString(`
      NxcCore.Buckets.reset()
      local out = NxcCore.Buckets.allocate({ owner = 'nxc_interiors', purpose = 'apartment' })
      return { ok = out.ok, id = out.value.id }
    `);
    assert.equal(r.ok, true);
    assert.ok(r.id >= 1000 && r.id <= 99999, 'never the shared world or a reserved id');
  });

  test('two allocations never collide', async () => {
    const r = await lua.doString(`
      NxcCore.Buckets.reset()
      local seen = {}
      for i = 1, 500 do
        local id = NxcCore.Buckets.allocate({ owner = 'x', purpose = 'p' }).value.id
        if seen[id] then return { duplicate = true } end
        seen[id] = true
      end
      return { duplicate = false, count = NxcCore.Buckets.count() }
    `);
    assert.equal(r.duplicate, false, 'two resources sharing an id is the accidental-instance failure');
    assert.equal(r.count, 500);
  });

  test('an empty unheld bucket releases when the last occupant leaves', async () => {
    const r = await lua.doString(`
      NxcCore.Buckets.reset()
      local id = NxcCore.Buckets.allocate({ owner = 'x', purpose = 'p' }).value.id
      NxcCore.Buckets.enter(id, 1)
      NxcCore.Buckets.enter(id, 2)
      local first = NxcCore.Buckets.leave(id, 1)
      local second = NxcCore.Buckets.leave(id, 2)
      return {
        firstReleased = first.value.released,
        secondReleased = second.value.released,
        remaining = NxcCore.Buckets.count(),
      }
    `);
    assert.equal(r.firstReleased, false);
    assert.equal(r.secondReleased, true);
    assert.equal(r.remaining, 0);
  });

  test('a held bucket survives being empty', async () => {
    const r = await lua.doString(`
      NxcCore.Buckets.reset()
      local id = NxcCore.Buckets.allocate({ owner = 'x', purpose = 'event', hold = true }).value.id
      NxcCore.Buckets.enter(id, 1)
      local left = NxcCore.Buckets.leave(id, 1)
      local released = NxcCore.Buckets.setHold(id, false)
      return {
        afterLeave = left.value.released,
        afterUnhold = released.value.released,
        remaining = NxcCore.Buckets.count(),
      }
    `);
    assert.equal(r.afterLeave, false, 'a hold is explicit and visible');
    assert.equal(r.afterUnhold, true);
    assert.equal(r.remaining, 0);
  });

  test('a resource stopping releases every bucket it owned', async () => {
    const r = await lua.doString(`
      NxcCore.Buckets.reset()
      NxcCore.Buckets.allocate({ owner = 'nxc_interiors', purpose = 'a' })
      NxcCore.Buckets.allocate({ owner = 'nxc_interiors', purpose = 'b' })
      NxcCore.Buckets.allocate({ owner = 'nxc_events', purpose = 'c' })
      local released = NxcCore.Buckets.releaseOwner('nxc_interiors')
      return { released = #released, remaining = NxcCore.Buckets.count() }
    `);
    assert.equal(r.released, 2, 'the caller resolves entities that were in them');
    assert.equal(r.remaining, 1);
  });

  test('a disconnect sweeps the occupant out of every bucket', async () => {
    const r = await lua.doString(`
      NxcCore.Buckets.reset()
      local a = NxcCore.Buckets.allocate({ owner = 'x', purpose = 'a' }).value.id
      local b = NxcCore.Buckets.allocate({ owner = 'x', purpose = 'b' }).value.id
      NxcCore.Buckets.enter(a, 7)
      NxcCore.Buckets.enter(b, 7)
      NxcCore.Buckets.enter(b, 8)
      local released = NxcCore.Buckets.removeOccupant(7)
      return { released = #released, remaining = NxcCore.Buckets.count() }
    `);
    assert.equal(r.released, 1, 'only the bucket left empty is released');
    assert.equal(r.remaining, 1, 'a crashed client never runs a clean exit, so this sweeps');
  });

  test('an unknown bucket reports clearly', async () => {
    const r = await lua.doString(`
      NxcCore.Buckets.reset()
      return {
        enter = NxcCore.Buckets.enter(4242, 1).error.code,
        leave = NxcCore.Buckets.leave(4242, 1).error.code,
      }
    `);
    assert.equal(r.enter, 'NXC_CORE_BUCKET_NOT_FOUND');
    assert.equal(r.leave, 'NXC_CORE_BUCKET_NOT_FOUND');
  });

  test('allocation requires an owner and a purpose', async () => {
    const r = await lua.doString(`
      NxcCore.Buckets.reset()
      return {
        noOwner = NxcCore.Buckets.allocate({ purpose = 'p' }).ok,
        noPurpose = NxcCore.Buckets.allocate({ owner = 'x' }).ok,
      }
    `);
    assert.equal(r.noOwner, false);
    assert.equal(r.noPurpose, false);
  });

  test('a released id can be reused without colliding with a live bucket', async () => {
    const r = await lua.doString(`
      NxcCore.Buckets.reset()
      local first = NxcCore.Buckets.allocate({ owner = 'x', purpose = 'a' }).value.id
      NxcCore.Buckets.enter(first, 1)
      NxcCore.Buckets.leave(first, 1)
      local ids = {}
      for i = 1, 20 do
        local id = NxcCore.Buckets.allocate({ owner = 'x', purpose = 'p' }).value.id
        if ids[id] then return { collision = true } end
        ids[id] = true
      end
      return { collision = false }
    `);
    assert.equal(r.collision, false);
  });
});
