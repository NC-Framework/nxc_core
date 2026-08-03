import { test, describe, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { createEngine, withFrozenClock } from './harness.mjs';

let lua;
beforeEach(async () => {
  lua = await createEngine();
  await withFrozenClock(lua, 1700000000000);
});
afterEach(() => lua.global.close());

/**
 * The capability grants a session carries.
 *
 * nxc_core owned capabilities as a pure module with nothing to apply them to:
 * no session held any grants, and no resource could ask. Both halves of that are
 * fixed here — the session carries grants, and server/api.lua exposes the
 * question.
 */
describe('Session capability grants', () => {
  const withSession = (body) => lua.doString(`
    NxcCore.Sessions.reset()
    local created = NxcCore.Sessions.create({
      source = 1, accountId = NxcCore.Identifiers.account(),
    })
    ${body}
  `);

  test('a new session starts with no grants, not with nil', async () => {
    const r = await withSession(`
      return type(NxcCore.Sessions.get(1).capabilityGrants)
    `);
    // nil would make every consumer write the same guard, and one of them would
    // forget.
    assert.equal(r, 'table');
  });

  test('with no grants, every capability answers false', async () => {
    const r = await withSession(`
      local resolved = NxcCore.Capabilities.resolve(NxcCore.Sessions.get(1).capabilityGrants)
      return NxcCore.Capabilities.has(resolved, 'doors.open')
    `);
    // FAILING CLOSED is the right direction for the gap. Nothing populates
    // grants yet — employment and ranks are later phases — so a server-side
    // gate refuses everything, which is visible immediately. Permitting
    // everything would not be visible at all.
    assert.equal(r, false);
  });

  test('grants can be set and are then honoured', async () => {
    const r = await withSession(`
      NxcCore.Sessions.setCapabilityGrants(1, {
        { source = 'employment', sourceId = 'job_police', allow = { 'doors.open' } },
      })
      local resolved = NxcCore.Capabilities.resolve(NxcCore.Sessions.get(1).capabilityGrants)
      return {
        allowed = NxcCore.Capabilities.has(resolved, 'doors.open'),
        other = NxcCore.Capabilities.has(resolved, 'doors.lock'),
      }
    `);
    assert.equal(r.allowed, true);
    assert.equal(r.other, false);
  });

  test('setting grants replaces rather than merges', async () => {
    const r = await withSession(`
      NxcCore.Sessions.setCapabilityGrants(1, {
        { source = 'employment', sourceId = 'job_police', allow = { 'doors.open' } },
      })
      NxcCore.Sessions.setCapabilityGrants(1, {
        { source = 'employment', sourceId = 'job_shop', allow = { 'till.open' } },
      })
      local resolved = NxcCore.Capabilities.resolve(NxcCore.Sessions.get(1).capabilityGrants)
      return { old = NxcCore.Capabilities.has(resolved, 'doors.open'),
               new = NxcCore.Capabilities.has(resolved, 'till.open') }
    `);
    // A grant is evidence of a relationship, and those change as a set. Merging
    // piecemeal is how a revoked one survives a job change.
    assert.equal(r.old, false, 'a revoked grant survived');
    assert.equal(r.new, true);
  });

  test('setting grants on a connection with no session is refused', async () => {
    const r = await lua.doString(`
      NxcCore.Sessions.reset()
      local result = NxcCore.Sessions.setCapabilityGrants(99, {})
      return { ok = result.ok, code = result.error.code }
    `);
    assert.equal(r.ok, false);
    assert.equal(r.code, 'NXC_LIB_SESSION_INVALID');
  });

  test('grants must be a list', async () => {
    const r = await withSession(`
      local result = NxcCore.Sessions.setCapabilityGrants(1, 'police')
      return result.ok
    `);
    assert.equal(r, false);
  });
});
