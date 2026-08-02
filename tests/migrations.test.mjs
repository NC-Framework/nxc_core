import { test, describe, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { createEngine, withFrozenClock } from './harness.mjs';

let lua;
beforeEach(async () => {
  lua = await createEngine();
  await withFrozenClock(lua, 1700000000000);
});
afterEach(() => lua.global.close());

describe('Migrations', () => {
  test('filenames parse into sequence and name', async () => {
    const r = await lua.doString(`
      local a = NxcCore.Migrations.parseName('0001_accounts_and_characters.sql')
      return {
        sequence = a.sequence, name = a.name,
        bad = NxcCore.Migrations.parseName('accounts.sql'),
        noExt = NxcCore.Migrations.parseName('0001_accounts'),
      }
    `);
    assert.equal(r.sequence, 1);
    assert.equal(r.name, 'accounts_and_characters');
    assert.equal(r.bad, undefined);
    assert.equal(r.noExt, undefined);
  });

  test('the checksum is stable and content-sensitive', async () => {
    const r = await lua.doString(`
      local a = NxcCore.Migrations.checksum('CREATE TABLE x (id INT);')
      local b = NxcCore.Migrations.checksum('CREATE TABLE x (id INT);')
      local c = NxcCore.Migrations.checksum('CREATE TABLE y (id INT);')
      return { stable = a == b, differs = a ~= c, length = #a }
    `);
    assert.equal(r.stable, true);
    assert.equal(r.differs, true);
    assert.equal(r.length, 8);
  });

  test('line endings do not change the checksum', async () => {
    const r = await lua.doString(`
      local unix = NxcCore.Migrations.checksum('CREATE TABLE x;\\nSELECT 1;\\n')
      local win  = NxcCore.Migrations.checksum('CREATE TABLE x;\\r\\nSELECT 1;\\r\\n')
      return unix == win
    `);
    assert.equal(r, true, 'a checkout on another platform must not look edited');
  });

  test('a plan is ordered by sequence, not by input order', async () => {
    const r = await lua.doString(`
      local out = NxcCore.Migrations.plan({
        { filename = '0003_c.sql', sql = 'SELECT 3;' },
        { filename = '0001_a.sql', sql = 'SELECT 1;' },
        { filename = '0002_b.sql', sql = 'SELECT 2;' },
      })
      return {
        ok = out.ok,
        first = out.value[1].filename,
        second = out.value[2].filename,
        third = out.value[3].filename,
      }
    `);
    assert.equal(r.ok, true);
    assert.equal(r.first, '0001_a.sql');
    assert.equal(r.second, '0002_b.sql');
    assert.equal(r.third, '0003_c.sql');
  });

  test('a duplicate sequence is rejected', async () => {
    const r = await lua.doString(`
      local out = NxcCore.Migrations.plan({
        { filename = '0001_a.sql', sql = 'SELECT 1;' },
        { filename = '0001_b.sql', sql = 'SELECT 2;' },
      })
      return { ok = out.ok, reason = out.error.details.fields[1].reason }
    `);
    assert.equal(r.ok, false, 'order would depend on the filesystem listing');
    assert.match(r.reason, /duplicates sequence/);
  });

  test('a badly named or empty migration is rejected', async () => {
    const r = await lua.doString(`
      local bad = NxcCore.Migrations.plan({ { filename = 'setup.sql', sql = 'SELECT 1;' } })
      local empty = NxcCore.Migrations.plan({ { filename = '0001_a.sql', sql = '   ' } })
      return { bad = bad.ok, empty = empty.ok }
    `);
    assert.equal(r.bad, false);
    assert.equal(r.empty, false);
  });

  test('only unapplied migrations are pending', async () => {
    const r = await lua.doString(`
      local planned = NxcCore.Migrations.plan({
        { filename = '0001_a.sql', sql = 'SELECT 1;' },
        { filename = '0002_b.sql', sql = 'SELECT 2;' },
      }).value
      local applied = { { migration = '0001_a.sql', checksum = planned[1].checksum } }
      local out = NxcCore.Migrations.pending(planned, applied)
      return { ok = out.ok, count = #out.value.pending, next_ = out.value.pending[1].filename }
    `);
    assert.equal(r.ok, true);
    assert.equal(r.count, 1);
    assert.equal(r.next_, '0002_b.sql');
  });

  test('an edited applied migration is an error, not a warning', async () => {
    const r = await lua.doString(`
      local planned = NxcCore.Migrations.plan({
        { filename = '0001_a.sql', sql = 'SELECT 1;' },
      }).value
      local applied = { { migration = '0001_a.sql', checksum = 'deadbeef' } }
      local out = NxcCore.Migrations.pending(planned, applied)
      return { ok = out.ok, code = out.error.code, reason = out.error.details.fields[1].reason }
    `);
    assert.equal(r.ok, false, 'the live schema no longer matches its recorded history');
    assert.equal(r.code, 'NXC_CORE_MIGRATION_DRIFT');
    assert.match(r.reason, /edited since it was applied/);
  });

  test('an applied migration with no file is reported, not an error', async () => {
    const r = await lua.doString(`
      local planned = NxcCore.Migrations.plan({
        { filename = '0001_a.sql', sql = 'SELECT 1;' },
      }).value
      local applied = {
        { migration = '0001_a.sql', checksum = planned[1].checksum },
        { migration = '0009_from_a_newer_version.sql', checksum = 'abc12345' },
      }
      local out = NxcCore.Migrations.pending(planned, applied)
      return { ok = out.ok, ahead = out.value.appliedAhead[1] }
    `);
    assert.equal(r.ok, true, 'a downgrade leaves the schema ahead, not inconsistent');
    assert.equal(r.ahead, '0009_from_a_newer_version.sql');
  });

  test('nothing pending when everything is applied', async () => {
    const r = await lua.doString(`
      local planned = NxcCore.Migrations.plan({
        { filename = '0001_a.sql', sql = 'SELECT 1;' },
      }).value
      local out = NxcCore.Migrations.pending(planned,
        { { migration = '0001_a.sql', checksum = planned[1].checksum } })
      return #out.value.pending
    `);
    assert.equal(r, 0);
  });
});
