import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createEngine, withFrozenClock } from './harness.mjs';

let lua;
before(async () => {
  lua = await createEngine();
  await withFrozenClock(lua, 1700000000000);
});
after(() => lua.global.close());

// A convar getter backed by a table, so bootstrap validation is testable
// without the FiveM runtime.
const CONVARS = `
  function makeGetter(t)
    return function(name, default_)
      local v = t[name]
      if v == nil then return default_ end
      return v
    end
  end
  VALID = {
    mysql_connection_string = 'mysql://nexus:s3cret@127.0.0.1/nexus?charset=utf8mb4',
    nxc_environment = 'development',
    nxc_token_signing_key = string.rep('k', 48),
  }
  function withOverrides(o)
    local t = {}
    for k, v in pairs(VALID) do t[k] = v end
    for k, v in pairs(o) do if v == '__nil__' then t[k] = nil else t[k] = v end end
    return t
  end
`;

describe('Bootstrap', () => {
  before(async () => { await lua.doString(CONVARS); });

  test('a complete environment validates', async () => {
    const r = await lua.doString(`
      local out = NxcCore.Bootstrap.validate(makeGetter(VALID))
      if not out.ok then
        return { ok = false, reason = out.error.details.fields[1].reason }
      end
      return { ok = true, env = out.value.nxc_environment, mode = out.value.nxc_startup_mode }
    `);
    assert.equal(r.ok, true, r.reason);
    assert.equal(r.env, 'development');
    assert.equal(r.mode, 'normal', 'an optional value falls back to its default');
  });

  test('a secret is recorded as present, never by value', async () => {
    const r = await lua.doString(`
      local out = NxcCore.Bootstrap.validate(makeGetter(VALID))
      return {
        connection = out.value.mysql_connection_string,
        key = out.value.nxc_token_signing_key,
      }
    `);
    assert.equal(r.connection, true, 'settings are logged and surfaced in health reports');
    assert.equal(r.key, true);
  });

  test('a missing required value fails with a structured error', async () => {
    const r = await lua.doString(`
      local out = NxcCore.Bootstrap.validate(
        makeGetter(withOverrides({ mysql_connection_string = '' })))
      return {
        ok = out.ok, code = out.error.code,
        field = out.error.details.fields[1].field,
      }
    `);
    assert.equal(r.ok, false);
    assert.equal(r.code, 'NXC_CORE_BOOTSTRAP_INVALID');
    assert.equal(r.field, 'mysql_connection_string');
  });

  test('every problem is reported, not just the first', async () => {
    const r = await lua.doString(`
      local out = NxcCore.Bootstrap.validate(makeGetter(withOverrides({
        mysql_connection_string = '',
        nxc_environment = 'banana',
        nxc_token_signing_key = 'short',
      })))
      return { ok = out.ok, count = #out.error.details.fields }
    `);
    assert.equal(r.ok, false);
    assert.equal(r.count, 3, 'fixing one at a time means restarting three times');
  });

  test('an unfilled placeholder is caught', async () => {
    const r = await lua.doString(`
      local out = NxcCore.Bootstrap.validate(makeGetter(withOverrides({
        mysql_connection_string = 'mysql://<USER>:<PASSWORD>@<HOST>/<DATABASE>',
      })))
      return { ok = out.ok, reason = out.error.details.fields[1].reason }
    `);
    assert.equal(r.ok, false);
    assert.match(r.reason, /placeholder/);
  });

  test('a short signing key is rejected', async () => {
    const r = await lua.doString(`
      local out = NxcCore.Bootstrap.validate(
        makeGetter(withOverrides({ nxc_token_signing_key = 'tooshort' })))
      return { ok = out.ok, reason = out.error.details.fields[1].reason }
    `);
    assert.equal(r.ok, false);
    assert.match(r.reason, /at least 32/);
  });

  test('development mode in production is a startup failure', async () => {
    const r = await lua.doString(`
      local out = NxcCore.Bootstrap.validate(makeGetter(withOverrides({
        nxc_environment = 'production',
        nxc_dev_mode = 'true',
      })))
      return { ok = out.ok, reason = out.error.details.fields[1].reason }
    `);
    assert.equal(r.ok, false, 'diagnostics in production are an information-disclosure risk');
    assert.match(r.reason, /must be false in production/);
  });

  test('debug logging in production is a startup failure', async () => {
    const r = await lua.doString(`
      local out = NxcCore.Bootstrap.validate(makeGetter(withOverrides({
        nxc_environment = 'production',
        nxc_log_level = 'debug',
      })))
      return { ok = out.ok }
    `);
    assert.equal(r.ok, false);
  });

  test('development mode is permitted outside production', async () => {
    const r = await lua.doString(`
      local out = NxcCore.Bootstrap.validate(makeGetter(withOverrides({
        nxc_environment = 'development', nxc_dev_mode = 'true',
      })))
      return out.ok
    `);
    assert.equal(r, true);
  });

  test('the failure explanation names each value and what is wrong', async () => {
    const r = await lua.doString(`
      local out = NxcCore.Bootstrap.validate(makeGetter(withOverrides({
        nxc_environment = 'banana',
      })))
      return NxcCore.Bootstrap.explain(out.error)
    `);
    assert.match(r, /cannot start/);
    assert.match(r, /nxc_environment/);
    assert.match(r, /development, staging, or production/);
  });
});
