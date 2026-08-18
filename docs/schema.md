# RealtorIQ — data model

The product ships as **RealtorIQ**. The design source carries an earlier
"BHOOMI" wordmark; that name is not used anywhere in this codebase.

Two phases. **Phase 1 is built and migrated.** Phase 2 is the agreed target for
the broker CRM, documented here so the React team can build against the shape we
settled on, and so each feature lands against a plan rather than being invented
at the keyboard.

---

## Conventions that apply everywhere

**Primary keys** — UUIDv7 on every table, generated in Ruby (`lib/uuid_v7.rb`).
Time-ordered, so ids sort by creation and index inserts stay at the right-hand
edge of the B-tree. Postgres 14 has no native `uuidv7()`; migrations still set
`gen_random_uuid()` as the column default so a row inserted outside Rails gets a
valid key.

**Tenancy** — every firm-owned table carries `firm_id uuid NOT NULL`, and its
model includes `FirmScoped`. The default scope is fail-closed: with no
`Current.firm` set it becomes `firm_id IS NULL`, which matches nothing. A
request that forgets to establish a tenant sees an empty result, never another
firm's rows. `spec/models/tenancy_isolation_spec.rb` fails the build if a model
with a `firm_id` is missing the concern.

> **Associations are not uniform about this, and getting it wrong produces
> silent empty results rather than errors.** Three cases, all pinned by spec:
> - `firm.users` — fine. The association's own key *is* `firm_id`, so Rails
>   replaces the default scope's condition with it.
> - `user.auth_sessions` — needs `-> { unscope(where: :firm_id) }`. The key is
>   `user_id`, so `firm_id IS NULL` survives from the default scope.
> - `one_time_code.user` — needs unscoping too. A `belongs_to` gets no
>   foreign-key substitution at all, so a scoped target resolves to `nil`.
>
> Anything read before a tenant is established (the whole sign-in path) must be
> unscoped, and say why in a comment.
>
> The working rule that fell out of this: **unscope associations reached through
> an already firm-scoped parent.** Getting to a lead at all means the tenant
> check has happened, so its owner, timeline and history are necessarily in the
> same firm — while leaving them scoped makes them silently resolve to nil or
> empty whenever `Current.firm` isn't set.

**Money** — `bigint`, **whole rupees**, plainly named (`agreement_value`, not
`agreement_value_paise`). Percentages are `decimal(5,2)`. Where a percentage
meets an amount, compute in `BigDecimal` and round half-up to the nearest rupee
**once**, at the point the result is stored; never chain off an already-rounded
intermediate. Parse input with `.to_d`, never `.to_f`.

The accepted cost: a brokerage figure can differ by up to ₹1 from a broker's own
hand calculation, and GST on invoices rounds the same way.

**Enums** — string columns with a Rails `enum` and a database `CHECK`
constraint. The constraint is what stops a bad value arriving from psql or a
console session.

---

## Phase 1 — built

### Tenancy and identity

| Table | Notes |
| --- | --- |
| `firms` | The tenant. `code` is the human-facing `CP-MH-04218`; `slug` addresses it in admin URLs. `status`: pending / active / suspended / churned. Logo via Active Storage. |
| `firm_bank_accounts` | Printed on invoices the broker raises. `account_number` is encrypted (deterministic, so duplicates are still detectable). Partial unique index enforces one primary per firm. |
| `users` | Broker users. **No password** — sign-in is a code to the mobile. `mobile` is globally unique, because the sign-in screen has no subdomain or firm code to scope the lookup by. `role`: super_admin / manager / agent, with a partial unique index enforcing one super_admin per firm. |
| `contact_channels` | The **firm's** email / mobile / WhatsApp, one of each. Users have no channels: the login code proves possession at sign-in, which is authentication, not channel verification. WhatsApp is its own row because a firm's WhatsApp Business number is often not its stated contact number. |
| `one_time_codes` | Login and channel-verification codes, stored as bcrypt digests only. Deliberately **not** firm-scoped — a login code is created before we know who is signing in. |
| `auth_sessions` | One row per signed-in device. Refresh token stored as a SHA-256 digest. This is what makes a JWT revokable. |
| `admin_users`, `admin_sessions` | Platform staff, cookie sessions. Separate from `users` so there is no credential path between broker and admin. |
| `audit_events` | Append-only (`readonly?` once persisted). Polymorphic actor and subject. Written from day one; no viewer UI yet. |

### Billing

| Table | Notes |
| --- | --- |
| `plans` | `price` in whole rupees, `interval` month/year, `max_users`, `max_devices`. |
| `subscriptions` | Partial unique index allows one live (`trialing`/`active`) subscription per firm; superseded ones stay as history. `amount` is a snapshot, so changing a plan's price never rewrites the past. `entitled?` checks the **date** as well as the status, so a firm nobody remembered to mark lapsed still loses access. |

### Global masters

`cities` (with `state_code` — `MH`, not a truncation of "Maharashtra"),
`localities`, `builders`, `typologies` (decimal `bedrooms` for 2.5 BHK),
`lead_sources`, `lead_statuses` (`is_dead` / `is_booked` are what make the
reports writable without hardcoding names in SQL), `property_types`.

**Buildings are deliberately not here** — see Phase 2.

---

## Phase 2 — designed, not yet migrated

### Leads — **built**

`leads`, `lead_typologies`, `lead_activities`, `lead_status_changes`, as
designed. Columns are in the migrations; the rules that aren't obvious from them:

- **`name` is nullable.** Brokers capture a number off a portal before anything
  else, and requiring a name means "Unknown" typed into a thousand records. The
  design's form marks phone, transaction type, property type and budget as
  required — not the name.
- **`property_type_id` is required for `sale` and forbidden for `rent`**, because
  the design's form drops the question entirely for rentals. Enforced in the
  model against the *association*, not the foreign key — an unsaved property type
  is present as an object while its id is still nil.
- **`code` is sequential per firm** (`L-0001`), unique on `(firm_id, code)`, with
  a retry on collision. Brokers read these numbers to each other, so they are not
  random. The max is computed on the digits, not the string, or `L-9999` would
  outrank `L-10000` and start reissuing.
- **`project_id` is not there yet** — it arrives with the inventory slice.

Two behaviours worth knowing before writing a query:

- **"Missed f/u" is not a status.** The design's tab strip carries it but
  `LEAD_STATUSES` does not. It means `next_action_at` in the past on a
  non-terminal lead, and is reachable as `status=missed_followup`.
- **Budget filtering is overlap, not containment.** A window of ₹1–1.3 Cr returns
  the lead whose own range is ₹80L–1.2 Cr. Containment would hide exactly the
  lead a broker widening the filter is looking for.

**Visibility**: agents see only leads assigned to them; managers and the super
admin see the firm's whole pipeline (`Lead.visible_to`). A lead an agent may not
see returns 404, not 403. Because unassigned leads are invisible to agents, a
lead an agent creates is auto-assigned to them.

### Inventory — **built**

`builders` (extended), `projects`, `project_typologies`, `buildings`,
`properties`. Columns are in the migrations; the rules that aren't obvious:

- **`builders` now carries a nullable `firm_id`.** NULL is the platform's
  curated list; a value is one a broker added inline from the project form,
  visible to that firm alone. `Builder` is therefore **not** `FirmScoped` — a
  fail-closed scope would hide exactly the global rows everyone should see — and
  the guard spec records the exemption. Uniqueness is two partial indexes,
  because Postgres treats NULLs as distinct and a plain `(firm_id, name)` index
  would let the global list hold a name twice.
- **`buildings` are firm-owned**, unique on `(firm_id, name, locality_id)`. One
  broker's typo must not reach every other firm's dropdown. The accepted cost is
  duplication across firms.
- **`properties.confidential_note`** never appears in a list payload and never
  in the `shareable` subset. It is returned only by the property detail, where
  the design puts it behind a reveal.
- Amenities (`has_pool`, `has_gym`) live on the **building**, not the listing —
  every flat in it shares the same pool.

**Derived, never stored**: a project's price and area bands (min/max across its
typologies) and rate per sqft on both properties and project typologies. A
stored band can end up disagreeing with the rows it came from. Note that on a
rental, `price` is monthly rent, so `rate_per_sqft` is rent per sqft per month.

**Deviation from the original design of this table**: `project_typologies`
carries only `starting_price` and `starting_carpet_sqft`. The `price_to` /
`area_to_sqft` pair was dropped — the design has one price and one area per
typology, and the bands come from the set.

**Share payloads.** The client composes share text, so every project and
property detail carries a **`shareable`** object holding exactly the fields that
may go to a client. Building a message from `shareable` cannot reach the
confidential note, and `shareable` on a project omits `brokerage_percent` —
what the broker earns is not the client's business.

### Still to build

**`visits`** — `lead_id`, `project_id`/`property_id`, `scheduled_at`, `status`,
`notes`, `outcome`.

**Matching** — the design's "Map Lead" and "Show New Matches". The data it needs
(typology starting prices and areas, lead budgets and preferred configurations)
is all in place; the scoring rules are their own design pass.

### Bookings and money — **built**

`bookings`, `booking_documents`, `invoices`, `collections`.

**Net income is computed and stored** on every save:

```
net_income = round(agreement_value × commission_percent / 100) + kicker − passback
```

BigDecimal, rounded half-up **once**, where the percentage meets the value — never off an
already-rounded figure. The design's worked example is the fixture: ₹1,56,00,000 at 4.5% is
₹7,02,000, plus a ₹50,000 kicker, minus a ₹66,000 passback = **₹6,86,000**, the "₹6.86 L" on its
booking screen. Stored rather than derived so a booking's displayed revenue can never drift from
what the reports sum.

**Two hard blocks**, enforced in `app/services/bookings/`:

- an invoice may not take the booking past its net income (`over_invoiced`)
- a collection may not take the booking past what is invoiced (`over_collected`), and one naming
  a specific invoice may not take that invoice past its own amount
  (`over_collected_for_invoice`) — which is what catches a payment filed against the wrong invoice

Every refusal carries the arithmetic in `error.details`, so the app can say how much is left
rather than only that it said no.

**Behaviours worth knowing before writing a query:**

- **Bookings never touch the lead.** Neither creating nor cancelling changes lead status, so
  `Booked` and `lead.booked_at` are set by hand. This departs from the design's cancel copy
  ("reopens the lead") deliberately.
- **Cancelling sets status and nothing else.** Invoices already raised stay on record, and the
  booking leaves `Booking.live`, which is where every money query starts.
- **`customer_name` / `customer_mobile` are snapshots** taken at booking time — correcting a lead
  a year later must not rewrite what was booked.
- **Managers and super admins only.** Agents get `forbidden_role` on every booking endpoint.
- Never sum totals over a scope carrying `includes(:invoices, :collections)` — it becomes a LEFT
  JOIN and counts a booking once per associated row, inflating revenue.
  `BookingsController#totals_for` re-selects by id for exactly that reason.

Invoice numbers are entered by the broker (`INV-2026-041`) so they match what was raised outside
the system, and are unique per firm. Cancelling an invoice is not built — the design shows no
control for it.


### Ancillary

**`notifications`** — `user_id`, `kind`, `title`, `body`, `read_at`, `data`.
**`news_articles`** — global, platform-published: `category`, `title`, `body`,
`read_minutes`, `published_at`, image.

### Reports

No tables. All four report shapes are grouped queries over the above:

| Report | Reads |
| --- | --- |
| Source × status matrix | `leads` grouped by `lead_source_id` × `lead_status_id`, date-filtered |
| Dead leads by FY month | `lead_status_changes` into a status where `is_dead`, plus `leads.created_at` for the generated column |
| Bookings by FY month | `bookings` counts, `invoices` / `collections` for the followup columns |
| Revenue by FY month | Same shape, amounts instead of counts |

Materialised views are a later optimisation, and only if measurement asks for
them.

---

## Out of scope in this build

- **Top opportunities** on the dashboard — comes from the turbo-rails8 API.
  `projects.source` + `external_ref` are the only seam left for it.
- **Payment gateway** — subscriptions are ops-managed by hand.
- **Broker user CRUD in the admin panel** — the super admin is created with the
  firm; the detail page lists users read-only.
- **Audit log viewer** — the table is written, the screen is not built.
