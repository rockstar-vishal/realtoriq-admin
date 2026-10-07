#!/usr/bin/env bash
# Checks a deployed staging box against every fix that has shipped, and prints
# PASS / FAIL for each. Exits non-zero if anything failed, so it can gate a
# deploy.
#
#   script/verify_deploy.sh
#   BASE=https://staging.realtoriq.kgen.tech script/verify_deploy.sh
#
# Needs curl and jq. Signs in with the fixed staging code 888888, so it only
# works against staging — production has no fixed code and it stops at the
# first sign-in.
#
# It creates a few records to test against — projects, a booking, invoices —
# tagged with the run's timestamp, and tidies them up on exit however the run
# ends: projects are archived and bookings cancelled (the API deletes neither).
#
# Written for the bash 3.2 that ships with macOS, which has two traps this
# script works around:
#   - Anything appended inside $( ... ) happens in a subshell and is lost, so
#     created records are tracked in a file rather than an array.
#   - Escaped quotes inside "$( ... )" are not treated as quoting, so a JSON
#     literal there is brace-expanded at its commas and reaches curl as broken
#     JSON — Rails then answers with an HTML 400 that looks like an app bug.
#     Always build a JSON body into a variable first.

set -uo pipefail

BASE="${BASE:-https://staging.realtoriq.kgen.tech}"
API="$BASE/api/v1"
TAG="DV$(date +%s)"

SUPER_ADMIN=9820144210
MANAGER=9820144211
AGENT=9820144212
OTHER_FIRM_OWNER=9820312115 # a user in a second firm, for the cross-tenant checks

# Never production. The first thing this does is request sign-in codes for
# hardcoded mobile numbers — in production that sends a real SMS to whoever owns
# them — and then it creates bookings, invoices and projects. It could not sign
# in there anyway (no fixed code), but by then the texts have gone out.
case "$BASE" in
  *staging*|*localhost*|*127.0.0.1*) ;;
  *) echo "Refusing to run against $BASE — this script is for staging only."
     echo "It requests sign-in codes, which in production texts real people."
     exit 2 ;;
esac

command -v jq >/dev/null || { echo "jq is required: brew install jq"; exit 2; }

if [ -t 1 ]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'; else G=; R=; Y=; B=; N=; fi

BODY_FILE=$(mktemp)
TRACK_FILE=$(mktemp)
FAIL_FILE=$(mktemp)
pass=0; fail=0; skip=0

tidy_up() {
  while IFS='|' read -r kind token id; do
    case "$kind" in
      project) curl -s -o /dev/null -X PATCH "$API/projects/$id" -H "Authorization: Bearer $token" \
                 -H 'Content-Type: application/json' -d '{"status":"archived"}' ;;
      booking) curl -s -o /dev/null -X POST "$API/bookings/$id/cancel" -H "Authorization: Bearer $token" \
                 -H 'Content-Type: application/json' -d "{\"reason\":\"Deploy verification $TAG - not a real booking\"}" ;;
      lead)    curl -s -o /dev/null -X POST "$API/leads/$id/status" -H "Authorization: Bearer $token" \
                 -H 'Content-Type: application/json' \
                 -d "{\"status\":\"dead\",\"reason\":\"Deploy verification $TAG\"}" ;;
    esac
  done < "$TRACK_FILE"
  rm -f "$BODY_FILE" "$TRACK_FILE" "$FAIL_FILE" "$BODY_FILE".race.*
}
trap tidy_up EXIT

track() { echo "$1|$2|$3" >> "$TRACK_FILE"; }

ok()      { pass=$((pass + 1)); printf "  ${G}PASS${N}  %s\n" "$1"; }
skipped() { skip=$((skip + 1)); printf "  ${Y}SKIP${N}  %s — %s\n" "$1" "$2"; }
section() { printf "\n${B}%s${N}\n" "$1"; }
bad() {
  fail=$((fail + 1)); echo "$1" >> "$FAIL_FILE"
  printf "  ${R}FAIL${N}  %s\n" "$1"
  [ -n "${2:-}" ] && printf "        ${Y}%s${N}\n" "$2"
  # The response that failed, so a failure explains itself.
  [ -s "$BODY_FILE" ] && printf "        response: %s\n" "$(head -c 240 "$BODY_FILE" | tr '\n' ' ')"
}
check() { if [ "$3" = "$2" ]; then ok "$1"; else bad "$1" "expected $2, got $3${4:+ — $4}"; fi; }
check_gt() {
  if [ -n "$2" ] && [ "$2" -gt 0 ] 2>/dev/null; then ok "$1"
  else bad "$1" "expected > 0, got ${2:-empty}"
  fi
}

# request METHOD PATH TOKEN [JSON] — prints the status; the body lands in $BODY_FILE.
request() {
  local method=$1 path=$2 token=$3 json=${4:-}
  set -- -s -o "$BODY_FILE" -w '%{http_code}' -X "$method" "$API$path" -H 'Content-Type: application/json'
  [ -n "$token" ] && set -- "$@" -H "Authorization: Bearer $token"
  [ -n "$json" ] && set -- "$@" -d "$json"
  curl "$@"
}
field() { jq -r "$1" < "$BODY_FILE" 2>/dev/null; }

sign_in() {
  local rid
  rid=$(curl -s -X POST "$API/auth/otp" -H 'Content-Type: application/json' -d "{\"mobile\":\"$1\"}" | jq -r '.request_id // empty')
  [ -z "$rid" ] && return 1
  curl -s -X POST "$API/auth/verify" -H 'Content-Type: application/json' \
    -d "{\"request_id\":\"$rid\",\"code\":\"888888\"}" | jq -r '.access_token // empty'
}

# Creates a project and records it for tidy-up. Sets $PROJECT_ID (no subshell).
create_project() {
  local token=$1 name=$2 extra=${3:-}
  request POST /projects "$token" \
    "{\"name\":\"$name\",\"builder_id\":\"$BUILDER\",\"city_id\":\"$CITY\",\"starting_budget\":9900000,\"possession_label\":\"Dec 2028\"$extra}" >/dev/null
  PROJECT_ID=$(field '.project.id // empty')
  [ -n "$PROJECT_ID" ] && track project "$token" "$PROJECT_ID"
}

in_ids() { field "[.projects[].id] | map(select(. == \"$1\")) | length"; }
in_lead_ids() { field "[.leads[].id] | map(select(. == \"$1\")) | length"; }
in_property_ids() { field "[.properties[].id] | map(select(. == \"$1\")) | length"; }

# Unique 10-digit mobiles for this run. $1 is a small integer offset.
lead_mobile() { printf '98%08d' $(( (${TAG#DV} + $1) % 100000000 )); }

# Creates a rent lead (no property_type_id) and records it to mark dead on exit.
create_lead() {
  local token=$1 json=$2
  request POST /leads "$token" "$json" >/dev/null
  LEAD_ID=$(field '.lead.id // empty')
  [ -n "$LEAD_ID" ] && track lead "$token" "$LEAD_ID"
}

printf "${B}Verifying %s${N}  (run %s)\n" "$BASE" "$TAG"

# ══════════════════════════════════════════════════════════════════════════════
section "Environment"

check "app is up" 200 "$(curl -s -o "$BODY_FILE" -w '%{http_code}' "$BASE/up")"

SA=$(sign_in $SUPER_ADMIN)
if [ -z "$SA" ]; then bad "sign in with 888888" "no token — is this staging, with demo:seed loaded?"; exit 1; fi
ok "sign in with the fixed staging code"
MGR=$(sign_in $MANAGER)
AG=$(sign_in $AGENT)

request GET /reference "$SA" >/dev/null
BUILDER=$(field '.builders[0].id'); CITY=$(field '.cities[0].id'); TYPOLOGY=$(field '.typologies[0].id')
request GET /me "$MGR" >/dev/null; MGR_ID=$(field .user.id)
request GET /me "$AG" >/dev/null;  AG_ID=$(field .user.id)

# ══════════════════════════════════════════════════════════════════════════════
section "Previous deploy — these should already pass"

check "page=0 no longer returns 500" 200 "$(request GET '/leads?page=0' "$SA")"
check "page=abc no longer returns 500" 200 "$(request GET '/leads?page=abc' "$SA")"
check "typology_ids[] filter works on the default sort" 200 "$(request GET "/leads?typology_ids%5B%5D=$TYPOLOGY" "$SA")"

rid=$(curl -s -X POST "$API/auth/otp" -H 'Content-Type: application/json' -d "{\"mobile\":\"$MANAGER\"}" | jq -r .request_id)
json="{\"request_id\":\"$rid\",\"code\":\"888888\",\"device\":\"iPhone 15\"}"
check "sign-in survives a device sent as a string" 200 "$(request POST /auth/verify '' "$json")"

# Agents cannot reassign; PATCH assigned_user_id is manager-role+ only.
request GET '/leads?per_page=1' "$AG" >/dev/null; AG_LEAD=$(field '.leads[0].id // empty')
if [ -n "$AG_LEAD" ]; then
  request PATCH "/leads/$AG_LEAD" "$AG" "{\"assigned_user_id\":\"$MGR_ID\"}" >/dev/null
  request GET "/leads/$AG_LEAD" "$SA" >/dev/null
  if [ "$(field .lead.assigned_user.id)" = "$AG_ID" ]; then
    ok "an agent cannot reassign a lead through PATCH"
  else
    bad "an agent cannot reassign a lead through PATCH" "the lead moved — putting it back"
    request PATCH "/leads/$AG_LEAD" "$SA" "{\"assigned_user_id\":\"$AG_ID\"}" >/dev/null
  fi
else
  skipped "an agent cannot reassign a lead through PATCH" "the agent has no leads"
fi

# Money: four simultaneous invoices against a booking earning 1,00,000.
request GET '/leads?per_page=1' "$SA" >/dev/null; LEAD=$(field '.leads[0].id')
request POST /bookings "$SA" \
  "{\"lead_id\":\"$LEAD\",\"booked_on\":\"$(date +%F)\",\"agreement_value\":1000000,\"commission_percent\":10,\"kicker\":0,\"passback\":0,\"unit_no\":\"$TAG\"}" >/dev/null
BOOKING=$(field '.booking.id // empty')
if [ -n "$BOOKING" ]; then
  track booking "$SA" "$BOOKING"
  for i in 1 2 3 4; do
    curl -s -o /dev/null -w '%{http_code}' -X POST "$API/bookings/$BOOKING/invoices" \
      -H "Authorization: Bearer $SA" -H 'Content-Type: application/json' \
      -d "{\"number\":\"$TAG-$i\",\"issued_on\":\"$(date +%F)\",\"amount\":100000}" > "$BODY_FILE.race.$i" &
  done
  wait
  won=$(cat "$BODY_FILE".race.* | grep -c 201)
  check "four simultaneous invoices: exactly one accepted" 1 "$won" "the booking lock is not holding"
  json='{"agreement_value":100000}'
  check "editing a booking cannot strand invoices already raised" 422 "$(request PATCH "/bookings/$BOOKING" "$SA" "$json")"
else
  skipped "money race and stranded invoices" "could not create a booking"
fi

# Cross-tenant: another firm's records must not attach to this firm's.
OTHER=$(sign_in $OTHER_FIRM_OWNER)
if [ -n "$OTHER" ]; then
  request GET /me "$OTHER" >/dev/null; OTHER_ID=$(field .user.id)

  create_project "$OTHER" "Other firm only $TAG"
  request POST /bookings "$SA" \
    "{\"lead_id\":\"$LEAD\",\"project_id\":\"$PROJECT_ID\",\"booked_on\":\"$(date +%F)\",\"agreement_value\":1000000,\"commission_percent\":1}" >/dev/null
  leaked=$(field '.booking.id // empty'); [ -n "$leaked" ] && track booking "$SA" "$leaked"
  check "another firm's project cannot be attached to a booking" \
    "isn't one of this firm's records" "$(field '.error.details.project_id[0] // "accepted"')"

  MOBILE="98$(date +%s | cut -c3-10)"
  request POST /leads "$SA" "{\"mobile\":\"$MOBILE\",\"transaction_type\":\"rent\",\"assigned_user_id\":\"$OTHER_ID\"}" >/dev/null
  # Assignable-scope fails closed for another firm's user the same way it does
  # for someone this actor cannot manage. The row is never attached.
  check "a lead cannot be assigned to another firm's user" \
    "isn't assignable" "$(field '.error.details.assigned_user_id[0] // "accepted"')"
else
  skipped "cross-tenant checks" "no second firm at $OTHER_FIRM_OWNER"
fi

preflight=$(curl -s -o /dev/null -D- -X OPTIONS "$BASE/rails/active_storage/disk/x" \
  -H 'Origin: https://app.example.com' -H 'Access-Control-Request-Method: PUT' | grep -ci 'access-control-allow-origin')
: > "$BODY_FILE"
check "uploads: CORS allows the PUT to storage" 1 "$preflight"
admin_cors=$(curl -s -o /dev/null -D- -X OPTIONS "$BASE/admin/firms" \
  -H 'Origin: https://app.example.com' -H 'Access-Control-Request-Method: GET' | grep -ci 'access-control-allow-origin')
check "admin panel stays closed cross-origin" 0 "$admin_cors"

# ══════════════════════════════════════════════════════════════════════════════
section "Previous deploy — project search, sort, and input handling"

status=$(request GET '/projects/search?q=aurum' "$SA")
if [ "$status" = 404 ]; then
  bad "GET /projects/search exists" "404 — this deploy has not reached the box yet"
  skipped "search checks" "the endpoint is not deployed"
elif [ "$status" = 500 ]; then
  bad "GET /projects/search works" "500 — deployed, but the migration has probably not run: RAILS_ENV=staging bin/rails db:migrate"
  skipped "search checks" "the endpoint errors"
else
  check "GET /projects/search responds" 200 "$status"

  request GET '/projects/search?q=au' "$SA" >/dev/null
  check "fewer than 3 characters is refused" query_too_short "$(field .error.code)"
  check "punctuation alone is refused (needs letters or numbers)" 422 "$(request GET '/projects/search?q=___' "$SA")"
  check "search requires sign-in" 401 "$(request GET '/projects/search?q=aurum' '')"

  create_project "$SA" "Lodha Verify $TAG"
  create_project "$SA" "Lotus Verify $TAG";       LOTUS=$PROJECT_ID
  create_project "$SA" "Kalpataru Paramount $TAG" ",\"rera_number\":\"P$TAG\""; KALP=$PROJECT_ID

  request GET '/projects/search?q=lod' "$SA" >/dev/null
  check "short query returns literal matches only, not look-alikes" false "$(field .meta.fuzzy)"
  check "  'lod' does not return Lotus" 0 "$(in_ids "$LOTUS")"
  check "  every result actually contains 'lod'" 0 \
    "$(field '[.projects[].name | ascii_downcase | select(contains("lod") | not)] | length')"

  request GET '/projects/search?q=kalpatru' "$SA" >/dev/null
  check "a typo still finds the project" 1 "$(in_ids "$KALP")"
  check "  and is flagged as a close spelling" true "$(field .meta.fuzzy)"

  request GET "/projects/search?q=P$TAG%C2%A0" "$SA" >/dev/null
  check "a RERA number pasted with a trailing non-breaking space matches" 1 "$(in_ids "$KALP")"

  request GET "/projects/search?q=P$TAG" "$SA" >/dev/null
  check "a result is slim" '["builder","city","city_id","id","locality","locality_id","name","rera_number","source"]' \
    "$(field '.projects[0] | keys | tostring')"

  request GET '/projects?sort=recent&per_page=1' "$SA" >/dev/null
  check "sort=recent puts the newest project first" "$KALP" "$(field '.projects[0].id')"
fi

check "a NUL byte in a search no longer returns 500 (leads)" 200 "$(request GET '/leads?q=a%00b' "$SA")"
check "a NUL byte in a search no longer returns 500 (projects)" 200 "$(request GET '/projects?q=a%00b' "$SA")"

# ══════════════════════════════════════════════════════════════════════════════
section "This deploy — Yash screens API"

# Home snapshot counters. Additive on GET /dashboard; missing keys means this
# slice is not on the box yet. `recent` is the missed-followup strip (max 3).
request GET /dashboard "$SA" >/dev/null
check "GET /dashboard has home snapshot keys" \
  '["bookings","hot","hot_negotiation","missed_followups","new","todays_followups","total","visit_planned","visited"]' \
  "$(field '.leads | del(.recent) | keys | sort | tostring')"

# Pipeline card totals. Independent of the list filter — an empty search still
# carries the object. Missing keys means this slice is not on the box yet.
request GET "/leads?q=NoSuchLead$TAG" "$SA" >/dev/null
check "GET /leads returns counts" '["booked","hot_negotiation","missed_followup","new","visit_planned","visited"]' \
  "$(field '(.counts // {}) | keys | sort | tostring')"
check "  the filtered list can be empty while counts remain" 0 "$(field '.leads | length')"

json="{\"mobile\":\"$(lead_mobile 1)\",\"transaction_type\":\"rent\",\"budget\":18000000,\"name\":\"BudgetWrite $TAG\"}"
create_lead "$SA" "$json"
if [ -n "$LEAD_ID" ]; then
  check "POST budget writes budget_max and clears budget_min" 18000000 "$(field '.lead.budget')"
  check "  leftover column budget_min is null" null "$(field '.lead.budget_min')"
  check "  stored budget_max matches" 18000000 "$(field '.lead.budget_max')"
else
  bad "POST budget writes budget_max and clears budget_min" "lead was not created"
fi

json="{\"mobile\":\"$(lead_mobile 2)\",\"transaction_type\":\"rent\",\"budget_min\":12000000,\"name\":\"BudgetIgnored $TAG\"}"
create_lead "$SA" "$json"
if [ -n "$LEAD_ID" ]; then
  check "budget_min on write is ignored" null "$(field '.lead.budget_min')"
else
  bad "budget_min on write is ignored" "lead was not created"
fi

create_project "$SA" "FromProject $TAG"
FROM_PROJECT=$PROJECT_ID
json="{\"mobile\":\"$(lead_mobile 3)\",\"transaction_type\":\"rent\",\"project_id\":\"$FROM_PROJECT\"}"
create_lead "$SA" "$json"
if [ -n "$LEAD_ID" ]; then
  check "create-from-project copies starting_budget into budget_max" 9900000 "$(field '.lead.budget_max')"
  check "  and does not write budget_min" null "$(field '.lead.budget_min')"
else
  bad "create-from-project copies starting_budget into budget_max" "lead was not created"
fi

json="{\"mobile\":\"$(lead_mobile 4)\",\"transaction_type\":\"rent\",\"name\":\"NcdSort-$TAG-overdue\",\"followup\":{\"comment\":\"Opening call\",\"next_action_at\":\"2020-01-01T00:00:00+05:30\"}}"
create_lead "$SA" "$json"; OVERDUE_LEAD=$LEAD_ID
json="{\"mobile\":\"$(lead_mobile 5)\",\"transaction_type\":\"rent\",\"name\":\"NcdSort-$TAG-null\"}"
create_lead "$SA" "$json"; NULL_LEAD=$LEAD_ID
if [ -n "$NULL_LEAD" ] && [ -n "$OVERDUE_LEAD" ]; then
  request GET "/leads?q=NcdSort-$TAG" "$SA" >/dev/null
  check "default sort puts unset NCD above overdue" "$NULL_LEAD" "$(field '.leads[0].id')"
  request GET "/leads?q=NcdSort-$TAG&sort=worklist" "$SA" >/dev/null
  check "sort=worklist still puts overdue first" "$OVERDUE_LEAD" "$(field '.leads[0].id')"
else
  bad "default sort puts unset NCD above overdue" "could not create the two leads"
fi

json="{\"mobile\":\"$(lead_mobile 6)\",\"transaction_type\":\"rent\",\"name\":\"DrawerAlpha $TAG\"}"
create_lead "$SA" "$json"; ALPHA_LEAD=$LEAD_ID
json="{\"mobile\":\"$(lead_mobile 7)\",\"transaction_type\":\"rent\",\"name\":\"DrawerBeta $TAG\"}"
create_lead "$SA" "$json"; BETA_LEAD=$LEAD_ID
if [ -n "$ALPHA_LEAD" ] && [ -n "$BETA_LEAD" ]; then
  request GET "/leads?q=DrawerAlpha&name=DrawerBeta%20$TAG" "$SA" >/dev/null
  check "a drawer filter drops q" 1 "$(in_lead_ids "$BETA_LEAD")"
  check "  the q-only match is gone" 0 "$(in_lead_ids "$ALPHA_LEAD")"
  request GET "/leads?q=DrawerAlpha%20$TAG&status=new" "$SA" >/dev/null
  check "status=new does not drop q" 1 "$(in_lead_ids "$ALPHA_LEAD")"
else
  bad "a drawer filter drops q" "could not create the two leads"
fi

json="{\"mobile\":\"$(lead_mobile 8)\",\"transaction_type\":\"rent\",\"name\":\"Visited $TAG\"}"
create_lead "$SA" "$json"; VISIT_LEAD=$LEAD_ID
if [ -n "$VISIT_LEAD" ]; then
  json='{"visited_on":"2020-01-15","notes":"deploy verification site visit"}'
  check "logging a visit" 201 "$(request POST "/leads/$VISIT_LEAD/visits" "$SA" "$json")"
  request GET "/leads?visited=true&q=Visited%20$TAG" "$SA" >/dev/null
  check "visited=true is a lead_visits row" 1 "$(in_lead_ids "$VISIT_LEAD")"
  request GET "/leads?q=Visited%20$TAG" "$SA" >/dev/null
  check "list card visit_count after a visit" 1 "$(field '.leads[0].visit_count')"
  check "  last_followup_comment is not the visit body" null \
    "$(field '.leads[0].last_followup_comment')"
  json='{"comment":"deploy verification followup"}'
  check "logging a followup" 201 "$(request POST "/leads/$VISIT_LEAD/followups" "$SA" "$json")"
  request GET "/leads?q=Visited%20$TAG" "$SA" >/dev/null
  check "  last_followup_comment is the followup comment" "deploy verification followup" \
    "$(field '.leads[0].last_followup_comment')"
else
  bad "visited=true is a lead_visits row" "lead was not created"
fi

json="{\"mobile\":\"$(lead_mobile 9)\",\"transaction_type\":\"rent\",\"name\":\"HotCard $TAG\"}"
create_lead "$SA" "$json"; HOT_LEAD=$LEAD_ID
if [ -n "$HOT_LEAD" ]; then
  json='{"status":"hot"}'
  request POST "/leads/$HOT_LEAD/status" "$SA" "$json" >/dev/null
  request GET "/leads?status=hot_negotiation&q=HotCard%20$TAG" "$SA" >/dev/null
  check "status=hot_negotiation returns a hot lead" 1 "$(in_lead_ids "$HOT_LEAD")"
else
  bad "status=hot_negotiation returns a hot lead" "lead was not created"
fi

create_project "$SA" "Psf $TAG" \
  ",\"brokerage_percent\":4.5,\"typologies\":[{\"typology_id\":\"$TYPOLOGY\",\"starting_price\":14200000,\"starting_carpet_sqft\":720}]"
PSF_PROJECT=$PROJECT_ID
if [ -n "$PSF_PROJECT" ]; then
  request GET "/projects?q=Psf%20$TAG" "$SA" >/dev/null
  check "project list includes avg_psf" 19722 "$(field '.projects[0].avg_psf')"
  request GET '/projects?brokerage_min=4&brokerage_max=5&sort=recent&per_page=50' "$SA" >/dev/null
  check "brokerage_min/max keeps a 4.5% project" 1 "$(in_ids "$PSF_PROJECT")"
  request GET "/projects?q=NoSuchProject$TAG&status=active" "$SA" >/dev/null
  check "project status pill does not drop q" 0 "$(field '.meta.total_count')"
  request GET "/projects?q=NoSuchProject$TAG&builder_id=$BUILDER" "$SA" >/dev/null
  check_gt "project drawer filter drops q" "$(field '.meta.total_count')"
else
  bad "project list includes avg_psf" "project was not created"
fi

json="{\"name\":\"Bldg $TAG\",\"city_id\":\"$CITY\"}"
check "create a building for property checks" 201 "$(request POST /buildings "$SA" "$json")"
BUILDING_ID=$(field '.building.id // empty')
if [ -n "$BUILDING_ID" ]; then
  json="{\"building_id\":\"$BUILDING_ID\",\"typology_id\":\"$TYPOLOGY\",\"listing_for\":\"sale\",\"price\":11800000,\"carpet_area_sqft\":400}"
  request POST /properties "$SA" "$json" >/dev/null
  json="{\"building_id\":\"$BUILDING_ID\",\"typology_id\":\"$TYPOLOGY\",\"listing_for\":\"sale\",\"price\":11800000,\"carpet_area_sqft\":690}"
  check "create a property" 201 "$(request POST /properties "$SA" "$json")"
  PROP_ID=$(field '.property.id // empty')
  if [ -n "$PROP_ID" ]; then
    json='{"status":"sold_out"}'
    check "PATCH status=sold_out" 200 "$(request PATCH "/properties/$PROP_ID" "$SA" "$json")"
    check "  payload says sold_out" sold_out "$(field '.property.status')"
    json='{"status":"available"}'
    check "sold_out is reversible" 200 "$(request PATCH "/properties/$PROP_ID" "$SA" "$json")"
    request GET '/properties?carpet_min=600&carpet_max=800&sort=recent&per_page=50' "$SA" >/dev/null
    check "carpet_min/max keeps a 690 sqft listing" 1 "$(in_property_ids "$PROP_ID")"
    request GET "/properties?q=NoSuchListing$TAG&listing_for=sale" "$SA" >/dev/null
    check_gt "property drawer filter drops q" "$(field '.meta.total_count')"
  else
    bad "PATCH status=sold_out" "property was not created"
  fi
else
  bad "create a building for property checks" "building was not created"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "Server — nginx"

big=$(head -c 2000000 /dev/zero | curl -s -o "$BODY_FILE" -w '%{http_code}' -X POST "$BASE/up" \
        -H 'Content-Type: application/octet-stream' --data-binary @-)
if [ "$big" = 413 ]; then
  bad "nginx accepts uploads over 1 MB" "413 — add 'client_max_body_size 6m;' to the server block and reload nginx"
else
  ok "nginx accepts uploads over 1 MB"
fi

# ══════════════════════════════════════════════════════════════════════════════
printf "\n${B}%d passed, %d failed, %d skipped${N}\n" "$pass" "$fail" "$skip"
if [ "$fail" -gt 0 ]; then
  printf "\n${R}Failed:${N}\n"
  sed 's/^/  - /' "$FAIL_FILE"
  exit 1
fi
