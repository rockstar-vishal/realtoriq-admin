# Postman — staging

**The full API collection is `RealtorIQ.postman_collection.json` in this folder.**
It is a symlink to the one in the parent directory, so there is exactly one copy
to maintain and it cannot drift.

```bash
npx newman run docs/postman/staging/RealtorIQ.postman_collection.json \
  -e docs/postman/staging/RealtorIQ.staging.postman_environment.json
```

| File | What | Size |
| --- | --- | --- |
| `RealtorIQ.postman_collection.json` → `../` | **Every API.** Run this one | 56 requests, 117 assertions |
| `RealtorIQ.staging-checks.postman_collection.json` | Post-deploy health check only | 11 requests, 30 assertions |
| `RealtorIQ.staging.postman_environment.json` | The environment both use | — |

The *checks* collection is deliberately small and deliberately not the API: it
asserts environment facts — TLS and HSTS, the admin panel turning anonymous
callers away, Active Storage's direct-upload endpoint still shadowed, and that
sign-in codes really are pinned to `888888` on this box. Run it after a deploy;
run the full collection when you want to know the API works.

```bash
npx newman run docs/postman/staging/RealtorIQ.staging-checks.postman_collection.json \
  -e docs/postman/staging/RealtorIQ.staging.postman_environment.json
```

## Coverage

**49 of 51 routes.** The two that are missing are missing because no client can
call them:

- `DELETE /api/v1/projects/:id/photos/:photo_id`
- `DELETE /api/v1/properties/:id/photos/:photo_id`

Both take an **attachment id**, and no response anywhere returns one — the
project and property serializers expose `photo_urls`, `photo_count` and
`cover_photo_url`, never the id. The signed blob URL encodes the *blob* id,
which is a different thing, so it cannot be scraped out either. Verified against
staging: attaching a photo succeeds, and every subsequent delete is a 404.

The fix is in the serializers, not here — return photos as
`[{ id, url }]` alongside `photo_urls`. Add the two requests once it lands.

## Re-running

Both collections are safe to re-run. Anything unique per firm — firm names,
invoice numbers, document labels — carries `{{$timestamp}}`, and the checks
collection creates no data at all.

Run the folders **top to bottom**. `Sign out` is last because it revokes the
session; anything after it gets a 401.

## The demo firm

The environment signs in as the firm `bin/rails demo:seed` creates, currently
**Sethi Realty**:

| Role | Mobile |
| --- | --- |
| `super_admin` | 9820144210 |
| `manager` | 9820144211 |
| `agent` | 9820144212 |

If staging is rebuilt from scratch, re-run `RAILS_ENV=staging bin/rails db:seed`
and `RAILS_ENV=staging bin/rails demo:seed`, or the collection has nobody to
sign in as.

## Sign-in codes are 888888

Staging pins every one-time code and delivers nothing. That is what makes the
collection runnable without a phone, and it is **a complete authentication
bypass**: anyone who knows a registered mobile number can sign in as that broker.

- **Never point this environment at production.** Production refuses to boot with
  `OTP_FIXED_CODE` set, so the fixed code would not work — but the demo mobiles
  would still be real sign-in attempts against real accounts.
- **The staging host should not be on the open internet.** It currently is. See
  [`docs/staging.md`](../../staging.md).

## The admin panel is not in here

It is server-rendered HTML on cookie sessions, not an API. Drive it in a browser
at https://staging.realtoriq.kgen.tech/admin.
