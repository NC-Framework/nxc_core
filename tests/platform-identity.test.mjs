import { test, describe, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createEngine, withFrozenClock } from './harness.mjs';

const here = dirname(fileURLToPath(import.meta.url));

let lua;
beforeEach(async () => {
  lua = await createEngine();
  await withFrozenClock(lua, 1700000000000);
});
afterEach(() => lua.global.close());

describe('Platform identity', () => {
  test('a FiveM identifier list parses into kinds', async () => {
    const r = await lua.doString(`
      local out = NxcCore.PlatformIdentity.parse({
        'license:abcdef0123456789',
        'discord:112233445566778899',
        'steam:110000112345678',
        'ip:203.0.113.7',
      })
      return { license = out.license, discord = out.discord, steam = out.steam, ip = out.ip }
    `);
    assert.equal(r.license, 'abcdef0123456789');
    assert.equal(r.discord, '112233445566778899');
    assert.equal(r.steam, '110000112345678');
    assert.equal(r.ip, undefined, 'an address is never an identity key');
  });

  test('an unknown identifier kind is dropped, not stored', async () => {
    const r = await lua.doString(`
      local out = NxcCore.PlatformIdentity.parse({ 'somethingnew:xyz', 'license:abc123def456' })
      local n = 0
      for _ in pairs(out) do n = n + 1 end
      return { count = n, license = out.license }
    `);
    assert.equal(r.count, 1, 'a kind nobody has reasoned about must not become an identity key');
    assert.equal(r.license, 'abc123def456');
  });

  test('the first of a kind wins, so ordering cannot decide identity', async () => {
    const r = await lua.doString(`
      local out = NxcCore.PlatformIdentity.parse({ 'license:first0000', 'license:second000' })
      return out.license
    `);
    assert.equal(r, 'first0000');
  });

  test('malformed entries are ignored rather than crashing the handshake', async () => {
    const r = await lua.doString(`
      local out = NxcCore.PlatformIdentity.parse({ '', 'nocolon', ':novalue', 'license:ok123456' })
      local n = 0
      for _ in pairs(out) do n = n + 1 end
      return { count = n, license = out.license }
    `);
    assert.equal(r.count, 1);
    assert.equal(r.license, 'ok123456');
  });

  test('the primary identifier follows declared priority, not input order', async () => {
    const r = await lua.doString(`
      local ids = NxcCore.PlatformIdentity.parse({ 'discord:111', 'steam:222', 'license:333' })
      local kind, value = NxcCore.PlatformIdentity.primary(ids)
      return { kind = kind, value = value }
    `);
    assert.equal(r.kind, 'license', 'the licence is tied to the entitlement, not a swappable account');
    assert.equal(r.value, '333');
  });

  test('a player with no usable identifier is insufficient, not an error', async () => {
    const r = await lua.doString(`
      local none = NxcCore.PlatformIdentity.parse({ 'ip:203.0.113.7' })
      local some = NxcCore.PlatformIdentity.parse({ 'discord:111' })
      return {
        none = NxcCore.PlatformIdentity.sufficient(none),
        some = NxcCore.PlatformIdentity.sufficient(some),
      }
    `);
    assert.equal(r.none, false, 'guessing would create a new account on every connection');
    assert.equal(r.some, true);
  });

  test('rows are ordered by priority so repeated connections produce the same statements', async () => {
    const r = await lua.doString(`
      local a = NxcCore.PlatformIdentity.rows('acc_x',
        NxcCore.PlatformIdentity.parse({ 'discord:111', 'license:333' }))
      local b = NxcCore.PlatformIdentity.rows('acc_x',
        NxcCore.PlatformIdentity.parse({ 'license:333', 'discord:111' }))
      return {
        first = a[1].kind, second = a[2].kind,
        sameOrder = a[1].kind == b[1].kind and a[2].kind == b[2].kind,
        account = a[1].accountId,
      }
    `);
    assert.equal(r.first, 'license');
    assert.equal(r.second, 'discord');
    assert.equal(r.sameOrder, true);
    assert.equal(r.account, 'acc_x');
  });

  test('redaction keeps enough to correlate and not enough to identify', async () => {
    const r = await lua.doString(`
      local out = NxcCore.PlatformIdentity.redact({
        license = 'abcdef0123456789',
        discord = 'short',
      })
      return { license = out.license, short = out.discord }
    `);
    assert.equal(r.license, 'abc**********789');
    assert.equal(r.short, '*****', 'a short value cannot be partially shown without giving it away');
  });
});

describe('Migration statement splitting', () => {
  test('the real migration splits into the statements it contains', async () => {
    const sql = readFileSync(
      resolve(here, '..', 'migrations', '0001_accounts_and_characters.sql'), 'utf8');
    await lua.global.set('__sql', sql);
    const r = await lua.doString(`
      local out = NxcCore.Migrations.statements(__sql)
      local creates, other = 0, {}
      for _, st in ipairs(out) do
        if st:upper():find('CREATE TABLE') then creates = creates + 1
        else other[#other + 1] = st:sub(1, 40) end
      end
      return { count = #out, creates = creates, unexpected = table.concat(other, ' | ') }
    `);
    // Four tables, and nothing else — the migration creates only.
    assert.equal(r.creates, 4, 'the migration creates four tables');
    assert.equal(r.count, 4, `unexpected statements: ${r.unexpected}`);
  });

  test('comment-only fragments between statements are dropped', async () => {
    const r = await lua.doString(`
      local out = NxcCore.Migrations.statements(
        '-- a comment;\\nSELECT 1;\\n-- another;\\nSELECT 2;\\n')
      return { count = #out, first = out[1], second = out[2] }
    `);
    assert.equal(r.count, 2, 'an error pointing at a comment helps nobody');
    assert.match(r.first, /SELECT 1$/);
    assert.match(r.second, /SELECT 2$/);
  });

  test('trailing content after the last semicolon is not silently executed', async () => {
    const r = await lua.doString(`
      local out = NxcCore.Migrations.statements('SELECT 1;\\nSELECT 2 -- unterminated\\n')
      return { count = #out, only = out[1] }
    `);
    assert.equal(r.count, 1);
    assert.match(r.only, /SELECT 1$/);
  });

  test('an empty migration yields no statements rather than one blank one', async () => {
    const r = await lua.doString(`
      return #NxcCore.Migrations.statements('\\n\\n-- nothing here\\n\\n')
    `);
    assert.equal(r, 0);
  });
});
