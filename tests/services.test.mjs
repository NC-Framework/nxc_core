import { test, describe, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { createEngine, withFrozenClock } from './harness.mjs';

let lua;
beforeEach(async () => {
  lua = await createEngine();
  await withFrozenClock(lua, 1700000000000);
});
afterEach(() => lua.global.close());

describe('Services', () => {
  test('a registered service is discoverable', async () => {
    const r = await lua.doString(`
      NxcCore.Services.reset()
      NxcCore.Services.register({ name = 'nxc_banking', version = '0.1.0', contractVersion = 1 })
      local d = NxcCore.Services.discover('nxc_banking')
      return { present = d.present, ready = d.ready, reason = d.reason }
    `);
    assert.equal(r.present, true);
    assert.equal(r.ready, false, 'registered is not the same as ready');
    assert.match(r.reason, /registered/);
  });

  test('an absent service is a condition, not an error', async () => {
    const r = await lua.doString(`
      NxcCore.Services.reset()
      local d = NxcCore.Services.discover('nxc_properties')
      return { present = d.present, ready = d.ready, reason = d.reason }
    `);
    assert.equal(r.present, false, 'optional dependencies depend on this being a normal answer');
    assert.equal(r.ready, false);
    assert.equal(r.reason, 'not registered');
  });

  test('a ready service reports ready', async () => {
    const r = await lua.doString(`
      NxcCore.Services.reset()
      NxcCore.Services.register({ name = 'nxc_config', version = '0.1.0', contractVersion = 1 })
      NxcCore.Services.setState('nxc_config', NxcCore.Services.STATE.READY)
      local d = NxcCore.Services.discover('nxc_config')
      return { ready = d.ready, reason = d.reason }
    `);
    assert.equal(r.ready, true);
    assert.equal(r.reason, undefined);
  });

  test('a contract version below the requirement is reported clearly', async () => {
    const r = await lua.doString(`
      NxcCore.Services.reset()
      NxcCore.Services.register({ name = 'nxc_banking', version = '0.1.0', contractVersion = 1 })
      NxcCore.Services.setState('nxc_banking', NxcCore.Services.STATE.READY)
      local d = NxcCore.Services.discover('nxc_banking', 2)
      return { present = d.present, ready = d.ready, reason = d.reason }
    `);
    assert.equal(r.present, true);
    assert.equal(r.ready, false);
    assert.match(r.reason, /contract version 1 is below the required 2/);
  });

  test('duplicate registration is refused', async () => {
    const r = await lua.doString(`
      NxcCore.Services.reset()
      NxcCore.Services.register({ name = 'nxc_ui', contractVersion = 1 })
      local out = NxcCore.Services.register({ name = 'nxc_ui', contractVersion = 1 })
      return { ok = out.ok, code = out.error.code }
    `);
    assert.equal(r.ok, false);
    assert.equal(r.code, 'NXC_CORE_SERVICE_ALREADY_REGISTERED');
  });

  test('unregistering removes the service, so no stale registration remains', async () => {
    const r = await lua.doString(`
      NxcCore.Services.reset()
      NxcCore.Services.register({ name = 'nxc_zones', contractVersion = 1 })
      local removed = NxcCore.Services.unregister('nxc_zones')
      local d = NxcCore.Services.discover('nxc_zones')
      return { removed = removed, present = d.present }
    `);
    assert.equal(r.removed, true);
    assert.equal(r.present, false, 'a stale registration is worse than an absent one');
  });

  test('an invalid registration is rejected', async () => {
    const r = await lua.doString(`
      NxcCore.Services.reset()
      return {
        badName = NxcCore.Services.register({ name = '9bad', contractVersion = 1 }).ok,
        noVersion = NxcCore.Services.register({ name = 'nxc_ok' }).ok,
      }
    `);
    assert.equal(r.badName, false);
    assert.equal(r.noVersion, false);
  });

  test('optional capabilities are reported', async () => {
    const r = await lua.doString(`
      NxcCore.Services.reset()
      NxcCore.Services.register({
        name = 'nxc_config', contractVersion = 1, capabilities = { 'rollback', 'scheduled' },
      })
      return {
        has = NxcCore.Services.supports('nxc_config', 'rollback'),
        hasNot = NxcCore.Services.supports('nxc_config', 'timeTravel'),
        absent = NxcCore.Services.supports('nxc_nothing', 'rollback'),
      }
    `);
    assert.equal(r.has, true);
    assert.equal(r.hasNot, false);
    assert.equal(r.absent, false);
  });
});

/**
 * The framework's health is the worst of its parts.
 *
 * This ranking was inline in the `health` export until it was moved here, which
 * is the only reason any of it is tested: a decision inlined in a closure is a
 * decision nothing can reach.
 */
describe('Summarising health', () => {
  const worstOf = (states) => lua.doString(`
    local reports = {}
    for _, s in ipairs({ ${states.map((s) => `'${s}'`).join(', ')} }) do
      reports[#reports + 1] = { state = s }
    end
    return NxcCore.Services.worstOf(reports)
  `);

  test('everything serviceable is serviceable', async () => {
    assert.equal(await worstOf(['serviceable', 'serviceable', 'serviceable']), 'serviceable');
  });

  test('one failure fails the framework, whatever the rest say', async () => {
    // THE WHOLE POINT. Sessions being down is not offset by seven resources
    // that are fine, and a summary that averaged would read green.
    assert.equal(
      await worstOf(['serviceable', 'serviceable', 'failed', 'serviceable']), 'failed');
  });

  test('degraded outranks starting, and starting outranks unknown', async () => {
    assert.equal(await worstOf(['starting', 'degraded']), 'degraded');
    assert.equal(await worstOf(['unknown', 'starting']), 'starting');
  });

  test('a resource that said nothing is worse than one that said it is fine', async () => {
    // `unknown` is not evidence of health. It is also not evidence of failure,
    // and reporting it as either would invent a fact about a silent resource.
    assert.equal(await worstOf(['serviceable', 'unknown']), 'unknown');
  });

  test('nonsense is treated as unknown rather than ignored', async () => {
    // Ignoring an unrecognised state would let a resource hide by reporting
    // something nobody defined.
    assert.equal(await worstOf(['serviceable', 'excellent']), 'unknown');
  });

  test('no resources at all is serviceable, not an error', async () => {
    // An empty framework is a real state on a server where nothing has
    // registered yet, and the console command says so in words.
    assert.equal(await worstOf([]), 'serviceable');
  });
});
