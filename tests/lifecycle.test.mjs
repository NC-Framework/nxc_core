import { test, describe, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { createEngine, withFrozenClock } from './harness.mjs';

let lua;
beforeEach(async () => {
  lua = await createEngine();
  await withFrozenClock(lua, 1700000000000);
});
afterEach(() => lua.global.close());

describe('Lifecycle', () => {
  test('a connection begins in connecting', async () => {
    const r = await lua.doString(`
      local s = NxcCore.Lifecycle.begin(1)
      return { stage = s.stage, hasCorrelation = Nxc.Correlation.isValid(s.correlationId) }
    `);
    assert.equal(r.stage, 'connecting');
    assert.equal(r.hasCorrelation, true);
  });

  test('the normal path transitions cleanly', async () => {
    const r = await lua.doString(`
      local s = NxcCore.Lifecycle.begin(1)
      local path = { 'identifying', 'checking', 'session_open', 'selecting', 'loading', 'playing' }
      for _, stage in ipairs(path) do
        local out = NxcCore.Lifecycle.transition(s, stage)
        if not out.ok then return { ok = false, failedAt = stage } end
      end
      return { ok = true, stage = s.stage }
    `);
    assert.equal(r.ok, true);
    assert.equal(r.stage, 'playing');
  });

  test('a character switch is a normal transition from playing', async () => {
    const r = await lua.doString(`
      return NxcCore.Lifecycle.canTransition('playing', 'selecting')
    `);
    assert.equal(r, true);
  });

  test('an undefined transition is refused', async () => {
    const r = await lua.doString(`
      local s = NxcCore.Lifecycle.begin(1)
      local out = NxcCore.Lifecycle.transition(s, 'playing')
      return { ok = out.ok, code = out.error.code, from = out.error.details.from }
    `);
    assert.equal(r.ok, false, 'catching it here beats an inconsistent session later');
    assert.equal(r.code, 'NXC_CORE_INVALID_TRANSITION');
    assert.equal(r.from, 'connecting');
  });

  test('disconnecting is reachable from every stage and is terminal', async () => {
    const r = await lua.doString(`
      local stages = { 'connecting','identifying','checking','queued','session_open',
                       'selecting','loading','playing' }
      local unreachable = 0
      for _, s in ipairs(stages) do
        if not NxcCore.Lifecycle.canTransition(s, 'disconnecting') then
          unreachable = unreachable + 1
        end
      end
      return {
        unreachable = unreachable,
        terminal = not NxcCore.Lifecycle.canTransition('disconnecting', 'playing'),
      }
    `);
    assert.equal(r.unreachable, 0, 'a player can drop at any point');
    assert.equal(r.terminal, true);
  });

  test('connection checks return the first rejection with a reason', async () => {
    const r = await lua.doString(`
      local base = { hasIdentifier = true, banned = false, whitelisted = true,
                     whitelistRequired = false, slotsFree = true, bootstrapOk = true }
      local function withF(o)
        local t = {} for k,v in pairs(base) do t[k]=v end
        for k,v in pairs(o) do t[k]=v end
        return t
      end
      return {
        clean = NxcCore.Lifecycle.evaluateConnection(base).ok,
        noId = NxcCore.Lifecycle.evaluateConnection(
          withF({ hasIdentifier = false })).error.details.rejection,
        banned = NxcCore.Lifecycle.evaluateConnection(
          withF({ banned = true })).error.details.rejection,
        notWhite = NxcCore.Lifecycle.evaluateConnection(
          withF({ whitelistRequired = true, whitelisted = false })).error.details.rejection,
        full = NxcCore.Lifecycle.evaluateConnection(
          withF({ slotsFree = false })).error.details.rejection,
        bootstrap = NxcCore.Lifecycle.evaluateConnection(
          withF({ bootstrapOk = false })).error.details.rejection,
      }
    `);
    assert.equal(r.clean, true);
    assert.equal(r.noId, 'no_identifier');
    assert.equal(r.banned, 'banned');
    assert.equal(r.notWhite, 'not_whitelisted');
    assert.equal(r.full, 'server_full');
    assert.equal(r.bootstrap, 'bootstrap_failed');
  });

  test('a ban is checked before whitelist, and reports its reason', async () => {
    const r = await lua.doString(`
      local out = NxcCore.Lifecycle.evaluateConnection({
        hasIdentifier = true, banned = true, banReason = 'Banned until 2027 for duplication.',
        whitelisted = false, whitelistRequired = true, slotsFree = true, bootstrapOk = true,
      })
      return { rejection = out.error.details.rejection, message = out.error.message }
    `);
    assert.equal(r.rejection, 'banned');
    assert.match(r.message, /duplication/);
  });

  test('reconnect always creates a new session', async () => {
    const r = await lua.doString(`
      local plan = NxcCore.Lifecycle.planReconnect({
        accountId = 'acc_x', lastCharacterId = 'chr_x',
        lastSeenMs = Nxc.Time.nowMs() - 1000,
      })
      return { newSession = plan.newSession, restore = plan.restoreCharacter }
    `);
    assert.equal(r.newSession, true, 'a resurrected session would carry a possibly leaked token');
    assert.equal(r.restore, true);
  });

  test('a reconnect beyond the grace window does not restore the character', async () => {
    const r = await lua.doString(`
      local plan = NxcCore.Lifecycle.planReconnect({
        accountId = 'acc_x', lastCharacterId = 'chr_x',
        lastSeenMs = Nxc.Time.nowMs() - (10 * 60 * 1000),
        graceMs = 5 * 60 * 1000,
      })
      return { restore = plan.restoreCharacter, reason = plan.reason }
    `);
    assert.equal(r.restore, false);
    assert.match(r.reason, /beyond the grace window/);
  });

  test('a first connection has nothing to restore', async () => {
    const r = await lua.doString(`
      local plan = NxcCore.Lifecycle.planReconnect({ accountId = 'acc_x' })
      return { restore = plan.restoreCharacter, reason = plan.reason }
    `);
    assert.equal(r.restore, false);
    assert.match(r.reason, /no previous character/);
  });

  test('the disconnect plan lists what must be cleaned up', async () => {
    const r = await lua.doString(`
      local plan = NxcCore.Lifecycle.disconnectPlan({
        id = 'ses_1', activeCharacterId = 'chr_1', bucket = 1042,
      })
      return {
        character = plan.unloadCharacter, bucket = plan.releaseBucket,
        steps = #plan.steps,
      }
    `);
    assert.equal(r.character, 'chr_1');
    assert.equal(r.bucket, 1042);
    assert.ok(r.steps >= 4);
  });

  test('a disconnect with no character or bucket still destroys the session', async () => {
    const r = await lua.doString(`
      local plan = NxcCore.Lifecycle.disconnectPlan({ id = 'ses_1', bucket = 0 })
      return { bucket = plan.releaseBucket, character = plan.unloadCharacter, steps = #plan.steps }
    `);
    assert.equal(r.bucket, undefined);
    assert.equal(r.character, undefined);
    assert.ok(r.steps >= 2);
  });
});
