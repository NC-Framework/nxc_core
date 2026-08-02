import { test, describe, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { createEngine, withFrozenClock } from './harness.mjs';

let lua;
beforeEach(async () => {
  lua = await createEngine();
  await withFrozenClock(lua, 1700000000000);
});
afterEach(() => lua.global.close());

const SETUP = `
  NxcCore.Sessions.reset()
  ACCOUNT_A = NxcCore.Identifiers.account()
  ACCOUNT_B = NxcCore.Identifiers.account()
  CHAR_A1 = NxcCore.Identifiers.character()
  CHAR_A2 = NxcCore.Identifiers.character()
  CHAR_B1 = NxcCore.Identifiers.character()
  OWNERS = { [CHAR_A1] = ACCOUNT_A, [CHAR_A2] = ACCOUNT_A, [CHAR_B1] = ACCOUNT_B }
  function ownedBy(id) return OWNERS[id] end
`;

describe('Sessions', () => {
  test('a session is created without a character selected', async () => {
    const r = await lua.doString(SETUP + `
      local out = NxcCore.Sessions.create({ source = 1, accountId = ACCOUNT_A })
      return {
        ok = out.ok,
        account = out.value.accountId,
        character = out.value.activeCharacterId,
        validId = NxcCore.Identifiers.isValid(out.value.id, 'ses'),
      }
    `);
    assert.equal(r.ok, true);
    assert.equal(r.character, undefined, 'no character during selection is a normal state');
    assert.equal(r.validId, true);
  });

  test('the actor is resolved from the session, never from a payload', async () => {
    const r = await lua.doString(SETUP + `
      NxcCore.Sessions.create({ source = 1, accountId = ACCOUNT_A })
      NxcCore.Sessions.selectCharacter(1, CHAR_A1, ownedBy)
      return {
        account = NxcCore.Sessions.resolveAccount(1),
        character = NxcCore.Sessions.resolveCharacter(1),
        unknown = NxcCore.Sessions.resolveAccount(99),
      }
    `);
    assert.equal(r.account.startsWith('acc_'), true);
    assert.equal(r.character.startsWith('chr_'), true);
    assert.equal(r.unknown, undefined);
  });

  test('an account holds multiple characters and can switch between them', async () => {
    const r = await lua.doString(SETUP + `
      NxcCore.Sessions.create({ source = 1, accountId = ACCOUNT_A })
      NxcCore.Sessions.selectCharacter(1, CHAR_A1, ownedBy)
      local switch = NxcCore.Sessions.selectCharacter(1, CHAR_A2, ownedBy)
      return {
        ok = switch.ok,
        previous = switch.value.previousCharacterId == CHAR_A1,
        active = NxcCore.Sessions.resolveCharacter(1) == CHAR_A2,
      }
    `);
    assert.equal(r.ok, true);
    assert.equal(r.previous, true, 'the caller needs it to clean up the previous character');
    assert.equal(r.active, true);
  });

  test('selecting a character belonging to another account is refused', async () => {
    const r = await lua.doString(SETUP + `
      NxcCore.Sessions.create({ source = 1, accountId = ACCOUNT_A })
      local out = NxcCore.Sessions.selectCharacter(1, CHAR_B1, ownedBy)
      return { ok = out.ok, code = out.error.code }
    `);
    assert.equal(r.ok, false, 'otherwise a client selects any character by sending its id');
    assert.equal(r.code, 'NXC_LIB_FORBIDDEN');
  });

  test('a nonexistent character and a foreign one fail identically', async () => {
    const r = await lua.doString(SETUP + `
      NxcCore.Sessions.create({ source = 1, accountId = ACCOUNT_A })
      local foreign = NxcCore.Sessions.selectCharacter(1, CHAR_B1, ownedBy)
      local missing = NxcCore.Sessions.selectCharacter(
        1, NxcCore.Identifiers.character(), ownedBy)
      return { foreign = foreign.error.code, missing = missing.error.code }
    `);
    assert.equal(r.foreign, r.missing, 'distinguishing them would confirm a character id exists');
  });

  test('a malformed character identifier is rejected', async () => {
    const r = await lua.doString(SETUP + `
      NxcCore.Sessions.create({ source = 1, accountId = ACCOUNT_A })
      local out = NxcCore.Sessions.selectCharacter(1, "'; DROP TABLE --", ownedBy)
      return { ok = out.ok, code = out.error.code }
    `);
    assert.equal(r.ok, false);
    assert.equal(r.code, 'NXC_LIB_VALIDATION_FAILED');
  });

  test('acting without a session fails', async () => {
    const r = await lua.doString(SETUP + `
      local out = NxcCore.Sessions.selectCharacter(42, CHAR_A1, ownedBy)
      return { ok = out.ok, code = out.error.code }
    `);
    assert.equal(r.ok, false);
    assert.equal(r.code, 'NXC_LIB_SESSION_INVALID');
  });

  test('destroy reports what must be cleaned up', async () => {
    const r = await lua.doString(SETUP + `
      NxcCore.Sessions.create({ source = 1, accountId = ACCOUNT_A, bucket = 42 })
      NxcCore.Sessions.selectCharacter(1, CHAR_A1, ownedBy)
      local out = NxcCore.Sessions.destroy(1)
      return {
        ok = out.ok,
        character = out.value.characterId == CHAR_A1,
        bucket = out.value.bucket,
        gone = NxcCore.Sessions.get(1) == nil,
      }
    `);
    assert.equal(r.ok, true);
    assert.equal(r.character, true);
    assert.equal(r.bucket, 42, 'the caller releases the bucket; a crash never runs a clean exit');
    assert.equal(r.gone, true);
  });

  test('sessions for one account are reportable for concurrent-login policy', async () => {
    const r = await lua.doString(SETUP + `
      NxcCore.Sessions.create({ source = 1, accountId = ACCOUNT_A })
      NxcCore.Sessions.create({ source = 2, accountId = ACCOUNT_A })
      NxcCore.Sessions.create({ source = 3, accountId = ACCOUNT_B })
      return { a = #NxcCore.Sessions.forAccount(ACCOUNT_A), total = NxcCore.Sessions.count() }
    `);
    assert.equal(r.a, 2);
    assert.equal(r.total, 3);
  });

  test('a duplicate session for one connection is refused', async () => {
    const r = await lua.doString(SETUP + `
      NxcCore.Sessions.create({ source = 1, accountId = ACCOUNT_A })
      local out = NxcCore.Sessions.create({ source = 1, accountId = ACCOUNT_A })
      return { ok = out.ok, code = out.error.code }
    `);
    assert.equal(r.ok, false);
    assert.equal(r.code, 'NXC_CORE_SESSION_EXISTS');
  });

  test('character slot limits are enforced against a supplied maximum', async () => {
    const r = await lua.doString(`
      return {
        under = NxcCore.Sessions.canCreateCharacter(2, 5),
        at = NxcCore.Sessions.canCreateCharacter(5, 5),
        defaultUnder = NxcCore.Sessions.canCreateCharacter(1),
      }
    `);
    assert.equal(r.under, true);
    assert.equal(r.at, false);
    assert.equal(r.defaultUnder, true);
  });
});
