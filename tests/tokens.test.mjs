import { test, describe, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { createEngine, withFrozenClock } from './harness.mjs';

let lua;
beforeEach(async () => {
  lua = await createEngine();
  await withFrozenClock(lua, 1700000000000);
});
afterEach(() => lua.global.close());

describe('Token signing key', () => {
  test('with no operator value, one is generated', async () => {
    const r = await lua.doString(`
      local out = NxcCore.Tokens.decide(nil, function() return string.rep('a', 64) end)
      return { ok = out.ok, source = out.value.source, length = #out.value.key }
    `);
    assert.equal(r.ok, true);
    assert.equal(r.source, 'generated');
    assert.equal(r.length, 64);
  });

  test('an empty operator value counts as absent', async () => {
    const r = await lua.doString(`
      local out = NxcCore.Tokens.decide('', function() return string.rep('b', 64) end)
      return out.value.source
    `);
    // The recipe ships this convar blank, so empty is the normal case, not an error.
    assert.equal(r, 'generated');
  });

  test('an operator value is used as given', async () => {
    const r = await lua.doString(`
      local out = NxcCore.Tokens.decide(string.rep('k', 48), function()
        error('the generator must not run when a key was supplied', 0)
      end)
      return { source = out.value.source, length = #out.value.key }
    `);
    assert.equal(r.source, 'operator');
    assert.equal(r.length, 48);
  });

  test('a short operator value is refused, not quietly replaced', async () => {
    const r = await lua.doString(`
      local out = NxcCore.Tokens.decide('tooshort', function() return string.rep('c', 64) end)
      return { ok = out.ok, code = out.error.code, reason = out.error.details.fields[1].reason }
    `);
    // Silently generating instead would make a multi-instance deployment fail in
    // a way that looks like anything but a rejected key.
    assert.equal(r.ok, false);
    assert.equal(r.code, 'NXC_CORE_SIGNING_KEY_TOO_SHORT');
    assert.match(r.reason, /at least 32/);
    assert.match(r.reason, /unset to have one generated/);
  });

  test('a generator that cannot produce a key stops startup', async () => {
    const r = await lua.doString(`
      local none = NxcCore.Tokens.decide(nil, function() return nil, 'RANDOM_BYTES unavailable' end)
      local short = NxcCore.Tokens.decide(nil, function() return 'abc' end)
      return {
        none = none.ok, reason = none.error.details.reason,
        short = short.ok, shortCode = short.error.code,
      }
    `);
    // Falling back to something weaker would be the worst option: the server
    // would start, and every session token would be forgeable.
    assert.equal(r.none, false);
    assert.match(r.reason, /RANDOM_BYTES unavailable/);
    assert.equal(r.short, false);
    assert.equal(r.shortCode, 'NXC_CORE_SIGNING_KEY_UNAVAILABLE');
  });

  test('reading the key before it is installed raises rather than returning nil', async () => {
    const r = await lua.doString(`
      NxcCore.Tokens.reset()
      local ok, err = pcall(NxcCore.Tokens.key)
      return { ok = ok, ready = NxcCore.Tokens.isReady(), err = tostring(err) }
    `);
    // Signing with nil produces a token anyone can forge, and nothing would notice.
    assert.equal(r.ok, false);
    assert.equal(r.ready, false);
    assert.match(r.err, /not been installed/);
  });

  test('the source is reportable; the key is not part of any report', async () => {
    const r = await lua.doString(`
      NxcCore.Tokens.reset()
      local out = NxcCore.Tokens.decide(nil, function() return string.rep('d', 64) end)
      NxcCore.Tokens.install(out.value.key, out.value.source)
      return {
        source = NxcCore.Tokens.source(),
        ready = NxcCore.Tokens.isReady(),
        key = NxcCore.Tokens.key(),
      }
    `);
    assert.equal(r.source, 'generated');
    assert.equal(r.ready, true);
    // Retrievable for signing, and deliberately absent from source()/isReady(),
    // which are what the health surface and nxc_status print.
    assert.equal(r.key.length, 64);
  });
});
