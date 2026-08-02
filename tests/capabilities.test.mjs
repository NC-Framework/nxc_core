import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createEngine, withFrozenClock } from './harness.mjs';

let lua;
before(async () => {
  lua = await createEngine();
  await withFrozenClock(lua, 1700000000000);
});
after(() => lua.global.close());

describe('Capabilities across concurrent employments', () => {
  test('grants from several employments union', async () => {
    const r = await lua.doString(`
      local resolved = NxcCore.Capabilities.resolve({
        { source = 'employment', sourceId = 'police', allow = { 'police.evidence.view' } },
        { source = 'business', sourceId = 'biz_1', allow = { 'business.accounts.withdraw' } },
        { source = 'temporary', sourceId = 'contract_9', allow = { 'logistics.cargo.load' } },
      })
      return {
        police = NxcCore.Capabilities.has(resolved, 'police.evidence.view'),
        business = NxcCore.Capabilities.has(resolved, 'business.accounts.withdraw'),
        temp = NxcCore.Capabilities.has(resolved, 'logistics.cargo.load'),
        count = #NxcCore.Capabilities.list(resolved),
      }
    `);
    assert.equal(r.police, true);
    assert.equal(r.business, true);
    assert.equal(r.temp, true);
    assert.equal(r.count, 3, 'a second job adds capabilities; it never removes them');
  });

  test('a denial from one source cannot be overridden by a grant from another', async () => {
    const r = await lua.doString(`
      local resolved = NxcCore.Capabilities.resolve({
        { source = 'employment', sourceId = 'police', deny = { 'police.evidence.destroy' } },
        { source = 'temporary', sourceId = 'contract_9', allow = { 'police.evidence.destroy' } },
      })
      return {
        has = NxcCore.Capabilities.has(resolved, 'police.evidence.destroy'),
        deniedBy = NxcCore.Capabilities.deniedBy(resolved, 'police.evidence.destroy'),
      }
    `);
    assert.equal(r.has, false, 'a contract must not restore a deliberately revoked capability');
    assert.equal(r.deniedBy, 'employment:police');
  });

  test('resolution does not depend on grant order', async () => {
    const r = await lua.doString(`
      local a = NxcCore.Capabilities.resolve({
        { source = 'employment', allow = { 'x.y.z' } },
        { source = 'business', deny = { 'x.y.z' } },
      })
      local b = NxcCore.Capabilities.resolve({
        { source = 'business', deny = { 'x.y.z' } },
        { source = 'employment', allow = { 'x.y.z' } },
      })
      return { a = NxcCore.Capabilities.has(a, 'x.y.z'), b = NxcCore.Capabilities.has(b, 'x.y.z') }
    `);
    assert.equal(r.a, false);
    assert.equal(r.b, false, 'employments load asynchronously; order must not decide authorization');
  });

  test('the granting source is recorded for the audit trail', async () => {
    const r = await lua.doString(`
      local resolved = NxcCore.Capabilities.resolve({
        { source = 'employment', sourceId = 'fire', allow = { 'fire.command.dispatch' } },
      })
      return NxcCore.Capabilities.grantedBy(resolved, 'fire.command.dispatch')
    `);
    assert.equal(r, 'employment:fire', 'a review must be able to ask which job authorized an action');
  });

  test('explicitly denied is distinguishable from never granted', async () => {
    const r = await lua.doString(`
      local resolved = NxcCore.Capabilities.resolve({
        { source = 'employment', sourceId = 'police', deny = { 'police.armory.rifle' } },
      })
      return {
        denied = NxcCore.Capabilities.deniedBy(resolved, 'police.armory.rifle'),
        never = NxcCore.Capabilities.deniedBy(resolved, 'police.armory.shotgun'),
      }
    `);
    assert.equal(r.denied, 'employment:police');
    assert.equal(r.never, undefined, 'different situations for an operator investigating a complaint');
  });

  test('require returns a structured error naming the capability', async () => {
    const r = await lua.doString(`
      local resolved = NxcCore.Capabilities.resolve({})
      local out = NxcCore.Capabilities.require(resolved, 'business.employees.hire', 'c-0000000000000001')
      return { ok = out.ok, code = out.error.code, cap = out.error.details.capability }
    `);
    assert.equal(r.ok, false);
    assert.equal(r.code, 'NXC_LIB_FORBIDDEN');
    assert.equal(r.cap, 'business.employees.hire');
  });

  test('revoking one employment leaves the others intact', async () => {
    const r = await lua.doString(`
      local grants = {
        { source = 'employment', sourceId = 'police', allow = { 'police.evidence.view' } },
        { source = 'business', sourceId = 'biz_1', allow = { 'business.accounts.withdraw' } },
      }
      local remaining, removed = NxcCore.Capabilities.revokeSource(grants, 'employment', 'police')
      local resolved = NxcCore.Capabilities.resolve(remaining)
      return {
        removed = removed,
        police = NxcCore.Capabilities.has(resolved, 'police.evidence.view'),
        business = NxcCore.Capabilities.has(resolved, 'business.accounts.withdraw'),
      }
    `);
    assert.equal(r.removed, 1);
    assert.equal(r.police, false, 'termination revokes immediately, including for an offline player');
    assert.equal(r.business, true, 'the other employment is untouched');
  });

  test('revoking a whole source class removes every grant from it', async () => {
    const r = await lua.doString(`
      local grants = {
        { source = 'temporary', sourceId = 'c1', allow = { 'a.b.c' } },
        { source = 'temporary', sourceId = 'c2', allow = { 'd.e.f' } },
        { source = 'employment', sourceId = 'police', allow = { 'g.h.i' } },
      }
      local remaining, removed = NxcCore.Capabilities.revokeSource(grants, 'temporary')
      return { removed = removed, left = #remaining }
    `);
    assert.equal(r.removed, 2);
    assert.equal(r.left, 1);
  });

  test('an empty grant list grants nothing', async () => {
    const r = await lua.doString(`
      local resolved = NxcCore.Capabilities.resolve({})
      return { count = #NxcCore.Capabilities.list(resolved) }
    `);
    assert.equal(r.count, 0);
  });
});
