# Postman collection — Broker API v1

Two files:

- `RealtorIQ.postman_collection.json` — the requests, with tests
- `RealtorIQ.local.postman_environment.json` — where to point them

Import both (Postman → Import → Files), pick **RealtorIQ — Local** from the
environment dropdown, and run the folders top to bottom.

## Before you run it

```bash
bin/rails db:seed && bin/rails demo:seed && bin/dev
```

`demo:seed` creates the firm the collection signs into, with three users:

| Role | Mobile |
| --- | --- |
| `super_admin` | 9820144210 |
| `manager` | 9820144211 |
| `agent` | 9820144212 |

Sign-in codes are `888888` in development and nothing is delivered.

## It chains itself

You never copy a token. The test scripts write the runtime values into
**collection** variables as they go:

| Request | Captures |
| --- | --- |
| `1. Request sign-in code` | `request_id` |
| `2. Verify code and sign in` | `access_token`, `refresh_token` |
| `List channels` | `channel_id` (prefers an unverified channel) |

Collection auth then sends `Bearer {{access_token}}` on everything else.

**The environment holds configuration only** — `base_url`, the mobiles, the OTP
code. Runtime values are deliberately *not* in it: environment scope beats
collection scope in Postman, so an empty `request_id` there would shadow the one
the script just captured and every request after sign-in would fail. That is a
real bug this collection had before it was run end to end.

## Order matters

`Sign out` is its own folder at the end, because it revokes the session — put it
in the Auth folder and everything after it gets 401.

The two error-state requests that need their own setup carry pre-request scripts:
`Wrong code` mints a fresh `request_id` (the real one has been consumed), and
`Agent verifying a channel` signs in as the agent so the 403 is genuine.

## Running it headless

```bash
npx newman run docs/postman/RealtorIQ.postman_collection.json -e docs/postman/RealtorIQ.local.postman_environment.json
```

29 assertions on a freshly seeded database. It is safe to re-run without
reseeding: the channel assertions accept both "code sent" and "already verified",
so a second pass stays honest rather than green by luck. Re-run `demo:seed` to
reset the demo firm's WhatsApp channel to unverified.

## What isn't here

The admin panel. It is server-rendered HTML on cookie sessions, not an API —
drive it in a browser at `/admin`.
