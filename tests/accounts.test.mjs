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
 * A stateful fake of the two account tables, driven through the SCOPED provider.
 *
 * Going through `Persistence.scoped` rather than the raw double is the whole
 * point: the scoped provider returns `NxcResult`, and the defect this suite
 * exists for was code that treated those Results as raw rows. A test against the
 * raw provider would have passed while the server failed every connection.
 */
const FAKE_DB = `
  function makeDb(opts)
    opts = opts or {}
    local identifiers, accounts = {}, {}

    local double = NxcCore.Persistence.inMemoryDouble({
      onQuery = function(sql, params)
        if sql:find('FROM nxc_core_account_identifiers') then
          local key = params[1] .. '|' .. params[2]
          local accountId = identifiers[key]
          if accountId then return { { account_id = accountId } } end
          return {}
        end
        if sql:find('FROM nxc_core_accounts') then
          local row = accounts[params[1]]
          if row then return { row } end
          return {}
        end
        return {}
      end,
      onExecute = function(sql, params)
        if sql:find('INSERT IGNORE INTO nxc_core_account_identifiers') then
          local key = params[2] .. '|' .. params[3]
          if not identifiers[key] then identifiers[key] = params[1] end
        end
        return 1
      end,
      onTransaction = function(statements)
        if opts.failCreate then error('duplicate key', 0) end
        for _, st in ipairs(statements) do
          if st.query:find('INSERT INTO nxc_core_accounts') then
            accounts[st.values[1]] = { id = st.values[1], whitelisted = 0, character_slots = 5 }
          elseif st.query:find('INSERT INTO nxc_core_account_identifiers') then
            identifiers[st.values[2] .. '|' .. st.values[3]] = st.values[1]
          end
        end
        return true
      end,
    })

    NxcCore.Persistence.setProvider(double)
    NxcCore.Accounts.setProvider(NxcCore.Persistence.scoped('nxc_core'))

    -- Seed helper, so a test can say "this player already exists".
    return {
      seed = function(accountId, kind, value)
        accounts[accountId] = { id = accountId, whitelisted = 0, character_slots = 5 }
        identifiers[kind .. '|' .. value] = accountId
      end,
      accountCount = function()
        local n = 0
        for _ in pairs(accounts) do n = n + 1 end
        return n
      end,
    }
  end
`;

describe('Account resolution', () => {
  test('a first connection creates an account', async () => {
    const r = await lua.doString(`
      ${FAKE_DB}
      local h = makeDb()
      local ids = NxcCore.PlatformIdentity.parse({ 'license:abcdef0123', 'discord:9911' })
      local out = NxcCore.Accounts.resolve(ids)
      return {
        ok = out.ok,
        reason = not out.ok and out.error.details.reason or nil,
        id = out.ok and out.value.id or nil,
        accounts = h.accountCount(),
      }
    `);
    assert.equal(r.ok, true, r.reason);
    assert.match(r.id, /^acc_/);
    assert.equal(r.accounts, 1);
  });

  test('a returning player resolves to the same account, not a new one', async () => {
    const r = await lua.doString(`
      ${FAKE_DB}
      local h = makeDb()
      local ids = NxcCore.PlatformIdentity.parse({ 'license:abcdef0123' })
      local first = NxcCore.Accounts.resolve(ids)
      local second = NxcCore.Accounts.resolve(ids)
      return {
        same = first.value.id == second.value.id,
        accounts = h.accountCount(),
      }
    `);
    // The original defect: Results read as rows, so nothing was ever found and
    // every connection looked like a first connection.
    assert.equal(r.same, true);
    assert.equal(r.accounts, 1, 'a returning player must not acquire a second account');
  });

  test('a new secondary identifier still resolves to the existing account', async () => {
    const r = await lua.doString(`
      ${FAKE_DB}
      local h = makeDb()
      h.seed('acc_known', 'license', 'abcdef0123')
      local ids = NxcCore.PlatformIdentity.parse({ 'license:abcdef0123', 'discord:brandnew' })
      local out = NxcCore.Accounts.resolve(ids)
      return { id = out.value.id, accounts = h.accountCount() }
    `);
    assert.equal(r.id, 'acc_known');
    assert.equal(r.accounts, 1);
  });

  test('a changed licence still resolves through a secondary identifier', async () => {
    const r = await lua.doString(`
      ${FAKE_DB}
      local h = makeDb()
      h.seed('acc_known', 'discord', '9911')
      local ids = NxcCore.PlatformIdentity.parse({ 'license:brandnewlicence', 'discord:9911' })
      local out = NxcCore.Accounts.resolve(ids)
      return { id = out.value.id, accounts = h.accountCount() }
    `);
    assert.equal(r.id, 'acc_known', 'every identifier is checked, not only the strongest');
    assert.equal(r.accounts, 1);
  });

  test('losing the creation race re-reads rather than failing', async () => {
    const r = await lua.doString(`
      ${FAKE_DB}
      local h = makeDb({ failCreate = true })
      -- The winner's row is already there; our INSERT will be refused.
      h.seed('acc_winner', 'license', 'abcdef0123')
      local ids = NxcCore.PlatformIdentity.parse({ 'license:abcdef0123' })
      local out = NxcCore.Accounts.resolve(ids)
      return { ok = out.ok, id = out.ok and out.value.id or nil }
    `);
    assert.equal(r.ok, true);
    assert.equal(r.id, 'acc_winner', 'the constraint told us the truth; our read was stale');
  });

  test('a creation that fails with nothing to find reports why', async () => {
    const r = await lua.doString(`
      ${FAKE_DB}
      makeDb({ failCreate = true })
      local ids = NxcCore.PlatformIdentity.parse({ 'license:abcdef0123' })
      local out = NxcCore.Accounts.resolve(ids)
      return { ok = out.ok, code = out.error.code, reason = out.error.details.reason }
    `);
    assert.equal(r.ok, false);
    assert.equal(r.code, 'NXC_CORE_ACCOUNT_RESOLUTION_FAILED');
    assert.match(r.reason, /could not create an account/);
    assert.match(r.reason, /duplicate key/, 'the underlying cause must survive into the reason');
  });

  test('a player with no usable identifier is refused before touching the database', async () => {
    const r = await lua.doString(`
      ${FAKE_DB}
      local h = makeDb()
      local ids = NxcCore.PlatformIdentity.parse({ 'ip:203.0.113.7' })
      local out = NxcCore.Accounts.resolve(ids)
      return { ok = out.ok, code = out.error.code, accounts = h.accountCount() }
    `);
    assert.equal(r.ok, false);
    assert.equal(r.code, 'NXC_CORE_NO_IDENTIFIER');
    assert.equal(r.accounts, 0, 'guessing would mint an account per connection');
  });

  test('resolution before the provider exists is retryable, not a crash', async () => {
    const r = await lua.doString(`
      NxcCore.Accounts.setProvider(nil)
      local ids = NxcCore.PlatformIdentity.parse({ 'license:abcdef0123' })
      local out = NxcCore.Accounts.resolve(ids)
      return { ok = out.ok, code = out.error.code, retryable = out.error.retryable }
    `);
    assert.equal(r.ok, false);
    assert.equal(r.code, 'NXC_CORE_PERSISTENCE_UNAVAILABLE');
    assert.equal(r.retryable, true);
  });

  test('a provider error surfaces its reason instead of looking like no rows', async () => {
    const r = await lua.doString(`
      local double = NxcCore.Persistence.inMemoryDouble({
        onQuery = function() error('connection lost', 0) end,
      })
      NxcCore.Persistence.setProvider(double)
      NxcCore.Accounts.setProvider(NxcCore.Persistence.scoped('nxc_core'))

      local ids = NxcCore.PlatformIdentity.parse({ 'license:abcdef0123' })
      local out = NxcCore.Accounts.resolve(ids)
      return { ok = out.ok, reason = out.error.details.reason }
    `);
    assert.equal(r.ok, false, 'a failed query must not be indistinguishable from an empty one');
    assert.match(r.reason, /connection lost/);
  });

  test('a cross-domain query is still refused through this path', async () => {
    const r = await lua.doString(`
      NxcCore.Persistence.setProvider(NxcCore.Persistence.inMemoryDouble())
      local scoped = NxcCore.Persistence.scoped('nxc_core')
      local out = scoped.query('SELECT * FROM nxc_banking_accounts')
      return { ok = out.ok, code = out.error.code }
    `);
    assert.equal(r.ok, false);
    assert.equal(r.code, 'NXC_CORE_CROSS_DOMAIN_QUERY');
  });
});
