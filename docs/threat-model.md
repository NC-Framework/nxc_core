# `nxc_core` — Threat Model

Every resource addresses the sixteen threats in the project security standards.

## Why this resource matters most

`nxc_core` owns **accounts, characters, sessions, and permissions**. It is the resource that answers
*who is asking* and *what they may do*.

A defect here is not a broken feature. It is impersonation, privilege escalation, or a ban that does not
ban — and every other resource's security depends on its answers being correct.

---

## The sixteen threats

| Threat | Handling |
| --- | --- |
| **Event spoofing** | The actor is resolved from the session, never from the payload. A request naming an account or character identifier is making a claim, and the claim is discarded. |
| **Replay attacks** | Sessions are identified separately from accounts, so a captured request cannot be replayed against a later session. Idempotency storage belongs to the owning domain. |
| **Permission bypass** | Capability resolution collects **denials before grants**, so a denial from any source wins and order cannot decide authorization. An unregistered capability is denied. |
| **Duplicate rewards** | Not applicable — `nxc_core` grants no rewards. It supplies the capability answer the granting domain checks. |
| **Inventory duplication** | Not applicable — owns no items. The persistence guard prevents another domain writing inventory tables through a `nxc_core`-scoped provider. |
| **Financial duplication** | Not applicable — owns no money. Same persistence guard. |
| **Vehicle cloning** | Not applicable. Bucket allocation prevents the accidental-instance failure that contributes to it. |
| **NUI callback replay** | No NUI. Session binding is available to resources that have one. |
| **Malformed payloads** | Every identifier is validated before use. Bootstrap values are validated at startup. State bag writes are validated against a registered schema. |
| **Unauthorized record access** | Selecting a character verifies it belongs to the session's account. The persistence guard refuses cross-domain queries. |
| **Entity creation abuse** | Bucket allocation is centralised, so a resource cannot pick an identifier that collides with another's instance. |
| **Resource restart behaviour** | All in-memory state — sessions, buckets, service registrations — is correctly lost on restart. Registrations are removed on stop so no stale entry survives. |
| **Disconnect during transactions** | The disconnect plan is data, produced without depending on a clean exit path, because a crashed client never runs one. |
| **Race conditions** | Capability resolution is order-independent by construction. Bucket allocation scans for a free identifier rather than trusting a counter. |
| **External service failures** | A database failure returns a **retryable structured error**, never a silent empty result — which application code would read as "no records". |
| **Rate-limit abuse** | Rate limiting is provided by `nxc_lib`; `nxc_core` supplies the actor identity that limits are keyed on. |

---

## Decisions worth stating

### The actor comes from the session

The single most important rule in the resource.

```lua
-- Wrong: the client chooses whose data to touch
local character = payload.characterId

-- Right: the server determines who is asking
local character = NxcCore.Sessions.resolveCharacter(source)
```

This prevents an entire class of impersonation exploit, and it only works if **every** resource follows
it. `nxc_core` provides no function that resolves an actor from a payload, so the wrong path requires
writing it deliberately.

### A foreign character and a missing one fail identically

Selecting a character belonging to another account returns the same error as selecting one that does not
exist.

Distinguishing them would confirm that a character identifier exists, which is a probing oracle: an
attacker enumerating identifiers learns which are real.

### Bans hang off the account

Checked against the account, not the character. **A ban that only stops one character is not a ban** —
the player simply selects another.

### Denials win, and order does not matter

Capability resolution collects every denial before any grant.

Without that, a character taking a temporary contract could silently regain a capability a department
had deliberately revoked. And because employments load asynchronously, an order-dependent resolution
would be a race that decides authorization.

### Production refuses to start with diagnostics enabled

Bootstrap validation fails — not warns — when a production environment has development mode or debug
logging on.

A warning leaves the decision to whoever reads the console. A diagnostics surface reachable in
production is an information-disclosure vulnerability, so it is a startup failure.

### Secrets are recorded as present, never by value

Bootstrap settings reach logs and health reports. The connection string and signing key are stored as
`true`, so no code path can accidentally emit them.

### The persistence guard is enforcement, not documentation

MariaDB cannot prevent one resource querying another's tables. A scoped provider checks the table prefix
on **every statement, including every statement in a transaction**, so a cross-domain write fails loudly
rather than succeeding quietly.

This is weaker than provider-enforced isolation and stronger than convention alone. The stronger option —
a separate database user per resource — is recorded in ADR-0003 as available if this proves insufficient.

### Every state bag is client-visible

Registration refuses keys whose leaf names money, items, capabilities, tokens, or medical and justice
data. The list is blunt on purpose: a false positive costs a conversation, a false negative is a
permanent client-visible disclosure.

---

## What this resource does not defend against

- **A resource that resolves an actor from a payload anyway.** `nxc_core` makes the correct path the easy
  one; it cannot prevent the wrong one being written.
- **A resource that queries the database directly** rather than through a scoped provider. The guard
  applies only to callers that use it.
- **Concurrent logins on one account.** The policy is an open question in ADR-0012; `Sessions.forAccount`
  reports the facts a policy would need, and no policy is enforced yet.
- **Anything requiring persistence.** Ban records, whitelist state, and capability grants all live in
  storage this resource defines an interface to and does not yet implement.

The last point is the largest gap today: **the MariaDB adapter is not written**, so the persistence
interface has an in-memory double and nothing else.
