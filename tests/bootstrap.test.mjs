import { test, describe, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { createEngine, withFrozenClock } from './harness.mjs';

let lua;
beforeEach(async () => {
  lua = await createEngine();
  await withFrozenClock(lua, 1700000000000);
});
afterEach(() => lua.global.close());

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
    nxc_server_build = '12345',
  }
  function withOverrides(o)
    local t = {}
    for k, v in pairs(VALID) do t[k] = v end
    for k, v in pairs(o) do if v == '__nil__' then t[k] = nil else t[k] = v end end
    return t
  end
`;

describe('Bootstrap', () => {
  beforeEach(async () => { await lua.doString(CONVARS); });

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
      local absent = NxcCore.Bootstrap.validate(makeGetter(VALID))
      local supplied = NxcCore.Bootstrap.validate(
        makeGetter(withOverrides({ nxc_token_signing_key = string.rep('k', 48) })))
      return {
        connection = absent.value.mysql_connection_string,
        keyAbsent = absent.value.nxc_token_signing_key,
        keySupplied = supplied.value.nxc_token_signing_key,
      }
    `);
    assert.equal(r.connection, true, 'settings are logged and surfaced in health reports');
    assert.equal(r.keyAbsent, false, 'no operator key: generated at startup instead');
    // An OPTIONAL secret is still a secret. Recording the value here would put an
    // operator-supplied signing key straight into the log.
    assert.equal(r.keySupplied, true);
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
        nxc_server_build = '',
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

  test('the signing key is no longer required at bootstrap', async () => {
    const r = await lua.doString(`
      local out = NxcCore.Bootstrap.validate(
        makeGetter(withOverrides({ nxc_token_signing_key = '__nil__' })))
      return out.ok
    `);
    // OD-005: generated at startup, rotated by restarting. A value nobody has to
    // set cannot be set wrongly — which is how a blank one reached a server.
    assert.equal(r, true);
  });

  test('an unrecorded server build is a startup failure', async () => {
    const r = await lua.doString(`
      local missing = NxcCore.Bootstrap.validate(
        makeGetter(withOverrides({ nxc_server_build = '__nil__' })))
      local placeholder = NxcCore.Bootstrap.validate(
        makeGetter(withOverrides({ nxc_server_build = 'UNPINNED' })))
      local prose = NxcCore.Bootstrap.validate(
        makeGetter(withOverrides({ nxc_server_build = 'latest' })))
      return {
        missing = missing.ok, missingReason = missing.error.details.fields[1].reason,
        placeholder = placeholder.ok,
        placeholderReason = placeholder.error.details.fields[1].reason,
        prose = prose.ok, proseReason = prose.error.details.fields[1].reason,
      }
    `);
    assert.equal(r.missing, false, 'a regression must be attributable to a specific build');
    assert.match(r.missingReason, /is required/);
    assert.equal(r.placeholder, false);
    assert.match(r.placeholderReason, /still a placeholder/);
    assert.equal(r.prose, false);
    assert.match(r.proseReason, /not a description/);
  });

  test('the server build is not checked for its edition', async () => {
    const r = await lua.doString(`
      local out = NxcCore.Bootstrap.validate(
        makeGetter(withOverrides({ nxc_server_build = '3095' })))
      return { ok = out.ok, recorded = out.value and out.value.nxc_server_build }
    `);
    // 3095 is a Legacy build, and bootstrap accepts it. A build number does not
    // carry its edition, so inventing a range to test against would fail closed
    // on correct input. Recording the build is the requirement here; proving the
    // server is Enhanced is gate check P1-E02, on real hardware.
    assert.equal(r.ok, true);
    assert.equal(r.recorded, '3095');
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
