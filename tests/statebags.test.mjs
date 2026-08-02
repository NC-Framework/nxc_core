import { test, describe, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { createEngine, withFrozenClock } from './harness.mjs';

let lua;
beforeEach(async () => {
  lua = await createEngine();
  await withFrozenClock(lua, 1700000000000);
});
afterEach(() => lua.global.close());

describe('StateBags', () => {
  test('a valid key registers', async () => {
    const r = await lua.doString(`
      NxcCore.StateBags.reset()
      local out = NxcCore.StateBags.register({
        key = 'nxc.duty.ondutyy', owner = 'nxc_duty', attachment = 'player',
        type = 'boolean', description = 'Whether the character is on duty.',
      })
      return { ok = out.ok }
    `);
    assert.equal(r.ok, true);
  });

  test('a key carrying money, items, or capabilities is refused', async () => {
    const r = await lua.doString(`
      NxcCore.StateBags.reset()
      local function try(key)
        return NxcCore.StateBags.register({
          key = key, owner = 'x', attachment = 'player',
          type = 'number', description = 'd',
        }).ok
      end
      return {
        balance = try('nxc.banking.balance'),
        inventory = try('nxc.inventory.items'),
        caps = try('nxc.core.capabilities'),
        token = try('nxc.core.token'),
      }
    `);
    assert.equal(r.balance, false, 'every bag is client-visible');
    assert.equal(r.inventory, false);
    assert.equal(r.caps, false);
    assert.equal(r.token, false);
  });

  test('a malformed key is refused', async () => {
    const r = await lua.doString(`
      NxcCore.StateBags.reset()
      local function try(key)
        return NxcCore.StateBags.register({
          key = key, owner = 'x', attachment = 'player',
          type = 'boolean', description = 'd',
        }).ok
      end
      return {
        noPrefix = try('duty.onduty'),
        uppercase = try('nxc.Duty.OnDuty'),
        tooFew = try('nxc.duty'),
      }
    `);
    assert.equal(r.noPrefix, false);
    assert.equal(r.uppercase, false);
    assert.equal(r.tooFew, false);
  });

  test('a table type is refused, because a bag carries small scalars', async () => {
    const r = await lua.doString(`
      NxcCore.StateBags.reset()
      local out = NxcCore.StateBags.register({
        key = 'nxc.duty.detail', owner = 'x', attachment = 'player',
        type = 'table', description = 'd',
      })
      return { ok = out.ok }
    `);
    assert.equal(r.ok, false, 'a table replicates its whole contents on every change');
  });

  test('a description is required, because a bag is a disclosure decision', async () => {
    const r = await lua.doString(`
      NxcCore.StateBags.reset()
      local out = NxcCore.StateBags.register({
        key = 'nxc.duty.state', owner = 'x', attachment = 'player',
        type = 'boolean', description = '',
      })
      return { ok = out.ok, reason = out.error.details.fields[1].reason }
    `);
    assert.equal(r.ok, false);
    assert.match(r.reason, /disclosure decision/);
  });

  test('a write is validated against the registered type and size', async () => {
    const r = await lua.doString(`
      NxcCore.StateBags.reset()
      NxcCore.StateBags.register({
        key = 'nxc.duty.callsign', owner = 'nxc_duty', attachment = 'player',
        type = 'string', description = 'Radio callsign.', maxBytes = 8,
      })
      return {
        good = NxcCore.StateBags.validateWrite('nxc.duty.callsign', '1-ADAM').ok,
        wrongType = NxcCore.StateBags.validateWrite('nxc.duty.callsign', 42).ok,
        tooLong = NxcCore.StateBags.validateWrite('nxc.duty.callsign', 'WAY-TOO-LONG').ok,
      }
    `);
    assert.equal(r.good, true);
    assert.equal(r.wrongType, false);
    assert.equal(r.tooLong, false);
  });

  test('writing an unregistered key fails', async () => {
    const r = await lua.doString(`
      NxcCore.StateBags.reset()
      local out = NxcCore.StateBags.validateWrite('nxc.made.up', true)
      return { ok = out.ok, code = out.error.code }
    `);
    assert.equal(r.ok, false);
    assert.equal(r.code, 'NXC_CORE_STATE_BAG_UNREGISTERED');
  });

  test('a resource stopping removes its keys', async () => {
    const r = await lua.doString(`
      NxcCore.StateBags.reset()
      NxcCore.StateBags.register({ key = 'nxc.duty.a', owner = 'nxc_duty',
        attachment = 'player', type = 'boolean', description = 'd' })
      NxcCore.StateBags.register({ key = 'nxc.duty.b', owner = 'nxc_duty',
        attachment = 'player', type = 'boolean', description = 'd' })
      NxcCore.StateBags.register({ key = 'nxc.zones.c', owner = 'nxc_zones',
        attachment = 'player', type = 'boolean', description = 'd' })
      local removed = NxcCore.StateBags.unregisterOwner('nxc_duty')
      return { removed = removed, left = #NxcCore.StateBags.all() }
    `);
    assert.equal(r.removed, 2);
    assert.equal(r.left, 1);
  });

  test('duplicate registration is refused', async () => {
    const r = await lua.doString(`
      NxcCore.StateBags.reset()
      NxcCore.StateBags.register({ key = 'nxc.duty.x', owner = 'a',
        attachment = 'player', type = 'boolean', description = 'd' })
      local out = NxcCore.StateBags.register({ key = 'nxc.duty.x', owner = 'b',
        attachment = 'player', type = 'boolean', description = 'd' })
      return out.ok
    `);
    assert.equal(r, false);
  });
});
