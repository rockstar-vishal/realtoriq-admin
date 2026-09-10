# Tech debt

Known, deliberately deferred. Nothing here is a mystery — each item says what it
is, what it costs, and when it has to be dealt with.

**Sources.** The audit of 10 Sep 2026 ([docs/audit-2026-09-10.md](audit-2026-09-10.md))
raised 72 findings; the 8 most severe were adversarially verified and fixed, along
with several others reproduced by hand. What is left of that audit is below,
**unverified** — plausible, cited, but not confirmed. Treat them as leads.

---

## Must be done before production

These are not optional. Production has never run, and each of these either
blocks it or breaks something silently on day one.

### 1. S3 and the `shareable` photo URLs

Production now stores uploads on S3 (`AWS_BUCKET` required). Disk and S3 build
blob URLs differently, and `config.active_storage.urls_expire_in` is unset.

**The risk:** `shareable` exists so a broker can paste a project or property
photo into WhatsApp, and that link has to keep working after the response is
gone. Booking documents and collection proofs deliberately expire after 15
minutes (`BlobUrl.sensitive`). Confirm both still behave that way against a real
bucket — one boots on S3 and checks a photo URL still resolves an hour later,
and a document URL does not.

**Cost if skipped:** either broker share links break in the field, or document
links stop expiring and go back to being permanent and unauthenticated.

### 2. MSG91 is not configured

The auth key is in credentials. `sms_template_id` (DLT-approved), and for
WhatsApp `whatsapp_number` and `whatsapp_template_name`, are still missing.

**Cost if skipped:** **nobody can sign in.** Indian transactional SMS is
DLT-regulated, so the template has to be registered with the operator and
referenced by id. Procurement takes time — start it early. `bin/rails msg91:check`
reports what is set without sending anything.

### 3. Rotate the two secrets shared in plaintext

The MSG91 auth key and the staging admin password were both pasted into a chat
transcript. Rotate both before production traffic.

### 4. Rails 8.0.5.1 reaches end of life on 7 November 2026

Brakeman flags it on every run. A patch-level bump, but it needs doing while it
is still routine.

### 5. Staging is on the open internet

Reachable with nothing in front of it, and every sign-in code is `888888`.
Anyone who guesses the hostname and knows a broker's mobile number *is* that
broker. Two lines of nginx basic auth. See [docs/staging.md](staging.md).

---

## Unverified findings — production readiness

The cluster most likely to bite on deploy day. None confirmed.

| Finding | Where |
| --- | --- |
| An idle-expired auth_session still occupies the one-live-per-device unique index, so re-signing-in on that device raises RecordNotUnique (500) forever | `app/models/auth_session.rb:28` |
| Two concurrent refreshes with the same refresh token both return 200, but only one of the two returned tokens works | `app/models/auth_session.rb:71` |
| `possible_duplicates` on lead create returns full lead payloads for leads the agent may not see | `app/controllers/api/v1/leads_controller.rb:43` |
| Nothing checks which firm a signed_id belongs to at attach time — and the URL in every response IS the attach token | `app/controllers/concerns/attaches_photos.rb:26` |
| PATCH /projects/:id purges the brochure before validation, so a rejected update still destroys the file | `app/controllers/api/v1/projects_controller.rb:40` |
| The documented `422 upload_incomplete` exists only on the photo path — every other attach path returns a 500 | `app/controllers/api/v1/booking_documents_controller.rb:22` |
| one_time_codes.user_id and contact_channels.verified_by_user_id are still ON DELETE NO ACTION — the two the cascade-fix migrations missed, and they break every user and firm deletion | `db/schema.rb:646` |
| Production Action Mailer has no delivery configured — it points at localhost:25, so email OTP verification silently never completes | `config/environments/production.rb:64` |
| No Solid Queue worker runs on the documented production deploy path — enqueued mail sits in the queue forever | `config/puma.rb:37` |
| Plaintext sign-in codes are written to the production log — filter_parameters covers :otp but the parameter is named `code` | `config/initializers/filter_parameter_logging.rb:7` |
| A stale or wrong-field id in lead_source_id / assigned_user_id 500s instead of returning a validation error | `app/controllers/api/v1/leads_controller.rb:166` |

---

## Unverified findings — medium

| Finding | Where |
| --- | --- |
| Refresh-token reuse is silent — no detection, no session revocation, no audit event — and rotation resets the 60-day expiry, so a stolen token never expires | `app/controllers/api/v1/auth_controller.rb:85` |
| A disabled user on an authenticated request gets 401 `unauthorized`, not the documented 403 `account_disabled` | `app/controllers/api/v1/authenticated_controller.rb:28` |
| GET /bookings `totals` omits invoiced / collected / outstanding, which docs/api-clarifications.md promised the mobile team as the source for the Outstanding tile | `app/controllers/api/v1/bookings_controller.rb:104` |
| Dashboard hands an agent the firm's whole live-booking count under `leads.bookings`, contradicting the same file's comment and docs/api.md:258 | `app/services/dashboard/summary.rb:65` |
| Dashboard: `leads.bookings` is the firm-wide live booking count, unscoped, and reaches agents | `app/services/dashboard/summary.rb:65` |
| POST/PATCH /bookings accepts another firm's `project_id` and renders that firm's project back | `app/controllers/api/v1/bookings_controller.rb:127` |
| UploadPurpose caps are enforced only when the ticket is issued, never at attach — pick the loosest purpose and the tightest cap is gone | `app/models/upload_purpose.rb:10` |
| Nothing ever sweeps orphaned blobs, and the metadata written to make sweeping possible is never read | `app/controllers/api/v1/uploads_controller.rb:30` |
| nginx rejects every step-2 PUT over 1 MiB, so four of the six advertised caps are unreachable | `app/models/upload_purpose.rb:19` |
| assigned_user_id (and bookings.project_id) are written straight from params with no firm or existence check, and no composite FK can catch it | `app/controllers/api/v1/leads_controller.rb:167` |
| The masters delete endpoint promises a friendly refusal but five of the seven models have no restrict_with_error, so deleting a referenced row 500s | `app/controllers/admin/masters/base_controller.rb:55` |
| bookings.net_income can be stored negative — no CHECK constraint and no validation, and it is summed straight into firm revenue | `db/schema.rb:137` |
| ALLOWED_HOSTS is silently ignored in production — host authorization is on in staging, off in production | `config/environments/production.rb:83` |
| The only master.key copy is one developer's working tree, and it is the sole key for the encrypted bank-account column | `app/models/firm_bank_account.rb:10` |
| database.yml.sample's production block contradicts the documented Postgres setup and will fail peer authentication | `config/database.yml.sample:124` |
| STORAGE_SERVICE is honoured in staging but hardcoded in production, and no `amazon` service is defined | `config/environments/production.rb:25` |
| GET /bookings runs 4 extra SQL sums per booking; the includes(:invoices, :collections) is dead weight | `app/controllers/api/v1/bookings_controller.rb:18` |
| GET /projects and GET /properties N+1 on photos, and /projects also N+1s on typologies | `app/controllers/api/v1/projects_controller.rb:72` |
| GET /buildings issues a COUNT per row for property_count and ignores per_page (hardcoded 50) | `app/controllers/api/v1/buildings_controller.rb:16` |
| GET /bookings totals: shape does not match the documented one and it ignores the status filter | `app/controllers/api/v1/bookings_controller.rb:104` |
| Near-miss filter names are silently ignored, and the inventory list filters are undocumented | `app/controllers/api/v1/leads_controller.rb:122` |
| `city` and `locality` are objects on /buildings and bare strings on /projects and property.building; a project payload carries no city_id at all | `app/serializers/api/v1/project_serializer.rb:14` |
| GET /properties and /projects silently default to a status filter that the dashboard counters do not apply | `app/controllers/api/v1/properties_controller.rb:75` |
| The list envelope is not uniform: /builders returns no meta and no pagination; invoices/collections indexes return no meta | `app/controllers/api/v1/builders_controller.rb:12` |
| POST /auth/verify and /auth/refresh can return `subscription: null`, which the docs never show | `app/controllers/api/v1/auth_controller.rb:131` |
| POST /leads/:id/activities returns `lead` in the list shape while every other endpoint's `lead` key is the detail shape | `app/controllers/api/v1/lead_activities_controller.rb:44` |

---

## Unverified findings — low

| Finding | Where |
| --- | --- |
| Admin masters: builder edit/update/destroy are not narrowed to the global list, so ops can mutate a firm's private builder | `app/controllers/admin/masters/builders_controller.rb:19` |
| Issuing a new login code does not invalidate the previous ones — every code from the last 10 minutes stays valid | `app/controllers/api/v1/auth_controller.rb:30` |
| `OneTimeCode.purge_expired` is documented as running from a recurring job, but nothing schedules it | `app/models/one_time_code.rb:78` |
| GET /bookings?status=cancelled lists cancelled bookings but reports totals of zero above them | `app/controllers/api/v1/bookings_controller.rb:106` |
| kicker and passback have no database CHECK constraint, unlike every other money column on the same tables | `db/schema.rb:135` |
| An agreement_value above the bigint range returns a 500 HTML error page from the JSON API | `app/models/booking.rb:29` |
| A disabled user gets 401 `unauthorized` on authenticated requests, never the documented 403 `account_disabled` | `app/controllers/api/v1/authenticated_controller.rb:28` |
| The `firm_logo` upload purpose has no consumer, so every ticket it issues is a guaranteed orphan | `app/models/upload_purpose.rb:31` |
| users.notification_mode and lead_sources.category are enumerated columns with a Ruby inclusion validator and no DB CHECK, against the documented convention | `db/migrate/20260804100300_create_users.rb:22` |
| Four global masters validate name uniqueness in Ruby with no unique index behind it | `app/models/typology.rb:7` |
| Production's default CORS origin is a developer laptop, and the failure is invisible server-side | `config/initializers/cors.rb:19` |
| Setup docs tell you to mint a fresh SECRET_KEY_BASE, though credentials already hold one — regenerating it invalidates admin sessions and all JWTs | `docs/staging.md:79` |
| Five error codes exist that docs/api.md's table does not list, and invalid_code is 422 here but documented as 401 | `docs/api.md:661` |
| `promo` is sent as null, not omitted, contradicting the documented contract | `app/serializers/api/v1/project_serializer.rb:24` |
| Dashboard's leads.bookings counter is firm-wide even for an agent, contradicting the documented scoping | `app/services/dashboard/summary.rb:65` |
| GET /reference's lead_statuses omit is_terminal, which the embedded lead.status carries and the API filters on | `app/controllers/api/v1/reference_controller.rb:53` |

---

## Known and deliberate

Recorded so they are not rediscovered as bugs:

- **Unknown and misshapen parameters are ignored.** `action_on_unpermitted_parameters = :raise`
  was considered and rejected: it breaks every client that sends a stray field.
  The mitigation is documentation. See the comment in
  `app/controllers/api/v1/base_controller.rb`.
- **A booking can compute a negative `net_income`** when the passback exceeds
  commission plus kicker. Nothing forbids it. Whether that is a real scenario or
  should be validated is an open product question.
- **Cancelling is the only lever on a booking** — invoices and collections have
  no update or destroy route, and cancelling an invoice was never built. That is
  why the concurrency bug was rated critical: there was no way to repair the
  damage.
- **`visited` on the dashboard** counts leads that have *ever* had a visit
  logged. The design's tile may have meant visits this month; the `visits` table
  is designed but unbuilt.

## Designed but unbuilt

Tracked in [docs/schema.md](schema.md), not repeated here: `visits`,
`notifications`, `news_articles`, lead-to-inventory matching ("Map Lead" /
"Show New Matches"), the four report screens, and `GET /users` for the
reassignment picker.
