# Answers — API & Backend Clarification Document (10 Sep 2026)

Response to the mobile team's 21 open items. Every "exists" answer below was run
against `staging.realtoriq.kgen.tech` while writing this; every "not built"
answer was checked against the routing table, not from memory.

**Full parameter-level reference: [docs/api.md](api.md).** Most of section 3–6
is answered there in more detail than this document repeats.

## Summary

| | Count | |
| --- | --- | --- |
| ✅ **Already exists** | 9 | Answered below, with the exact endpoint |
| 🔧 **Was broken, now fixed** | 1 | #14 uploads — see below, needs a deploy |
| 🆕 **Built since this document** | 4 | #4, #5, #19 and #6.c — one `GET /dashboard` |
| 🔨 **Genuinely missing, small** | 1 | #12 list users |
| 🚧 **Not built — needs a product decision** | 6 | Sections 1.1–1.3, 1.6, 2.x, 4.2, 5.2 |

> **Update — `GET /api/v1/dashboard` is built.** It closes items **4, 5, 19 and
> 6.c** together: the six pipeline counters, the money tiles including the
> This Month / This FY split, Registered and Cancelled values, and the
> properties strip — in one request. Shape and definitions in
> [docs/api.md](api.md#dashboard). Ships with the CORS fix.

> **Update — project search is built, and can be used for the Projects search box.**
>
> ```
> GET /api/v1/projects/search?q=<text>
> ```
>
> - **Call it once the user has typed at least 3 letters or numbers**, debounced
>   (~250 ms). Fewer returns `422 query_too_short`, with the minimum in
>   `details.min_length`.
> - **Matches what was typed first** — the project name or RERA number containing
>   the text, ranked exact → starts with → contains. Typing `lod` gives Lodha, not
>   every project starting "Lo".
> - **Offers close spellings only when nothing matches as typed** (4+ characters):
>   `aurm` finds *Aurum Vista*. `meta.fuzzy` is `true` then — label them "did you mean".
> - **Capped at 10.** `meta.more` is `true` when there are more — show "keep typing".
> - **Each result is slim** — `id`, `name`, `rera_number`, `source`, `builder`,
>   `locality`, `city`. Tap through to `GET /projects/:id` for the full project.
> - Built to stay fast as the project pool grows: it is answered from a search
>   index, not by scanning every project.
>
> Full shape in [docs/api.md](api.md#get-projectssearch). **Ships with the next
> deploy**, which needs a database migration.

> **Update — a project you just created is not missing, it is on page 2.**
> `GET /projects` is sorted A–Z by default, 25 per page. Pass **`sort=recent`** to
> get newest first, or — simplest after a create — show the project the `POST`
> returned instead of re-fetching the list. `GET /properties` was already newest
> first and also accepts `sort=name` (by building). Ships with the same deploy.

Two of your items were flagged blocking. **One is fixed** and one is a real gap
I can close quickly.

---

## 🔧 #14 — Uploads: step 2 (PUT to the pre-signed URL) — **fixed**

> **Update — files over 1 MB still fail, with `413 Request Entity Too Large`.**
> That one is the web server in front of the app, not the API: nginx's default
> request size is 1 MB while the app accepts up to 5 MB. It needs a one-line change
> on the staging server. Until then, test with files under 1 MB — the API itself
> handles the full 5 MB (verified with a 4.9 MB brochure).

**You were right, and the cause was a CORS rule of mine.**

`POST /api/v1/uploads` returns a `direct_upload.url` under
**`/rails/active_storage/disk/…`** — *not* under `/api`. Our CORS policy was
scoped to `resource "/api/*"`, so the browser's preflight `OPTIONS` to that PUT
target came back with **no `Access-Control-*` headers at all** and the request
was blocked before it left the client.

That is exactly the shape you described: step 1 fine, step 2 dead, nothing in the
server logs. And it is why `curl` worked and the app did not — curl sends no
`Origin`, so it never triggers a preflight.

Answering your four specific asks:

| Your question | Answer |
| --- | --- |
| (a) Is the pre-signed URL's expiry too short? | No — 5 minutes, and it was never reached |
| (b) Do the returned headers match what storage expects? | Yes. Send `direct_upload.headers` **verbatim** — currently just `Content-Type` |
| (c) Is CORS configured on the bucket for PUT from the app's origin? | **This was it.** Not the bucket — staging uses disk storage, so the PUT hits Rails, and Rails was not allowing the origin |
| (d) A known-good example PUT captured against staging | Below |

**The fix** adds `/rails/active_storage/*` to the CORS policy. Verified end to
end with an `Origin` header set, which is what makes it a browser-shaped request:

```
preflight OPTIONS → 200
  access-control-allow-origin: *
  access-control-allow-methods: GET, PUT, OPTIONS, HEAD
  access-control-allow-headers: content-type,content-md5
PUT              → 204
attach           → { "photo_count": 1, "attachment_id": "1954f8fc-…" }
```

The admin panel stays closed cross-origin and
`/rails/active_storage/direct_uploads` stays 404 — both re-checked.

> **This needs a deploy.** Until it ships, staging will keep failing at step 2.

**Known-good PUT.** No `Authorization` header — the URL is the credential:

```bash
curl -X PUT "<direct_upload.url>" \
  -H "Content-Type: image/png" \
  -H "Content-MD5: XrY7u+Ae7tCTyyK7j1rNww==" \
  --data-binary @photo.png
# → 204 No Content
```

`checksum` is the **base64 MD5** of the bytes, and the same value goes in
`Content-MD5`. A mismatch is rejected by storage — that is the integrity check,
not a bug.

Two related notes:

- Attaching a `signed_id` whose PUT never landed returns **`422 upload_incomplete`**,
  not a 500. Worth handling — it means the upload silently failed.
- **When we move to S3** (`STORAGE_SERVICE=amazon`), `direct_upload.url` will
  point at the bucket instead and this Rails-side rule stops applying. The CORS
  policy will have to be set on the bucket. Flagging now so it isn't rediscovered
  in production.

This unblocks §3.4, §4.3 and §5.3 together — they were all the same bug.

---

## 🔨 #12 — "List users" endpoint for the reassignment picker

**Correct, it does not exist.** There is no `/api/v1/users` route of any kind —
`GET /api/v1/users` is a 404 today.

`/me` returns only the signed-in user, so there is genuinely no way to populate
that dropdown. This needs building; it's small. Proposed:

```
GET /api/v1/users        → { users: [ { id, name, role, mobile, active } ] }
```

Firm-scoped implicitly (the JWT carries the firm), manager+ only, matching the
role guard already on `assign`. **Confirm you want `avatar`** — users have no
image field today, so that's a migration rather than a serializer line.

### Also: your reassign example uses the wrong verb

Your document shows `PATCH /api/v1/leads/{lead_id}/assign`. The route is **POST**:

```
PATCH → 404
POST  → 200
```

Body and behaviour are as you have them. `assigned_user_id: null` unassigns —
which hides the lead from every agent, since agents only see leads assigned to
them.

---

## ✅ Already exists

### §3.1 — Leads filters and search (items 11)

All of it exists on **one** endpoint, `GET /api/v1/leads`. There is no separate
search endpoint; `q` matches name, mobile **or** email.

Full list: `q`, `status`, `transaction_type`, `property_type_id`, `source_id`,
`assigned_user_id`, `budget_min`, `budget_max`, `possession_from`,
`possession_to`, `typology_ids[]`, `sort`, `page`, `per_page`.

Mapping your proposed filters to what actually exists:

| Your proposal | Reality |
| --- | --- |
| Lead status — Hot/Warm/Cold/Dead/New | `status=<code>`. Seeded codes are `new`, `hot`, `followup`, `visit_planned`, `negotiation`, `booked`, `dead` — **there is no Warm or Cold**. Read them from `GET /reference`, never hardcode |
| Source | `source_id` |
| Assigned-to | `assigned_user_id` |
| Date range | `possession_from` / `possession_to` (possession, not created) |
| Project/Property | ❌ not filterable — leads have no project link yet. See §4.2 |
| Budget range | `budget_min` / `budget_max` — **overlap, not containment** |
| Configuration/BHK | `typology_ids[]`, repeated |
| Today's follow-ups only | Use `status=missed_followup` for overdue. A "today" window is not built — say if you need it |
| Missed calls only | ❌ not built — there is no call log |

**`status=missed_followup` is not a real status.** It means `next_action_at` in
the past on a non-terminal lead, and it will never appear in `lead_statuses`.

**Budget filtering is overlap.** A ₹1–1.3 Cr window returns the lead whose own
range is ₹80L–1.2 Cr — deliberately, so widening the filter doesn't hide the lead
you're looking for.

`sort` is `worklist` (default — overdue first, then by due date, then newest),
`recent`, or `updated`. `per_page` clamps to 1–50; absent means 25.

### §3.3 — Lead activities (item 13)

`POST /api/v1/leads/{id}/activities` — your two examples are correct.

- **`kind`** is `call` · `whatsapp` · `visit` · `note`. (`status_change` exists in
  the enum but is written by the server on a status transition — don't send it.)
- **`outcome` is free text, not an enum.** A plain string column, no validation.
  If you want a fixed vocabulary, tell us the list and we'll constrain it —
  otherwise it stays open and reporting on it later will be messy.
- **`body` is required** for every kind you can send.
- Logging **`kind: "visit"`** sets `first_visit_at`, and the response returns the
  refreshed lead so you can update the "visited" badge without a second call.

**3.3.a — which screens should call it:** Log Call, Log Site Visit, and any
WhatsApp/Note action. All four map to `kind`. Email is **not** a valid kind
today — say if you need it added.

**3.3.b — yes**, `GET /api/v1/leads/{id}/activities` exists. Latest first, 25 per
page, with the standard `meta` block. The lead **detail** also embeds the latest
20 under `activities`, so the timeline usually needs no second request.

### §6.ii — Booking documents (item 20)

Both exist. **One correction to your guess:** the payload key is
**`signed_id`, singular** — one file per call, not an array.

```
POST   /api/v1/bookings/{id}/documents     { slot, label, signed_id }
DELETE /api/v1/bookings/{id}/documents/{document_id}
```

`slot` is `application_form` · `tagging_confirmation` · `lead_source_proof` ·
`other`. **Only `other` may hold more than one file** — a second file in a named
slot returns `422 slot_taken` rather than silently overwriting.

**6.ii.b — it hard-deletes.** The row goes and the blob is purged; an
unreferenced file would sit in storage being paid for forever. Both actions
return the refreshed booking.

Document ids **are** returned (`booking.documents[].id`), so the delete is
addressable. Photos had exactly this problem and it was fixed last week — see
"photos" in [docs/api.md](api.md) if you hit a stale build.

### §6.iii — Find lead by phone (item 21)

No dedicated endpoint. It's `GET /api/v1/leads?q=9820166666`.

Answering the two UI cases you raised:

- **No match** — the array is empty. Create the lead first; a booking requires
  one (`422 lead_required` without it).
- **More than one match** — expected and allowed. The design shows several leads
  on one number, and lead creation deliberately does not block duplicates; it
  returns `possible_duplicates` for you to show. **Let the broker pick.**

### §1.5 / §6.i — Bookings and revenue (items 5, 19) — *partially*

`GET /api/v1/bookings` already returns a `totals` block over the filtered set:

```json
"totals": { "net_income": …, "invoiced": …, "collected": …, "outstanding": … }
```

Combined with `booked_from` / `booked_to`, that covers **Revenue Till Date**,
**Bookings count**, **Brokerage Earned** and **Outstanding**.

What is **not** built: the **This Month / This FY** split, **Registered value**,
and **Cancelled value** as first-class tiles. Those are aggregations we'd add to
a dashboard endpoint — see #4 below.

**1.5.b — `LIVE` is a real enum value**, not a computed flag: `booking.status` is
`live` or `cancelled`. Cancelling sets the status and nothing else; invoices
already raised stay on record.

---

## 🚧 Not built — these need a decision, not an endpoint name

None of the following exist in any form. Listing them honestly rather than
inventing contracts:

| # | Item | State |
| --- | --- | --- |
| 1 | Notification bell — badge + inbox | `notifications` table is **designed** in `docs/schema.md`, not migrated. No endpoint |
| 2 | Real-time toast / push | Nothing. No push infrastructure, no FCM, no socket topic. This is a project, not an endpoint |
| 3 | Featured / Live Projects | **Use placeholder data on the client for now.** Featured projects will come from the **LaunchIQ** integration, which is not built yet — there is no endpoint for this, and `GET /dashboard` deliberately has no featured block. `inventory.projects` there is a count, not a list |
| 6 | Knowledge Center articles | `news_articles` is **designed**, not migrated. No CMS |
| 7 | EMI calculator | See note below |
| 8 | Reports — 4 kinds | **Designed in `docs/schema.md`** with the exact grouping for each, not built. This is the largest single item |
| 9 | Settings | Firm contact channels exist. Profile / notification preferences do not |
| 10 | Skills & Trainings | Not built and **not designed** — this has never been specced. Needs product input before an API question is meaningful |
| 16, 18 | "Map Lead" / "New Matches" | Not built. `docs/schema.md` notes the data is all in place but **the scoring rules are their own design pass** |

Three of these have a shortcut worth knowing:

**#4 — Leads Snapshot — now built.** `GET /api/v1/dashboard` returns all six
counters plus the money tiles from §1.5, the Registered / Cancelled / This Month
values from §6.i, and the properties strip from §1.6.c. One request.

Two things to code against: **the `money` block is absent for an agent**, not
zeroed — branch on the key existing. And **`this_fy` is 1 April to 31 March**,
so a 31 March booking and a 1 April one land in different years.

**#7 — EMI calculator.** The maths is pure client-side; there is no endpoint and
there doesn't need to be. **"Save to Lead" works today**: `POST /leads/{id}/activities`
with `kind: "note"` and the computed figures in `body`. If you want the numbers
queryable later rather than prose in a note, that's a structured field and needs
a decision. **"Share on WhatsApp"** is a client-side `wa.me` deep link — no
backend call. For project/property shares, build the message from the
**`shareable`** object on the detail payload; it is constructed to exclude
`confidential_note` and `brokerage_percent`.

**#16 / #18 — Map Lead.** Note that `leads` has **no `project_id` yet** — that
column arrives with this feature. So the Projects/Properties filter on the Leads
page (§3.1) is blocked on the same work.

---

## Suggested order

1. **Deploy** — the CORS fix and `GET /dashboard` are both waiting on it
2. **`GET /users`** — half a day, unblocks the reassign picker
3. **Reports** — designed, sizeable, the biggest remaining chunk
4. **Map Lead / New Matches** — needs a scoring-rules design pass first
5. **Notifications / push** — its own project
6. **Skills & Trainings** — needs product spec before anything

Items 4, 5, 6.c, 11, 13, 15, 17, 19, 20 and 21 need no work — they're answered above and in
[docs/api.md](api.md).

## Corrections to carry back

Three things in the document would have cost the team time:

1. `PATCH /leads/{id}/assign` → **POST**
2. Booking documents take **`signed_id`** (singular), not `signed_ids: [...]`
3. Lead statuses are `new/hot/followup/visit_planned/negotiation/booked/dead` —
   **no Warm or Cold**. Drive the filter chips from `GET /reference`
