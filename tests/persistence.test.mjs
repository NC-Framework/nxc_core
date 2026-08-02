import { test, describe, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { createEngine, withFrozenClock } from './harness.mjs';

let lua;
beforeEach(async () => {
  lua = await createEngine();
  await withFrozenClock(lua, 1700000000000);
});
afterEach(() => lua.global.close());

describe('Persistence', () => {
  test('a query before the provider is installed fails retryably', async () => {
    const r = await lua.doString(`
      NxcCore.Persistence.reset()
      local db = NxcCore.Persistence.scoped('nxc_banking')
      local out = db.query('SELECT * FROM nxc_banking_accounts')
      return { ok = out.ok, code = out.error.code, retryable = out.error.retryable }
    `);
    assert.equal(r.ok, false);
    assert.equal(r.code, 'NXC_CORE_PERSISTENCE_UNAVAILABLE');
    assert.equal(r.retryable, true);
  });

  test('a scoped provider allows queries on its own tables', async () => {
    const r = await lua.doString(`
      NxcCore.Persistence.reset()
      NxcCore.Persistence.setProvider(NxcCore.Persistence.inMemoryDouble())
      local db = NxcCore.Persistence.scoped('nxc_banking')
      return {
        select = db.query('SELECT * FROM nxc_banking_accounts WHERE id = ?', { 1 }).ok,
        update = db.execute('UPDATE nxc_banking_accounts SET balance_cents = 1').ok,
      }
    `);
    assert.equal(r.select, true);
    assert.equal(r.update, true);
  });

  test('a cross-domain query is refused', async () => {
    const r = await lua.doString(`
      NxcCore.Persistence.reset()
      NxcCore.Persistence.setProvider(NxcCore.Persistence.inMemoryDouble())
      local db = NxcCore.Persistence.scoped('nxc_shops')
      local out = db.query('SELECT * FROM nxc_banking_accounts')
      return { ok = out.ok, code = out.error.code, table_ = out.error.details.table_ }
    `);
    assert.equal(r.ok, false, 'MariaDB cannot enforce this, so it is enforced where it is visible');
    assert.equal(r.code, 'NXC_CORE_CROSS_DOMAIN_QUERY');
    assert.equal(r.table_, 'nxc_banking_accounts');
  });

  test('a transaction cannot smuggle a cross-domain write past the guard', async () => {
    const r = await lua.doString(`
      NxcCore.Persistence.reset()
      NxcCore.Persistence.setProvider(NxcCore.Persistence.inMemoryDouble())
      local db = NxcCore.Persistence.scoped('nxc_shops')
      local out = db.transaction({
        { query = 'UPDATE nxc_shops_stock SET qty = qty - 1' },
        { query = 'UPDATE nxc_banking_accounts SET balance_cents = balance_cents - 100' },
      })
      return { ok = out.ok, code = out.error.code }
    `);
    assert.equal(r.ok, false, 'every statement is checked, not just the first');
    assert.equal(r.code, 'NXC_CORE_CROSS_DOMAIN_QUERY');
  });

  test('a transaction on one domain succeeds', async () => {
    const r = await lua.doString(`
      NxcCore.Persistence.reset()
      local double = NxcCore.Persistence.inMemoryDouble()
      NxcCore.Persistence.setProvider(double)
      local db = NxcCore.Persistence.scoped('nxc_banking')
      local out = db.transaction({
        { query = 'UPDATE nxc_banking_accounts SET balance_cents = balance_cents - 100 WHERE id = ?' },
        { query = 'UPDATE nxc_banking_accounts SET balance_cents = balance_cents + 100 WHERE id = ?' },
      })
      return { ok = out.ok, recorded = #double.calls.transaction }
    `);
    assert.equal(r.ok, true);
    assert.equal(r.recorded, 1);
  });

  test('an empty transaction is refused', async () => {
    const r = await lua.doString(`
      NxcCore.Persistence.reset()
      NxcCore.Persistence.setProvider(NxcCore.Persistence.inMemoryDouble())
      return NxcCore.Persistence.scoped('nxc_banking').transaction({}).ok
    `);
    assert.equal(r, false);
  });

  test('a failing provider becomes a retryable structured error', async () => {
    const r = await lua.doString(`
      NxcCore.Persistence.reset()
      NxcCore.Persistence.setProvider({
        query = function() error('connection lost') end,
        execute = function() error('connection lost') end,
        transaction = function() error('connection lost') end,
      })
      local db = NxcCore.Persistence.scoped('nxc_banking')
      local out = db.query('SELECT 1 FROM nxc_banking_accounts')
      return { ok = out.ok, code = out.error.code, retryable = out.error.retryable }
    `);
    assert.equal(r.ok, false, 'never a silent empty result, which reads as "no records"');
    assert.equal(r.code, 'NXC_CORE_QUERY_FAILED');
    assert.equal(r.retryable, true);
  });

  test('a provider missing a method is refused at installation', async () => {
    const r = await lua.doString(`
      NxcCore.Persistence.reset()
      return not pcall(function()
        NxcCore.Persistence.setProvider({ query = function() end })
      end)
    `);
    assert.equal(r, true);
  });

  test('table ownership detection covers select, join, insert, and update', async () => {
    const r = await lua.doString(`
      local own = NxcCore.Persistence.ownsTables
      return {
        select = own('SELECT * FROM nxc_jobs_contracts', 'nxc_jobs'),
        join = own('SELECT * FROM nxc_jobs_a JOIN nxc_banking_b ON 1=1', 'nxc_jobs'),
        insert = own('INSERT INTO nxc_banking_accounts VALUES (1)', 'nxc_jobs'),
        update = own('UPDATE nxc_jobs_shifts SET x = 1', 'nxc_jobs'),
      }
    `);
    assert.equal(r.select, true);
    assert.equal(r.join, false, 'a join reaching into another domain is still a violation');
    assert.equal(r.insert, false);
    assert.equal(r.update, true);
  });
});
