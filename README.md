# RealtorIQ — admin panel and broker API

Multitenant Rails 8 backend for a channel-partner (broker) CRM. Two surfaces in
one app:

- **`/admin`** — internal panel where ops create and manage broker firms,
  maintain global reference data, and set plans and subscriptions.
- **`/api/v1`** — JSON API for the React broker app (separate repo).

Tenants are broker **firms**. A firm has one super admin and any number of
managers and agents. There is no self-signup anywhere: ops create the firm and
its super admin, who then signs in with a one-time code to their mobile.

## Getting started

Ruby 3.4.1 (via mise) and Postgres.

**1. Install and load the reference data.** Cities, localities, builders,
typologies, lead sources and statuses, property types, and three plans. Safe in
any environment and idempotent.

```bash
bin/setup && bin/rails db:seed
```

**2. Create an admin.** Seeds deliberately create none, so there is no default
credential anywhere for someone to inherit. The password is generated and
printed once unless you set `ADMIN_PASSWORD`.

```bash
ADMIN_EMAIL=you@example.com bin/rails admin:create
```

**3. Run it.** Sign in at http://localhost:3000/admin.

```bash
bin/dev
```

### Something to click through

For a working tenant in development — a firm, verified channels, one user of
each role, and a live subscription:

```bash
bin/rails demo:seed
```

It prints the curl commands to sign into the API as that firm's super admin.
`bin/rails demo:clear` removes it again. Both refuse to run in production.

### Admin tasks

| Task | What |
| --- | --- |
| `admin:create` | Create or reset an admin. `ADMIN_EMAIL` required; `ADMIN_NAME` and `ADMIN_PASSWORD` optional |
| `admin:list` | Who can sign in, and when they last did |
| `admin:deactivate` | Revoke access and end their open sessions. `ADMIN_EMAIL` required |

## Onboarding a firm

Creating a firm in the panel does the whole thing in one screen: the firm, its
three contact channels, its super admin, its first subscription, and activation.
That is deliberate — a firm without a live plan gets `subscription_lapsed` on
first sign-in, so leaving the plan to a later visit produced tenants that looked
finished but couldn't be used.

The broker then signs in with a one-time code to the mobile you entered. There
is no invite email and no password.

## Tests

```bash
bundle exec rspec
```

The load-bearing one is `spec/models/tenancy_isolation_spec.rb`: it fails the
build if any model with a `firm_id` is missing the `FirmScoped` concern, and it
pins the three ways associations interact with the fail-closed tenant scope.
Read it before adding a firm-owned model.

## Staging

A separate `RAILS_ENV=staging` where sign-in codes are always **`888888`** and
nothing is delivered — see **[docs/staging.md](docs/staging.md)** for the setup
steps.

It is its own environment rather than production-with-a-flag on purpose: a fixed
code is a complete authentication bypass, so production refuses to boot with one
and has no escape hatch. Keep the staging URL off the public internet.

## Sending one-time codes for real

SMS and WhatsApp go through **MSG91**; email goes through Action Mailer. The
auth key is already in Rails credentials. Each transport still needs its own
settings, and they're checked independently — SMS starts working the moment its
template id lands, without waiting on WhatsApp onboarding.

```bash
bin/rails msg91:check     # what's configured, sends nothing
bin/rails credentials:edit
```

```yaml
msg91:
  auth_key: <set>
  sms_template_id: <DLT-approved flow template id>   # still needed
  whatsapp_number: <WhatsApp Business number>         # still needed
  whatsapp_template_name: <approved template name>    # still needed
```

Indian transactional SMS is DLT-regulated: the message body is registered with
the operator as a template and referenced by id, so the app never composes it —
it only supplies the code as the template variable.

Delivery is chosen by `OTP_DELIVERY`, which defaults to `msg91` in production
and `log` everywhere else. An unconfigured transport raises a delivery error and
the API returns `delivery_failed` rather than pretending a code was sent.

## One-time codes in development

**Every code is `888888` in development and staging, and nothing is delivered.**
Sign in as any broker by entering their mobile and that code.

This is a complete authentication bypass — anyone who knows a registered mobile
number can become that broker — so production has no default and **refuses to
boot** with `OTP_FIXED_CODE` set. A warning in a deploy log gets scrolled past;
a failed boot does not.

Everything downstream is unchanged: the code is still hashed rather than stored,
still expires after ten minutes, still burns after one use, and still locks the
account after three wrong attempts. Only the digits are predictable.

The test environment deliberately keeps random codes, so the specs exercise the
real generation and attempt-counting logic.

To see the code path work normally, unset it — codes are then written to the log
by `Notifications::LogDeliverer`:

```
┌─ one-time code ──────────────────────────────
│ login via sms
│ to   +919820144210
│ code 814934
└──────────────────────────────────────────────
```

`LogDeliverer` also refuses to run in production, so a misconfiguration fails
loudly rather than quietly printing live codes into a log file.

## Where things are

| Path | What |
| --- | --- |
| `docs/schema.md` | The data model, and what is still designed but unbuilt |
| `docs/staging.md` | Staging setup — fixed codes, nothing delivered |
| `docs/postman/` | Postman collection for the broker API — chains its own tokens, 127 assertions over all 51 routes |
| `docs/postman/staging/` | The same collection pointed at staging, plus 30 post-deploy checks |
| `app/models/concerns/firm_scoped.rb` | Row-level tenancy. Fail-closed by design |
| `app/models/current.rb` | Per-request tenant. Read the comment before touching `firm_scope_bypassed` |
| `app/forms/admin/firm_form.rb` | Creates a firm, its channels and its super admin in one transaction |
| `app/services/notifications/` | Code delivery, behind an adapter |
| `app/services/api_auth/jwt.rb` | Access tokens for the broker API |
| `app/assets/tailwind/application.css` | The Modernist design tokens the panel is built from |

## Design system

The admin panel follows **Modernist**, the product's design system: Archivo
throughout, a single red accent (`#ec3013`) on a light ground, **zero corner
radius anywhere**, 2px rules instead of shadows, and labels flush left —
including inside buttons wider than their text. Take colours from the tokens in
`app/assets/tailwind/application.css`; never hard-code a hex in a view.
