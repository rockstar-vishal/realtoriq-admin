# RealtorIQ — Broker API v1

Reference for the React broker app. Every fact here was read out of the code or
observed against a live server; nothing is aspirational.

**Base URL** — `https://staging.realtoriq.kgen.tech/api/v1`

- [Conventions](#conventions)
- [Authentication](#authentication)
- [Session and reference data](#session-and-reference-data)
- [Users](#users)
- [Dashboard](#dashboard)
- [Reports](#reports)
- [Leads](#leads)
- [Inventory — projects, properties](#inventory)
- [Bookings and money](#bookings-and-money)
- [File uploads](#file-uploads)
- [Firm contact channels](#firm-contact-channels)
- [Notifications](#notifications)
- [Trainings](#trainings)
- [Inbound enquiries](#inbound-enquiries)
- [Facebook Lead Ads](#facebook-lead-ads)
- [Error codes](#error-codes)
- [Traps worth knowing](#traps-worth-knowing)

---

## Conventions

**Content type** — `application/json` on every request with a body.

**Parameters are flat.** There is no `{"lead": {...}}` wrapper anywhere:

```json
{ "name": "Yash Raheja", "mobile": "97597 54343", "transaction_type": "sale" }
```

**Responses are wrapped**, by the singular or plural resource name:

```json
{ "lead": { ... } }
{ "leads": [ ... ], "counts": { ... }, "meta": { ... } }
```

`counts` is only on `GET /leads` (pipeline card totals). Other lists are `resource` + `meta`.

**Ids** are UUIDv7 strings. They sort by creation time, so "newest first" and
"highest id first" agree.

**Money** is always a whole-rupee integer — `15600000` is ₹1,56,00,000. Never a
float, never paise, never a formatted string. Percentages are numbers
(`4.5`). Do not do money arithmetic on the client: the server sends every
derived total you need.

**Dates** are `YYYY-MM-DD`. **Timestamps** are ISO 8601 with the IST offset
(`2026-08-17T00:35:56.587+05:30`).

**Phone numbers** are normalised on write and returned in E.164
(`+919759754343`). You may send `97597 54343`, `9759754343` or `+919759754343` —
all the same number.

**Pagination** — list endpoints take `page` and `per_page` and return:

```json
"meta": { "page": 1, "per_page": 25, "total_count": 23, "total_pages": 1 }
```

`per_page` is clamped to 1–50. Absent or `0` means **25**. A `page` or
`per_page` that is not a whole number is `422 invalid` ("Page must be a whole
number, 0 or more." / "per_page must be a whole number, 0 or more."). `page`
of `0` or below still opens page 1.

A list filter that is present but cannot be read is `422 invalid` as well.
That is a budget or price that is not a whole number of rupees (spaces and
commas are stripped first; `1,00,000` is 100000), an area that is not a whole
number, a brokerage that is not a number, a date that is not `YYYY-MM-DD` or a
from-date after its upto, an id that is not a record id, or an enum outside
the values listed for that endpoint. The message names the field, in the same
shape as the date error. A parameter the endpoint does not use is still ignored.

**Errors** always have this shape, and you switch on `code`, never on the prose:

```json
{ "error": { "code": "over_invoiced", "message": "…", "details": { "available": 286000 } } }
```

`details` is present when there is something actionable in it — the remaining
balance, the attempts left, the failing fields.

---

## Authentication

**There are no passwords.** Possession of the mobile number is the credential,
Brokers may apply at `/self-signup`. Nobody gets a workspace until ops activate the firm in `/admin`. A pending firm cannot sign in.

### Flow

```
POST /auth/otp     { mobile }                    → request_id
POST /auth/verify  { request_id, code, device }  → access_token + refresh_token
POST /auth/refresh { refresh_token }             → a new pair
DELETE /auth/session { refresh_token }           → 204
```

Send `Authorization: Bearer <access_token>` on everything else.

| | Lifetime |
| --- | --- |
| Access token (JWT) | **15 minutes** |
| Refresh token | **60 days** |

**Refresh tokens rotate.** Each refresh invalidates the one you sent — store the
new one immediately. Replaying an old refresh token is a `401`, and that is also
how a stolen token gets caught.

### `POST /auth/otp`

| Field | Type | |
| --- | --- | --- |
| `mobile` | string | required |

```json
{ "request_id": "01a0…", "sent_to": "+919820144xxx", "expires_in": 599, "attempts_allowed": 3 }
```

The number comes back masked. An unknown mobile is `404 not_registered`, and the
message points at `https://api.realtoriq.kgen.tech/self-signup`. A pending firm is
`403 account_unapproved` and no code is sent. Production allows 5 requests for
one mobile per 15 minutes, and 60 per IP per 5 minutes. Other environments
allow 100 of each. An unknown mobile still counts against the IP. Either limit
is `429 rate_limited`. Three wrong codes on verify still lock that user.

### `POST /auth/verify`

| Field | Type | |
| --- | --- | --- |
| `request_id` | string | required |
| `code` | string | required, 6 digits |
| `device` | object | optional — `device_id`, `device_name`, `platform`, `app_version` |

```json
{
  "access_token": "<jwt>", "refresh_token": "<opaque>", "expires_in": 900,
  "user": { "id": "…", "name": "…", "mobile": "+91…", "role": "super_admin" },
  "firm": { "id": "…", "name": "Sethi Realty", "code": "CP-MH-18911", "status": "active" },
  "subscription": { "plan": "Growth", "status": "active", "entitled": true, "renews_on": "2026-09-18" }
}
```

Codes **expire in 10 minutes**, **burn after one use**, and three wrong attempts
**locks the account for 30 minutes** (`otp_locked`). A burned code counts as a
failed attempt, so retrying a consumed code eats into the three.

`details.attempts_left` tells you how many remain — show it.

> **On staging every code is `888888` and nothing is delivered.** Production
> generates six random digits and refuses to boot with a fixed code set.

### Roles

`super_admin`, `manager`, `agent`.

| | agent | manager | super_admin |
| --- | :-: | :-: | :-: |
| Leads assigned to them | ✅ | ✅ | ✅ |
| The firm's whole pipeline | ❌ | ✅ | ✅ |
| Reassign a lead | ❌* | ✅ | ✅ |
| Inventory (read) | ✅ | ✅ | ✅ |
| My Projects writes, firm builders | ❌ | ❌ | ✅ |
| Bookings, invoices, collections | ❌ | ✅ | ✅ |
| Verify firm contact channels | ❌ | ❌ | ✅ |
| Create / disable users, edit reporting lines | ❌ | ❌ | ✅ |

\*Agents can reassign a lead they can see to someone in their **active manageables** (themselves, plus anyone who reports to them). They cannot unassign.

`manage_users` on `GET /me` is the flag to drive the team screen — do not switch on `role` for that. `manage_projects` is the flag for My Projects create/edit/photos and for inline builder create. `manage_prospects` is the flag for deleting one prospect and for clearing the calling list.

Anything an agent may not do is `403 forbidden_role`. **A lead an agent may not
see is `404`, not `403`** — a 403 would confirm the record exists.

### Blocked account states

Checked on every authenticated request, so handle them globally:

| Code | Status | Meaning |
| --- | --- | --- |
| `unauthorized` | 401 | No token, malformed token, or the session was revoked |
| `account_suspended` | 403 | Ops suspended the firm. Sign the user out |
| `account_disabled` | 403 | This user specifically |
| `subscription_lapsed` | **402** | The firm's plan expired. Not an auth failure — show a billing wall |

`account_suspended` applies to a **live** access token, not only at sign-in — a
firm suspended mid-session starts failing on the next call.

---

## Registration

`GET /self-signup` is HTML on the API host, not a JSON endpoint. The broker verifies mobile and email, then submits once. WhatsApp is required and can be verified later. A successful submit creates a **pending** firm. Ops activate it from `/admin` after assigning a live plan. There is no draft. `GET /register` redirects there.

`GET /legal/terms` and `GET /legal/privacy` serve the pinned texts. `?embed=1` returns the body without the page chrome.

## Session and reference data

### `GET /me`

```json
{
  "user":   { "id": "…", "name": "Tanmay Sethi", "mobile": "+919820144210",
              "role": "super_admin", "notification_mode": "all", "rera_number": null },
  "firm":   { "id": "…", "name": "Sethi Realty", "code": "CP-MH-18911", "status": "active",
              "city": "Navi Mumbai", "logo_url": null, "channels_verified": true },
  "subscription": { "plan": "Growth", "status": "active", "entitled": true,
                    "renews_on": "2026-09-18", "amount": 2499 },
  "permissions":  { "manage_firm_settings": true, "verify_contact_channels": true,
                    "manage_users": true, "manage_projects": true, "manage_prospects": true },
  "limits":       { "devices": 3, "users": 5 }
}
```

**Drive the UI from `permissions`, not from `role`.** It is computed server-side
and will not drift when the rules change.

### `GET /reference`

Every dropdown in one call — cache it and refresh on app start.

```
cities[]         id, name, state, state_code
localities[]     id, city_id, name, pincode, lat, lng   ← lat and lng are null until a centre is known
builders[]       id, name, global
typologies[]     id, name, code, bedrooms, category, area_kind, uses_floor_band, details[]
lead_sources[]   id, name, code, category
lead_statuses[]  id, name, code, is_dead, is_booked, is_terminal
property_types[] id, name, code                  ← possession options; the key stays property_types
categories[]     code, name                      ← residential, commercial, land
area_units[]     code, label, sqft               ← sqft factor is a decimal string
pre_leased_details[]  key, label, type, options, min, max, unit
tenant_types[]   code, name
transaction_types[]  code, name                  ← fixed: sale, rent
floor_bands[]        code, name                  ← fixed: lower, middle, higher
prospect_statuses[]  code, name                  ← fixed: new, following, interested, not_interested
matching             anchor_radius_m             ← null while anchor matching is off
```

`localities` is a **flat list carrying `city_id`**, not nested under cities.
`lat` and `lng` are the locality centre, or null when it has not been placed.
`matching.anchor_radius_m` is the anchor circle in metres, or null while
anchor matching is off. The lead form draws its circle from it.
`typologies` is the configurations a broker can pick: active, and not merged
into another configuration. `category` is `residential`, `commercial`, or
`land`. `area_kind` is `carpet` or `plot`. `uses_floor_band` is false for
villa, row house, plots, and commercial configurations other than office.
`bedrooms` is still a JSON number. `details[]` is that configuration's
optional fields: `key`, `label`, `type` (`select`, `integer`, `decimal`,
`boolean`, `date`), `options` (`code` and `label`), `min`, `max` and `unit`.
A configuration with no spec has `details: []`.
`pre_leased_details[]` uses that same shape, so a select's `options` are
`{ code, label }`. Tenant names are Bank, Retail brand, F&B, Clinic,
Office tenant, and Other.

Seeded values today: statuses `new`, `hot`, `followup`, `visit_planned`,
`negotiation`, `booked`, `dead` · sources `portal_housing`, `portal_99acres`,
`portal_magicbricks`, `referral`, `walk-in`, `social_meta`, `cold_call`,
`builder_microsite`, `website` · property types
`under_construction`, `ready_possession`.

Never hardcode these ids. **Switch on `code`**, and use `is_dead` / `is_booked`
rather than matching a name.

---

## Users

Ops create the firm and its one super admin. That person creates everyone else.
There is no invite SMS — the new user signs in with their mobile and a code.

A firm has **exactly one** super admin. They cannot be disabled or demoted here,
and nobody can be promoted into the role.

### `GET /users`

| Caller | Who comes back |
| --- | --- |
| Super admin | The whole firm, **including disabled** (the team screen re-enables them) |
| Anyone else | **Active manageables** — themselves plus everyone who reports to them, walking the reporting graph. Disabled people in the line are omitted |

No pagination: a firm's user cap is small enough that the picker loads in one shot.

```json
{
  "users": [
    {
      "id": "…", "name": "Rohit Shah", "role": "manager",
      "mobile": "+919820144211", "email": "rohit@example.com",
      "status": "active", "active": true,
      "managers": [ { "id": "…", "name": "Priya Mehta", "role": "agent" } ]
    }
  ]
}
```

`active` is `status == "active"`. Drive the picker off this list: the ids here are
exactly the ids `PATCH /leads/:id` will accept as `assigned_user_id` for this
caller (the super admin's list also includes disabled people — filter those out
in the picker).

### `GET /users/:id`

Same payload as one list row. Super admin: anyone in the firm. Anyone else:
`404` unless that person is in their active manageables.

### `POST /users`

Super admin only. `{ name, mobile, role, email?, rera_number?, notification_mode?, manager_ids? }`.

`role` is `manager` or `agent` — sending `super_admin` is `422 invalid`.
`manager_ids` is an **array** of user ids; the super admin is not a valid
manager here (they already see the whole firm). The new user can sign in at
once.

`422 user_limit_reached` when the plan's `max_users` is hit. The message is
"All {n} seats on this plan are in use, including disabled members." **Disabled
users count toward the cap.** `max_users: null` is unlimited.

### `PATCH /users/:id`

Super admin only. `{ name, mobile, email, role, status, rera_number, notification_mode }`.

`status: "disabled"` revokes every live session. Reversible with `status: "active"`.
Role changes stay inside `manager` / `agent`.

### Reporting lines

A person may have **several** managers. The graph is not a tree. Super admins
are not stored in it. Agents may appear as `manager_id` so a senior agent can
own a slice of the pipeline.

| | |
| --- | --- |
| `POST /users/:id/managers` | `{ manager_id }`. Super admin only. A cycle is `422 reporting_cycle` |
| `DELETE /users/:id/managers/:manager_id` | Super admin only |

Disabling a user does **not** drop their reporting lines. A manager above them
still reaches them (and their reports) through `manageables`; they just cannot
be assigned a lead until they are active again.

---

## Dashboard

### `GET /dashboard`

> **This response has no featured-projects list.** The home screen loads that
> strip itself: the first 5 marketplace projects for this firm
> (`GET /projects?source=catalog&sort=relevant`). Those are LaunchIQ listings.
> The firm's own projects are not included. `inventory.projects` is a count, not a list.

The whole home screen in one request — pipeline counters, money tiles, the
inventory strip, and the top three of each list.

It exists because every counter is derivable from a filter the API already
exposes, so the alternative was six round trips for one card.

```json
{
  "leads": {
    "total": 29, "worklist": 22, "new": 4, "hot": 14, "hot_negotiation": 19,
    "todays_followups": 3, "missed_followups": 4,
    "visit_planned": 2, "visited": 8, "bookings": 2,
    "recent": [ /* at most 3 missed followups, most overdue first; same item shape as GET /leads */ ]
  },
  "prospects": { "new": 12, "following": 4, "interested": 2, "not_interested": 1 },
  "money": {
    "revenue_till_date": 68400000, "brokerage_earned": 413000, "bookings_count": 6,
    "this_month": { "bookings": 1, "revenue": 6900000, "brokerage": 69000 },
    "this_fy":    { "label": "2026-27", "starts_on": "2026-04-01", "ends_on": "2027-03-31",
                    "bookings": 6, "revenue": 68400000, "brokerage": 413000 },
    "registered": { "count": 2, "value": 31200000 },
    "cancelled":  { "count": 1, "value": 9000000 },
    "invoiced": 686000, "collected": 400000, "outstanding": 286000,
    "recent": [ { "id": "…", "code": "B-0001", "status": "live",
                  "customer_name": "Rhea Kapoor", "agreement_value": 15600000,
                  "net_income": 686000, "booked_on": "2026-08-24",
                  "lead": { "id": "…", "code": "L-0001" } } ]
  },
  "inventory": { "properties": 14, "properties_added_this_week": 3, "projects": 5 },
  "generated_at": "2026-09-10T18:22:10.114+05:30"
}
```

**The `money` block is absent for an agent — not zeroed.** Agents get
`forbidden_role` on every booking endpoint, and a block full of zeroes would
read as "no revenue", which is a different and wrong statement. Branch on the
key being present, not on the values.

**`prospects` is four firm-wide counts**, the same numbers for an agent and a
manager. Prospects are not assigned. The block has no names and no phone
numbers. Home buttons deep-link to `GET /prospects?status=`. The list's own
`counts` add `worklist`, `todays_followups` and `missed_followup`. This block
stays these four.

Everything else is scoped the same way the list endpoints are: an agent's
counters cover only leads assigned to them.

**Definitions worth pinning down**, because they are easy to assume wrong:

| Field | Means |
| --- | --- |
| `revenue_till_date` | Σ `agreement_value` over **live** bookings — gross value sold |
| `brokerage_earned` | Σ `net_income` — what the firm keeps. A different number |
| `worklist` | Not terminal (not Dead or Booked) and not unqualified. Home tile: **Worklist**. `total` stays |
| `new` | Status code `new` |
| `visit_planned` | Status code `visit_planned` — not `visited` |
| `hot_negotiation` | Status `hot` **or** `negotiation`. `hot` is still hot-only |
| `visited` | Leads with at least one `lead_visits` row — ever, not this month |
| `todays_followups` | `next_action_at` falls today. Home tile label: **Today's Calls** |
| `missed_followups` | `next_action_at <= now` on a non-terminal lead, **or** a Visit Planned lead whose `visit_planned_at` has passed. Today's Calls stays `next_action_at` only |
| `cancelled` | Counted **separately** and excluded from every figure above |

The home **Your pipeline** snapshot uses `worklist`, `new`,
`todays_followups`, `missed_followups`, `visit_planned`, `hot_negotiation`.
`total` stays for anything that still reads it. `hot`, `visited` and `bookings`
remain on the payload. `GET /leads` `counts` has `worklist` and `todays_calls`
(the same today rule as `todays_followups`) plus Visited and Booked, and has no
Total. There is no `status=todays_followup`; the Today's Calls tile lists via
`ncd_from` / `ncd_upto` for today (IST). The Worklist tile lists via
`view=worklist`.

**`leads.recent` is the missed-followup strip under the grid** — at most three,
most overdue first (`next_action_at ASC`), same item shape as `GET /leads`.
A Visit Planned visit whose time has passed is overdue here too.
It is **not** the worklist and not the leads-index NCD default. Empty if
nothing is overdue. "View all" is `GET /leads?missed_followup=true`.

**`todays_followups` and `missed_followups` overlap.** A followup due at 10am is
still "today's" at 5pm *and* already overdue. That is deliberate: the tiles
deep-link to `GET /leads`, and `missed_followup=true` there uses the same
rule — a tile that disagreed with the list it opens would be the real bug.

**`this_fy` is the Indian financial year, 1 April to 31 March.** A 31 March
booking and a 1 April one fall in different years. `label` is `"2026-27"`.

## Reports

Four grouped queries. Dates are inclusive calendar days in **Asia/Kolkata**.
Omit `from` and `upto` and the window is the last 30 days, including today.
A lead created at 00:30 IST on 1 April belongs in April.

`export=csv` returns the on-screen table as `text/csv`. Do not send
`format=csv` — Rails treats `format` as the response type and answers 406.
A cell that starts with `=`, `+`, `-` or `@` is prefixed with a quote.

Shared filters, all optional:

| Param | Notes |
| --- | --- |
| `from`, `upto` | `YYYY-MM-DD`. `from` after `upto`, or a non-date, is `422 invalid` |
| `transaction_type` | `sale` or `rent`. Blank is both. Anything else is `422 invalid` |
| `property_type_id` | Repeat the key, or comma-separate. Rent leads have no property type, so rent plus a type is an empty report. A value that is not an id is `422 invalid` |
| `source_id` | Repeat or comma-separate |
| `source_missing` | `true` adds leads with no source. With `source_id`, the list is those sources **plus** no source |
| `assigned_user_id` | Repeat or comma-separate. Narrows the leads the caller can already see. An agent cannot widen it to someone else's leads |
| `category` | `residential`, `commercial`, or `land`. Blank is every category. Anything else is `422 invalid`. Bookings and revenue follow the booking's lead |

`GET /reports/source_status` and `GET /reports/dead_leads` are every role.
An agent sees `Lead.visible_to` (their assigned leads). A manager or super
admin sees the firm. Both also take `status` (status codes, repeated or
comma-separated).

`GET /reports/bookings` and `GET /reports/revenue` are managers and super
admins, firm-wide. An agent gets `403 forbidden_role` with "Only a manager
can work with bookings." These two **ignore `status`**: saving a booking
does not mark the lead Booked. Cancelled bookings stay in the count columns
and stay out of every rupee, invoice and collection figure.

Money is whole rupees, already computed. Outstanding is invoiced minus
collected. Do not recompute it, and do not sum money through an invoice join.

### `GET /reports/source_status`

One row per source, in `sort_order`, plus **No source**. Housing and 99acres
stay separate; `lead_sources.category` is not used. An inactive source still
gets a row when the window contains one of its leads. Columns are the active
statuses in `sort_order`, plus any inactive status that has a lead in the
window, plus Total. A cell is leads **created** in the window whose source
and status are those **now**. A status or source filter hides the other
columns and rows.

```json
{
  "from": "2026-04-01", "upto": "2026-04-30",
  "columns": [ { "id": "…", "code": "hot", "name": "Hot" } ],
  "rows": [ { "source": { "id": "…", "name": "Housing" }, "counts": { "hot": 2 }, "total": 2 } ],
  "summary": { "total": 2, "counts": { "hot": 2 } }
}
```

`source.id` is `null` and `source.name` is `"No source"` for leads with no source.

### `GET /reports/dead_leads`

One row per IST calendar month the window touches, including months that are
all zeros. **Generated** is leads created in that month's overlap with the
window. **Dead** is `COUNT(DISTINCT lead_id)` of status changes into `is_dead`
in that overlap — a lead marked dead twice in one month counts once, and a
lead later revived still counts. **Rate** is the integer percent, half-up, of
that row's dead over generated, or `null` when generated is 0. The summary
rate uses the summary totals, not the average of the monthly rates. The rate
can exceed 100. Source columns are the sources of the dead leads only;
`by_source` keys are the source id or `"none"`.

```json
{
  "from": "2026-08-01", "upto": "2026-09-30",
  "sources": [ { "id": null, "name": "No source" } ],
  "rows": [ { "month": "2026-08", "label": "Aug 2026", "generated": 1, "dead": 0, "rate": 0, "by_source": { "none": 0 } } ],
  "summary": { "generated": 1, "dead": 2, "rate": 200, "by_source": { "none": 2 } }
}
```

### `GET /reports/bookings`

Month rows for `bookings.booked_on`. `agreement_value` is the sum of live
bookings. `invoices` and `collections` are counts on those live bookings, not
limited to documents raised inside the month.

```json
{
  "from": "2026-04-01", "upto": "2026-04-30",
  "rows": [ { "month": "2026-04", "label": "Apr 2026", "bookings": 2, "cancelled": 1, "live": 1, "agreement_value": 10000000, "invoices": 1, "collections": 1 } ],
  "summary": { "bookings": 2, "cancelled": 1, "live": 1, "agreement_value": 10000000, "invoices": 1, "collections": 1 }
}
```

### `GET /reports/revenue`

Same months. `agreement_value` is Total AV. `net_income` is Revenue, summed
as stored (it can be negative). `invoiced`, `collected` and `outstanding` are
the lifetime totals on the live bookings booked in that month.

```json
{
  "from": "2026-04-01", "upto": "2026-04-30",
  "rows": [ { "month": "2026-04", "label": "Apr 2026", "agreement_value": 10000000, "net_income": 950, "invoiced": 800, "collected": 300, "outstanding": 500 } ],
  "summary": { "agreement_value": 10000000, "net_income": 950, "invoiced": 800, "collected": 300, "outstanding": 500 }
}
```

### `GET /reports/assignees`

The assignee filter. Not `GET /users` — that list is a manager's reporting
line. A manager or super admin receives every user in the firm, including
disabled. An agent receives only themselves.

```json
{ "users": [ { "id": "…", "name": "Asha", "role": "agent", "status": "active" } ] }
```

## Leads

### `POST /leads`

| Field | Type | | Notes |
| --- | --- | --- | --- |
| `mobile` | string | **required** | Normalised to E.164 |
| `transaction_type` | enum | **required** | `sale` · `rent` |
| `property_type_id` | **string** | conditional | **Required for a residential or commercial `sale`, forbidden for `rent`, and cleared for Plot & Land** |
| `category` | enum | optional | `residential` (default) · `commercial` · `land`. When sent with configurations from another category: `422 invalid`, "Pick configurations from one category." Omitting it leaves the stored category, which stays `residential` for older clients |
| `area_min`, `area_max` | number | optional | Commercial and Plot & Land only. Stored on `area_min_value` / `area_max_value`. A residential lead clears them. Commercial area is sq ft |
| `area_unit` | enum | optional | `sqft` (default) · `sqyd` · `sqm` · `guntha` · `acre` · `hectare`. Commercial must be `sqft` |
| `prefers_pre_leased` | boolean | optional | Kept only for a commercial sale. Every other lead stores false |
| `name` | string | optional | Nullable by design — brokers capture a number first |
| `alt_mobile` | string | optional | |
| `email` | string | optional | |
| `budget` | integer | **required** | Whole rupees. Stored as `budget_max`; `budget_min` is cleared. **Do not send `budget_min` / `budget_max` on write** — they are ignored. A create or PATCH that leaves this blank is `422 invalid` |
| `possession_by` | date | optional | **Not** `possession_up_to` |
| `lead_source_id` | string | optional | |
| `source_detail` | string | optional | e.g. `"99acres enquiry #48213"` |
| `assigned_user_id` | string | optional | Super admin: any active user in the firm. Anyone else: an id from their active manageables. Defaults to the creator when an agent creates it |
| `followup` | object | optional | Opening followup. `{ comment, next_action_at }`. `comment` is required if you send a datetime (otherwise `422 comment_required` and the lead is not created). A `next_action_at` in the past is `422 next_call_in_past` ("The next call must be in the future.") and the lead is not created. Two minutes of grace covers clock drift. An import keeps the dates in its sheet. Top-level `next_action_at` / `next_action_note` are **ignored** — NCD only moves via this nested object or `POST /leads/:id/followups` |
| `notes` | text | optional | **Detailed Client Requirements** (the column is still `notes`). Not a follow-up comment. Preferred localities are `locality_ids`, not text in this field |
| `unqualified` | boolean | optional | Default false. `true` leaves the lead out of matching and records `lead.unqualified`. Only a manager or the super admin may set it; an agent gets `403 forbidden_role` and the lead is not created. Omitting it does not record that event. An incomplete requirement is `422 invalid` and the lead is not created |
| `typology_ids` | **array** of string | **required** | At least one. Sending the key replaces the whole set. Omit the key on a create-from-project (`project_id` set) to copy the project's configurations. An empty array does not copy |
| `locality_ids` | **array** of string | **required** | At least one preferred locality. Sending the key replaces the whole set. Omit the key on a create-from-project to copy that project's locality. An empty array does not copy. A microsite enquiry copies the project's locality and still saves when the project has none |
| `near_place` | object or null | optional | `{ label, address, lat, lng, google_place_id }`. `label` is required when the pin is set, up to 40 characters, stripped. `address` is up to 255. `lat` and `lng` are both set or both blank, and when set they sit inside India (lat 6–37, lng 68–98). Outside India is `422` with "The place must be inside India." `null` clears all five columns. Omitting the key leaves them alone. Detail only: the list card does not include it, and no payload another firm can see includes it |
| `project_id` | string | optional | Create-from-project. Copies a blank budget into `budget_max` (not min), plus possession / notes, and inserts a `LeadProject`. Own or catalog. **Create only** — ignored on PATCH |

> **`property_type_id` is a single string. `typology_ids` is an array.**
> One property type, many configurations. Sending `property_type_id` as an array
> gets it silently discarded and you get `422 Property type is required for a
> sale lead` with nothing pointing at the real cause. See
> [Traps](#traps-worth-knowing).

One **open** lead per `(firm, mobile, transaction_type, category)`. A dead lead does not hold that slot, so the same number can be created again. The same number may be open once as a residential sale and once as a commercial sale, and once as `sale` and once as `rent`. A second create of the same type and category is **`422 duplicate_lead`**. `details.lead_id`, `details.transaction_type` and `details.category` identify the existing card. The message is "A sale Residential lead already exists for this number." (`sale` or `rent`, and Residential, Commercial, or Plot & Land). A PATCH that moves the lead onto a type and category that is already open is the same `422`. Reviving a dead lead (`POST /leads/:id/status`, or a follow-up that changes status) while another open lead holds that mobile, type and category is the same `422`. The revived status cannot be New (`422 new_not_allowed`). Two revives at once return that error rather than a 500.

Returns `201` with the lead plus `possible_duplicates` — the **other** transaction type on the same number, if any, and only leads the caller can see. Same type is never in this array; it was refused.

`code` is assigned server-side and sequential per firm (`L-0002`). Brokers read
these to each other.

### Importing leads from a CSV

Desktop only. The broker downloads a sample, fills it in, and uploads it.
One bad row does not undo the rows that were added. The response is the
result; it is not stored. Download the failures before leaving the page.

| | |
| --- | --- |
| `GET /leads/import_template` | Sample CSV. Three example rows (`Example lead` / `9000000000`: a home, a shop, a plot) are skipped if left unchanged. A file of only those rows is `422` and says to replace Example lead. A header with no rows still says the file has no leads |
| `POST /leads/import` | Multipart field `file`. At most 1 MB and 200 data rows |

A workbook (`.xlsx`), a semicolon-separated file, a missing Mobile / Sale or
rent / Budget header, or more than 200 data rows is `422 invalid` and creates
nothing.

`POST /leads/import` returns `200`:

```json
{
  "created_count": 1,
  "failed_count": 1,
  "results": [
    { "row": 3, "status": "created", "name": "Rhea", "mobile": "9820155001", "lead_id": "…", "lead_code": "L-0004", "error": null },
    { "row": 4, "status": "failed", "name": "Asha", "mobile": "9820155002", "error": "Unknown project code P-ZZZZZZ.", "cells": { "Name": "Asha", "Mobile": "9820155002" } }
  ]
}
```

`cells` is present on failures only, in the sample's column order, so the
file can be fixed and uploaded again. An `Error` column on that file is ignored.

Each created row goes through the normal lead create and starts as New.
A blank **Assigned to** keeps the lead with the person importing. There is
no status column.

Sheet rules:

- **Mobile**, **Sale or rent** (`sale` or `rent`) and **Budget** (whole rupees, `12000000` or `1,20,00,000`) are required. A decimal other than `.00`, or text such as `1.2 Cr`, fails the row. A mobile Excel has turned into scientific notation or a decimal fails the row.
- **Possession** (the old header **Property type** is still accepted) is required for a residential or commercial sale even when a project code is filled in. The names are `Under construction` and `Ready possession`. A rent row must leave it blank. A Plot & Land row must leave it blank (`Leave Possession blank for Plot & Land.`). The date column is **Possession up to**. On a sheet that still has both **Property type** and **Possession**, Possession remains the date.
- **Configurations** are typology names (`2 BHK`, `Shop`, `Residential plot`). Spaces and case do not matter. There is no Category column: the category comes from the configurations, or from the shortlisted listings when that cell is empty. Names from more than one category fail the row (`Configurations must be from one category.`). An unknown name fails the row.
- **Area** is optional. `800-1200 sqft`, `2-4 guntha` or `3 acre`. One number sets the minimum and the maximum. A residential row must leave it blank. A commercial row is sq ft. Plot & Land may use sq ft, sq yd, sq m, guntha, acre or hectare.
- **Prefers pre-leased** is optional `yes` or `no`. It is kept only for a commercial sale.
- **Project codes** and **Property codes** take several values separated by commas, at most 20 in one cell. A code is `P-` plus 6 characters for a project and `H-` plus 6 characters for a property, shown on that project or property's list and detail. A cell may also contain the record id. A project cell may contain a LaunchIQ reference (`PR…`): the firm's own active copy is linked, otherwise the active marketplace row. Linking does not copy a marketplace project into My Projects.
- **Location** is added to the localities on the shortlisted listings, not used instead of them. Leave it blank to use only those. Write `Kharghar, Mumbai`. Navi Mumbai, Thane and Palghar are localities of Mumbai, not cities. A locality name that exists once may be written on its own. Several places are separated by semicolons.
- A project code on a rent row fails. A property is linked only when its sale/rent matches the row. An unknown code, an archived project, or a sold property fails the row and does not create the lead. A private code from another firm, and a code belonging to a firm that is not active, are reported as unknown. A shared property links only while that firm is active, matching `GET /properties/marketplace`.
- The same mobile may be imported once per category, and once as sale and once as rent. A second open row of the same kind and category fails. The message names the category (`A sale Commercial lead already exists for this number`). When the caller can see that lead, the error includes its code.
- **Assigned to** is optional. A team member's mobile (the same shapes as Mobile) or email. Blank means the person importing. An unknown value is `No active team member has {value}.` A disabled member is `{name} is disabled. Assign someone else or leave it blank.` An agent may only name their own mobile or email; anything else is `Only a manager can assign leads to someone else.` A manager can assign someone on their team, the same people the New lead form offers.
- **Next call** is optional. `DD/MM/YYYY HH:MM` in 24-hour time, or `DD/MM/YYYY` alone, which means 11:00. Read in IST. A past time is kept and shows as overdue. A bad value is `Type the next call as DD/MM/YYYY HH:MM, for example 28/10/2026 11:00.`
- **Next call note** is optional and has no length cap, the same as the new-lead form's note. It needs a Next call: `Add a Next call, or leave the note blank.` With both, the row is the opening follow-up (`followup: { comment, next_action_at }`). A time with no note is stored as the lead's next call and does not invent a comment.
- **Near place** and **Near place pin** are both filled or both blank: `Near place needs both a name and a pin.` The pin is `lat,lng`, or a full Google Maps link containing `@lat,lng`, `q=lat,lng` or `query=lat,lng`. A short link (`maps.app.goo.gl`, `goo.gl/maps`) is `Paste the full Google Maps link, or lat,lng. Short links can't be read.` The name is at most 40 characters and the pin must be inside India; those failures use the lead's own messages (`Near label is too long (maximum is 40 characters)`, `The place must be inside India.`). The address is left blank. A file that omits these columns imports as before.

`code` on a project and on a property is this import code. It is not
`external_ref` and it is not the lead's `L-0001`.

### `GET /leads`

Screen guide for the broker app: [`frontend/YASH.md`](../../frontend/YASH.md).

| Filter | Notes |
| --- | --- |
| `q` | Name, mobile or email. ANDs with every other filter |
| `view` | `worklist` leaves out terminal statuses (Dead and Booked) and unqualified leads. Any other value is `422 invalid`. Combines with every other param |
| `status` | A status `code`, **or `hot_negotiation`**. Repeat as `status[]=hot&status[]=negotiation`. Not `missed_followup` — that is its own boolean |
| `visited` | `true` / `false` — at least one `lead_visits` row, or none |
| `unqualified` | `true` / `false` — only unqualified leads, or only qualified ones. Blank does nothing |
| `missed_followup` | `true` / `false` — `next_action_at <= now` on a non-terminal lead, or a Visit Planned lead whose `visit_planned_at` has passed. ANDs with `status` |
| `name`, `mobile`, `email` | Drawer. ILIKE; `mobile` matches on digits so `98201 44210` hits stored `+919820144210` |
| `ncd_from`, `ncd_upto` | Drawer. Inclusive **IST** calendar days |
| `transaction_type` | Drawer. `sale` · `rent` |
| `side` | `sale` · `rent` on `transaction_type`. Any other value is `422 invalid`. ANDs with `q`. Meant for pickers |
| `property_type_id`, `source_id`, `assigned_user_id` | Drawer. Repeat the key, or comma-separate. An IN list. `source_missing=true` with `source_id` is those sources plus leads with no source |
| `source_missing` | Drawer. `true` keeps leads whose source is blank |
| `created_from`, `created_upto` | Drawer. Inclusive **IST** calendar days on `created_at` |
| `died_from`, `died_upto` | Drawer. Inclusive **IST** days of a change into a dead status. A lead later revived still matches |
| `budget_min`, `budget_max` | Drawer. Filter **window on the stored amount** (`budget` / `budget_max`, leftover `budget_min` if max is null). Not range overlap. These names on GET are the window, not write fields. A value that is not a whole number of rupees, 0 or more, is `422 invalid`. Spaces and commas are stripped first |
| `possession_from`, `possession_to` | Drawer |
| `typology_ids[]` | Drawer. Repeat the key |
| `category` | `residential` · `commercial` · `land`. ANDs with `q`. Pill `counts` follow it; nothing else narrows the counts |
| `sort` | **`ncd`** (default) · `worklist` · `recent` · `updated` · `booked` · `visited` |
| `page`, `per_page` | |

Drawer params: `name`, `mobile`, `email`, `ncd_from`, `ncd_upto`, `budget_min`, `budget_max`, `typology_ids`, `transaction_type`, `property_type_id`, `possession_from`, `possession_to`, `source_id`, `source_missing`, `assigned_user_id`, `created_from`, `created_upto`, `died_from`, `died_upto`.

A backwards or non-date `created_*`, `died_*`, `ncd_*`, or `possession_*` pair is `422 invalid` with "Dates must be YYYY-MM-DD, and from must be on or before upto." One side on its own is an open range. `status` must be a lead status code or `hot_negotiation`. `sort` must be one of the values above.

**`missed_followup` is not a real status.** Send it as `missed_followup=true`
(same shape as `visited`). It means `next_action_at <= now` on a non-terminal
lead, or a Visit Planned lead whose `visit_planned_at` has passed. It appears
in the design's tab strip beside the real statuses, but it will never come
back in `lead_statuses`. `status=missed_followup` is `422 invalid`. `hot_negotiation` is the Hot + Negotiation
codes together.

**Budget on GET is a point-in-window filter**, not overlap. A ₹1–1.3 Cr window
matches a lead whose stored amount is ₹1.2 Cr, and does **not** match a leftover
row whose max is ₹90L even if its old min was ₹80L.

Default sort is `next_action_at ASC NULLS FIRST, created_at DESC` — leads with
no next action sit **above** overdue. `sort=worklist` is the old overdue-first
order. `sort=booked` is `booked_at DESC NULLS LAST, created_at DESC`.
`sort=visited` orders by the lead's latest `lead_visits.visited_at`
(`DESC NULLS LAST`, then `created_at DESC`), via a correlated subquery so a
lead with several visits is one row. **`GET /dashboard` `leads.recent` is missed followups only** (at most
three, most overdue first), so the home strip and this list disagree by design.

The response includes **`counts`** every time, visibility-scoped. They ignore
the list's filters and search. They follow `category` when it is sent.

```json
"counts": {
  "new": 4, "missed_followup": 2, "visit_planned": 1,
  "visited": 3, "hot_negotiation": 5, "booked": 1,
  "worklist": 18, "todays_calls": 3
}
```

`worklist` is not terminal and not unqualified. `todays_calls` is
`next_action_at` today (IST), any status — the same rule as Home
`todays_followups`. The other keys are unchanged. Cards overlap (New + overdue
NCD is both New and Missed), so counts will not sum to `meta.total_count`.

### Lead payload

```json
{
  "id": "01a0…", "code": "L-0002", "name": "Sneha Desai",
  "display_name": "Sneha Desai",
  "mobile": "+919930371501", "email": "sneha.desai@example.com",
  "transaction_type": "sale",
  "budget": 11000000, "budget_min": null, "budget_max": 11000000,
  "possession_by": null,
  "status": { "id": "…", "code": "followup", "name": "Followup",
              "is_dead": false, "is_booked": false, "is_terminal": false },
  "property_type": { "id": "…", "name": "Under construction" },
  "typologies": [ { "id": "…", "name": "2 BHK" } ],
  "localities": [ { "id": "…", "name": "Kolshet", "city_id": "…", "city": "Thane" } ],
  "assigned_user": { "id": "…", "name": "Rohit Shah" },
  "source": { "id": "…", "name": "99acres" },
  "next_action_at": "2026-08-17T00:35:56.587+05:30",
  "visit_planned_at": null, "visit_due": false,
  "last_followup_comment": "Asked for the floor plan",
  "overdue": true, "visited": true, "visit_count": 1, "unqualified": false,
  "created_at": "2026-08-10T11:04:02.114+05:30",
  "updated_at": "2026-08-17T00:35:56.587+05:30"
}
```

`display_name` falls back to a formatted mobile when there is no name — use it
for headings. `overdue` and `visited` are computed; don't derive them yourself.
**`budget` is the amount to show** (`budget_max`, falling back to leftover
`budget_min`). Do not render a min–max range from the leftover columns.

List-card fields (also on detail, which extends this shape):

| UI | Field |
| --- | --- |
| Lead Name | `display_name` |
| Status | `status.name` (code/colour on the same object) |
| Sale / Rent | `transaction_type` |
| Under Construction | `property_type.name` — `null` on rent |
| Visits: 1 | **`visit_count`** — number of `lead_visits` rows. `visited` is the same fact (`visit_count > 0`) |
| Configuration | `typologies[].name` |
| Preferred localities | `localities[].name` (with `city`) |
| Budget | `budget` (integer rupees) |
| Source | `source.name` — `null` when unset. `source_detail` is detail-only |
| Last Followup Comments | **`last_followup_comment`** — `comment` of the latest `lead_followups` row. `null` if none. Truncate + "show more" on the client. **Not** an activity body, and there is no `next_action_note` |
| Next Action Date | `next_action_at` — copy of the last followup that sent a datetime. Cleared when the lead becomes dead or booked |
| Planned visit | `visit_planned_at` — set when a followup leaves the lead Visit Planned and sends `visit_at`. Cleared on leaving Visit Planned. `visit_due` is true when that status is Visit Planned and the time has passed |
| Created At | `created_at` |
| Unqualified | `unqualified` — boolean, on the list card and on detail. `true` leaves the lead out of matching. Dead status does not. Reviving the lead does not clear it. Only a manager or the super admin can change it |

The **detail** adds `alt_mobile`, `source_detail`,
`dead_reason`, `dead_at`, `booked_at`, `notes`, `web_enquiry`, `mapped_projects[]`,
`mapped_properties[]`, `activities[]` (latest 20), `status_history[]` and
`near_place`. There is no `first_visit_at`. `web_enquiry` is the ad click and
UTM fields stored from a website enquiry, or `{}`. Nothing else in the app
shows them. `near_place` is
`{ label, address, lat, lng, google_place_id }` or `null`. It is not on the
list card.

Detail includes `emi` or `null`. The list card does not. `emi` is the last Quick EMI save:

| Field | |
| --- | --- |
| `loan_amount` | Whole rupees, 500000–50000000 |
| `annual_rate` | Decimal **string**, two places, 6–14. Not a JSON number, so `8.5` is not `"0.85e1"` |
| `tenure_years` | Integer years, 1–30 |
| `saved_at` | ISO 8601. Render the calendar date in `Asia/Kolkata` |

`PATCH` with `emi: { loan_amount, annual_rate, tenure_years }` replaces that calculation. All three keys are required when `emi` is present (`422 invalid` otherwise, or when a value is outside the bounds). The server sets `saved_at`. Send `annual_rate` as a string (`"8.50"`). Computed EMI, interest, and total are not stored.

`mapped_projects[].id` / `mapped_properties[].id` are the **join ids** that
`DELETE` takes. The nested `project` / `property` is the inventory row.
Each mapped row also has `visited`, `visit_count`, and `last_visited_on`
(`YYYY-MM-DD` in IST, or `null`). A siteless visit does not flip these.
`mapped_projects[].project.starting_budget` is whole rupees.
`mapped_properties[].property` includes `price`, `listing_for`, and
`building_name` when the listing belongs to this firm. A visit row carries the
same price fields on `projects[]` and `properties[]`, and `building_name` on a
property that belongs to this firm. Another firm's listing leaves that name out.

### Other lead endpoints

| | |
| --- | --- |
| `GET /leads/:id` | Detail, with timeline, mappings and status history |
| `PATCH /leads/:id` | Same fields as create except `project_id` and nested `followup` (create-only). **Sending `typology_ids` or `locality_ids` replaces that whole set**; omitting a key leaves it alone. When the request sends `budget`, `typology_ids` or `locality_ids`, the saved lead must still have a budget, at least one configuration and at least one locality, or the PATCH is `422 invalid` and changes nothing. A PATCH that sends none of them (reassign, unqualified, EMI) is not checked. Follow-ups and status changes use their own endpoints and are not blocked by this. Sending `assigned_user_id` reassigns — see below. PATCH `transaction_type` is `422 duplicate_lead` if that type already exists on the mobile. **`next_action_at` / `next_action_note` are ignored** — NCD only moves by posting a followup. Optional `emi` — see below. Omitting `emi` leaves a saved calculation alone. Optional `unqualified` (boolean) leaves the lead out of matching. Omit the key to leave it. Send `false` to clear it. Status changes do not clear it. An agent who sends a different value gets `403 forbidden_role` and nothing is saved |
| `POST /leads/:id/status` | `{ status, reason, note }` — `status` is a status **code**. `reason` is **required** moving to a dead status. Moving to dead or booked **clears `next_action_at`**. `status: "new"` on a lead that is not New is `422 new_not_allowed` ("A lead can't go back to New."). `status: "visit_planned"` is `422 visit_needs_date` ("Plan a visit with a date.") — send Visit Planned on the followup, with `visit_at`. Leaving Visit Planned clears `visit_planned_at`. The Add Followup wizard should **not** also call this — send `status` on the followup instead |
| `GET /leads/:id/followups` | Newest first. `{ followups: [{ id, comment, next_action_at, user, created_at }], meta }`. Default 25 |
| `POST /leads/:id/followups` | `{ comment, next_action_at, status, reason, booked_on, visit_at }` — see below. `201` `{ followup, lead }` (`lead` is the **list** card shape) |
| `GET /leads/:id/activities` | |
| `GET /leads/:id/visits` | Newest `visited_at` first. `{ visits, meta }`. Default 25 |
| `POST /leads/:id/visits` | `{ visited_on, notes, project_ids, property_ids }` — see below. `201` `{ visit }` only. Refetch the lead for `visited` and mapped flags |
| `PATCH /leads/:id/visits/:id` | `{ visited_on, notes, project_ids, property_ids }`. Omit a key to leave it; `""` clears notes; `[]` clears that site list. New site ids must already be on the shortlist (`422 not_mapped`). Ids already on this visit may stay after the lead unmaps them. Does not change `user_id`. No delete |
| `POST /leads/:id/activities` | `{ kind, body, occurred_at, outcome }` — `call` / `whatsapp` / `note`. `kind=visit` is rejected |
| `POST /leads/:id/projects` | `{ project_id }` — map a My Projects row, a catalog row this firm already owns, or a global marketplace row. A global marketplace row is linked as itself. It is not copied. Anyone who can see the lead. `201` returns the refreshed lead. A project already on the shortlist is `422 invalid`: "That project is already on this lead's shortlist." |
| `DELETE /leads/:lead_id/projects/:id` | `:id` is the **join** id from `mapped_projects[]` |
| `POST /leads/:id/properties` | `{ property_id }` — same rules as projects |
| `DELETE /leads/:lead_id/properties/:id` | Join id from `mapped_properties[]` |
| `POST /leads/:id/matches` | Inventory scored 0–100. See below. An unqualified lead, a booked lead, or a lead with neither a locality nor a tagged pin, returns `[]`. A dead lead still matches. Does not copy anything into My Projects |
| `GET /match_digest` | The firm's latest curated list. Super admin only — anyone else is 404. `match_digest` is `null` before the first scan |

**`POST /leads/:id/matches`** lists unmapped rows. Optional `q` searches the
full set (name, builder or firm, locality, city, configuration; spaces and
case ignored, so `2bhk` finds `2 BHK`) and returns every hit, with no cap.
A `q` that is present but has no letters or numbers (`-`, `@`) returns no rows.
Without `q`, the body is the first 50. The first group fills those slots.
`truncated` is true when more unmapped matches exist, including a later group
that did not fit. Search returns those.

Anchor matching is the live rule once `bin/rails matches:anchor_enable` has
run. A lead has up to three anchors: the place on the lead, then visited
listings newest first, then shortlisted listings newest first. A listing
counts once. A project whose shortlist entry was withdrawn is not an anchor,
even if it was visited. A listing with no pin of its own is skipped and the
next one is taken. The circle uses that listing's own pin only, ignores the
city line, and is graded. The rings sit at a third, two thirds and the full
radius, for 30, 25 and 20 location points. The radius starts at 6 km, so the
rings are 2, 4 and 6 km. At 3 km they are 1, 2 and 3 km.
`bin/rails matches:anchor_radius METRES=3000` changes it and rewrites digests
without a notification. Past the radius, rows match by preferred locality and
then by neighbor locality, as below. A row in a preferred locality scores 30
even in an outer ring. Groups are fixed. A higher score does not move a row
into an earlier group:

1. Inside an anchor ring, nearest ring first, then score, then distance. A
   visited or shortlisted anchor sets `near_shortlist`. A placed anchor does
   not. The row's `anchor` is `{ kind, name }`.
2. Preferred localities, as one block. No distance is shown.
3. Whole neighbor localities whose centers are within 6 km, nearest center
   first. One hop. A listing anywhere in that locality is included. The shown
   distance is from the listing's own pin to the nearest preferred centre, and
   is omitted when the listing has no pin of its own.

The response also carries `anchors`: `{ kind, name, listing_kind, listing_id }`
for each anchor the lead kept. `listing_kind` and `listing_id` are null for the
place. A visited or shortlisted listing is left out of that lead's matches, and
a listing is never measured from itself.

While anchor matching is off, a row is listed only when a preferred locality
overlaps until `bin/rails matches:nearby_enable`. After that, the first group
is listings within 6 km of the nearest shortlisted pin, in that pin's city. A
mapped project with no usable pin uses its locality centre. A site visit does
not add a pin, and the place on the lead is ignored. Preferred localities are
the next group, then neighbor localities whose centres are within 6 km and in
the same city. `anchors` is `[]` and each row's `anchor` is null.

A pin outside India, or more than 20 km from its own locality center,
is ignored and the center is used instead. The saved pin is left as entered.
Shown distances use a real pin on both ends. A preferred-locality row has no
distance. A pin-circle row whose pin is a centre fallback has no distance.
Another firm's property, an anchor that is another firm's property, and
another firm's lead round the shown distance to the nearest 500 m and never
below 500 m (`distance_rounded` is true). Catalog projects stay exact.
`distance_m` on a lead's matches and on the firm's own listing leads is that
shown distance. Another firm's lead rows keep today's keys and always round.

Own projects and own properties need a score above 30. Catalog projects and
another firm's shared properties need a score above 50. A preferred locality
is 30 points (`matched_on` includes `locality`). A neighbor, or a listing that
is only inside an outer ring or the old 6 km pin circle, is 20
(`matched_on` includes `nearby`). The middle ring is 25. Catalog nearby still
needs a configuration and a price that scores, because 20 + 30 is not above 50.
Own nearby clears the floor with a configuration (40) or a price within 15%
(50). Locality points alone are left out.

A rent lead sees available rental properties only. A ready-possession sale lead
sees available sale properties plus active projects whose possession month is
this month in Asia/Kolkata, at most two months ahead, or any earlier month.
An under-construction sale lead sees active projects only. A possession label
with no date that starts with the word Ready, such as Ready to move or Ready
possession, counts as ready. A lead with no
preferred locality still matches listings inside an anchor circle, or within
6 km of a shortlisted project or property while anchor matching is off and
nearby matching is on. Archived projects and booked or sold-out properties
are left out. While a firm's booking copy and its catalog row are both active,
anchor matching lists only the catalog row, in lead matches, in a listing's
leads and in the digest. A shortlist entry for either marks both. Once the
catalog row is archived, the copy is listed. While anchor matching is off,
both are listed. The catalog row has `source: "catalog"` and
`marketplace: true`, with `listed_by` set to the builder. Another firm's shared
property has `marketplace: true` and `listed_by` set to that firm's name.

`bin/rails matches:anchor_disable` turns anchor matching off, rebuilds
same-city neighbor pairs, and rewrites digests without a notification. It
leaves nearby matching as it is. `bin/rails matches:anchor_compare` prints old
against new for every eligible firm's lead that has a place, a visit with a
site, or a shortlist entry, and writes `tmp/anchor_compare.csv`. It refuses to
run in production and rolls back what it changes. `RADIUS=3000` tries a smaller
circle. None of these tasks send a notification.

A listing is scored only inside the lead's category. Commercial and Plot & Land
also require the configuration the lead chose. Residential still scores every
configuration in the category: a smart match is 20 and any other configuration
is 0. Plot & Land does not ask possession, so a plot lead sees plot properties
and plotted projects of any possession date. A ready commercial buyer does not
see an under-construction project.

Commercial and Plot & Land score area instead of configuration. Both sides need
an area, otherwise area is 0. The lead's range is compared in square feet. An
area inside 90% of the minimum and 110% of the maximum is 20. An area inside
75% and 125% is 10. A missing maximum is open and a missing minimum is 0.
`matched_on` includes `area` only when those points are 20.

A commercial sale lead can prefer pre-leased stock. A pre-leased listing then
scores 10 more, and the total is capped at 100. Among equal scores the
pre-leased listing sorts first. With the preference off, that tie-break does
not move anything. `matched_on` includes `pre_leased` when the bonus was earned.

A project with more than one category shows that category's starting price as
`starting_budget`. A home buyer does not see the shop price. When that category
has no priced row, `starting_budget` and the price points are empty. A
single-category project still uses `starting_budget`.

The score is 100 points and is not stored:

| Points | When |
| --- | --- |
| 30 | A preferred locality, or the inner third of the anchor radius. `group` is `locality` when the locality is preferred |
| 25 | Anchor matching only. The middle third of the radius, and not a preferred locality. `group` is `nearby` |
| 20 | Not a preferred locality, and either the outer third of the radius, within 6 km of a tagged pin while anchor matching is off, or in a neighbor locality. `group` is `nearby` |
| 50 | The chosen price is at or under the budget plus 2% |
| 30 | That band was missed, and the price is at or under the budget plus 15% |
| 20 | Both of those were missed, and the price is at or under the budget plus 25% |
| 0 | The price is above the budget plus 25%, and the lead has a budget |
| 25 | The lead has no budget (null or zero). The listing's price does not change it. `matched_on` does not include `price` |
| 20 | Residential only. A configuration smart-matches, otherwise 0 |
| 20 or 10 | Commercial and Plot & Land only. The listing area is inside the inner band, or only the outer band. Otherwise 0 |
| 10 | A commercial sale lead prefers pre-leased stock and the listing is pre-leased. The total is then capped at 100 |

Price tiers do not stack. The budget is one amount: `budget_max`, or leftover
`budget_min` when max is null. A lead with neither amount, or with zero, scores
25 price points on every listing, below a listing that is within budget.
Comparisons use decimal arithmetic, inclusive
at each cutoff. When a configuration smart-matches, its price is the one
scored, and the matching configuration with the best tier wins. When none
match, the priced configuration closest in rupees is scored and configuration
points stay 0. A project with no configuration price uses `starting_budget`.
Commercial and Plot & Land do the same for the configurations the lead chose:
an unpriced one scores 0 price points when another of those has a price.
`starting_budget`, or that category's starting price on a mixed project, is
used only when none of them have a price.

"2 BHK", "2BHK Ultima" and "2 BHK Compact" all match. "2.5 BHK" does not match
"2 BHK". "1 RK" does not match "1 BHK". Villa and Penthouse match those words
in the name. Commercial and Plot & Land do not use that smart match: the lead's
chosen configuration is the only one scored.

```json
{ "matches": [
  { "kind": "project", "id": "…", "name": "Aurum Vista", "source": "catalog",
    "marketplace": true, "listed_by": "Aurum Developers",
    "city": "Thane", "locality": "Kolshet", "starting_budget": 14200000,
    "category": "residential", "area_sqft": 720, "area_unit": "sqft", "area_value": "720",
    "pre_leased": false,
    "area": { "value": "720", "unit": "sqft", "sqft": 720, "kind": "carpet" },
    "score": 100,
    "score_breakdown": { "location": 30, "price": 50, "fit": 20, "configuration": 20, "area": null, "bonus": 0 },
    "matched_price": 14200000, "matched_configuration": "2 BHK",
    "mapped": false, "matched_on": ["locality", "price", "configuration"],
    "distance_m": 800, "distance_rounded": false, "group": "locality",
    "near_shortlist": true, "anchor": { "kind": "visited", "name": "Mehta Marquina" } }
], "truncated": false,
  "interest_localities": [{ "id": "…", "name": "Kolshet" }],
  "neighbor_localities": [{ "id": "…", "name": "Balkum", "distance_m": 3200 }],
  "anchors": [{ "kind": "placed", "name": "Office", "listing_kind": null, "listing_id": null }] }
```

`kind` is `project` or `property`. A property row uses `name` (the listing
title), `price`, and `listing_for` instead of `source` and `starting_budget`.
`category` is the lead's category. `area` is the row that was scored: `kind`
is `plot` for Plot & Land and `carpet` otherwise. `area_sqft`, `area_unit` and
`area_value` repeat that area. `pre_leased` is true only for a pre-leased
commercial sale listing. `score_breakdown.fit` is the configuration points for
a home and the area points for commercial and Plot & Land. `configuration` is
null outside residential. `area` is null for a home. `bonus` is the pre-leased
points, or 0. `matched_on` lists the dimensions that scored: `locality` or
`nearby`, then `price` when those points are above 0 and are not the 25
no-budget points, `configuration` when those points are above 0, `area`
when the area points are 20, and `pre_leased` when the bonus was earned. `group` is
`locality` when the row's locality is one the lead named, otherwise `nearby`.
A pin-circle or anchor row in a named locality stays `group: "locality"` and
sets `near_shortlist` to true, except a placed anchor, which leaves it false.
`distance_m` is the shown distance: metres to the nearest real anchor or pin,
or from the listing's own pin to the preferred centre on a neighbor row. It is
null on a preferred row, when either end is a centre fallback, and while
nearby matching is off. `distance_rounded` is true when that distance was
rounded. `anchor` is null outside the anchor band. `interest_localities` is
what the lead named. `neighbor_localities` is empty until nearby matching is
on. Rows already mapped to the lead are omitted. While anchor matching is on,
a shortlist entry for a catalog project also marks the firm's booking copy,
and the reverse. While it is off, a catalog mapping does not mark the booking
copy, and the reverse is also separate.

### `GET /match_digest`

The list the firm was shown on its last scan, about every 12 hours. Super
admin only. A manager or agent gets **404** `not_found`. Before the first
scan the body is `{ "match_digest": null }`.

Each firm is scanned twice a day, 12 hours apart, on a stable hour of the
India clock. A firm that already has a list and missed that hour is picked
up on a later hour once the list is more than 13 hours old. A firm with no
list yet still waits for its own hour. A firm whose subscription has lapsed
is not scanned and is not pinged. The first scan treats every current
unlinked match as new and notifies the super admin. Later scans notify only
when a lead or listing on the list gained a match that was not stored last
time. The notification counts those rows and does not name the client. A
scan that finishes from 21:00 through 07:59 IST saves the list and sends the
ping between 08:00 and 09:00. The page already shows that list if they open
the app earlier. A lapsed firm with a ping still waiting has that ping
dropped.

The live `POST /leads/:id/matches` screen can disagree with a row opened
hours later. `generated_at` is when this list was built.

```json
{ "match_digest": {
  "generated_at": "2026-10-08T11:00:00.000+05:30",
  "lead_items": [
    { "lead_id": "…", "code": "L-0004", "name": "Asha", "budget": 10000000,
      "typologies": ["2 BHK"], "localities": ["Kharghar"], "dead": false,
      "match_count": 6, "new_count": 3, "top_score": 100,
      "category": "residential",
      "area": { "min": null, "max": null, "unit": null, "min_sqft": null, "max_sqft": null },
      "prefers_pre_leased": false }
  ],
  "listing_items": [
    { "kind": "property", "id": "…", "title": "2 BHK in Kharghar",
      "listing_for": "sale", "categories": ["residential"],
      "match_count": 4, "new_count": 1, "top_score": 80 }
  ]
} }
```

`match_count` is how many unlinked options cleared the floor (capped at 50,
same as the live match call). `new_count` is how many of those were not stored
on the previous scan, including matches that sat outside the rows the page
showed. The response is the first 30 leads and the first 30 listings, highest
score first. A lead or listing that moves into those 30 with the same matches
has `new_count` 0 and does not cause a ping. A quiet scan still returns the
rows and does not notify.
`bin/rails matches:rebaseline` rewrites every eligible firm's digest under the
same lock and does not notify, so a scoring change can land without pinging
brokers. It does not turn nearby matching or anchor matching on.
`matches:anchor_enable`, `matches:anchor_disable` and `matches:anchor_radius`
rewrite digests the same way.
`listing_items[].kind` is `project` or `property`. A property row includes
`listing_for` (`sale` or `rent`) so two listings with the same title can be
told apart. A project row omits it. A lead row also carries `category`,
`area` (`min`, `max`, `unit`, `min_sqft`, `max_sqft`) and
`prefers_pre_leased`. A listing row carries `categories`, in residential,
commercial, land order, taken from the configurations that matched.
Digests written before `matches:rebaseline` omit those keys.
Unqualified leads are
left out. Booked leads are left out. Dead leads stay, with `dead: true`.
A row already linked to that lead or listing is left out. Sold-out and
booked properties are left out.

**`POST /leads/:id/followups`** is the only write path for a follow-up comment
and for moving NCD. One transaction: insert the row, copy `next_action_at` onto
the lead if a datetime was parsed, set `visit_planned_at` when the lead is
Visit Planned afterwards and `visit_at` was sent, then optionally
`Leads::TransitionStatus`. A followup with no `status` leaves the status
alone (Schedule a call). Checks run in this order; each failure is `422`
and changes nothing:

| Field | |
| --- | --- |
| `comment` | **required.** Blank is `422 comment_required` |
| `status` | optional status **code**. Omit it to leave the status. `new` is `422 new_not_allowed` ("A lead can't go back to New."). Do **not** also call `POST /leads/:id/status` |
| `next_action_at` | required unless the lead ends up Booked or Dead (`422 next_call_required`, "Next call is required."). A time more than 2 minutes ago is `422 next_call_in_past` ("The next call must be in the future."). There is no way to clear NCD except by moving to a terminal status |
| `visit_at` | required when `status` is `visit_planned`, and when the lead is already Visit Planned and this key is sent blank (`422 visit_at_required`, "Visit date is required."). A time that is not in the future is `422 visit_in_past` ("The visit must be in the future."). A next call that is not before the visit is refused (`422 reminder_after_visit`, "The reminder call must be before the visit.") unless the visit is less than 2 hours away |
| `reason` | required when `status` is a dead status (`422 reason_required`); the followup is rolled back |
| `booked_on` | required when `status` is a booked status (`422 application_date_required`). IST start of day, stored on `leads.booked_at`. **Does not create a booking row** |

A failed status change rolls back the followup. Dead and booked clear
`leads.next_action_at`. Leaving Visit Planned clears `visit_planned_at`.
Logging a visit does not. Unknown `status` is `422 unknown_status`.

Many mappings are allowed. They stay after a booking. A booking does **not** require a mapping.

There is **no** `POST /leads/:id/assign`. Reassignment is `PATCH /leads/:id`
with `assigned_user_id`. `null` unassigns — which hides the lead from every
agent — and is manager-role+ only. Any other caller may only set an assignee
from their **active manageables** (the super admin: any active user in the
firm). An unknown or out-of-line id is `404 unknown_user`. Omitting the key
leaves the owner alone.

`kind` is `call` · `whatsapp` · `note`. (`status_change` and historical `visit`
rows exist, but the client cannot write them.) `body` is required.

**`POST /leads/:id/visits`** records an outing that already happened. It does
not change `lead.status` or `next_action_at`. `visited_on` is `YYYY-MM-DD`,
stored as IST start of day. A date after today IST is `422 future_visited_at`.
Missing `visited_on` is `422 visited_on_required`. `project_ids` and
`property_ids` are optional; every id must already be on this lead's shortlist
or the response is `422 not_mapped` ("Sites added to a visit must already be on
this lead's shortlist."). A siteless visit still increments `visit_count`.

**`PATCH /leads/:id/visits/:id`** may change date, notes, and sites. Omit a
site key to leave that set; send `[]` to clear it (the visit may become
siteless). Ids **already on this visit** may stay even if the lead later
unmapped them. **New** ids must already be on this lead's shortlist or the
response is `422 not_mapped`. Unmapping a lead does not rewrite visit joins;
edit is how a broker drops a site from that outing. `user_id` does not change.

`GET /projects/:id/visitors` and `GET /properties/:id/visitors` return
`visit_count` (outings that included that site) and `visitors` (distinct leads
the caller can see: `display_name`, `visit_count`, `last_visited_on`). An agent
does not see another agent's clients in the count.

There is **no delete**. `dead` is the terminal state and it carries a reason, so
the dead-leads report can explain itself.

---

## Prospects

A calling list, not a lead. Desktop only. Every user of the firm sees every
prospect. There is no assignee. The cap is **5,000 prospects per firm**, all
statuses, enforced under a firm row lock during import.

Statuses are only `new`, `following`, `interested`, `not_interested`. There is
no separate dead status. "Mark dead" on a call sets `not_interested`.

The list does not include phone numbers. Call and Edit load one number with
`GET /prospects/:id/mobile`. Home and the list must not print numbers.
`GET /dashboard` returns counts only. Search still matches a phone fragment.

### `GET /prospects`

Every param is optional and they AND, including `q`. Nothing sent returns
every prospect. The app sends `view=worklist` when nothing is applied.
`?status=following` from Home is a status filter.

| Param | |
| --- | --- |
| `view=worklist` | `status` in `new`, `following`. Any other `view` is `422 invalid` |
| `status` | Comma list of `new`, `following`, `interested`, `not_interested`. An unknown value is `422 invalid` |
| `name` | Name contains, case-insensitive |
| `mobile` | Phone fragment of at least 4 digits, cleaned the same way as `q` (leading `0` stripped, one leading `91` stripped when the digit string is longer than 10). Shorter than 4 digits does not filter |
| `missed_followup` | `true`: `next_action_at <= now` and status `new` or `following`. `false`: everyone else. Blank does nothing |
| `ncd_from`, `ncd_upto` | Next call on these IST calendar days, inclusive, same bounds as a lead's `ncd_between` |
| `created_from`, `created_upto` | Added on these IST calendar days, inclusive |
| `q` | Name, status label (`not interested` or `not_interested`), or a phone fragment of at least 4 digits |
| `sort` | `updated` is `updated_at` desc, then `id` desc. Nothing is the default order. Anything else is `422 invalid` |
| `page`, `per_page` | `per_page` default 25, clamp 1–50 |

A bad or backwards `created_*` or `ncd_*` pair is `422 invalid` with
"Dates must be YYYY-MM-DD, and from must be on or before upto." One side on
its own is an open range.

Default order is `next_action_at ASC NULLS FIRST, created_at DESC, id`.
`sort=updated` is what Interested and Not Interested send so those lists stay
latest update first.

```json
{
  "prospects": [ {
    "id": "…", "name": "Asha", "comment": null,
    "status": "following", "next_action_at": "2026-10-09T11:00:00.000+05:30",
    "latest_note": "Asked to call after lunch",
    "project": { "id": "…", "name": "Lodha Park", "code": "P-0004" },
    "property": null,
    "can_delete": false, "can_move_back": false,
    "lead_code": null, "lead_accessible": false,
    "created_at": "…", "updated_at": "…"
  } ],
  "counts": {
    "new": 12, "following": 4, "interested": 2, "not_interested": 1, "total": 19,
    "worklist": 16, "todays_followups": 3, "missed_followup": 2
  },
  "can_clear": false,
  "meta": { "page": 1, "per_page": 25, "total_count": 12, "total_pages": 1 }
}
```

`counts` are firm-wide and ignore every filter and `q`. `worklist` is `new` or
`following`. `todays_followups` is `next_action_at` today, IST, any status.
`missed_followup` is `next_action_at <= now` on `new` or `following`.
`can_clear` is true for a manager or super admin (`permissions.manage_prospects`).
`lead_code` is present
for every user once a lead exists. `lead_id` is added only when
`lead_accessible` is true (super admin, manager, or the lead's assignee).
Another firm's id is 404. The card has no `mobile`.

### `GET /prospects/:id/mobile`

Any user of the firm. `{ "mobile": "+919876543210" }`. One prospect, for Call
or Edit. Another firm's id is 404.

### `PATCH /prospects/:id`

`name` (optional), `mobile` (Indian mobile, same extraction as import),
`comment`, `project_id`, `property_id`. One of project or property, not both.
Sending a project clears the property, and the reverse. Blank clears that link.
Unknown keys are ignored.

Once `interested`, a change to name, mobile, project, or property is
`422 prospect_locked`. The comment can still change. Sending the current value
of a locked field is not a change.

### `POST /prospects/:id/followups`

Open statuses only (`new`, `following`). A second follow-up on interested or
not interested is `422 prospect_closed`. The prospect row is locked.

| Field | |
| --- | --- |
| `connected` | Required boolean. Missing stays nil and is `422 connected_required`. Do not treat a missing key as false |
| `notes` | Required. `422 notes_required` |
| `next_action_at` | Required when the call did not connect and the prospect stays on the list. Asia/Kolkata, same meaning as a lead NCD. A datetime without an offset is read in that zone. A time more than 2 minutes ago is `422 next_call_in_past` ("The next call must be in the future."). Import does not set a dial time |
| `mark_not_interested` | Missed call only. Notes required, next dial time cleared, status `not_interested` |
| `disposition` | Connected call: `interested`, `not_interested`, or `not_sure` |
| `lead` | Required when `disposition` is `interested`. See below |

Missed, and not marked not interested: status becomes `following` (a Following
row stays Following) and `next_action_at` is the next dial time.

Connected and `not_sure`: no next dial time is asked. Status becomes
`following`. An existing `next_action_at` is left as it is.

Connected and `not_interested`: next dial time is cleared.

Connected and `interested`: the same transaction creates a normal lead through
`Leads::Create` with **no** opening lead follow-up. The lead source is
Telecalling. The call notes and the prospect comment are written to `lead.notes`. If lead create fails, including
`duplicate_lead`, the prospect does not change. `details.lead_code` is the
existing lead. `details.lead_id` is included only when the caller can open it.

`lead.mode`:

| Mode | What is copied | What the client sends |
| --- | --- | --- |
| `project` | Sale. Starting budget, the configurations of one category, and locality, when the project has them | `project_id`. Optional `category` (`residential`, `commercial`, `land`); omitted uses the project's primary category, which is residential when the project has a home. `property_type_id` (Under construction or Ready possession) for a residential or commercial sale. Plot & Land does not take one. Budget, `typology_ids`, and `locality_ids` when the project lacks them |
| `property` | This firm only. Price, the property's category and typology, building locality, `listing_for` | `property_id`. Sale of a home or a commercial unit asks `property_type_id` (Ready possession). Rent and Plot & Land do not. The property is linked with `lead_properties` |
| `requirements` | Nothing. The category is the category of `typology_ids` | `transaction_type` (`sale` or `rent`), `budget` (whole rupees), `typology_ids`, `locality_ids`, and `property_type_id` when the configurations are a residential or commercial sale. Optional `area_min`, `area_max`, `area_unit` and `prefers_pre_leased`, with the same rules as `POST /leads` |

An agent is assigned to themselves by the existing create rules. A manager's
lead stays unassigned. A project may be this firm's or a marketplace listing.
A property must belong to this firm.

Response `201`: `{ prospect, followup }`. `followup` is `{ id, connected, notes, outcome, next_action_at, created_at }`. Outcomes are `retry`, `not_sure`, `interested`, `not_interested`.

### `POST /prospects/:id/move_to_following`

Not interested: any user. Status becomes `following`. There is no lead to change.

Interested: only the lead's assignee, a manager, or a super admin. An
unassigned lead can be moved by a manager or super admin. `403 forbidden_role`
otherwise. The linked lead is deleted only when it has no follow-up, visit,
visit pass, booking, inbound enquiry, marketplace enquiry, or Facebook import.
Those writes lock the lead first, in the same transaction as the insert, so a
row saved in the same moment is visible to this check and is not deleted with
the lead. A worked lead stays, the prospect stays interested, and the response is
`422 lead_worked`. A missing lead just sets Following.

### `DELETE /prospects/:id`

Manager or super admin. `204`. The prospect is hard-deleted. The linked lead
stays in the pipeline. An agent receives `403 forbidden_role`. Do not send a
body: clients drop DELETE bodies.

### `GET /prospects/import_template`

CSV sample. Headers: Client name, Client number, Comment, Project code,
Property code. The example row (name `Example caller`, number `9000000000`) is
skipped on import. A file that contains only that row is `422 invalid`: replace
it with your own clients.

### `POST /prospects/import`

Multipart `file`. Any user. CSV only, at most 5 MB and 5,000 data rows. An
`.xlsx` name or an Excel zip signature is `422 invalid` and creates nothing,
as does a semicolon-separated file.

A bad row is reported and does not undo earlier rows. Imported rows start as
`new`. A number already in the firm or earlier in the file fails that row and
does not refresh the existing prospect.

Numbers: spaces, dashes, dots, `+91`, a leading `0`, `0091`, a `wa.me` link, a
number buried in a sentence, and a trailing Excel `.0` are accepted. Landlines,
numbers that do not start with 6–9, two different mobiles in one cell, and
Excel scientific notation are rejected. A number that is not a 10-digit
Indian mobile says `Client number must be a 10-digit mobile number.` This
extractor is prospect-only.
`Phone.normalise` for leads is unchanged.

`200`: `{ created_count, failed_count, results }`. Each result is
`{ row, status, name, mobile, prospect_id, error, cells }`. `cells` uses the
header names so a failure sheet can be fixed and uploaded again.

### `GET /prospects/backup`

Manager or super admin. `statuses` or `statuses[]` is required.
`text/csv` attachment `prospects-backup.csv`. Columns are the import columns
plus Status, Next call, and Lead code. Import ignores the extras, so a clear
followed by an import restores people as New. A cell that starts with `=`,
`+`, `-`, or `@` is prefixed with `'` so Excel does not treat it as a formula.

### `POST /prospects/clear`

Manager or super admin. Body `{ "statuses": ["new", "not_interested"] }`.
Hard-deletes those prospects and their call notes. Linked leads stay.
`200`: `{ "deleted_count": 3 }`. An audit event is written on the firm
(`prospects_cleared`, statuses and count, no phone numbers). Deleting one
prospect writes `prospect_deleted` on that prospect (status, no phone).

---

## Inventory

`builders`, `projects`, `properties`. **No delete anywhere** —
archiving is a status change.

A **project** is a builder's development, sold from a brochure. A **property** is
one resale or rental listing. It carries its own place and its own amenities
(`has_pool`, `has_gym`).

Every project has a global `code` (`P-` and six characters) and every property
has one (`H-` and six characters). They are random, not a sequence, and they
are what the lead import sheet links. A firm's copy of a marketplace project
gets its own code. `external_ref` is still the LaunchIQ reference.

**My Projects vs marketplace.** `GET /projects` without `source`, and
`GET /projects/search` without `include_marketplace`, return only `source: own`
(My Projects). Marketplace
rows are `source: catalog` with no firm. They arrive from turbo-rails8, one row
per project code in `external_ref`. List them with `GET /projects?source=catalog`.
`GET /projects/:id` returns a marketplace row to any signed-in firm. Brokers
cannot edit catalog rows (`422 catalog_readonly`). A lead links the marketplace
row. A booking copies it into My Projects and stores that copy.

**Writes to My Projects and `POST /builders` are superadmin only**
(`403 forbidden_role`, gated in the app by `permissions.manage_projects`).
Anyone in the firm may create a **property**.

**Portal codes** are saved from the show page, not the create or edit form.
`PATCH /projects/:id/portal_codes` is superadmin only. A catalog project is
`422 catalog_readonly`. `PATCH /properties/:id/portal_codes` is any signed-in
user in the firm. Body keys are `99acres`, `magicbricks` and `housing`. Send
only the keys you are changing. A blank or null value clears that code. The
same code cannot be saved on two projects, or on two properties, in the firm
(comparison ignores case and extra spaces). Detail responses include
`portal_codes`; list responses do not.

```json
{ "99acres": "ACME-22", "magicbricks": null, "housing": null }
```

Own-list names are unique case-insensitively per firm. Catalog names are unique
the same way, in their own list. The same name may exist once in each.

### `POST /projects`

| Field | Type | | Notes |
| --- | --- | --- | --- |
| `name` | string | **required** | ≤ 160 chars. Unique case-insensitively among this firm's **own** projects |
| `builder_id` | string | **required** | Global, or one this firm added |
| `city_id` | string | **required** | |
| `locality_id` | string | **required** | Must belong to `city_id`. A broker create or update of an own project without one is `422 invalid`. A booking copy of a catalog project may be stored without one; the broker cannot save an edit until it is set |
| `starting_budget` | integer | **required** | > 0 |
| `possession_on` **or** `possession_label` | date / string | **one required** | `"Dec 2027"` when the date is vague |
| `brokerage_percent` | number | optional | Starting brokerage, 0–100 |
| `brokerage_ladder_signed_id` | string | optional | Image of the brokerage ladder. Detail returns `brokerage_ladder_url`. Omitted from `shareable` |
| `rera_number`, `address`, `google_place_id` | string | optional | |
| `lat` / `lng` | number | required on an own project's form | −90..90 / −180..180, and inside India (lat 6–37, lng 68–98). Missing on that form is `422` with "Place the pin on the map". Catalog rows and a status-only save do not require one. List, detail, and search include `has_pin`. List and detail also include `pin_approximate` |
| `promo_text`, `promo_ends_on` | string / date | optional | `promo_text` has no length limit |
| `status` | enum | optional | `active` (default) · `archived` |
| `brochure_signed_id` | string | optional | See [uploads](#file-uploads) |
| `typologies` | array of object | **required** | `{ typology_id, starting_price, starting_carpet_sqft, label, area_value, area_unit }`. `label`, `area_value` and `area_unit` are optional. At least one row needs `starting_price` > 0. On PATCH, sending `typologies` replaces the set and must still leave a priced row. The same configuration can appear twice only with different labels |

`pin_approximate` is returned on list and detail, beside `lat` and `lng` on
detail. It is true only for a pin placed at the locality centre. It is not a
request field.

**Derived, never sent and never stored**: `price_band`, `area_band` (min/max
across the typologies), per-config `rate_per_sqft`, and list/detail **`avg_psf`**
(unweighted mean of those rates; integer; half-up once; `null` if none). A stored
band can end up disagreeing with the rows it came from. `starting_budget` is not
recomputed from configurations.

Each typology row also returns `label`, `display_name`, `category`, `area`
(`value`, `unit`, `sqft`, `kind`) and `needs_review`. `name` stays the
configuration's own name. The project returns `categories` (residential, then
commercial, then land — only those it has), `starting_prices`
(`{ residential, commercial, land }`, null when that category has no positive
price) and `price_summary`. One category is `From ₹X` from `starting_budget`.
A mix is `Homes from ₹90 L · Commercial from ₹40 L`. `GET /projects?category=`
limits the list to projects that have that category and sets
`display_starting_price` and `price_summary` to that category only. The filter
is a subquery, so a project is not repeated once per row.

**`promo` is an object and appears only while the promo is live** —
`{ text, ends_on }`, or absent. An expired promo is omitted entirely rather than
sent with a past date for you to check.

### `GET /projects`

| Filter | Notes |
| --- | --- |
| `q` | Substring of **project name, builder name, city, locality, or RERA number**. Not the street address. **Ignored when any drawer param is present.** `status` does not drop `q`. For a search box, [`/projects/search`](#get-projectssearch) is the typeahead |
| `name` | Drawer. Substring of the **project name only**. Applied together with the other drawer filters — this is the advanced-search name, not `q` |
| `status` | `active` (default) · `archived` · `all` (no status filter). Omitting the param is `active`, not every project. Heading pill — does not drop `q` |
| `builder_id`, `city_id`, `locality_id` | Drawer |
| `budget_min`, `budget_max` | Drawer. Projects with **at least one configuration whose starting price** is in the window. Not overlap — unlike a lead's stored amount — and a project with no configurations never matches. Not a whole number of rupees is `422 invalid` |
| `brokerage_min`, `brokerage_max` | Drawer. Rows with `NULL` brokerage drop out of a range. Not a number, 0 or more, is `422 invalid` |
| `possession_before` | date. Not a drawer field; still applies alongside `q`. A non-date is `422 invalid` |
| `typology_ids[]` | Drawer. Repeat the key |
| `category` | `residential` · `commercial` · `land`. Projects with at least one configuration in that category. Not a drawer field |
| `source` | `catalog` lists the marketplace (active shared projects only). Omit it for My Projects |
| `sort` | **`name`** (default, A–Z) · `recent` (newest first) · `relevant` (marketplace browse; see below) |
| `page`, `per_page` | 25 per page by default |

**Without `source=catalog` the list is My Projects only** (`source: own`).
`status=marketplace` is `422 invalid`. Use `source=catalog`. A `sort` outside `name`, `recent`, and `relevant` is `422 invalid` too. Blank `sort` stays A–Z.

Drawer params: `name`, `builder_id`, `typology_ids`, `budget_min`, `budget_max`,
`city_id`, `locality_id`, `brokerage_min`, `brokerage_max`.

**The list is paginated and sorted A–Z by default, so a project you just created
may not be on page 1.** Either pass `sort=recent`, read `meta.total_pages`, or —
simplest after a create — show the project the `POST` returned rather than
re-fetching the list.

**`sort=relevant` applies only to an unfiltered marketplace list**
(`source=catalog`, no `q`, no drawer param). It orders that firm's projects in
bands, then `id`. Until nearby matching is on, or until a tagged locality has
a center, the bands are the firm's primary locality, its other localities, the
rest of the cities those localities belong to, then everywhere else, newest
first inside a band. Once nearby matching is on and a center exists, neighbor
localities (centers within 6 km of a tagged locality, same city) sit between
the tagged localities and the rest of the city. Inside a band the nearer
project comes first, using a usable pin or else the locality center. A tagged
locality stays ahead of a closer locality the firm did not tag. A project
with a city and no locality sits in the city band. A firm with no primary
locality gets newest first. The order is not explained to the broker. With
`q`, `sort=relevant` is ignored and the list stays A–Z. With a drawer param
it is ignored and the list stays newest first. On My Projects it is ignored
and the list stays A–Z (or `sort=recent` when that was asked for).

### `GET /projects/search`

Typeahead for a project search box. Call it once the user has typed **at least
three letters or numbers**, debounced (~250 ms).

| Param | |
| --- | --- |
| `q` | **Required: 3+ letters or numbers.** Fewer returns `422 query_too_short`. Punctuation alone (`___`, `!!!`) does not count. Up to 160 characters — the longest a project name can be |
| `status` | `active` (default) · `archived` · `all`. An unrecognised value is treated as `active` |
| `include_marketplace` | `true` also returns active marketplace rows (`source: catalog`). Omitted, the typeahead is My Projects only. A firm's booking copy of that project is left out, so the hit is the marketplace row a lead mapping stores. `status=archived` does not add marketplace rows |

**Literal matches first.** If the project name, builder, city, locality, or RERA
number contains what was typed, those are the results, ranked **exact → starts
with → contains** on the project name and RERA number. The street address is
not searched.

**Close spellings only when nothing matches as typed**, and only for 4+
characters — `aurm` finds *Aurum Vista*, `lodah` finds *Lodha Amara*. `meta.fuzzy`
is `true` when that happened, so label them "did you mean". Typing `lod` returns
Lodha — not every project that starts with "Lo".

The builder, the location and the RERA number are never fuzzy-matched: a
near-miss registration is a different project, and a near-miss builder is a
different builder. Spaces pasted in with text — including non-breaking ones
from web pages — are cleaned up first.

**At most 10 results.** Your firm's projects, plus marketplace rows when
`include_marketplace=true`. `active` unless `status` says otherwise. Mapping a
`source: catalog` id links that row. It does not create a My Projects copy.

```json
{
  "projects": [
    {
      "id": "01a0…", "name": "Aurum Vista", "rera_number": "P51700054321",
      "source": "own",
      "builder": { "id": "01a0…", "name": "Lodha Group" },
      "locality": "Kolshet", "locality_id": "01a0…",
      "city": "Thane", "city_id": "01a0…",
      "has_pin": false,
      "match_label": "Sale · Under construction"
    }
  ],
  "meta": { "query": "aurum", "limit": 10, "min_length": 3, "more": false, "fuzzy": false }
}
```

- **`meta.more`** is `true` when there are more than 10 — show "keep typing".
- **`meta.fuzzy`** is `true` when these are close spellings rather than matches.
- **`meta.query`** is what was actually searched, after trimming.

A result carries only what a row shows, including `code` and `match_label`
(`Sale · Under construction` or `Sale · Ready possession`). Tap through to
`GET /projects/:id` for the full project.

`source` is `own`, or `catalog` when `include_marketplace=true` returned a
marketplace row. Lead matching still goes through `POST /leads/:id/matches`.

List and detail also carry `city_id` and `locality_id` (the names stay as
`city` / `locality`). Use the ids when editing; rematching by name can attach
the wrong locality.

### `POST /properties`

`building_name` (**required**), `city_id`, `locality_id`, `address`,
`lat`, `lng`, `google_place_id`, `has_pool`, `has_gym`, `typology_id`,
`listing_for` (`sale` · `rent`),
`price`, `carpet_area_sqft`, `area_value`, `area_unit`, `details`, `pre_leased`,
`floor_band` (`lower` · `middle` · `higher`),
`available_from`, `description`, `confidential_note`, `status`,
`listed_on_marketplace` (boolean, default true). `lat` and `lng` are required on this form
("Place the pin on the map"). A pin outside India (lat 6–37, lng 68–98) is
rejected. Turning `listed_on_marketplace` off hides the
listing from other firms' matches and from `marketplace_firms`. A mapping
already saved stays.
(`available` · `booked` · `sold_out`). Any role may create. List and detail
include `created_by: { id, name }` (or `null` on older rows) — show it when
`permissions.manage_projects` is true. `PATCH` may set `status` to `available`,
`booked` or `sold_out` for anyone who can edit the listing. Detail for a
manager or super admin of the owning firm also includes `live_booking`:
`{ id, code, customer_name }`, or null. An agent does not get that key. It is
this firm's live booking on the listing, not another firm's.

`carpet_area_sqft` is the area in square feet (carpet for a home or a
commercial unit, plot area converted to sq ft for land). Send `area_value`
and `area_unit` for guntha, acre and the rest. When only `carpet_area_sqft`
is sent, it is stored as that many sq ft. A home or commercial unit must use
`sqft`. Plot & Land is sale only. Floor band is cleared for villa, row house,
plots, and commercial units other than office. `pre_leased` is kept only on a
commercial sale, and then `details.lease_monthly_rent` is required.

List and detail add `category`, `area` (`value`, `unit`, `sqft`, `kind`),
`details`, `pre_leased`, `lease` (or `null`) and `rate_per_unit`
(`{ amount, unit }`). `carpet_area_sqft` and `rate_per_sqft` stay.
`GET /properties` also takes `category`, `area_min` and `area_max`.
`carpet_min` and `carpet_max` remain aliases of that area filter.

`POST /builders` is superadmin only. `{ name, website }`. A name that already
exists on the **master** list is `422 invalid` — pick the master row instead of
minting a private duplicate.

`GET /properties` takes `sort`: **`recent`** (default, newest first) · `name`
(A–Z by building name — a listing has no name of its own). `status` is
`available` (default) · `booked` · `sold_out` · `all` (no status filter).
Omitting the param is `available`, not every listing. **Mark sold** is
`PATCH { "status": "sold_out" }` from any status; any status may be patched to
any other.

Also: `q` (the card title `{typology} in {locality}`, either half of that
title, the building name, or the description — **not the city**. Ignored when a
**drawer** param is set; `status` and `side` do not drop `q`. Omitting `status` is
`available`, so a search does not return booked or sold-out listings unless
`status` asks for them), `listing_for`, `side` (`sale` · `rent` on `listing_for`;
any other value is `422 invalid`; not a drawer field, so a picker can keep `q`;
the marketplace list does not take it), `city_id`, `locality_id`, `typology_id`,
`price_min` / `price_max` (a non-number is `422 invalid`), **`carpet_min` / `carpet_max`** (NULL
carpet drops out of a range; a non-number is `422 invalid`), `floor_band`. Drawer params: `city_id`,
`locality_id`, `typology_id`, `price_min`, `price_max`, `carpet_min`,
`carpet_max`, `listing_for`.

List and detail add `building_name`, `city` and `locality` (each `{ id, name }`),
`address`, `lat`, `lng`, `pin_approximate`, `google_place_id`, `has_pool`,
`has_gym`, and `has_pin`. `pin_approximate` is true when the pin is the
locality centre placed for a demo listing, not a spot the broker chose.
Matching, anchors, shown distance, and map links treat that pin as missing.
Sending `lat` or `lng` that differs from the stored pin clears the flag.
Sending the same pin, or omitting it, keeps the flag. Clients do not send
`pin_approximate`.
They also include `code`, `listed_on_marketplace` and `match_label`
(`Rent`, or `Sale · Ready possession` — a property has no possession month).
A Plot & Land sale reads `Sale`.
The marketplace list includes `code` as well, and still omits private fields.

> **`confidential_note` is returned only by `GET /properties/:id`.** It is absent
> from every list payload and absent from `shareable`. Never render it anywhere a
> client might be looking.

**On a rental, `price` is monthly rent** — so `rate_per_sqft` is rent per sqft
per month there and price per sqft on a sale.

### `POST /projects/:id/share_link`

Marketplace projects, and a firm's own copy of one (an `external_ref` matching
`PR` plus hex), return `{ share_link: { url, token } }`. The link is always for
the marketplace row, so a share from the copy still reaches the microsite.
Anything else is `422 not_marketplace`. `url` is the turbo microsite
`{turbo_public_origin}/m/{project code}?share_token=`. The token is reused for
the same broker and project. A double tap returns the same token.
`503 turbo_origin_missing` when `realtoriq.turbo_public_origin` is not set. An
enquiry on that link creates a sale lead for the broker, with lead source
`Builder Microsite`, in the project's primary category. An open lead for the
same mobile, sale and category is not duplicated; its source is left as it was. The owner is emailed from
`RealtorIQ by KGen <realtoriq-noreply@mail.kgen.tech>` when they have an email, a
follow-up is recorded, and the owner gets a `marketplace_enquiry` notification.
A dead lead does not block a new one. The same `enquiry_id` again is `200` and
does nothing else. `pushed_at` more than 10 minutes from now is `422` with
`This enquiry has expired.` A sharer who is disabled is not used: the firm's
super admin receives the lead. A firm that is not `active` is refused. A lapsed
subscription is not.

### `POST /projects/:id/creatives/:creative_id/personalised`

Any signed-in user. The creative must be on this marketplace project, or on
the catalog row a booking copy points at. Anything else is `404`.

`200` is `{ file: { url, filename, content_type, byte_size } }`. `url` is a
permanent proxy URL (`/rails/active_storage/blobs/proxy/…`), streamed by this
API so the browser can fetch it. It does not expire. The file is the original
creative with a white footer added underneath. The footer carries this firm's
name, logo, verified phone and RERA number, and the project's registration
numbers. A second call with the same details returns the stored file.

`410 creative_expired` — "This creative has expired." Checked before the firm is eligible.
`422 not_personalisable` — "Videos are shared as links."
`422 firm_rera_missing` — "It's printed on every creative and kit you share, as MahaRERA requires. Ask your RealtorIQ RM to add it."
`422 firm_phone_missing` — "Creatives carry your firm's verified mobile or WhatsApp number."

### `POST /projects/:id/microsite_kit` and `GET /projects/:id/microsite_kit`

Marketplace projects only, including a firm's booking copy. `404` otherwise.
The same `422` reasons as a personalised creative.

`POST` returns `202 { kit: { status: "preparing" } }` and builds the zip in
the background. If a kit with the same firm, project and details is already
ready, `POST` returns `200 { kit: { status: "ready", url, download_url, filename, byte_size, prepared_on } }`.
`prepared_on` is the India date, for example `29 Oct 2026`. `url` is the same
permanent proxy URL as a personalised creative. `download_url` is a permanent
redirect (`/rails/active_storage/blobs/redirect/…?disposition=attachment`) that
sends the browser to storage to save the zip. Older app builds keep using `url`.

`GET` is the latest kit for this firm and project: `preparing`, `ready` (the
same fields as the `200`), or `failed` with `message`. `message` is
"Couldn't Prepare the Kit." A kit left `preparing` for more than 10 minutes
is marked failed, and the next `POST` starts a new one. No kit yet is `404`.

The zip is `{project}-microsite-kit.zip`. It contains `index.html`,
`privacy.html`, `GUIDE.html`, `copy.txt`, resized photos, the firm logo, a
QR for each registration that has a MahaRERA link, the brochure when it can
be fetched, and every active image or PDF creative already personalised.
An expired creative is left out. A video is not a file in `creatives/`.
When the project has an active video, `index.html` has a Videos section:
YouTube plays from `youtube-nocookie.com` after a click, and Instagram,
Facebook and Google Drive are a link that opens the provider.
`GUIDE.html` says videos are links and play from the provider.
It does not contain brokerage, the RM, or another firm's details.

### Project detail `rera_registrations`, `creatives`, `marketing`

Detail adds three fields. List does not.

`rera_registrations` is `[{ number, label, maharera_url }]`. On a marketplace
project and on a firm's booking copy, these are the catalog row's
registrations. An empty list is the project's `rera_number` split on commas,
with `label` and `maharera_url` null. An own project that is not a copy uses
its own `rera_number` the same way.

`creatives` is the active creatives only. An expired creative is omitted.
Each one is `{ id, title, kind, page_count, registration_numbers, valid_until, thumb_url, width, height }`.
`valid_until` is an ISO date or null. The creative is available through that
India date and hidden the next day. `kind` is `image`, `pdf` or `video`.
`thumb_url` for an image is a 480px image. A PDF uses a first-page preview
when `pdftoppm` or `mutool` is installed, and is null otherwise.
A video also has `video_url`, `video_provider` (`youtube`, `instagram`,
`facebook` or `google_drive`), `width` and `height` null, and `share_text`.
`thumb_url` for YouTube is `https://i.ytimg.com/vi/{id}/hqdefault.jpg`, and
null for the other providers. `share_text` is the broker's lines for WhatsApp,
built from the same firm details as the footer, and is null when `marketing`
says the firm cannot share. The Project Reg. line is omitted when the creative
has no registration numbers. An own project that is not a copy
has `creatives: []`. A booking copy shows the catalog row's creatives.

`marketing` is `{ can_share, blocked_reason }`. `blocked_reason` is null,
`firm_rera_missing` when the caller's firm has no RERA number, or
`firm_phone_missing` when it has neither a verified mobile nor a verified
WhatsApp. `can_share` is true only when both are present.

Detail adds `rm_name` and `rm_contact` for marketplace rows. They are not in
`shareable`. `brochure_url` on a marketplace project is
`{turbo_public_origin}/realtoriq/brochures/{external_ref}`. LaunchIQ serves
that file from its own storage. RealtorIQ does not download it. When
`turbo_public_origin` is unset, the stored LaunchIQ URL is returned as it
arrived. A firm's own project is this app's `GET /realtoriq/brochures/{code}.pdf`,
the PDF it uploaded. The share message uses `brochure_url`, so it does not
contain `/rails/active_storage`. `brokerage_ladder_url` is the copied ladder
image and is on every project detail that has one, marketplace or own. It is
not in `shareable`.

### `POST /projects/:id/lead_matches`

Sale leads this caller can see that prefer this project's locality and
clear the same score floor as `POST /leads/:id/matches` (above 30 for an own
project, above 50 for a catalog project). An agent sees only leads assigned to
them. A project outside the ready window matches under-construction leads. A
project inside it matches both under-construction and ready-possession leads.
Unqualified leads, booked leads, rent leads, and a project that is archived or has no locality
and no usable pin return `[]`. A dead lead still matches, including when a live lead already has
the same mobile. At most 50. Until nearby matching is on, highest score first.
After that, the same groups as inventory matching, seen from the listing: a
buyer with a tagged pin within 6 km, then a buyer who named this locality,
then a buyer who named a neighbor locality. A higher score does not jump a
group. A high-scoring dead lead can sit above a live one inside the same group.

```json
{ "matches": [
  { "kind": "lead", "id": "…", "code": "L-0001", "name": "Meera Shah",
    "mobile": "+919820144210",
    "budget": 16000000, "typologies": ["2 BHK"], "localities": ["Kolshet"],
    "category": "residential", "area_sqft": 720, "area_unit": "sqft", "area_value": "720",
    "pre_leased": false,
    "area": { "value": "720", "unit": "sqft", "sqft": 720, "kind": "carpet" },
    "status": { "code": "dead", "name": "Dead", "is_dead": true, "is_booked": false },
    "score": 100,
    "score_breakdown": { "location": 30, "price": 50, "fit": 20, "configuration": 20, "area": null, "bonus": 0 },
    "matched_price": 14200000, "matched_configuration": "2 BHK",
    "mapped": false, "matched_on": ["locality", "price", "configuration"],
    "distance_m": null, "group": "locality", "near_shortlist": false }
] }
```

`distance_m`, `group`, and `near_shortlist` are the same fields as
`POST /leads/:id/matches`. `mobile` is that lead's primary number, so the caller can open WhatsApp without
a second request. It is only present because the caller can already open the
lead. `status` is that lead's pipeline stage, so a dead or booked card is
visible before anyone shares it. `mapped` is true when this lead is already
linked to this project id.

### `POST /properties/:id/lead_matches`

Own-firm leads use the same lead payload as the project endpoint, including
`mobile` and `status`, at the above-30 floor. A sale listing matches ready-possession leads. A rental matches
rent leads. The lead must prefer the listing's locality, or, once nearby
matching is on, a neighbor of it or a tagged pin within 6 km. Booked and sold-out
listings return `[]`. An unqualified lead is left out. A booked lead is left out. A dead lead still matches.

Another firm may call this for a listing that is still shared and available,
and whose firm is active. `matches` is then that caller's own leads, and only
those that score above 50. A listing that is not shared, or whose firm is not
active, returns 404 to every firm except the owner. The review demo cannot open it.
`marketplace_matches` and `marketplace_firms` are empty for every firm except
the owner.

`marketplace_matches` is the other firms' leads that score above 50, and only
the owning firm receives them. Each row is
`{ firm_id, firm_name, code, localities, configurations, marketplace: true, distance_m, group }`.
`distance_m` and `group` follow the same nearby rules.
`firm_id` is the other firm's id, the same id as in `marketplace_firms`.
Match a phone number on that id. Firm names are not unique.
`code` is that firm's own lead code, so the other broker can find the client.
`localities` is the shared locality. `configurations` is that lead's
typology names. There is no lead id, name, phone, budget, or score.
An under-construction home or commercial lead is not included on a sale listing.
A plot lead is included: Plot & Land does not ask possession. The lead's
category must match the listing, and commercial and Plot & Land also require
the configuration the lead chose. An unqualified
lead is not included. A booked lead is not included. A dead lead still is. At most 50.
Until nearby matching is on, highest score first, then firm name, then lead code.
After that, the pin, named-locality, and neighbor groups come first, and firm
name then lead code break ties inside a group. A high-scoring dead lead can
sit above a live one inside the same group. The score stays off the row. The
list is empty when `listed_on_marketplace` is false.

`marketplace_firms` is the other firms to contact, and only the owning firm
receives them. Each row is `{ id, name, mobile, whatsapp }`. A firm is
included when one of its leads would score above 50 on this property, or
when that firm has mapped the property. An unqualified lead does not score
a firm in. A booked lead does not score a firm in. A mapped firm still appears. A dead lead still scores its firm in.
No lead id, name, phone, budget, or score is included. The list is empty
when `listed_on_marketplace` is false.

### `GET /properties/marketplace`

The properties marketplace tab. Every **other active firm's** shared,
available listing, sale and rent together, newest first. This firm's own
stock is not included. A listing that is booked, sold out, or no longer
shared is left out. 25 per page (`per_page` up to 50).

`q` matches the firm name, locality, city, or configuration. Spaces and
case are ignored, so `2bhk` finds `2 BHK`. The building name and the
description are not searched. A query that is only punctuation returns
no rows.

Each row is the safe card: `id`, `code`, `title`, `listing_for`, `price`,
`typology`, `locality`, `city`, `category`, `pre_leased`, and
`firm: { name, mobile, whatsapp }`.
There is no area, carpet, photo, building, address, floor, description, or
confidential note. Open one row with `GET /properties/:id/marketplace`.

### `GET /properties/:id/marketplace`

Another firm's view of a shared, available listing. The owning firm receives
404 and uses `GET /properties/:id`. The body is the title, configuration,
`category`, locality, city, price, carpet, `area`, `pre_leased`, `lease`
(rent, lock-in, tenant, and yield; null when the listing is not pre-leased),
and the firm's name, mobile, and WhatsApp.
There is no note, building name, address, pin, floor, description, photos, or
confidential note. A listing that is not shared, or whose firm is not active, returns 404. The review demo cannot open it.

Mapping that property (`POST /leads/:id/properties`) is allowed for any lead
this caller can see whose sale/rent matches the listing, including an
under-construction client. A project can't go on a rental lead's shortlist.
A listing for sale can't go on a rental lead's shortlist, and a listing for
rent can't go on a sale lead's shortlist. A mapped shared
property can be logged on a site visit; that visit stays on the mapping firm's
lead and does not appear in the listing firm's visitors.

### `GET /projects/:id/mapped_customers`

Leads already mapped to this project, newest mapping first, 25 per page.
`?page=` defaults to 1. An agent sees only leads assigned to them. A withdrawn
mapping is left out. A marketplace row and the firm's booking copy list the
same customers. An unrelated project returns `customers: []`.

```json
{ "customers": [
  { "id": "…", "code": "L-0001", "name": "Meera Shah", "mapped_at": "2026-09-29T12:00:00Z" }
], "meta": { "page": 1, "per_page": 25, "total_count": 1, "total_pages": 1 } }
```

### `GET /properties/:id/mapped_customers`

Same payload for leads mapped to this property.

### `GET /projects/:id/marketplace_leads`

Leads mapped to the marketplace project. Works from the catalog row or from
the firm's booking copy. An own project with no `PR` code is
`422 not_marketplace`. An agent sees only leads assigned to them.

```json
{ "leads": [
  { "id": "…", "code": "L-0001", "name": "Meera Shah", "withdrawn": false,
    "pass_generated": true, "shared_with_builder": false,
    "status": "Pass generated", "pass_code": "CPVP…", "turbo_status": "unused" }
],
  "meta": { "page": 1, "per_page": 25, "total_count": 1, "total_pages": 1 } }
```

`page` defaults to 1. Each page is the 25 newest mappings. `meta.total_pages` tells the screen when to offer the next page.

`status` is `No pass`, `Pass pending`, `Pass generated`, `Shared with builder`
(the pass was scanned), or `Already registered with the builder`. A pass is
still created on the lead, one per marketplace project mapped to that lead.

### Visit passes

A pass is created only for a lead that is already mapped to a marketplace
project (`external_ref` is the turbo `PR` code). The mapping points at the
marketplace row.

`POST /leads/:id/visit_passes` with `{ project_id, tentative_visit_planned }`.
`201` `{ visit_pass }` on a new pass. `200` returns the existing unused pass
for that lead and project. A visit time more than a day in the past is `422
invalid`. `422 already_tagged` when a pass for that lead and project was
already scanned. `422 already_registered` when LaunchIQ has marked it
`duplicate`. `422 project_withdrawn` when the developer withdrew the listing.
`422 rera_required` when neither the broker nor the firm has a RERA number.
`422 not_mapped` / `not_marketplace` otherwise. LaunchIQ errors are `422
launchiq_rejected` with the message turbo returned. A timeout leaves the pass
`pending`; the next create sends the same idempotency key.

`POST /leads/:id/visit_passes/:id/refresh` pulls status. Allowed once every 6
hours from `last_fetched_at`. Earlier is `429 refresh_too_soon` with
`details.next_refresh_at`. A change on a scanned pass writes a follow-up
comment and does not change the lead's pipeline status or its next call date.
`turbo_status` `duplicate` stores `status_message` and writes that sentence as
a follow-up. The lead detail includes `visit_passes[]` (`pass_code`,
`pass_url`, `address`, `rm_name`, `rm_contact`, `status_message`,
`turbo_status` of `pending`, `unused`, `used` or `duplicate`, `turbo_lead_code`,
`turbo_status_name`, `status_detail`, `last_followup_at`,
`last_followup_comment`, `next_followup_at`, `last_fetched_at`,
`next_refresh_at`).

`mapped_projects[].withdrawn` is true after the developer withdraws that
project. Bookings on the copy are left as they are.

`mapped_projects[].project.external_ref` is the turbo project code on a
marketplace project. A booking, not the mapping, creates the firm's copy.

RealtorIQ calls turbo with `realtoriq.inbound_token` (bearer) at
`realtoriq.turbo_api_origin`, or `realtoriq.turbo_public_origin` when the API
origin is not set. Both must be https.

### turbo-rails8 `POST /turbo/events`

Not a broker call. HMAC-SHA256 of the raw body in `X-RealtorIQ-Signature: sha256=<hex>`,
secret `realtoriq.webhook_secret`. `401` is `{ "error": "Unauthorized" }` (a
string, not the broker error envelope). Other failures are
`{ "error": "<sentence>" }` so the public enquiry form can show them. `200` is
`{ "ok": true }`. An upsert is `202` once the listing is saved. Photos and
the brokerage ladder are copied afterwards. The brochure is not copied: an
https URL is stored when its host is the LaunchIQ origin or S3. Any other
URL is ignored and the previous link stays. A blank `brochure` clears the
link. `pushed_at` is required. An older `pushed_at` is
ignored. `event` is `upsert`, `hide`, `withdraw`, or `enquiry`. Hide archives
the catalog row only. Withdraw archives the catalog row and every firm copy of
that project code, and sets `mapped_projects[].withdrawn`. A later upsert makes
them active again. Neither deletes leads. An upsert requires `developer_name`,
`city`, `locality`, `rera_number` and `possession_on` (`YYYY-MM-DD`). A blank or missing locality is `locality is required`. A catalog row already stored without a locality stays until the next push includes one. Images are
`images: [{ url, checksum, filename }]` and the brochure is
`{ url, filename, checksum }`. The brochure URL is stored, not downloaded. When its host is `turbo_api_origin` and `turbo_public_origin` is a different host, the stored link uses the public host and keeps the path.
Optional on an upsert: `promo_text` (no length
limit; a blank value clears it), `brokerage_percent` (starting brokerage,
greater than 0 and at most 100; omitted leaves the stored percent alone, blank
clears it), and `brokerage_ladder: { url, checksum, filename }` (copied;
omitted leaves the image alone). Optional `rera_registrations` replaces the
whole list. Each entry is `{ number, label, maharera_url }`. The number is
stored uppercased, a blank number is dropped, and `label` is at most 40
characters. `maharera_url` is kept only for
`https://maharerait.maharashtra.gov.in/project/view/{digits}` or the same path
under `/public/`, with any query. It is stored without `/public` and without
the query. Any other URL is stored as null. Omitting the key leaves the list
alone. Optional `creatives` replaces the set. Each creative is `{ id, title, position, kind, valid_until, registration_numbers }` plus either the file keys `{ url, checksum, filename, content_type }` or `{ video_url, video_provider, tags }`.
`id` is unique per project. `valid_until` is `YYYY-MM-DD` or null. Omitting
`valid_until` stores null, so a payload from before this field still applies.
`kind` `video` stores the link and does not download a file. `tags` is ignored.
The link must be `https` on YouTube (`watch`, `youtu.be`, `shorts`, `embed`,
`live`), Instagram (`reel`, `reels`, `p`, `tv`), Facebook (video, reel, watch,
share, or `fb.watch`) or Google Drive (`file/d/{id}` or `open?id=`). `www.` and
`m.` are ignored. The provider is taken from the host. A rejected link skips
that creative and the rest of the push still applies. Images are jpeg, png or
webp. A PDF may be at most 5 pages. A file that fails is skipped. Changing an
image or PDF into a video drops its file and personalised copies. Changing a
video into a file downloads the file. Omitting `creatives` leaves the set alone. An older
`pushed_at` changes neither. Detail shows all three on a
marketplace project. `shareable` still omits the percent and the ladder. The
builder is `developer_name`, not `company_code`. Each `unit_types` entry is stored as its own configuration row: `label`, `typology_name`, `typology_category` (`residential`, `commercial` or `land`), `typology_slug`, `price_min` (whole rupees), `area_min` and `area_unit` (`sqft` or `sqm`). A home or office sent in sqm is stored in sq ft, converted with 10.7639. A plot keeps the typed sqm.

### `GET /turbo/share_links/:token`

Not a broker call. `Authorization: Bearer` is `realtoriq.inbound_token`. A
missing or wrong token is `401 { "error": "Unauthorized" }`. An unknown token,
or a firm that is not active, is `404 { "error": "Not found" }`. More than
600 calls a minute from one address is `429 { "error": "Too many requests" }`.

`200` is `{ firm: { name, mobile, whatsapp, rera_number, logo_url }, project_code }`.
`mobile` and `whatsapp` are the firm's verified numbers in E.164, or null.
`logo_url` is a 192px logo, or null. `project_code` is the catalog row's
LaunchIQ code.

### `shareable`

Every project and property **detail** carries a `shareable` object holding
exactly the fields that may go to a buyer.

**Compose share messages from `shareable` and nothing else.** It cannot reach
`confidential_note`, and on a project it omits `brokerage_percent` — what the
broker earns is not the client's business.

### Photos

| | |
| --- | --- |
| `POST /projects/:id/photos` | `{ photo_signed_ids: [...] }` |
| `DELETE /projects/:id/photos/:photo_id` | |
| `POST /properties/:id/photos` | |
| `DELETE /properties/:id/photos/:photo_id` | |

A detail returns **both**:

```json
"photos": [
  {
    "id": "59418d74-…",
    "url": "https://…/flat.jpg",
    "thumb_url": "https://…/representations/…/flat.webp",
    "large_url": "https://…/representations/…/flat.webp",
    "width": 1600,
    "height": 1200
  }
],
"photo_urls": [ "https://…/flat.jpg" ],
"photo_count": 1,
"cover_photo_url": "https://…/flat.jpg",
"cover_thumb_url": "https://…/representations/…/flat.webp"
```

**`photos[].id` is the attachment id that `DELETE` takes.** It is not the id
inside the blob URL — that is the *blob* id, a different record, and using it
gives you a 404. Max **20** photos per listing (`too_many_photos`). Attachment
ids are random, so they do not sort by time. `photos`, `photo_urls` and
`cover_photo_url` follow upload order (`created_at`). The first upload is the
cover. There is no reordering.

`thumb_url` is a WebP at most 480×480. `large_url` is a WebP at most 1600×1600.
`width` and `height` are the original's pixel size, or null before analysis.
A list row carries `cover_thumb_url` (the first photo's thumb) and does not
carry `photos`. `url`, `photo_urls`, `cover_photo_url` and
`shareable.photo_urls` stay the original file, because those links are pasted
into WhatsApp. A file that cannot be resized returns that same original URL
for `thumb_url` and `large_url`. Marketplace property cards still omit photos.

---

## Bookings and money

**Managers and super admins only.** Every endpoint here is `403 forbidden_role`
for an agent.

### The one formula

```
net_income = round(agreement_value × commission_percent / 100) + kicker − passback
```

Computed and **stored** server-side on every save, rounded half-up once. Worked
example: ₹1,56,00,000 at 4.5% = ₹7,02,000, plus a ₹50,000 kicker, minus a ₹66,000
passback = **₹6,86,000**.

**Never recompute this on the client.** Rounding is done once, at the point the
percentage meets the value, and a client that rounds an intermediate will drift
by rupees from what the reports sum.

### `POST /bookings`

| Field | Type | | Notes |
| --- | --- | --- | --- |
| `lead_id` | string | **required** | `422 lead_required` without it |
| `booked_on` | date | optional | **Defaults to today** if omitted — so a near-miss key lands the booking in the wrong month for every report. Send it explicitly |
| `agreement_value` | integer | **required** | |
| `commission_percent` | number | **required** | |
| `kicker` / `passback` | integer | optional | Default 0 |
| `customer_name` / `customer_mobile` | string | optional | **Snapshotted** — see below |
| `project_id` | string | optional | A booking is on a project **or** a listing, not both. Sending both is `422 project_and_listing` |
| `property_id` | string | optional | The firm's own listing, of any status, or a Marketplace listing this firm can see. The Marketplace rule is the same as a shared property, except the listing need not still be Available. Anything else is `422 listing_not_found`. One **live** booking per listing per firm (`422 listing_already_booked`, `details.booking_id` and `details.code`). Another firm can book the same Marketplace listing. The booking stores the listing's typology. Its title is the safe card title when the listing belongs to another firm (configuration and locality, or Listing), and this firm's own title when the listing is theirs, including after that listing leaves the Marketplace. Existing bookings are not backfilled |
| `project_typology_id` | string | optional | A configuration of that project. The booking stores that typology and label, so a later project save can replace the row without blanking the booking. On a catalog or marketplace booking the id is matched to the firm's copy by typology and label. When the copy has no such row, the booking still saves with the snapshot and `project_typology_id` null. A configuration of some other project is `422 invalid`. On PATCH, omit the key to keep the snapshot; send null to clear it. Removing the project clears it. Nothing is backfilled |
| `mark_lead_booked` | boolean | optional | When true, the lead moves to the active Booked status in the same transaction, with the same timeline entry as `POST /leads/:id/status`. `booked_at` is `booked_on` at the start of that day in Asia/Kolkata, not the time the booking was entered. When the firm has no Booked status the booking still saves and the response adds top-level `lead_status_unchanged: true`. A failed move (for example `duplicate_lead`) rolls the booking back. Omit it, or send false, and the lead stays as it is |
| `mark_property_booked` | boolean | optional | When true, and the listing is the firm's own and Available, the listing becomes `booked` in the same transaction. Otherwise it is ignored and the response adds top-level `property_status_unchanged: true`. On PATCH this applies only when `property_id` changes to a different listing. The listing it pointed at before is left as it is. Omit it, or send false, and the listing stays as it is |
| `unit_no` | string | conditional | **Required when `project_id` is set.** Unique among **live** bookings on that project. Cancel frees the unit |
| `builder_ref_no` | string | optional | |
| `use_existing` | boolean | optional | Catalog booking name clash — reuse the existing My Projects row |
| `new_name` | string | optional | Catalog booking name clash — copy under this name instead |
| `carpet_area_sqft`, `other_details` | | optional | |
| `area_kind` | | response | `carpet`, or `plot` when the lead's category is land. Not a write field |
| `registration_done_on` | date | optional | |
| `client_paid_percent` | integer | optional | 0–100 |

**`customer_name` and `customer_mobile` are snapshots.** Omit them and they are
copied from the lead at booking time. They do not track the lead afterwards —
correcting a lead's name a year later must not rewrite what was booked.

There is no endpoint to find a lead by phone before booking; it is just
`GET /leads?q=<digits>`.

**Catalog bookings.** If `project_id` is a catalog row, the server copies
required fields into a My Projects (`source: own`) row and stores *that* id on
the booking. Leads stay mapped to the catalog row. A cancelled booking
**keeps** the copy.

A **global marketplace** project (`source: catalog`, no firm) is copied by its
project code, never by name. A same-named project the firm added itself is left
alone, and the copy is named `"<name> (<developer>)"` when the plain name is
taken. `use_existing` and `new_name` do not apply to that row. This is the
only time a firm copy is created.

`PATCH /bookings/:id` copies a catalog or marketplace `project_id` the same
way before it saves. The booking never stores the shared project's id. Omit
`project_id` to leave the booking's project alone. `use_existing` and
`new_name` apply to a firm-owned catalog row on PATCH as well. `property_id`
and `mark_property_booked` follow the create rules. Omit `property_id` to leave
the listing alone. Send null to clear it. A `property_status_unchanged: true`
on the response means the flag was sent and the listing's status was not changed.

A catalog row this firm already owns still uses the name check. If My Projects
already has that name: **`422 project_name_clash`** with
`details.existing_project_id` and `details.name`. Retry the same body with
`use_existing: true` (point the booking at the existing own row) or `new_name`
(copy under the new name). Do not send both; `use_existing` wins.

### `GET /bookings`

| Filter | Notes |
| --- | --- |
| `q` | Substring of customer name, customer phone, unit, builder ref, booking code, or **project name**. When it contains 4 or more digits, the phone is also matched on those digits alone, so `98201 55011` and `+91 98201-55011` find `+919820155011` |
| `stage` | `to_invoice` · `awaiting_payment` · `paid` · `cancelled`. Replaces the default of live. Anything else is `422 invalid` |
| `status` | Still accepted for older clients: `live` (the default when neither `stage` nor `status` is sent) · `cancelled`. Anything else is `422 invalid` |
| `registration` | `done` · `pending`. Anything else is `422 invalid` |
| `client_phone`, `project_id` | `project_id` that is not an id is `422 invalid` |
| `booked_from`, `booked_to` | A non-date, or from after to, is `422 invalid` |
| `page`, `per_page` | 25 per page by default |

`totals` is over the **live** rows in the filtered set (`status=cancelled` and `stage=cancelled` therefore return zeros):

```json
"totals": {
  "agreement_value": 15600000, "net_income": 686000,
  "invoiced": 686000, "collected": 400000, "outstanding": 286000, "to_invoice": 0
}
```

`invoiced` and `collected` are the stored booking totals. `outstanding` is invoiced minus collected. `to_invoice` is the sum of `max(net_income − invoiced, 0)` per booking.

`stage_counts` uses the same filters **except** `stage`, so the pills do not collapse when one is selected. `all` counts live bookings. `{ "all", "to_invoice", "awaiting_payment", "paid", "cancelled" }`.

A row's `stage` is `cancelled`, else `paid` when `net_income <= 0` or the collected total has reached it, else `awaiting_payment` when invoiced is ahead of collected, else `to_invoice`. `registration` is not a stage.

### Payload

```json
{
  "code": "B-0001", "status": "live", "stage": "awaiting_payment",
  "agreement_value": 15600000, "net_income": 686000,
  "invoiced": 686000, "collected": 400000, "outstanding": 286000, "to_invoice": 0,
  "registration_done_on": null, "oldest_due_invoice_on": "2026-08-04",
  "configuration": { "id": "…", "label": "2 BHK Ultima", "category": "residential", "typology_id": "…" },
  "property": { "id": "…", "code": "H-0001", "title": "2 BHK in Powai", "listing_for": "sale", "status": "booked", "own": true },
  "category": "residential", "cancellation_reason": null,
  "revenue": {
    "agreement_value": 15600000, "commission_percent": 4.5,
    "commission_amount": 702000, "kicker": 50000, "passback": 66000,
    "net_income": 686000, "invoiceable_balance": 0
  }
}
```

`configuration` is null until a booking is saved with one. `label` and `category` come from the snapshot taken then, not from the project's current row. `typology_id` is that typology. `id` is `project_typology_id` while that row still exists; after the project is saved in the configuration editor it is the new row with the same typology and label, or null if the project no longer has one. `category` is repeated at the top level (`residential`, `commercial`, `land`) and is null without a configuration. A booking linked to a listing snapshots that listing's typology the same way, and `property.title` is the safe card title for another firm's listing, or the listing's current title when it is this firm's. `property` is null when the booking has no listing. `property.firm_name` is present only when `own` is false. `oldest_due_invoice_on` is the issue date of the oldest raised invoice that still has a balance of its own; an unlinked collection does not settle an invoice, and a cancelled invoice is ignored.

The list-card figures are top level; the itemised breakdown is under `revenue`. The detail also carries `created_by_name` (who recorded the booking), `documents[]`, `invoices[]`, and `collections[]`.

### Invoices and collections

| | |
| --- | --- |
| `GET` / `POST /bookings/:id/invoices` | `{ number, issued_on, amount, comment }` |
| `GET` / `POST /bookings/:id/collections` | `{ received_on, amount, mode, transaction_no, invoice_id, proof_signed_id }` |

`number` is entered by the broker (`INV-2026-041`) so it matches what was raised
outside the system, and is unique per firm. **Cancelling an invoice is not
built.**

`mode` is `neft_rtgs` · `upi` · `cheque` · `cash`. `invoice_id` is optional —
"Unlinked payment" is a first-class choice.

Both index actions return a `totals` block rather than the parent booking:

```json
{ "invoices": [...], "totals": { "net_income": 686000, "invoiced": 686000, "invoiceable_balance": 0 } }
{ "collections": [...], "totals": { "invoiced": 686000, "collected": 400000, "outstanding": 286000 } }
```

### Three hard blocks

All `422`, all carrying the arithmetic in `details` so you can say *how much is
left* rather than only that it said no.

| Code | Refuses |
| --- | --- |
| `over_invoiced` | An invoice past the booking's net income |
| `over_collected` | A collection past what has been invoiced |
| `over_collected_for_invoice` | A collection past **that one invoice**, even when the booking total allows it |

The third is what catches a payment filed against the wrong invoice.

```json
{ "error": { "code": "over_invoiced", "message": "…",
  "details": { "net_income": 686000, "already_invoiced": 686000, "attempted": 1, "available": 0 } } }
```

### Cancelling

`POST /bookings/:id/cancel` with a **required** `reason` (`422 reason_required`). Always JSON — a 422 is `{ "error": { "code", "message", "details" } }`, never Rails' HTML `public/422.html`.

- Sets status to `cancelled` and **nothing else**. Invoices already raised stay
  on record.
- The booking leaves `Booking.live`, which is where every money query starts.
- **Cancelling does not touch the lead.** It does not reopen it. Creating a
  booking moves the lead only when `mark_lead_booked` is true.
- `release_property`, when true, sets the firm's own `booked` listing back to
  `available` in the same transaction, if no other live booking of this firm
  points at it. A Marketplace listing is left as it is. Omit it, or send false,
  and the listing stays as it is.
- Cancelling twice is `422 already_cancelled`. Updating a cancelled booking is
  refused.

### Documents

`POST /bookings/:id/documents` — `{ slot, label, signed_id }`. Slots are
`application_form`, `tagging_confirmation`, `lead_source_proof`, `other`. **Only
`other` may hold more than one file**; a second file in a named slot is
`422 slot_taken`, not a silent overwrite. `DELETE /bookings/:id/documents/:id`
purges the blob too.

### MahaRERA Form 6

Managers and the super admin. An agent is `403 forbidden_role`.

Form 6 is a Maharashtra return. `available` is true when the firm's city is in
Maharashtra. `GET /form6/settings` always answers. `PATCH /form6/settings`,
`GET /form6/preview` and `GET /form6/download` are `403 form6_unavailable`
when it is false.

`GET /form6/settings` returns the saved answers plus `firm_rera_number`,
`firm_legal_name`, `available`, and `periods`. Each period is
`{ id, from, to, due_on }`. Ids look like `2026-04` (1 Apr–30 Sep, due 20 Oct)
and `2025-10` (1 Oct–31 Mar, due 20 Apr). `periods` is the six newest halves
that have fully ended, newest first.

`PATCH /form6/settings` merges. Unknown keys are dropped. A person object
replaces that person. Send JSON:

| Key | |
| --- | --- |
| `registered_name` | Falls back to the legal name, then the firm name, on the form |
| `competency_certificate_no` | |
| `signatory_name`, `signatory_designation` | The signature block |
| `designated_project_ids` | This firm's project ids, or a LaunchIQ catalog project (no firm, `source` catalog, any status), in the order Table A should print them. Another firm's project is refused |
| `turnover_20l_or_more` | `true` or `false` only |
| `principal_officer`, `designated_director` | `{ name, appointed_on, mobile, email, address }`. `appointed_on` is `YYYY-MM-DD`. `mobile` is an Indian mobile |

`GET /form6/preview?period=2026-04` returns `period`, `bookings_count` (live
bookings on a project, booked in the half), `left_out` (`cancelled`,
`without_project`), `designated_projects_count`, `gaps`
(`projects_without_rera`, `bookings_without_configuration`, `missing_settings`)
and `filename`. A cancelled booking with no project counts only as cancelled.
A half that has not ended, or a bad id, is `422 invalid`.

`missing_settings` lists blanks in form order. `firm_rera_number` is first when
the firm's registration number is empty — brokers cannot set it; ops adds it
on the firm, and the Word file's letterhead drops the line. Then
`competency_certificate_no`, `signatory_name` and `signatory_designation`.
When `turnover_20l_or_more` is true, each blank field of the two people
follows: `principal_officer.name`, `principal_officer.appointed_on`,
`principal_officer.mobile`, `principal_officer.email`, `principal_officer.address`,
then the same five for `designated_director`.

`GET /form6/download?period=2026-04` sends that `.docx`
(`application/vnd.openxmlformats-officedocument.wordprocessingml.document`).

---

## File uploads

Three steps. **The size and type caps are enforced at step 1**, so a rejection
arrives before you have moved any bytes.

```
1.  POST /uploads  { purpose, filename, byte_size, checksum, content_type }
      → { signed_id, direct_upload: { url, headers } }

2.  PUT <direct_upload.url>          ← the file itself. No Authorization header;
      headers: direct_upload.headers   the url is pre-signed.

3.  POST /projects/:id/photos  { photo_signed_ids: [signed_id] }
    …or send signed_id / brochure_signed_id / proof_signed_id with the parent record.
```

`checksum` is the **base64-encoded MD5** of the bytes. Storage rejects the PUT if
it does not match — that is the integrity check, not a bug.

| `purpose` | Max | Types |
| --- | --- | --- |
| `property_photo` | 5 MB | jpeg, png, webp |
| `project_photo` | 5 MB | jpeg, png, webp |
| `project_brochure` | 5 MB | pdf |
| `project_brokerage_ladder` | 5 MB | jpeg, png, webp |
| `booking_document` | 2 MB | pdf, jpeg, png |
| `collection_proof` | 2 MB | pdf, jpeg, png |
| `firm_logo` | 1 MB | png, jpeg, svg, webp |

Rejections at step 1: `file_too_large`, `unsupported_type`.

Attaching a `signed_id` whose PUT never landed is **`422 upload_incomplete`**, not
a 500 — photos, brochures, booking documents and collection proofs all take that
code. A malformed signed_id, one issued for another firm, or one issued for a
different `purpose` is `422 invalid_upload`. Caps are checked again at attach, so
a 5 MB `project_photo` ticket cannot be attached as a 2 MB `collection_proof`.

> Rails' own `/rails/active_storage/direct_uploads` is deliberately **404'd**.
> It sits outside our auth and enforces none of these caps. `POST /uploads` is
> the only way to get a ticket.

---

## Brand website

Super admin only. The public site is `https://cp-{firm-slug}.realtoriq.kgen.tech`.
It is not a path on the app host. `website_enabled` starts true. Turning it
off returns 404 for the whole host and does not change each listing's
`on_website`.

| | |
| --- | --- |
| `GET /firm/website` | |
| `PATCH /firm/website` | |

```json
{
  "about": "Family brokerage in Pune.",
  "website_phone": "9820144210",
  "website_enabled": true,
  "address_line1": "12 MG Road",
  "address_line2": null,
  "city_id": "…",
  "locality_id": "…",
  "pincode": "411001",
  "lat": 18.52,
  "lng": 73.85,
  "google_place_id": "ChIJ…",
  "logo_signed_id": "…",
  "remove_logo": false
}
```

Unknown keys are ignored. `website_phone` is stored for the public Call and
WhatsApp buttons only. It does not change `contact_channels`. Blank clears it.
The logo is png, jpeg, or webp. SVG is rejected. `url` in the response is the
public home when the site is actually up, otherwise null. `suggested_phone`
is the firm's verified mobile when `website_phone` is blank. It is a hint.
Sending it back is what stores it; a blank `website_phone` stays blank, and a
later save that omits the key does not copy the verified mobile onto the site.
`lat` and `lng` are sent together. One without the other is `422 invalid`,
and the stored pin is left as it was. Sending both blank clears the pin.

The public home form emails the broker and does not create a lead. The address
is the firm's verified email channel, or the super admin's email when that
channel is not verified. A project page or a property page is what creates a
lead, mapped to that listing. The checkbox posts `g-recaptcha-response`.

`PATCH /projects/:id` and `PATCH /properties/:id` accept `on_website`. Project
edits stay super-admin only. The detail payload adds `on_website`, `slug`, and
`website_url` (null unless that listing is on the public site right now).
`website_url` is `https://cp-{firm slug}.realtoriq.kgen.tech/projects/{code}/{name}`
for a project and `/properties/{code}/{title}` for a property. The code is that
listing's own code. The words are the current name, so a rename changes the
words and the code keeps the old link working.

---

## Firm contact channels

The **firm's** email, mobile and WhatsApp — one of each. Users have no channels
of their own: the sign-in code proves possession at sign-in, which is
authentication, not channel verification.

| | |
| --- | --- |
| `GET /firm/contact_channels` | |
| `POST /firm/contact_channels/:id/request_code` | Super admin only |
| `POST /firm/contact_channels/:id/verify` | `{ code }`. Super admin only |

**Editing a channel's value clears its verification.** `channels_verified` on
`/me` is the "all three done" flag.

---

## Notifications

The inbox is the record. Browser push is a best-effort delivery of an inbox row
to this browser. A `201` from the test endpoint means the push service accepted
the message, not that the broker saw it.

VAPID keys live in Rails credentials under `vapid` (`public_key`, `private_key`,
optional `subject`). Generate a pair with `bin/rails notifications:generate_vapid`
and paste it in. Do not commit the private key. The page reads the public key
from the API so it cannot drift from the private key.

`notification_mode` `none` suppresses follow-up reminders. `all` and `important`
both deliver them. A test ignores the mode. There is no `PATCH /me` for the mode.

Follow-up reminders go only to the lead's assignee, and only once the scanner's
watermark has passed that `next_action_at`. The first run of
`Notifications::DispatchDueFollowups.call` plants the watermark and sends
nothing. From a console, `Notifications::SendTest.to_user(user)` pushes to
every device that broker has registered.

| | |
| --- | --- |
| `GET /notifications` | `{ notifications, meta }` including `meta.unread_count` |
| `GET /notifications/unread_count` | `{ unread_count }` |
| `PATCH /notifications/:id/read` | `{ notification }`. Another user's row is 404 |
| `POST /notifications/mark_all_read` | `{ unread_count: 0 }` |
| `POST /notifications/test` | This session only. 201 `{ notification, push }` or 422 `no_subscription` / `push_rejected` / `push_key_mismatch`. 503 `push_not_configured` |
| `GET /push_subscriptions` | `{ push_subscription: { subscribed } }`. No endpoint or keys |
| `POST /push_subscriptions` | `{ endpoint, p256dh, auth, content_encoding? }` → `{ push_subscription: { subscribed: true } }` |
| `DELETE /push_subscriptions` | 204. This session only |
| `GET /push_subscriptions/vapid_public_key` | `{ vapid_public_key }` or 503 `push_not_configured` |

A notification looks like:

```json
{
  "id": "…",
  "kind": "followup_due",
  "title": "Followup — Rhea Kapoor",
  "body": "Due 26 Sep, 4:30 PM",
  "read_at": null,
  "data": { "page": "leads", "item": "…" },
  "created_at": "2026-09-26T16:30:00.000+05:30"
}
```

`kind` is `followup_due`, `test`, `training_published`, `marketplace_enquiry`,
`inbound_enquiry`, `facebook`, `match_digest`, or `website_enquiry`. A match digest opens
`/matches` (`data.page` is `matches`) and is sent only to the firm's super admin.
Its title is `New Matches Are Ready`. The body counts leads and listings and
does not name a client.
A marketplace enquiry points at the lead (`data.page` `leads`, `data.item` the
lead id). The title is `New Marketplace Enquiry` for a new lead and
`Marketplace Enquiry on <lead code>` when the mobile already had a live lead.

`data.page` is the screen (`leads`, `projects`, `properties`, `bookings`,
`matches`, `settings`, `team`, `reports`, `subscription`, `skills-training`, or `home`). With `data.item` the
row opens that record's show page (`/leads/<item>`). With `data.params` and no
`item`, it opens the list plus that query (`filter=missed_followup`). No
`page`, or a page the app does not have, means the row is not clickable. An
`item` and `params` together: the show page wins and the filter is ignored.

---

## Trainings

Skills & Trainings is platform content: KGen ops publish a training from the
admin panel and every firm sees the same list. There is no `firm_id` on a
training. All three roles read them — there is no money in a training and
nothing tenant-specific to hide.

A training is visible when it is **active** and its `valid_upto` has not passed.
The last day counts (a training valid upto 31 March is readable all day on the
31st, in IST), and anything else — a draft, an archived one, an expired one —
answers **404**, the same way an invisible lead does.

| | |
| --- | --- |
| `GET /trainings` | `{ trainings, meta }`, newest first, 25 a page |
| `GET /trainings/:id` | `{ training }` with the intro, the file URLs and the caller's own note |
| `PUT /trainings/:id/note` | `{ body }` → `{ note }`. An empty body clears it and returns `{ "note": null }` |

The list card:

```json
{
  "id": "…",
  "title": "Real Estate Basics & Closing Techniques",
  "description": "RERA rules, poori cost, SPIN discovery aur closing.",
  "language": "hinglish",
  "language_label": "Hinglish",
  "banner_url": "https://…",
  "valid_upto": "2027-03-31",
  "podcast_duration_seconds": 1200,
  "published_at": "2026-10-05T12:00:00.000+05:30"
}
```

`valid_upto` is `null` when a training never expires; the screen writes
"Expiring: Never". The detail adds:

```json
{
  "intro_text": "Site visit perfect gaya. …",
  "instructions_text": null,
  "document_url": "https://…",
  "podcast_url": "https://…",
  "created_by_name": "Priya Ops",
  "note": { "body": "Saturday: pre-approval slot", "updated_at": "2026-10-06T11:02:00.000+05:30" }
}
```

- `instructions_text` is `null` when ops left it blank — the client then shows
  its own default steps rather than an empty section.
- `note` is `null` until this broker writes one. It is theirs alone: notes are
  firm-scoped and keyed by user.
- **The file URLs are permanent**, like photos and unlike booking documents. A
  training is teaching material, not evidence, and a 20-minute audio element
  whose URL expires mid-listen is worse than the risk a forwarded link carries.
  An uploaded podcast wins over a pasted link.
- `document_url` is streamed by this API (`/rails/active_storage/blobs/proxy/…`).
  The guide reader fetches the file in the browser. A redirect to object storage
  answers `200` without `Access-Control-Allow-Origin`, and the browser discards
  it. `banner_url` and an uploaded `podcast_url` stay redirects.
- `language` is `hinglish`, `en` or `mr`. One training per language: the English
  edition of a course is a separate row.

Writing a note is a `PUT` because the client holds one text area and sends
whatever is in it. A body over 20,000 characters is refused rather than
truncated, and a body that is not text is a `400` — ignoring it, which is what
the API does with misshapen params elsewhere, would read as "clear my note".

When a training is activated for the first time, every active broker in every
active firm gets one `training_published` notification (`data.page` is
`skills-training`). Archiving and activating it again says nothing: it is a
correction, not news.

---

## Inbound enquiries

A website posts a buyer here. The firm is the one that owns the key in
`Authorization: Bearer`. The body cannot name a firm. These routes do not use
a broker JWT. A bad or missing key, or a firm that is not active, is
`401 unauthorized`. An unknown portal in the path is `404 not_found`, and only
after the key is valid. The portal and project-or-property choice come from
the path. A query string cannot change them.

A body over 8 KB is `413 invalid` ("This enquiry is too large.") and is refused
before the JSON is read. Calls are counted per address and per key we have
already accepted. An unrecognised bearer does not get a bucket of its own.
More than 20 failed keys a minute from one address, more than 300 calls a
minute from one address, or more than 30 calls a minute for one valid key is
`429 rate_limited`. A cache that cannot count refuses the call.

`listing`, `enquiry_id`, `city`, `locality` and `configuration` longer than
255 characters are rejected. `name` is shortened to 255. An `email` that is
not a normal address is dropped and the lead is still saved. `budget` is at
most 15 digits. A rejected call notifies the owner at most 10 times a day.
The same rejection is only sent once that day. Retries of that same rejection
do not use up the 10.

| Method | Path |
| --- | --- |
| POST | `/inbound/99acres/projects` |
| POST | `/inbound/99acres/properties` |
| POST | `/inbound/magicbricks/projects` |
| POST | `/inbound/magicbricks/properties` |
| POST | `/inbound/housing/projects` |
| POST | `/inbound/housing/properties` |
| POST | `/inbound/general/projects` |
| POST | `/inbound/general/properties` |

The path sets the lead source: `portal_99acres`, `portal_magicbricks`,
`portal_housing`, or `website`. Unknown body keys are ignored.

| Field | Notes |
| --- | --- |
| `mobile` | **required.** A 10-digit Indian mobile. `9876543210`, `+91 98765 43210` and `09876543210` are the same number |
| `name` | optional |
| `email` | optional. A value that is not an email address is ignored |
| `listing` | The saved portal code, the `P-` or `H-` code, or — for a project — the exact project name. Case and extra spaces are ignored. On a projects URL, a marketplace `P-` code or LaunchIQ `PR` code is accepted after this firm's own projects. An archived catalog row is "That project is archived." |
| `message` | optional, at most 500 characters. On a new project lead it is stored as `notes`. On an existing lead it is added to the follow-up note |
| `gclid`, `gbraid`, `wbraid`, `utm_source`, `utm_medium`, `utm_campaign`, `utm_term`, `utm_content` | optional, each at most 200 characters. Stored on `leads.web_enquiry`. A later enquiry replaces the keys it sends and leaves the rest. Returned on lead detail as `web_enquiry` |
| `consent` | optional. The value `yes` stores `web_enquiry.consent_at`. Any other value is ignored |
| `enquiry_id` | optional. The same id on the same portal is a no-op after it has been saved. A call that failed can be retried with the same id |
| `budget` | Whole rupees, digits only (`12000000`), at most 15 digits. Used only when `listing` is omitted |
| `city` | Exact city name. Required with `locality` when `listing` is omitted. Two cities with the same name are refused |
| `locality` | Exact locality name inside that city |
| `configuration` | Exact typology name, for example `2 BHK` |
| `transaction_type` | `sale` or `rent`. Read only on `POST /inbound/general/properties` when `listing` is omitted |

A named project is always a sale. Ready possession is set when the project has
no possession date and its label starts with the word Ready (`Ready`,
`Ready to move`, `Ready possession`), or its possession month is this month,
one of the next two, or any earlier month in India. A later month is Under
construction. Budget, locality and every configuration are copied
from the project. A project with no configuration is rejected. A project with
no locality is still saved.

A named property takes sale or rent from the listing. A sale is Ready
possession. A rent has no property type. Budget is the listing price. The
99acres, Magicbricks and Housing property URLs require `listing`. The general
property URL can omit it, and then `budget`, `city`, `locality`,
`configuration` and `transaction_type` are required. A sale in that case is
Ready possession.

Omitting `listing` on any projects URL requires `budget`, `city`, `locality`
and `configuration`. The lead is a sale under construction. A phone number
alone is rejected.

When a listing is matched, `budget`, `city`, `locality`, `configuration`,
`transaction_type` and `property_type` in the body are ignored.

A second enquiry for the same mobile and the same sale or rent type does not
create a second card. The listing is attached, a follow-up note is added, and
a missing locality or configuration is added. Stored budget and property type
stay as they are. A dead lead does not block a new one. The new lead is
unassigned. The firm owner gets an in-app notification. A rejected call
notifies the owner as well, without the key. Sold and booked properties still
create the lead and link the property.

Success is `200` and `{ "status": "created" }` or
`{ "status": "already_in_pipeline" }`. A rejection is `422 invalid` with a
plain `message`.

### `GET /inbound_credentials`

Superadmin only. Creates the firm's key the first time. Returns the token and
four notes the owner can copy. The token is in the note, never in the URL.

```json
{
  "inbound_credential": {
    "token": "…",
    "portals": [
      {
        "channel": "99acres",
        "label": "99acres",
        "projects_url": "https://api.example/api/v1/inbound/99acres/projects",
        "properties_url": "https://api.example/api/v1/inbound/99acres/properties",
        "message": "Please send new 99acres enquiries…"
      }
    ]
  }
}
```

`portals` is `99acres`, `magicbricks`, `housing`, then `general`.

### `POST /inbound_credentials/rotate`

Superadmin only. Replaces the key. Every previous URL stops. The response is
the same shape as the GET. The audit row records the rotation and does not
store the token.

---

## Facebook Lead Ads

Super admin only. Every other role is `403 forbidden_role`. Another firm's
page, form or import id is `404 not_found`. Responses never include
`access_token`, `page_access_token`, or an OAuth attempt's result.

These routes sit **outside** `/api/v1` and have no broker JWT:

| Method | Path | |
| --- | --- | --- |
| GET | `/facebook/webhook` | `hub.mode=subscribe` and the verify token → plain-text `hub.challenge`. Otherwise 403 |
| POST | `/facebook/webhook` | `X-Hub-Signature-256` must be `sha256=` plus HMAC-SHA256 of the raw body. 401 if it does not match, 413 if the body is over 1 MB, 400 if it is not JSON. 200 when every lead was stored or dropped on purpose. 500 only when a database write failed, so Meta retries |
| GET | `/facebook/callback` | Facebook's redirect. A normal attempt sends the browser to `web_origin/settings/facebook`. A handoff attempt sends it to `web_origin/facebook/done?result=connected`, `denied`, `failed`, or `expired`. The connection is not stored here |
| GET | `/facebook/start?ticket=` | No broker session. A started, unexpired handoff whose ticket is unused and unexpired is marked used and redirected to the same Facebook authorization URL `POST /facebook/connect` builds. Anything else redirects to `web_origin/facebook/done?result=expired`. A ticket works once |

The broker app uses:

| Method | Path | |
| --- | --- | --- |
| GET | `/facebook/integration` | `configured`, `system_user_login`, the newest connection that is `active` or `invalid`, its pages with form listings, import counters. A disconnected firm has `connection: null` |
| POST | `/facebook/connect` | `{ nonce }` at least 32 characters. Optional `handoff: true`. Returns `authorization_url` and `attempt_id`. A handoff also returns `handoff_url`, `{web_origin}/facebook/start?ticket=…`. The ticket is 32 random bytes, base64url. Only its SHA-256 is stored. It expires in 10 minutes and works once |
| GET | `/facebook/connect/:attempt_id` | `{ status, error_code, expires_at }` for the user and firm that started it. Anyone else is `404 not_found`. The installed app polls this when the broker comes back. It does not store the connection |
| POST | `/facebook/connections` | `{ attempt_id, nonce }`. Stores the connection. `warnings[]` has `kind`, `page_id` and `page_name`. `page_taken` means that Page is held by another firm and was skipped. `subscription_refresh` means the lead subscription could not be refreshed. `page_taken` is a 422 only when every granted Page is held |
| DELETE | `/facebook/connection` | Stops delivery for the newest `active` or `invalid` connection. Pages, forms and past imports stay. Tokens are cleared, so the Pages are no longer held |
| POST | `/facebook/connection/health_check` | `{ ok, connection }` for that same connection |
| POST | `/facebook/pages/:id/subscribe` | Subscribes the Page to lead ads |
| DELETE | `/facebook/pages/:id/subscribe` | Unsubscribes it at Meta, then here |
| POST | `/facebook/pages/:id/sync_forms` | Counts: `mapped`, `available` |
| POST | `/facebook/pages/:id/forms` | `{ meta_form_id }`. 422 `already_mapped` if another firm owns it |
| GET | `/facebook/forms/:id` | Questions, mappings, listing, sample lead. `ui_field_mappings` is what the editor shows, including suggestions. `category` is the stored category or null. `project_categories` is the mapped project's categories in Residential, Commercial, Plot & Land order, or `[]` |
| PATCH | `/facebook/forms/:id` | Optional `category` (`residential`, `commercial`, `land`). A blank value clears it. Remapping to a project that does not offer the stored category clears it. 422 `invalid_form` with an active form and no listing, an unusable listing, mappings that skip Name or Mobile, a newly chosen lead source that is turned off, or a mixed project saved with no category (`Category is required when the project has more than one category`). A category the project does not offer is `Category must be one of this project's categories` when it was not cleared by the remap. Sync and import do not run this category check |
| GET | `/facebook/imports?page=` | 20 per page, newest first |
| POST | `/facebook/imports/:id/retry` | Failed or dead only. Resets the retry count and queues the lead |
| POST | `/facebook/imports/retry_failed` | The same for every failed or dead import. `{ retried }` |

A lead's mobile is any number the lead form already accepts: `+` and 10 to 15
digits. A missing or malformed mobile is a dead import. A 10-digit number with
no country code is stored as India (`+91`).

Connect error codes, all 422 unless noted: `invalid_request`, `not_configured`,
`expired`, `not_yours`, `wrong_browser`, `already_used`, `denied`,
`exchange_failed`, `short_lived_token`, `no_pages`, `missing_subscribed_pages`
(`details.pages` is the page names), `page_taken` (`details.pages` is the page
names; returned only when every granted Page is held, and the current
connection is left as it was), `already_connected`, `already_mapped`,
`invalid_form`, `facebook_error`, `not_retryable`.

---

## Error codes

Switch on `code`. The `message` is for humans and may be reworded.

### Auth and account

| Code | Status | |
| --- | --- | --- |
| `not_registered` | 404 | No such mobile. The message links to `/self-signup` |
| `account_unapproved` | 403 | The firm is still pending. No code is sent, and an existing session is not force-logged-out by the web app |
| `invalid_code` | 401 | Wrong, expired or already-used code. `details.attempts_left` |
| `otp_locked` | 429 | Three wrong codes. Locked 30 minutes |
| `rate_limited` | 429 | Too many code requests for this mobile or from this IP |
| `delivery_failed` | 503 | The SMS provider refused |
| `unauthorized` | 401 | Missing, malformed or revoked token |
| `account_suspended` | 403 | Firm suspended. Sign out |
| `account_disabled` | 403 | This user |
| `subscription_lapsed` | **402** | Billing wall, not an auth wall |
| `forbidden_role` | 403 | The role may not do this |
| `demo_account_restricted` | 403 | Not available in the demo account. The Meta review firm cannot send contact-channel codes, add users, change a mobile, or create a LaunchIQ visit pass |

### Requests

| Code | Status | |
| --- | --- | --- |
| `invalid` | 422 | Validation failed. `details` maps field → messages |
| `invalid_request` | 400 | A required parameter is missing |
| `not_found` | 404 | Also returned for another firm's — or another agent's — record |
| `unknown_user` | 404 | That user isn't in this firm, or isn't in the caller's assignable set |
| `user_limit_reached` | 422 | All {n} seats on this plan are in use, including disabled members. Disabled accounts still occupy a seat |
| `reporting_cycle` | 422 | That manager/report pair would loop the reporting graph |
| `query_too_short` | 422 | Search needs 3+ letters or numbers. `details.min_length`, and `details.length` counted the same way |
| `duplicate_lead` | 422 | That mobile already has an open lead of this transaction type and category. Also when reviving a dead lead, changing status through a follow-up, changing a lead onto a taken category, or marking a prospect interested. The message names the type and the category, for example "A sale Commercial lead already exists for this number." `details.lead_id` (omitted on a prospect follow-up when the caller cannot open the lead), `details.transaction_type`, `details.category`, and on a prospect follow-up `details.lead_code` and `details.lead_accessible` |
| `notes_required` | 422 | A prospect follow-up needs a note |
| `connected_required` | 422 | A prospect follow-up must say whether the call connected. A missing `connected` is not false |
| `ncd_required` | 422 | A missed prospect call that stays on the list needs a next dial time |
| `next_call_in_past` | 422 | A next call more than 2 minutes ago, on a lead follow-up or a prospect call-back. "The next call must be in the future." |
| `prospect_closed` | 422 | Interested and not interested prospects take no further follow-up |
| `prospect_locked` | 422 | An interested prospect can change its comment only |
| `not_movable` | 422 | Only interested or not interested can move back to Following |
| `lead_worked` | 422 | Move back left the lead in place because it already has a follow-up, visit, visit pass, booking, inbound enquiry, marketplace enquiry, or Facebook import |
| `comment_required` | 422 | A followup (nested on create, or `POST /leads/:id/followups`) needs “what was discussed” |
| `unknown_status` | 422 | `status` is not a seeded lead-status code |
| `application_date_required` | 422 | Marking a lead booked via a followup needs `booked_on` |
| `catalog_readonly` | 422 | Catalog projects cannot be edited |

### Money

| Code | Status | |
| --- | --- | --- |
| `lead_required` | 422 | A booking needs a lead |
| `over_invoiced` | 422 | Past the booking's net income |
| `over_collected` | 422 | Past what is invoiced |
| `over_collected_for_invoice` | 422 | Past that one invoice |
| `reason_required` | 422 | Cancelling a booking, or moving a lead to a dead status, needs a reason |
| `already_cancelled` | 422 | |
| `unit_taken` | 422 | A live booking already has this `project_id` + `unit_no`. `details.project_id`, `details.unit_no` |
| `project_and_listing` | 422 | A booking has `project_id` or `property_id`, not both |
| `listing_not_found` | 422 | `property_id` is not this firm's listing and not a Marketplace listing this firm can see |
| `listing_already_booked` | 422 | This firm already has a live booking on that listing. `details.booking_id`, `details.code`. Another firm may still book it |
| `project_name_clash` | 422 | Booking a catalog project whose name already exists in My Projects. `details.existing_project_id`, `details.name`. Retry with `use_existing` or `new_name` |
| `form6_unavailable` | 403 | Form 6 write, preview and download, when the firm's city is not in Maharashtra |

### Files

| Code | Status | |
| --- | --- | --- |
| `file_too_large` / `unsupported_type` | 422 | At `POST /uploads` |
| `invalid_upload` | 422 | The `signed_id` doesn't verify, belongs to another firm, or was issued for a different purpose |
| `upload_incomplete` | 422 | Ticket issued, file never arrived. Photos, brochure, documents, collection proof |
| `too_many_photos` | 422 | 20 per listing |
| `slot_taken` | 422 | A named document slot already has a file |

### Trainings

| Code | Status | |
| --- | --- | --- |
| `note_too_long` | 422 | A training note is capped at 20,000 characters |

### Notifications

| Code | Status | |
| --- | --- | --- |
| `no_subscription` | 422 | This test had no browser registered for the targeted session or user |
| `push_not_configured` | 503 | VAPID keys are missing from credentials |
| `push_rejected` | 422 | The push service refused, or the subscription was already gone |
| `push_key_mismatch` | 422 | The VAPID key does not match the key the browser subscribed with. The subscription is kept |

### Facebook Lead Ads

| Code | Status | |
| --- | --- | --- |
| `not_configured` | 422 | The server has no Facebook app credentials |
| `expired` | 422 | The Facebook login expired, or the return link was bad |
| `not_yours` / `wrong_browser` | 422 | Started in another browser or by another user. The attempt is voided |
| `already_used` | 422 | That login was already turned into a connection |
| `denied` | 422 | The person cancelled or Facebook refused |
| `exchange_failed` | 422 | The code could not be exchanged |
| `short_lived_token` | 422 | The Meta configuration returned a token that expires in under a day |
| `no_pages` | 422 | Facebook shared no Pages. The current connection is left as it was |
| `missing_subscribed_pages` | 422 | A subscribed Page was not in the new grant. `details.pages` |
| `page_taken` | 422 | Every Page in the login is already held by another firm. `details.pages`. A login that also includes a free Page connects that Page and lists the rest under `warnings` with `kind: page_taken` |
| `already_connected` | 422 | Another connect finished first |
| `already_mapped` | 422 | That form belongs to another firm |
| `invalid_form` | 422 | An active form with no listing, an unusable listing, mappings without Name and Mobile, or a newly chosen lead source that is turned off |
| `facebook_error` | 422 | Meta refused a subscribe, unsubscribe or form sync |
| `not_retryable` | 422 | That import is not failed or dead |

---

## Traps worth knowing

**1. A wrong-shaped or misnamed parameter is silently dropped.**

Rails discards an array value for a scalar-typed parameter, and ignores unknown
keys entirely. Neither produces an error.

```jsonc
{ "property_type_id": ["01a0…"] }   // → 422 "Property type is required for a sale lead"
{ "property_type_id":  "01a0…"  }   // → 201

{ "possession_up_to": "2026-09-02" } // → 201, and possession_by is null
{ "possession_by":    "2026-09-02" } // → 201, and it is set
```

Both mistakes are easy from a typed client that isn't matched to this list.
`property_type_id` is a **string**; `typology_ids` and `photo_signed_ids` are
**arrays**.

**This leniency is deliberate and is not going to change.** Rejecting unknown
keys would break any client that sends a stray field, which is what an app
mid-rollout does. So the server will not tell you — check your field names
against the tables above, and against the Postman collection, which sends the
complete accepted set for every endpoint.

A cheap client-side guard, if you want one: assert in dev that the object you
POSTed round-trips in the response. A field that vanishes was dropped.

**2. `404` is used where you might expect `403`.** Another firm's record and
another agent's lead both return `404`, deliberately — a 403 confirms the record
exists. Do not treat 404 as "deleted".

**3. `subscription_lapsed` is `402`, not `401`.** Refreshing the token will not
help. It needs a billing wall.

**4. Don't recompute money.** `net_income`, `invoiced`, `collected`,
`outstanding`, `rate_per_sqft`, `avg_psf`, `price_band` and `area_band` all
arrive computed.

**5. Booking and lead status are independent.** Creating a booking does not set
the lead to `Booked`, and cancelling does not reopen it. If your flow wants that,
make the `POST /leads/:id/status` call yourself.

**6. `photos[].id` ≠ the id in the photo URL.** The URL carries the blob id;
deletion takes the attachment id from `photos[].id`.

**7. Drawer filters drop `q`.** If any drawer param is present, `GET /leads`,
`GET /projects` and `GET /properties` ignore `q`. Heading pills (`status`) and
lead cards (`status`, `visited`) do not. `side` (`sale` or `rent`) on leads and
on the firm's own properties does not either: it is for pickers that need one
side and still want the search. Any other `side` is ignored. Sending
`q=Aurum&city_id=…` searches only by city.

**8. `budget` on write is not `budget_min` / `budget_max` on GET.** Create and
PATCH store a single amount in `budget`. On GET those two names are the filter
window. Sending `budget_min` on POST is ignored. Property statuses are
`available` · `booked` · `sold_out` — `under_offer` / `closed` 422.

**9. NCD is not a PATCH field.** `next_action_at` and `next_action_note` on
`POST /leads` or `PATCH /leads/:id` are dropped. Send `followup: { comment,
next_action_at }` on create, or `POST /leads/:id/followups`. `notes` is Detailed
Client Requirements, not a follow-up comment.

---

## Running the collection

A Postman collection covering all 52 routes and every accepted parameter lives at
[`docs/postman/RealtorIQ.postman_collection.json`](postman/RealtorIQ.postman_collection.json),
with a staging environment in [`docs/postman/staging/`](postman/staging/). It chains
its own tokens — you never paste one.

```bash
npx newman run docs/postman/RealtorIQ.postman_collection.json \
  -e docs/postman/staging/RealtorIQ.staging.postman_environment.json
```
