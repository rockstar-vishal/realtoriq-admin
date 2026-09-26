# RealtorIQ — Broker API v1

Reference for the React broker app. Every fact here was read out of the code or
observed against a live server; nothing is aspirational.

**Base URL** — `https://staging.realtoriq.kgen.tech/api/v1`

- [Conventions](#conventions)
- [Authentication](#authentication)
- [Session and reference data](#session-and-reference-data)
- [Users](#users)
- [Dashboard](#dashboard)
- [Leads](#leads)
- [Inventory — projects, buildings, properties](#inventory)
- [Bookings and money](#bookings-and-money)
- [File uploads](#file-uploads)
- [Firm contact channels](#firm-contact-channels)
- [Notifications](#notifications)
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

`per_page` is clamped to 1–50. Absent or `0` means **25**.

**Errors** always have this shape, and you switch on `code`, never on the prose:

```json
{ "error": { "code": "over_invoiced", "message": "…", "details": { "available": 286000 } } }
```

`details` is present when there is something actionable in it — the remaining
balance, the attempts left, the failing fields.

---

## Authentication

**There are no passwords.** Possession of the mobile number is the credential,
and there is no self-signup: ops create the firm and its first user.

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

The number comes back masked. An unregistered mobile is `404 not_registered` —
said plainly, because with no self-signup a stranger learns nothing they can act
on.

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

`manage_users` on `GET /me` is the flag to drive the team screen — do not switch on `role` for that. `manage_projects` is the flag for My Projects create/edit/photos and for inline builder create.

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
                    "manage_users": true, "manage_projects": true },
  "limits":       { "devices": 3, "users": 5 }
}
```

**Drive the UI from `permissions`, not from `role`.** It is computed server-side
and will not drift when the rules change.

### `GET /reference`

Every dropdown in one call — cache it and refresh on app start.

```
cities[]         id, name, state, state_code
localities[]     id, city_id, name, pincode      ← flat, filter by city_id yourself
builders[]       id, name, global
typologies[]     id, name, code, bedrooms
lead_sources[]   id, name, code, category
lead_statuses[]  id, name, code, is_dead, is_booked, is_terminal
property_types[] id, name, code
transaction_types[]  code, name                  ← fixed: sale, rent
floor_bands[]        code, name                  ← fixed: lower, middle, higher
```

`localities` is a **flat list carrying `city_id`**, not nested under cities.

Seeded values today: statuses `new`, `hot`, `followup`, `visit_planned`,
`negotiation`, `booked`, `dead` · sources `portal_housing`, `portal_99acres`,
`referral`, `walk-in`, `social_meta`, `cold_call` · property types
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

`422 user_limit_reached` when the plan's `max_users` is hit. **Disabled users
count toward the cap.** `max_users: null` is unlimited.

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

> **There is no featured / live projects block, and there will not be one here yet.**
> Featured projects will come from the LaunchIQ integration. Until then, render that
> section from placeholder data on the client. `inventory.projects` is a count, not a list.

The whole home screen in one request — pipeline counters, money tiles, the
inventory strip, and the top three of each list.

It exists because every counter is derivable from a filter the API already
exposes, so the alternative was six round trips for one card.

```json
{
  "leads": {
    "total": 29, "new": 4, "hot": 14, "hot_negotiation": 19,
    "todays_followups": 3, "missed_followups": 4,
    "visit_planned": 2, "visited": 8, "bookings": 2,
    "recent": [ /* at most 3 missed followups, most overdue first; same item shape as GET /leads */ ]
  },
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

Everything else is scoped the same way the list endpoints are: an agent's
counters cover only leads assigned to them.

**Definitions worth pinning down**, because they are easy to assume wrong:

| Field | Means |
| --- | --- |
| `revenue_till_date` | Σ `agreement_value` over **live** bookings — gross value sold |
| `brokerage_earned` | Σ `net_income` — what the firm keeps. A different number |
| `new` | Status code `new` |
| `visit_planned` | Status code `visit_planned` — not `visited` |
| `hot_negotiation` | Status `hot` **or** `negotiation`. `hot` is still hot-only |
| `visited` | Leads with at least one `lead_visits` row — ever, not this month |
| `todays_followups` | `next_action_at` falls today. Home tile label: **Today's Calls** |
| `missed_followups` | `next_action_at <= now` on a non-terminal lead |
| `cancelled` | Counted **separately** and excluded from every figure above |

The home **Your pipeline** snapshot uses six of these: `total`, `new`,
`todays_followups`, `missed_followups`, `visit_planned`, `hot_negotiation`.
`hot`, `visited` and `bookings` remain on the payload. This set is **not**
`GET /leads` `counts` (that one has Visited + Booked and has no Total / today's).
There is no `status=todays_followup`; the Today's Calls tile lists via
`ncd_from` / `ncd_upto` for today (IST).

**`leads.recent` is the missed-followup strip under the grid** — at most three,
most overdue first (`next_action_at ASC`), same item shape as `GET /leads`.
It is **not** the worklist and not the leads-index NCD default. Empty if
nothing is overdue. "View all" is `GET /leads?missed_followup=true`.

**`todays_followups` and `missed_followups` overlap.** A followup due at 10am is
still "today's" at 5pm *and* already overdue. That is deliberate: the tiles
deep-link to `GET /leads`, and `missed_followup=true` there uses the same
rule — a tile that disagreed with the list it opens would be the real bug.

**`this_fy` is the Indian financial year, 1 April to 31 March.** A 31 March
booking and a 1 April one fall in different years. `label` is `"2026-27"`.

## Leads

### `POST /leads`

| Field | Type | | Notes |
| --- | --- | --- | --- |
| `mobile` | string | **required** | Normalised to E.164 |
| `transaction_type` | enum | **required** | `sale` · `rent` |
| `property_type_id` | **string** | conditional | **Required for `sale`, forbidden for `rent`** |
| `name` | string | optional | Nullable by design — brokers capture a number first |
| `alt_mobile` | string | optional | |
| `email` | string | optional | |
| `budget` | integer | optional | Whole rupees. Stored as `budget_max`; `budget_min` is cleared. **Do not send `budget_min` / `budget_max` on write** — they are ignored |
| `possession_by` | date | optional | **Not** `possession_up_to` |
| `lead_source_id` | string | optional | |
| `source_detail` | string | optional | e.g. `"99acres enquiry #48213"` |
| `assigned_user_id` | string | optional | Super admin: any active user in the firm. Anyone else: an id from their active manageables. Defaults to the creator when an agent creates it |
| `followup` | object | optional | Opening followup. `{ comment, next_action_at }`. `comment` is required if you send a datetime (otherwise `422 comment_required` and the lead is not created). Top-level `next_action_at` / `next_action_note` are **ignored** — NCD only moves via this nested object or `POST /leads/:id/followups` |
| `notes` | text | optional | **Detailed Client Requirements** (the column is still `notes`). Not a follow-up comment. No separate locality column — put location text here |
| `typology_ids` | **array** of string | optional | |
| `project_id` | string | optional | Create-from-project. Copies blank budget into `budget_max` (not min), plus possession / notes, and inserts a `LeadProject`. Own or catalog. **Create only** — ignored on PATCH |

> **`property_type_id` is a single string. `typology_ids` is an array.**
> One property type, many configurations. Sending `property_type_id` as an array
> gets it silently discarded and you get `422 Property type is required for a
> sale lead` with nothing pointing at the real cause. See
> [Traps](#traps-worth-knowing).

One lead per `(firm, mobile, transaction_type)`. Same number may exist once as `sale` and once as `rent`. A second create of the same type is **`422 duplicate_lead`** with `details.lead_id` and `details.transaction_type` so you can open the existing card. PATCH `transaction_type` to the other type is the same `422` if that type already exists on the number.

Returns `201` with the lead plus `possible_duplicates` — the **other** transaction type on the same number, if any, and only leads the caller can see. Same type is never in this array; it was refused.

`code` is assigned server-side and sequential per firm (`L-0002`). Brokers read
these to each other.

### `GET /leads`

Screen guide for the broker app: [`frontend/YASH.md`](../../frontend/YASH.md).

| Filter | Notes |
| --- | --- |
| `q` | Name, mobile or email. **Ignored when any drawer param below is present** — drawer replaces search, it does not AND. Card/pill params (`status`, `visited`, `missed_followup`) do **not** drop `q` |
| `status` | A status `code`, **or `hot_negotiation`**. Repeat as `status[]=hot&status[]=negotiation`. Not `missed_followup` — that is its own boolean |
| `visited` | `true` / `false` — at least one `lead_visits` row, or none |
| `missed_followup` | `true` / `false` — `next_action_at <= now` on a non-terminal lead. ANDs with `status` |
| `name`, `mobile`, `email` | Drawer. ILIKE; `mobile` matches on digits so `98201 44210` hits stored `+919820144210` |
| `ncd_from`, `ncd_upto` | Drawer. Inclusive **IST** calendar days |
| `transaction_type` | Drawer. `sale` · `rent` |
| `property_type_id`, `source_id`, `assigned_user_id` | Drawer |
| `budget_min`, `budget_max` | Drawer. Filter **window on the stored amount** (`budget` / `budget_max`, leftover `budget_min` if max is null). Not range overlap. These names on GET are the window, not write fields |
| `possession_from`, `possession_to` | Drawer |
| `typology_ids[]` | Drawer. Repeat the key |
| `sort` | **`ncd`** (default) · `worklist` · `recent` · `updated` |
| `page`, `per_page` | |

Drawer params: `name`, `mobile`, `email`, `ncd_from`, `ncd_upto`, `budget_min`, `budget_max`, `typology_ids`, `transaction_type`, `property_type_id`, `possession_from`, `possession_to`, `source_id`, `assigned_user_id`.

**`missed_followup` is not a real status.** Send it as `missed_followup=true`
(same shape as `visited`). It means `next_action_at <= now` on a non-terminal
lead. It appears in the design's tab strip beside the real statuses, but it
will never come back in `lead_statuses`. `status=missed_followup` looks up a
code that does not exist and returns an empty list. `hot_negotiation` is
the Hot + Negotiation codes together.

**Budget on GET is a point-in-window filter**, not overlap. A ₹1–1.3 Cr window
matches a lead whose stored amount is ₹1.2 Cr, and does **not** match a leftover
row whose max is ₹90L even if its old min was ₹80L.

Default sort is `next_action_at ASC NULLS FIRST, created_at DESC` — leads with
no next action sit **above** overdue. `sort=worklist` is the old overdue-first
order. **`GET /dashboard` `leads.recent` is missed followups only** (at most
three, most overdue first), so the home strip and this list disagree by design.

The response includes **`counts`** every time, visibility-scoped and **not**
narrowed by the current filter:

```json
"counts": {
  "new": 4, "missed_followup": 2, "visit_planned": 1,
  "visited": 3, "hot_negotiation": 5, "booked": 1
}
```

Cards overlap (New + overdue NCD is both New and Missed), so counts will not sum
to `meta.total_count`. Hide the cards in the UI when `q` or a drawer param is on.

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
  "assigned_user": { "id": "…", "name": "Rohit Shah" },
  "source": { "id": "…", "name": "99acres" },
  "next_action_at": "2026-08-17T00:35:56.587+05:30",
  "last_followup_comment": "Asked for the floor plan",
  "overdue": true, "visited": true, "visit_count": 1,
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
| Budget | `budget` (integer rupees) |
| Source | `source.name` — `null` when unset. `source_detail` is detail-only |
| Last Followup Comments | **`last_followup_comment`** — `comment` of the latest `lead_followups` row. `null` if none. Truncate + "show more" on the client. **Not** an activity body, and there is no `next_action_note` |
| Next Action Date | `next_action_at` — copy of the last followup that sent a datetime. Cleared when the lead becomes dead or booked |
| Created At | `created_at` |

The **detail** adds `alt_mobile`, `source_detail`,
`dead_reason`, `dead_at`, `booked_at`, `notes`, `mapped_projects[]`,
`mapped_properties[]`, `activities[]` (latest 20) and `status_history[]`.
There is no `first_visit_at`.

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

### Other lead endpoints

| | |
| --- | --- |
| `GET /leads/:id` | Detail, with timeline, mappings and status history |
| `PATCH /leads/:id` | Same fields as create except `project_id` and nested `followup` (create-only). **Sending `typology_ids` replaces the whole set**; omitting the key leaves it alone. Sending `assigned_user_id` reassigns — see below. PATCH `transaction_type` is `422 duplicate_lead` if that type already exists on the mobile. **`next_action_at` / `next_action_note` are ignored** — NCD only moves by posting a followup. Optional `emi` — see below. Omitting `emi` leaves a saved calculation alone |
| `POST /leads/:id/status` | `{ status, reason, note }` — `status` is a status **code**. `reason` is **required** moving to a dead status. Moving to dead or booked **clears `next_action_at`**. The Add Followup wizard should **not** also call this — send `status` on the followup instead |
| `GET /leads/:id/followups` | Newest first. `{ followups: [{ id, comment, next_action_at, user, created_at }], meta }`. Default 25 |
| `POST /leads/:id/followups` | `{ comment, next_action_at, status, reason, booked_on }` — see below. `201` `{ followup, lead }` (`lead` is the **list** card shape) |
| `GET /leads/:id/activities` | |
| `GET /leads/:id/visits` | Newest `visited_at` first. `{ visits, meta }`. Default 25 |
| `POST /leads/:id/visits` | `{ visited_on, notes, project_ids, property_ids }` — see below. `201` `{ visit }` only. Refetch the lead for `visited` and mapped flags |
| `PATCH /leads/:id/visits/:id` | `{ visited_on, notes, project_ids, property_ids }`. Omit a key to leave it; `""` clears notes; `[]` clears that site list. New site ids must be mapped (`422 not_mapped`). Ids already on this visit may stay after the lead unmaps them. Does not change `user_id`. No delete |
| `POST /leads/:id/activities` | `{ kind, body, occurred_at, outcome }` — `call` / `whatsapp` / `note`. `kind=visit` is rejected |
| `POST /leads/:id/projects` | `{ project_id }` — map a My Projects or catalog row. Anyone who can see the lead. `201` returns the refreshed lead |
| `DELETE /leads/:lead_id/projects/:id` | `:id` is the **join** id from `mapped_projects[]` |
| `POST /leads/:id/properties` | `{ property_id }` — same rules as projects |
| `DELETE /leads/:lead_id/properties/:id` | Join id from `mapped_properties[]` |
| `POST /leads/:id/matches` | Show New Matches. **Stub:** `{ "matches": [] }` until LaunchIQ. Do not fake this from `GET /projects` |

**`POST /leads/:id/followups`** is the only write path for a follow-up comment
and for moving NCD. One transaction: insert the row, copy `next_action_at` onto
the lead if a datetime was parsed, then optionally `Leads::TransitionStatus`.

| Field | |
| --- | --- |
| `comment` | **required.** Blank is `422 comment_required` |
| `next_action_at` | optional timestamp. Omit or blank to **leave** the lead's current NCD. There is no way to clear NCD except by moving to a terminal status |
| `status` | optional status **code**. Same as `POST /leads/:id/status`. Do **not** call that endpoint as well |
| `reason` | required when `status` is a dead status (`422 reason_required`); the followup is rolled back |
| `booked_on` | required when `status` is a booked status (`422 application_date_required`). IST start of day, stored on `leads.booked_at`. **Does not create a booking row** |

A failed status change rolls back the followup. Dead and booked clear
`leads.next_action_at`. Unknown `status` is `422 unknown_status`.

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
`property_ids` are optional; every id must already be mapped or the response
is `422 not_mapped`. A siteless visit still increments `visit_count`.

**`PATCH /leads/:id/visits/:id`** may change date, notes, and sites. Omit a
site key to leave that set; send `[]` to clear it (the visit may become
siteless). Ids **already on this visit** may stay even if the lead later
unmapped them. **New** ids must be on the lead’s current mappings or the
response is `422 not_mapped`. Unmapping a lead does not rewrite visit joins;
edit is how a broker drops a site from that outing. `user_id` does not change.

`GET /projects/:id/visitors` and `GET /properties/:id/visitors` return
`visit_count` (outings that included that site) and `visitors` (distinct leads
the caller can see: `display_name`, `visit_count`, `last_visited_on`). An agent
does not see another agent's clients in the count.

There is **no delete**. `dead` is the terminal state and it carries a reason, so
the dead-leads report can explain itself.

---

## Inventory

`builders`, `projects`, `buildings`, `properties`. **No delete anywhere** —
archiving is a status change.

A **project** is a builder's development, sold from a brochure. A **property** is
one resale or rental listing inside a **building**. Amenities live on the
building, because every flat in it shares the same pool.

**My Projects vs catalog.** `GET /projects` and `GET /projects/search` return
only `source: own` (My Projects). Catalog rows (`source: catalog`) are LaunchIQ
copies stored per firm; they are not a Marketplace tab. You see them on a lead
via mappings / `GET /projects/:id` / the matches stub. Brokers cannot edit them
(`422 catalog_readonly`).

**Writes to My Projects and `POST /builders` are superadmin only**
(`403 forbidden_role`, gated in the app by `permissions.manage_projects`).
Anyone in the firm may create a **property**.

Own-list names are unique case-insensitively per firm. Catalog names are unique
the same way, in their own list. The same name may exist once in each.

### `POST /projects`

| Field | Type | | Notes |
| --- | --- | --- | --- |
| `name` | string | **required** | ≤ 160 chars. Unique case-insensitively among this firm's **own** projects |
| `builder_id` | string | **required** | Global, or one this firm added |
| `city_id` | string | **required** | |
| `locality_id` | string | optional | Must belong to `city_id` |
| `starting_budget` | integer | **required** | > 0 |
| `possession_on` **or** `possession_label` | date / string | **one required** | `"Dec 2027"` when the date is vague |
| `brokerage_percent` | number | optional | 0–100 |
| `rera_number`, `address`, `google_place_id` | string | optional | |
| `lat` / `lng` | number | optional | −90..90 / −180..180 |
| `promo_text`, `promo_ends_on` | string / date | optional | |
| `status` | enum | optional | `active` (default) · `archived` |
| `brochure_signed_id` | string | optional | See [uploads](#file-uploads) |
| `typologies` | array of object | optional | `{ typology_id, starting_price, starting_carpet_sqft }` |

**Derived, never sent and never stored**: `price_band`, `area_band` (min/max
across the typologies), per-config `rate_per_sqft`, and list/detail **`avg_psf`**
(unweighted mean of those rates; integer; half-up once; `null` if none). A stored
band can end up disagreeing with the rows it came from. `starting_budget` is not
recomputed from configurations.

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
| `budget_min`, `budget_max` | Drawer. Projects with **at least one configuration whose starting price** is in the window. Not overlap — unlike a lead's stored amount — and a project with no configurations never matches |
| `brokerage_min`, `brokerage_max` | Drawer. Rows with `NULL` brokerage drop out of a range |
| `possession_before` | date. Not a drawer field; still applies alongside `q` |
| `typology_ids[]` | Drawer. Repeat the key |
| `sort` | **`name`** (default, A–Z) · `recent` (newest first) |
| `page`, `per_page` | 25 per page by default |

**The list is My Projects only** (`source: own`). Catalog rows are omitted.
Marketplace is an empty client pill — do not list catalog here.

Drawer params: `name`, `builder_id`, `typology_ids`, `budget_min`, `budget_max`,
`city_id`, `locality_id`, `brokerage_min`, `brokerage_max`.

**The list is paginated and sorted A–Z by default, so a project you just created
may not be on page 1.** Either pass `sort=recent`, read `meta.total_pages`, or —
simplest after a create — show the project the `POST` returned rather than
re-fetching the list.

### `GET /projects/search`

Typeahead for a project search box. Call it once the user has typed **at least
three letters or numbers**, debounced (~250 ms).

| Param | |
| --- | --- |
| `q` | **Required: 3+ letters or numbers.** Fewer returns `422 query_too_short`. Punctuation alone (`___`, `!!!`) does not count. Up to 160 characters — the longest a project name can be |
| `status` | `active` (default) · `archived` · `all`. An unrecognised value is treated as `active` |

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

**At most 10 results.** Your firm's projects only. `active` unless `status`
says otherwise.

```json
{
  "projects": [
    {
      "id": "01a0…", "name": "Aurum Vista", "rera_number": "P51700054321",
      "source": "own",
      "builder": { "id": "01a0…", "name": "Lodha Group" },
      "locality": "Kolshet", "locality_id": "01a0…",
      "city": "Thane", "city_id": "01a0…"
    }
  ],
  "meta": { "query": "aurum", "limit": 10, "min_length": 3, "more": false, "fuzzy": false }
}
```

- **`meta.more`** is `true` when there are more than 10 — show "keep typing".
- **`meta.fuzzy`** is `true` when these are close spellings rather than matches.
- **`meta.query`** is what was actually searched, after trimming.

A result carries only what a row shows. Tap through to `GET /projects/:id` for the
full project.

`source` is `own` on this endpoint. Catalog projects are not searchable here —
they arrive through `POST /leads/:id/matches`.

List and detail also carry `city_id` and `locality_id` (the names stay as
`city` / `locality`). Use the ids when editing; rematching by name can attach
the wrong locality.

### `POST /buildings` and `POST /properties`

Buildings: `name` (**required**), `city_id`, `locality_id`, `address`, `lat`,
`lng`, `google_place_id`, `has_pool`, `has_gym`. Unique on
**(firm, name, locality)** — one broker's typo must not reach another firm's
dropdown.

Properties: `building_id`, `typology_id`, `listing_for` (`sale` · `rent`),
`price`, `carpet_area_sqft`, `floor_band` (`lower` · `middle` · `higher`),
`available_from`, `description`, `confidential_note`, `status`
(`available` · `booked` · `sold_out`). Any role may create. List and detail
include `created_by: { id, name }` (or `null` on older rows) — show it when
`permissions.manage_projects` is true.

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
**drawer** param is set; `status` does not drop `q`. Omitting `status` is
`available`, so a search does not return booked or sold-out listings unless
`status` asks for them), `listing_for`, `city_id`, `locality_id`, `typology_id`,
`building_id`, `price_min` / `price_max`, **`carpet_min` / `carpet_max`** (NULL
carpet drops out of a range), `floor_band`. Drawer params: `city_id`,
`locality_id`, `typology_id`, `price_min`, `price_max`, `carpet_min`,
`carpet_max`, `building_id`, `listing_for`.

> **`confidential_note` is returned only by `GET /properties/:id`.** It is absent
> from every list payload and absent from `shareable`. Never render it anywhere a
> client might be looking.

**On a rental, `price` is monthly rent** — so `rate_per_sqft` is rent per sqft
per month there and price per sqft on a sale.

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
"photos":     [ { "id": "59418d74-…", "url": "https://…/flat.jpg" } ],
"photo_urls": [ "https://…/flat.jpg" ],
"photo_count": 1,
"cover_photo_url": "https://…/flat.jpg"
```

**`photos[].id` is the attachment id that `DELETE` takes.** It is not the id
inside the blob URL — that is the *blob* id, a different record, and using it
gives you a 404. Max **20** photos per listing (`too_many_photos`). The first by
id is the cover; there is no reordering.

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
| `project_id` | string | optional | |
| `unit_no` | string | conditional | **Required when `project_id` is set.** Unique among **live** bookings on that project. Cancel frees the unit |
| `builder_ref_no` | string | optional | |
| `use_existing` | boolean | optional | Catalog booking name clash — reuse the existing My Projects row |
| `new_name` | string | optional | Catalog booking name clash — copy under this name instead |
| `carpet_area_sqft`, `other_details` | | optional | |
| `registration_done_on` | date | optional | |
| `client_paid_percent` | integer | optional | 0–100 |

**`customer_name` and `customer_mobile` are snapshots.** Omit them and they are
copied from the lead at booking time. They do not track the lead afterwards —
correcting a lead's name a year later must not rewrite what was booked.

There is no endpoint to find a lead by phone before booking; it is just
`GET /leads?q=<digits>`.

**Catalog bookings.** If `project_id` is a catalog row, the server copies
required fields into a My Projects (`source: own`) row and stores *that* id on
the booking. The catalog row stays for other mapped leads. A cancelled booking
**keeps** the copy.

If My Projects already has that name: **`422 project_name_clash`** with
`details.existing_project_id` and `details.name`. Retry the same body with
`use_existing: true` (point the booking at the existing own row) or `new_name`
(copy under the new name). Do not send both; `use_existing` wins.

### `GET /bookings`

| Filter | Notes |
| --- | --- |
| `q` | Substring of customer name, unit, builder ref, booking code, or **project name** |
| `status` | `live` (default, when omitted) · `cancelled` |
| `client_phone`, `project_id` | |
| `booked_from`, `booked_to` | |
| `page`, `per_page` | 25 per page by default |

`totals` is agreement value and net income over **live** rows in the filtered set, so `status=cancelled` returns zero totals. Status is `live` or `cancelled` — never `Cancelled` / `Completed`.

### Payload

```json
{
  "code": "B-0001", "status": "live",
  "agreement_value": 15600000, "net_income": 686000,
  "invoiced": 686000, "collected": 400000, "outstanding": 286000,
  "revenue": {
    "agreement_value": 15600000, "commission_percent": 4.5,
    "commission_amount": 702000, "kicker": 50000, "passback": 66000,
    "net_income": 686000, "invoiceable_balance": 0
  }
}
```

The three list-card figures are top level; the itemised breakdown is under
`revenue`. The detail also carries `documents[]`, `invoices[]`, `collections[]`.

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
- **The lead is untouched.** Cancelling does not reopen it, and booking does not
  set it to `Booked` — that is a separate `POST /leads/:id/status` call.
- Cancelling twice is `422 already_cancelled`. Updating a cancelled booking is
  refused.

### Documents

`POST /bookings/:id/documents` — `{ slot, label, signed_id }`. Slots are
`application_form`, `tagging_confirmation`, `lead_source_proof`, `other`. **Only
`other` may hold more than one file**; a second file in a named slot is
`422 slot_taken`, not a silent overwrite. `DELETE /bookings/:id/documents/:id`
purges the blob too.

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
  "title": "Follow up — Rhea Kapoor",
  "body": "Due 26 Sep, 4:30 PM",
  "read_at": null,
  "data": { "page": "leads", "item": "…" },
  "created_at": "2026-09-26T16:30:00.000+05:30"
}
```

`kind` is `followup_due` or `test`.

`data.page` is the screen (`leads`, `projects`, `properties`, `bookings`,
`settings`, `team`, `reports`, `subscription`, or `home`). With `data.item` the
row opens that record's show page (`/leads/<item>`). With `data.params` and no
`item`, it opens the list plus that query (`filter=missed_followup`). No
`page`, or a page the app does not have, means the row is not clickable. An
`item` and `params` together: the show page wins and the filter is ignored.

---

## Error codes

Switch on `code`. The `message` is for humans and may be reworded.

### Auth and account

| Code | Status | |
| --- | --- | --- |
| `not_registered` | 404 | No such mobile. There is no self-signup |
| `invalid_code` | 401 | Wrong, expired or already-used code. `details.attempts_left` |
| `otp_locked` | 429 | Three wrong codes. Locked 30 minutes |
| `rate_limited` | 429 | Too many code requests from this IP |
| `delivery_failed` | 503 | The SMS provider refused |
| `unauthorized` | 401 | Missing, malformed or revoked token |
| `account_suspended` | 403 | Firm suspended. Sign out |
| `account_disabled` | 403 | This user |
| `subscription_lapsed` | **402** | Billing wall, not an auth wall |
| `forbidden_role` | 403 | The role may not do this |

### Requests

| Code | Status | |
| --- | --- | --- |
| `invalid` | 422 | Validation failed. `details` maps field → messages |
| `invalid_request` | 400 | A required parameter is missing |
| `not_found` | 404 | Also returned for another firm's — or another agent's — record |
| `unknown_user` | 404 | That user isn't in this firm, or isn't in the caller's assignable set |
| `user_limit_reached` | 422 | The plan's `max_users` is full. Disabled accounts still occupy a seat |
| `reporting_cycle` | 422 | That manager/report pair would loop the reporting graph |
| `query_too_short` | 422 | Search needs 3+ letters or numbers. `details.min_length`, and `details.length` counted the same way |
| `duplicate_lead` | 422 | That mobile already has this transaction type. `details.lead_id`, `details.transaction_type` |
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
| `project_name_clash` | 422 | Booking a catalog project whose name already exists in My Projects. `details.existing_project_id`, `details.name`. Retry with `use_existing` or `new_name` |

### Files

| Code | Status | |
| --- | --- | --- |
| `file_too_large` / `unsupported_type` | 422 | At `POST /uploads` |
| `invalid_upload` | 422 | The `signed_id` doesn't verify, belongs to another firm, or was issued for a different purpose |
| `upload_incomplete` | 422 | Ticket issued, file never arrived. Photos, brochure, documents, collection proof |
| `too_many_photos` | 422 | 20 per listing |
| `slot_taken` | 422 | A named document slot already has a file |

### Notifications

| Code | Status | |
| --- | --- | --- |
| `no_subscription` | 422 | This test had no browser registered for the targeted session or user |
| `push_not_configured` | 503 | VAPID keys are missing from credentials |
| `push_rejected` | 422 | The push service refused, or the subscription was already gone |
| `push_key_mismatch` | 422 | The VAPID key does not match the key the browser subscribed with. The subscription is kept |

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
lead cards (`status`, `visited`) do not. Sending `q=Aurum&city_id=…` searches
only by city.

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
