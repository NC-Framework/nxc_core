# `nxc_core` — Performance Budget

> **These figures are estimates, not measurements.** No target server build, OneSync mode, concurrent
> player count, or development environment has been identified. Recalibration is required once one
> exists.

## The ten dimensions

| Dimension | Budget | Basis |
| --- | --- | --- |
| **Idle client CPU** | **0.00 ms/frame** | The implemented modules register no thread and no tick. Not an estimate — there is nothing running. |
| **Active client CPU** | < 0.1 ms/frame | Client work is limited to reading replicated session state. |
| **Server tick impact** | **0.00 ms/tick** | No polling loop. Everything is event-driven: connection, selection, disconnect. |
| **Maximum event frequency** | 2 per player per session | `playerLoaded` and `playerUnloaded`. Character switching adds one pair per switch. |
| **Maximum payload size** | 2 KiB per lifecycle event | Identifiers and stage, not records. Consumers read what they need from the owner. |
| **Queries per action** | See below | |
| **Cache policy** | Sessions and buckets in memory; **no cached authority** | Permission resolution may be cached per session, invalidated on any grant change. |
| **NUI memory** | n/a | Ships no NUI. |
| **Entity-scan scope** | None | Scans no entities. Bucket occupancy is a maintained set, not a scan. |
| **Degraded mode** | See below | |

## Queries per action

| Action | Expected | Note |
| --- | --- | --- |
| Connection | 2 | Account lookup, ban and whitelist check |
| Character list | 1 | Scoped to the account |
| Character load | 1 | Single record by immutable identifier |
| Character switch | 2 | Save the previous, load the next |
| Disconnect | 1 | Persist last-seen and position |
| Capability resolution | 1 | Grants for the character, resolved in memory |

**Connection cost is the number that matters.** It is on the path every player takes and is the one an
operator notices during a restart rush, when the whole population reconnects at once.

## Complexity of the hot paths

| Operation | Cost |
| --- | --- |
| `Sessions.resolveAccount` / `resolveCharacter` | Constant. One table lookup. Called on **every** request, so this is the single most-executed function in the framework. |
| `Capabilities.resolve` | Linear in the number of grants, which is the number of concurrent employments — single digits in practice |
| `Buckets.enter` / `leave` | Constant, plus an emptiness check |
| `Buckets.allocate` | Constant in the normal case. Scans for a free identifier only when the counter wraps. |
| `Buckets.removeOccupant` | **Linear in allocated buckets.** Called once per disconnect. See below. |
| `Identifiers.new` | Constant. Fixed-length encoding, no allocation beyond the string. |
| `Persistence` guard | Linear in statement length. Runs per statement, including inside transactions. |

### The one path worth watching

`Buckets.removeOccupant` sweeps every allocated bucket. It is called once per disconnect, and it must
sweep rather than target a known bucket because **a crashed client never runs a clean exit path**.

At the expected scale — dozens to low hundreds of buckets — the sweep is trivial. If bucket count ever
reaches thousands, this becomes worth an occupant-to-bucket index. It is recorded now so the decision is
informed rather than discovered.

## Memory

| Structure | Growth | Bounded by |
| --- | --- | --- |
| Sessions | One per connected player | Server slot count |
| Buckets | One per active instance | Released when empty and unheld |
| Service registry | One per resource | The resource count, ~97 at most |
| State bag registry | One per registered key | Registered at startup, removed on stop |

**Every structure has a removal path**, and each is exercised by a test: sessions on disconnect, buckets
on leave and on owner release, services on unregister, state bags on owner unregister.

That matters more than the sizes. A structure without a removal path is a leak that only appears after
days of uptime, which is exactly when it is hardest to diagnose.

## Degraded-mode behaviour

| Condition | Behaviour |
| --- | --- |
| Bootstrap invalid | **Refuse to start**, with a structured error naming every problem |
| Database unavailable | Retryable structured error. Never a silent empty result. |
| `nxc_config` not yet registered | Run on declared defaults, which are part of the schema |
| An optional service absent | Report `present = false`. A condition, not a failure. |
| Buckets exhausted | Structured error. Allocation fails rather than colliding with a live instance. |
| A cross-domain query attempted | Refused before reaching the provider |

## Measured so far

| Measurement | Value | Conditions |
| --- | --- | --- |
| Full test suite | ~300 ms | 83 tests, 9 suites, `wasmoon` under Node 24 |

A test-harness figure. It says nothing about in-game cost and is recorded because it is the only real
number this resource has.

## What must be measured

1. **Connection path latency** under a restart rush, when the whole population reconnects at once.
2. **`resolveCharacter` cost** at request volume — it is the most-executed function in the framework.
3. **Bucket count** at realistic instancing load, which decides whether the disconnect sweep needs an
   index.
4. **Query count per connection** against the real schema, once the MariaDB adapter exists.
