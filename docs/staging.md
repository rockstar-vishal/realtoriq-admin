# Staging

Production in every respect except three, each chosen so the environment can be
exercised without reaching a real broker or a real rupee:

| | Staging | Production |
| --- | --- | --- |
| Sign-in code | **Always `888888`** | Generated, six random digits |
| Delivery | Written to the log. MSG91 is never called | MSG91 (SMS/WhatsApp) + Action Mailer |
| OTP rate limit | 100 per IP / 5 min | 12 per IP / 5 min |
| Email | `delivery_method = :test` — nothing leaves | Real SMTP |

Everything else — eager loading, caching, SSL, Solid Queue/Cache/Cable, the four
databases — matches production.

## Why it is a separate RAILS_ENV

A fixed sign-in code is a **complete authentication bypass**: anyone who knows a
registered mobile number can sign in as that broker. The application therefore
**refuses to boot in production** with `OTP_FIXED_CODE` set, and that guard has
no escape hatch — a guard production could switch off is not a guard.

So staging is `RAILS_ENV=staging`, not production with a flag. Running your
staging box as `RAILS_ENV=production` will fail to boot the moment you set the
fixed code, and that is the intended behaviour.

**Treat the staging URL as sensitive.** Keep it off the public internet — VPN, IP
allowlist, or HTTP basic auth in front of it. Anyone who reaches it and knows a
broker's mobile number is that broker. The app logs a warning to this effect on
every boot.

## Setup

Ruby 3.4.1, Postgres, and the repo checked out.

**1. Environment variables.** The three that matter:

```bash
export RAILS_ENV=staging
export SECRET_KEY_BASE=$(bin/rails secret)
export RAILS_MASTER_KEY=$(cat config/master.key)
```

`RAILS_MASTER_KEY` is required — Active Record encryption (the bank-account
field) reads its keys from credentials, and the app will not boot without it.

Optional, with sensible defaults:

| Variable | Default | Notes |
| --- | --- | --- |
| `APP_HOST` | `http://localhost:3000` | Public origin. **Set this** — file URLs are absolute |
| `ALLOWED_HOSTS` | unset (any) | Comma-separated, e.g. `staging.realtoriq.in` |
| `CORS_ORIGINS` | `http://localhost:5173` | Where the React app is served from |
| `DATABASE_HOST` / `DATABASE_USERNAME` | `localhost` / `kgen_realtoriq_admin` | |
| `KGEN_REALTORIQ_ADMIN_DATABASE_PASSWORD` | — | |
| `STORAGE_SERVICE` | `local` | `amazon` once S3 is configured |
| `FORCE_SSL` / `ASSUME_SSL` | `true` | Set both `false` if terminating plain HTTP |
| `OTP_FIXED_CODE` | `888888` | Only to change the code; you do not need to set it |

**2. Databases.** Staging has its own four, named `..._staging*`, so it can never
point at production's.

```bash
bin/rails db:prepare
```

**3. Reference data and an admin.**

```bash
bin/rails db:seed
```

```bash
ADMIN_EMAIL=you@example.com bin/rails admin:create
```

The password is printed once. Add `ADMIN_PASSWORD=` to choose your own.

**4. Demo tenant** — optional, and safe here. `demo:seed` refuses to run in
production but not in staging, which is deliberate: staging is exactly where you
want a firm to click through.

```bash
bin/rails demo:seed
```

**5. Assets, then boot.**

```bash
bin/rails assets:precompile
```

```bash
bin/rails server -e staging
```

Background jobs, if you need them (OTP email delivery is the only user today):

```bash
bin/jobs
```

## Signing in

Any registered mobile, code `888888`. The demo firm gives you one of each role:

| Role | Mobile |
| --- | --- |
| `super_admin` | 9820144210 |
| `manager` | 9820144211 |
| `agent` | 9820144212 |

```bash
curl -s -X POST "$APP_HOST/api/v1/auth/otp" -H 'Content-Type: application/json' -d '{"mobile":"9820144210"}'
```

Take the `request_id` from that, then:

```bash
curl -s -X POST "$APP_HOST/api/v1/auth/verify" -H 'Content-Type: application/json' -d '{"request_id":"<from above>","code":"888888"}'
```

Point the Postman environment's `base_url` at the staging host and the whole
collection runs against it unchanged — `otp_code` is already `888888`.

## Verifying the environment is what you think

```bash
bin/rails runner -e staging 'puts [Rails.env, Rails.configuration.x.otp_fixed_code, Rails.configuration.x.otp_delivery].inspect'
```

Expect `["staging", "888888", "log"]`. If `otp_delivery` reads `msg91` you are
not in staging, and real messages will be sent.

```bash
bin/rails msg91:check
```

Reports what is configured without sending anything.

## Going to production later

Nothing to undo. Deploy the same code with `RAILS_ENV=production` and do **not**
set `OTP_FIXED_CODE` — production has no default, generates real codes, and
refuses to boot if a fixed one is supplied. Before real brokers sign in you will
need the MSG91 `sms_template_id` (DLT-approved) and, for WhatsApp, the business
number and template name.
