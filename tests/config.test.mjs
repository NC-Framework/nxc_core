import { test, describe, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { createEngine, withFrozenClock } from './harness.mjs';

let lua;
beforeEach(async () => {
  lua = await createEngine();
  await withFrozenClock(lua, 1700000000000);
});
afterEach(() => lua.global.close());

describe('Config schema', () => {
  test('the schema validates against its own rules', async () => {
    const r = await lua.doString(`
      local out = NxcCore.ConfigSchema.validate()
      local first
      if not out.ok then first = out.error.details.fields[1] end
      return { ok = out.ok, field = first and first.field, reason = first and first.reason }
    `);
    assert.equal(r.ok, true, r.ok ? '' : `${r.field}: ${r.reason}`);
  });

  test('every field declares all fourteen properties', async () => {
    const r = await lua.doString(`
      local required = {
        'key', 'type', 'description', 'default', 'validation', 'scope', 'clientVisible',
        'editCapability', 'auditClassification', 'sensitive', 'reloadBehavior',
        'migrationBehavior', 'rollbackBehavior', 'changeEvent',
      }
      local missing = 0
      for _, field in ipairs(NxcCore.ConfigSchema.FIELDS) do
        for _, prop in ipairs(required) do
          if field[prop] == nil then missing = missing + 1 end
        end
      end
      return { missing = missing, count = #NxcCore.ConfigSchema.FIELDS }
    `);
    assert.equal(r.missing, 0);
    assert.ok(r.count >= 6);
  });

  test('a malformed field is caught rather than registered', async () => {
    const r = await lua.doString(`
      local saved = NxcCore.ConfigSchema.FIELDS
      NxcCore.ConfigSchema.FIELDS = {
        { key = 'wrong.shape', type = 'string', description = 'd', default = 'x',
          validation = {}, scope = { 'global' }, clientVisible = true,
          editCapability = 'c', auditClassification = 'operational', sensitive = true,
          reloadBehavior = 'Whenever', migrationBehavior = 'retain',
          rollbackBehavior = 'restore', changeEvent = 'e' },
      }
      local out = NxcCore.ConfigSchema.validate()
      local reasons = {}
      for _, p in ipairs(out.error.details.fields) do reasons[#reasons + 1] = p.reason end
      NxcCore.ConfigSchema.FIELDS = saved
      return { ok = out.ok, reasons = table.concat(reasons, ' | ') }
    `);
    assert.equal(r.ok, false);
    assert.match(r.reasons, /key must be nxc_core/);
    assert.match(r.reasons, /unknown reload behavior/);
    assert.match(r.reasons, /sensitive field cannot be client-visible/);
  });

  test('a default that its own validation would reject is caught', async () => {
    const r = await lua.doString(`
      local saved = NxcCore.ConfigSchema.FIELDS
      NxcCore.ConfigSchema.FIELDS = {
        { key = 'nxc_core.group.key', type = 'integer', description = 'd', default = 99,
          validation = { min = 1, max = 20 }, scope = { 'global' }, clientVisible = false,
          editCapability = 'c', auditClassification = 'operational', sensitive = false,
          reloadBehavior = 'Immediate', migrationBehavior = 'retain',
          rollbackBehavior = 'restore', changeEvent = 'e' },
      }
      local out = NxcCore.ConfigSchema.validate()
      local reason = out.error.details.fields[1].reason
      NxcCore.ConfigSchema.FIELDS = saved
      return { ok = out.ok, reason = reason }
    `);
    assert.equal(r.ok, false, 'a fresh server would start on a value the panel rejects');
    assert.match(r.reason, /declared default is invalid/);
  });

  test('a duplicate key is caught', async () => {
    const r = await lua.doString(`
      local saved = NxcCore.ConfigSchema.FIELDS
      local one = saved[1]
      NxcCore.ConfigSchema.FIELDS = { one, one }
      local out = NxcCore.ConfigSchema.validate()
      NxcCore.ConfigSchema.FIELDS = saved
      return { ok = out.ok }
    `);
    assert.equal(r.ok, false, 'the loser is editable in the panel and read by nothing');
  });

  test('registration passes the resource name and the fields', async () => {
    const r = await lua.doString(`
      local seenResource, seenCount
      local out = NxcCore.ConfigSchema.register(function(resource, fields)
        seenResource, seenCount = resource, #fields
        return true
      end)
      return { ok = out.ok, resource = seenResource, count = seenCount }
    `);
    assert.equal(r.ok, true);
    assert.equal(r.resource, 'nxc_core');
    assert.equal(r.count, 6);
  });

  test('a refused or throwing registrar returns an error, not a crash', async () => {
    const r = await lua.doString(`
      local refused = NxcCore.ConfigSchema.register(function() return false end)
      local threw = NxcCore.ConfigSchema.register(function() error('config is down') end)
      return { refused = refused.ok, threw = threw.ok, reason = threw.error.details.reason }
    `);
    assert.equal(r.refused, false);
    assert.equal(r.threw, false);
    assert.match(r.reason, /config is down/);
  });
});

describe('Config values', () => {
  test('a setting has its declared default before anything is published', async () => {
    const r = await lua.doString(`
      return {
        max = NxcCore.Config.get('nxc_core.characters.maxPerAccount'),
        switch = NxcCore.Config.get('nxc_core.characters.allowLiveSwitch'),
        grace = NxcCore.Config.get('nxc_core.session.reconnectGraceMs'),
      }
    `);
    assert.equal(r.max, 5);
    assert.equal(r.switch, true);
    assert.equal(r.grace, 300000);
  });

  test('an unknown key raises rather than returning nil', async () => {
    const r = await lua.doString(`
      local ok, err = pcall(NxcCore.Config.get, 'nxc_core.characters.maxPerAcount')
      return { ok = ok, err = tostring(err) }
    `);
    assert.equal(r.ok, false, 'a typo returning nil becomes a silent behaviour change');
    assert.match(r.err, /unknown configuration key/);
  });

  test('a published value replaces the default and reports its reload behaviour', async () => {
    const r = await lua.doString(`
      local out = NxcCore.Config.apply({ ['nxc_core.characters.maxPerAccount'] = 12 })
      local entry = out.value.applied[1]
      return {
        value = NxcCore.Config.get('nxc_core.characters.maxPerAccount'),
        from = entry.from, to = entry.to, reload = entry.reloadBehavior,
        rejected = #out.value.rejected,
      }
    `);
    assert.equal(r.value, 12);
    assert.equal(r.from, 5);
    assert.equal(r.to, 12);
    assert.equal(r.reload, 'Immediate');
    assert.equal(r.rejected, 0);
  });

  test('a rejected value leaves the running one in place', async () => {
    const r = await lua.doString(`
      NxcCore.Config.apply({ ['nxc_core.characters.maxPerAccount'] = 12 })
      local out = NxcCore.Config.apply({ ['nxc_core.characters.maxPerAccount'] = 99 })
      return {
        value = NxcCore.Config.get('nxc_core.characters.maxPerAccount'),
        reason = out.value.rejected[1].reason,
      }
    `);
    assert.equal(r.value, 12, 'a bad edit must not knock the running value out');
    assert.match(r.reason, /at most 20/);
  });

  test('type, range, and enumeration are all enforced', async () => {
    const r = await lua.doString(`
      local out = NxcCore.Config.apply({
        ['nxc_core.characters.maxPerAccount'] = 2.5,
        ['nxc_core.characters.allowLiveSwitch'] = 'yes',
        ['nxc_core.logging.level'] = 'verbose',
        ['nxc_core.session.reconnectGraceMs'] = -1,
      })
      local by = {}
      for _, p in ipairs(out.value.rejected) do by[p.field] = p.reason end
      return {
        count = #out.value.rejected,
        whole = by['nxc_core.characters.maxPerAccount'],
        bool = by['nxc_core.characters.allowLiveSwitch'],
        level = by['nxc_core.logging.level'],
        grace = by['nxc_core.session.reconnectGraceMs'],
      }
    `);
    assert.equal(r.count, 4);
    assert.match(r.whole, /whole number/);
    assert.match(r.bool, /must be a boolean/);
    assert.match(r.level, /must be one of/);
    assert.match(r.grace, /at least 0/);
  });

  test('a key belonging to another resource is rejected, not stored', async () => {
    const r = await lua.doString(`
      local out = NxcCore.Config.apply({ ['nxc_lib.logging.level'] = 'debug' })
      return { count = #out.value.rejected, reason = out.value.rejected[1].reason }
    `);
    assert.equal(r.count, 1);
    assert.match(r.reason, /not a nxc_core setting/);
  });

  test('one bad field does not discard the good ones', async () => {
    const r = await lua.doString(`
      local out = NxcCore.Config.apply({
        ['nxc_core.characters.maxPerAccount'] = 8,
        ['nxc_core.logging.level'] = 'verbose',
      })
      return {
        applied = #out.value.applied,
        rejected = #out.value.rejected,
        max = NxcCore.Config.get('nxc_core.characters.maxPerAccount'),
        level = NxcCore.Config.get('nxc_core.logging.level'),
      }
    `);
    assert.equal(r.applied, 1);
    assert.equal(r.rejected, 1);
    assert.equal(r.max, 8);
    assert.equal(r.level, 'info');
  });

  test('the snapshot covers every declared field', async () => {
    const r = await lua.doString(`
      local snap = NxcCore.Config.snapshot()
      local missing = 0
      for _, field in ipairs(NxcCore.ConfigSchema.FIELDS) do
        if snap[field.key] == nil then missing = missing + 1 end
      end
      return { missing = missing }
    `);
    assert.equal(r.missing, 0);
  });

  test('reset returns every setting to its declared default', async () => {
    const r = await lua.doString(`
      NxcCore.Config.apply({ ['nxc_core.characters.maxPerAccount'] = 20 })
      NxcCore.Config.reset()
      return NxcCore.Config.get('nxc_core.characters.maxPerAccount')
    `);
    assert.equal(r, 5);
  });
});

describe('Configured behaviour', () => {
  test('the character limit is read from configuration, not from the constant', async () => {
    const r = await lua.doString(`
      local before = NxcCore.Sessions.canCreateCharacter(5)
      NxcCore.Config.apply({ ['nxc_core.characters.maxPerAccount'] = 8 })
      local after = NxcCore.Sessions.canCreateCharacter(5)
      return { before = before, after = after }
    `);
    assert.equal(r.before, false);
    assert.equal(r.after, true, 'raising the limit in game must take effect');
  });

  test('an explicit slot count still overrides the configured one', async () => {
    const r = await lua.doString(`
      NxcCore.Config.apply({ ['nxc_core.characters.maxPerAccount'] = 8 })
      return NxcCore.Sessions.canCreateCharacter(3, 2)
    `);
    assert.equal(r, false, 'a per-account override must win over the server default');
  });

  test('disabling the live switch closes only that transition', async () => {
    const r = await lua.doString(`
      local on = NxcCore.Lifecycle.canTransition('playing', 'selecting')
      NxcCore.Config.apply({ ['nxc_core.characters.allowLiveSwitch'] = false })
      return {
        on = on,
        off = NxcCore.Lifecycle.canTransition('playing', 'selecting'),
        disconnect = NxcCore.Lifecycle.canTransition('playing', 'disconnecting'),
        select = NxcCore.Lifecycle.canTransition('session_open', 'selecting'),
      }
    `);
    assert.equal(r.on, true);
    assert.equal(r.off, false);
    assert.equal(r.disconnect, true, 'a player must always be able to leave');
    assert.equal(r.select, true, 'first selection is not a switch');
  });

  test('the reconnect grace window is read from configuration', async () => {
    const r = await lua.doString(`
      NxcCore.Config.apply({ ['nxc_core.session.reconnectGraceMs'] = 60000 })
      local inside = NxcCore.Lifecycle.planReconnect({
        accountId = 'acc_x', lastCharacterId = 'chr_x',
        lastSeenMs = 0, nowMs = 30000,
      })
      local outside = NxcCore.Lifecycle.planReconnect({
        accountId = 'acc_x', lastCharacterId = 'chr_x',
        lastSeenMs = 0, nowMs = 120000,
      })
      return { inside = inside.restoreCharacter, outside = outside.restoreCharacter }
    `);
    assert.equal(r.inside, true);
    assert.equal(r.outside, false);
  });

  test('zero grace always returns the player to selection', async () => {
    const r = await lua.doString(`
      NxcCore.Config.apply({ ['nxc_core.session.reconnectGraceMs'] = 0 })
      local plan = NxcCore.Lifecycle.planReconnect({
        accountId = 'acc_x', lastCharacterId = 'chr_x', lastSeenMs = 0, nowMs = 1,
      })
      return plan.restoreCharacter
    `);
    assert.equal(r, false);
  });
});
