import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createEngine, withFrozenClock } from './harness.mjs';

let lua;
before(async () => {
  lua = await createEngine();
  await withFrozenClock(lua, 1700000000000);
});
after(() => lua.global.close());

describe('Identifiers', () => {
  test('generated identifiers are well formed and prefixed', async () => {
    const r = await lua.doString(`
      return {
        account = NxcCore.Identifiers.account(),
        character = NxcCore.Identifiers.character(),
        session = NxcCore.Identifiers.session(),
      }
    `);
    assert.match(r.account, /^acc_[0-9A-HJKMNP-TV-Z]{26}$/);
    assert.match(r.character, /^chr_[0-9A-HJKMNP-TV-Z]{26}$/);
    assert.match(r.session, /^ses_[0-9A-HJKMNP-TV-Z]{26}$/);
  });

  test('the alphabet excludes characters that are misread', async () => {
    const r = await lua.doString(`
      local ids = {}
      for i = 1, 200 do ids[#ids+1] = NxcCore.Identifiers.character() end
      local joined = table.concat(ids)
      return {
        i = joined:find('I') ~= nil,
        l = joined:find('L') ~= nil,
        o = joined:find('O') ~= nil,
        u = joined:find('U') ~= nil,
      }
    `);
    assert.equal(r.i, false);
    assert.equal(r.l, false);
    assert.equal(r.o, false);
    assert.equal(r.u, false);
  });

  test('identifiers do not collide under rapid generation', async () => {
    const r = await lua.doString(`
      local seen = {}
      for i = 1, 2000 do
        local id = NxcCore.Identifiers.character()
        if seen[id] then return { duplicate = true } end
        seen[id] = true
      end
      return { duplicate = false }
    `);
    assert.equal(r.duplicate, false, 'the clock is frozen, so this exercises the counter');
  });

  test('identifiers are time-ordered', async () => {
    const clock = await withFrozenClock(lua, 1700000000000);
    const first = await lua.doString(`return NxcCore.Identifiers.character()`);
    await clock.advance(60000);
    const second = await lua.doString(`return NxcCore.Identifiers.character()`);
    assert.ok(second > first, 'time-ordered identifiers index well as a clustered key');
  });

  test('validation rejects malformed and wrong-kind identifiers', async () => {
    const r = await lua.doString(`
      local good = NxcCore.Identifiers.character()
      return {
        valid = NxcCore.Identifiers.isValid(good),
        rightKind = NxcCore.Identifiers.isValid(good, 'chr'),
        wrongKind = NxcCore.Identifiers.isValid(good, 'acc'),
        empty = NxcCore.Identifiers.isValid(''),
        number = NxcCore.Identifiers.isValid(12345),
        lowercase = NxcCore.Identifiers.isValid('chr_abcdefghij'),
        injection = NxcCore.Identifiers.isValid("chr_A'; DROP TABLE --"),
      }
    `);
    assert.equal(r.valid, true);
    assert.equal(r.rightKind, true);
    assert.equal(r.wrongKind, false);
    assert.equal(r.empty, false);
    assert.equal(r.number, false);
    assert.equal(r.lowercase, false);
    assert.equal(r.injection, false);
  });

  test('kindOf reports the prefix', async () => {
    const r = await lua.doString(`
      return {
        kind = NxcCore.Identifiers.kindOf(NxcCore.Identifiers.account()),
        bad = NxcCore.Identifiers.kindOf('nonsense'),
      }
    `);
    assert.equal(r.kind, 'acc');
    assert.equal(r.bad, undefined);
  });
});
