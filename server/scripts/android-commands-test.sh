#!/usr/bin/env bash
# Jarvis Prompt 10 — Android control app: verify the command flow against
# the LIVE dev server. The APK itself cannot be built in this environment
# (no JDK / Android SDK here — see apps/android/README.md), so this script
# proves the exact API call sequence the app's commands make:
#   login -> create portal -> list portals -> create + assign method ->
#   invite (code once) -> customer login -> traffic report -> block ->
#   blocked login denied -> unblock -> re-invite.
#
# Usage (from server/):
#   DATABASE_URL=<redacted>
#   DATABASE_URL=<redacted> PORT=4001 npm run dev > /tmp/jarvis-p10-server.log 2>&1 &
#       JWT_SECRET is NOT exported here — it must come from server/.env
#       via dotenv.
#   ANDROID_DB_FILE="$PWD/prisma/test-android.db" BASE_URL=http://localhost:4001 \
#     bash scripts/android-commands-test.sh
#
# The DATABASE_URL must be ABSOLUTE (Prompt 4 lesson). Prisma resolves a
# relative SQLite path against the schema dir (server/prisma/), not the
# cwd, so a relative URL in the server and a relative URL in this script
# can silently open two different files. Pass the DB file explicitly via
# ANDROID_DB_FILE (Prompt 7 lesson) or the DB check reads the wrong file.
#
# Uses a separate test database (test-android.db) — never touches dev.db.
# Tokens and codes are NEVER printed in full; only a masked prefix and
# the HTTP status are shown.
set -u
cd "$(dirname "$0")/.." # always run from server/ so dotenv finds ./.env
BASE="${BASE_URL:-http://localhost:4001}"
DB_FILE="${ANDROID_DB_FILE:-$(pwd)/prisma/test-android.db}"
FAIL=0
TMP=/tmp/jarvis-p10
mkdir -p "$TMP"

mask() { # print first 10 chars of a secret + its length, nothing more
  local t="$1"
  printf '%s...(len %s)' "${t:0:10}" "${#t}"
}

check() { # check <name> <expected-status> <actual-status>
  if [ "$2" = "$3" ]; then echo "PASS: $1 (HTTP $3)";
  else echo "FAIL: $1 — expected HTTP $2, got HTTP $3"; FAIL=$((FAIL+1)); fi
}

expect() { # expect <name> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "PASS: $1 ($3)";
  else echo "FAIL: $1 — expected '$2', got '$3'"; FAIL=$((FAIL+1)); fi
}

jget() { # jget <json-file> <node-expr> — extract a field without printing secrets
  node -e "const d=require('$1'); console.log($2)" 2>/dev/null
}

ADMIN_EMAIL="prompt10-admin@test.local"
ADMIN_PASS="TestAdmin123!"
CUSTA_EMAIL="prompt10-customer-a@test.local"

# 0. Health
code=$(curl -s -o "$TMP/health.json" -w "%{http_code}" "$BASE/health")
check "0. GET /health" 200 "$code"

# 1. Register the first ADMIN, then log in (the app's sign-in screen).
code=$(curl -s -o "$TMP/register.json" -w "%{http_code}" -X POST "$BASE/api/auth/register" -H 'Content-Type: application/json' -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\",\"name\":\"Don\"}")
check "1. first register -> ADMIN" 201 "$code"
code=$(curl -s -o "$TMP/login.json" -w "%{http_code}" -X POST "$BASE/api/auth/login" -H 'Content-Type: application/json' -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\"}")
check "1. ADMIN login" 200 "$code"
ADMIN_TOKEN=$(jget "$TMP/login.json" "d.data.token")
echo "    admin token: $(mask "$ADMIN_TOKEN")"
AUTH=(-H "Authorization: Bearer $ADMIN_TOKEN")

# 2. `create portal VIP Coaching` -> POST /api/portals
code=$(curl -s -o "$TMP/portal-a.json" -w "%{http_code}" -X POST "$BASE/api/portals" "${AUTH[@]}" -H 'Content-Type: application/json' -d '{"name":"VIP Coaching","slug":"vip-coaching","currency":"USD"}')
check "2. create portal VIP Coaching" 201 "$code"
PORTAL_A_ID=$(jget "$TMP/portal-a.json" "d.data.portal.id")
expect "2. portal A slug is vip-coaching" "vip-coaching" "$(jget "$TMP/portal-a.json" "d.data.portal.slug")"
code=$(curl -s -o "$TMP/portal-b.json" -w "%{http_code}" -X POST "$BASE/api/portals" "${AUTH[@]}" -H 'Content-Type: application/json' -d '{"name":"Second Portal","slug":"second-portal","currency":"USD"}')
check "2. create portal B" 201 "$code"

# 3. `list portals` -> GET /api/portals
code=$(curl -s -o "$TMP/portals.json" -w "%{http_code}" "$BASE/api/portals" "${AUTH[@]}")
check "3. list portals" 200 "$code"
grep -q "vip-coaching" "$TMP/portals.json" && echo "PASS: 3. list contains vip-coaching" || { echo "FAIL: 3. list is missing vip-coaching"; FAIL=$((FAIL+1)); }

# 4. Payment methods: create CASH_APP, assign to A (twice = idempotent),
#    confirm via GET /api/portals/:id; negatives: unknown method/portal.
code=$(curl -s -o "$TMP/method.json" -w "%{http_code}" -X POST "$BASE/api/payment-methods" "${AUTH[@]}" -H 'Content-Type: application/json' -d '{"type":"CASH_APP","label":"Cash App — APF","handle":"$MsCarterb"}')
check "4. create CASH_APP method" 201 "$code"
METHOD_ID=$(jget "$TMP/method.json" "d.data.method.id")
code=$(curl -s -o "$TMP/assign.json" -w "%{http_code}" -X POST "$BASE/api/portals/$PORTAL_A_ID/methods" "${AUTH[@]}" -H 'Content-Type: application/json' -d "{\"paymentMethodId\":\"$METHOD_ID\"}")
check "4. assign method to portal A" 201 "$code"
code=$(curl -s -o "$TMP/assign2.json" -w "%{http_code}" -X POST "$BASE/api/portals/$PORTAL_A_ID/methods" "${AUTH[@]}" -H 'Content-Type: application/json' -d "{\"paymentMethodId\":\"$METHOD_ID\"}")
check "4. re-assign is idempotent" 201 "$code"
code=$(curl -s -o "$TMP/portal-a-full.json" -w "%{http_code}" "$BASE/api/portals/$PORTAL_A_ID" "${AUTH[@]}")
check "4. GET portal A (assigned methods)" 200 "$code"
grep -q "CASH_APP" "$TMP/portal-a-full.json" && echo "PASS: 4. portal A shows the assigned CASH_APP method" || { echo "FAIL: 4. portal A is missing the assigned method"; FAIL=$((FAIL+1)); }
code=$(curl -s -o "$TMP/assign-bad.json" -w "%{http_code}" -X POST "$BASE/api/portals/$PORTAL_A_ID/methods" "${AUTH[@]}" -H 'Content-Type: application/json' -d '{"paymentMethodId":"no-such-method"}')
check "4. assign unknown method -> 404" 404 "$code"
code=$(curl -s -o "$TMP/assign-bad2.json" -w "%{http_code}" -X POST "$BASE/api/portals/no-such-portal/methods" "${AUTH[@]}" -H 'Content-Type: application/json' -d "{\"paymentMethodId\":\"$METHOD_ID\"}")
check "4. assign to unknown portal -> 404" 404 "$code"

# 5. `invite <email> to vip-coaching` -> POST /api/access/invite.
#    The code is returned ONCE; the grants list must never contain it.
code=$(curl -s -o "$TMP/invite.json" -w "%{http_code}" -X POST "$BASE/api/access/invite" "${AUTH[@]}" -H 'Content-Type: application/json' -d "{\"portalId\":\"$PORTAL_A_ID\",\"email\":\"$CUSTA_EMAIL\"}")
check "5. invite customer A" 201 "$code"
CODE_A=$(jget "$TMP/invite.json" "d.data.code")
echo "    invite code: $(mask "$CODE_A")"
if [[ "$CODE_A" =~ ^[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$ ]]; then echo "PASS: 5. code format is XXXX-XXXX-XXXX";
else echo "FAIL: 5. code format is wrong"; FAIL=$((FAIL+1)); fi
code=$(curl -s -o "$TMP/grants.json" -w "%{http_code}" "$BASE/api/access/portals/$PORTAL_A_ID/grants" "${AUTH[@]}")
check "5. list grants" 200 "$code"
grep -q "$CUSTA_EMAIL" "$TMP/grants.json" && echo "PASS: 5. grants list contains the customer email" || { echo "FAIL: 5. grants list is missing the email"; FAIL=$((FAIL+1)); }
if grep -q "$CODE_A" "$TMP/grants.json"; then echo "FAIL: 5. plain code leaked into the grants list"; FAIL=$((FAIL+1));
else echo "PASS: 5. plain code does NOT appear in the grants list"; fi

# 6. The customer can log in with the code (proves the invite works).
code=$(curl -s -o "$TMP/cust-login.json" -w "%{http_code}" -X POST "$BASE/api/access/login" -H 'Content-Type: application/json' -d "{\"portalSlug\":\"vip-coaching\",\"email\":\"$CUSTA_EMAIL\",\"code\":\"$CODE_A\"}")
check "6. customer login with the code" 200 "$code"
CUST_TOKEN=$(jget "$TMP/cust-login.json" "d.data.token")
echo "    customer token: $(mask "$CUST_TOKEN")"

# 7. `show traffic vip-coaching`: an unauthorised visit is logged with a
#    lookup; an authorised visit is logged WITHOUT one (Prompt 8 contract).
code=$(curl -s -o "$TMP/visit1.json" -w "%{http_code}" -X POST "$BASE/api/security/visit" -H 'Content-Type: application/json' -d '{"portalSlug":"vip-coaching","ip":"203.0.113.10","userAgent":"JarvisAndroidTest/1.0","path":"/pay","hasAccess":false}')
check "7. unauthorised visit logged" 201 "$code"
code=$(curl -s -o "$TMP/visit2.json" -w "%{http_code}" -X POST "$BASE/api/security/visit" -H 'Content-Type: application/json' -d "{\"portalSlug\":\"vip-coaching\",\"ip\":\"203.0.113.11\",\"userAgent\":\"JarvisAndroidTest/1.0\",\"path\":\"/pay\",\"email\":\"$CUSTA_EMAIL\"}")
check "7. authorised visit logged" 201 "$code"
code=$(curl -s -o "$TMP/traffic.json" -w "%{http_code}" "$BASE/api/security/portals/$PORTAL_A_ID/traffic?hasAccess=false&limit=100" "${AUTH[@]}")
check "7. traffic report (hasAccess=false)" 200 "$code"
grep -q "203.0.113.10" "$TMP/traffic.json" && echo "PASS: 7. report contains the unauthorised visit" || { echo "FAIL: 7. report is missing the unauthorised visit"; FAIL=$((FAIL+1)); }
if grep -q "203.0.113.11" "$TMP/traffic.json"; then echo "FAIL: 7. authorised visit leaked into the unauthorised report"; FAIL=$((FAIL+1));
else echo "PASS: 7. authorised visit is NOT in the unauthorised report"; fi
code=$(curl -s -o "$TMP/traffic-cust.json" -w "%{http_code}" "$BASE/api/security/portals/$PORTAL_A_ID/traffic" -H "Authorization: Bearer $CUST_TOKEN")
check "7. CUSTOMER traffic list -> 403" 403 "$code"

# 8. `block <email> on vip-coaching` -> POST /api/security/block.
code=$(curl -s -o "$TMP/block.json" -w "%{http_code}" -X POST "$BASE/api/security/block" "${AUTH[@]}" -H 'Content-Type: application/json' -d "{\"portalId\":\"$PORTAL_A_ID\",\"email\":\"$CUSTA_EMAIL\",\"reason\":\"Policy violation\"}")
check "8. block customer A" 201 "$code"
BLOCKED_ID=$(jget "$TMP/block.json" "d.data.blocked.id")
code=$(curl -s -o "$TMP/grants2.json" -w "%{http_code}" "$BASE/api/access/portals/$PORTAL_A_ID/grants" "${AUTH[@]}")
grep -q '"status":"TERMINATED"' "$TMP/grants2.json" && echo "PASS: 8. grant is TERMINATED" || { echo "FAIL: 8. grant is not TERMINATED"; FAIL=$((FAIL+1)); }
code=$(curl -s -o "$TMP/blocked-login.json" -w "%{http_code}" -X POST "$BASE/api/access/login" -H 'Content-Type: application/json' -d "{\"portalSlug\":\"vip-coaching\",\"email\":\"$CUSTA_EMAIL\",\"code\":\"$CODE_A\"}")
check "8. blocked login with good code -> 401" 401 "$code"
grep -q "Invalid credentials" "$TMP/blocked-login.json" && echo "PASS: 8. blocked login denial is generic" || { echo "FAIL: 8. blocked login denial is not generic"; FAIL=$((FAIL+1)); }

# 9. A blocked payer can never be paid (Prompt 8 contract, via the app flow):
#    ADMIN creates an invoice, then the manual confirm is refused.
code=$(curl -s -o "$TMP/invoice.json" -w "%{http_code}" -X POST "$BASE/api/invoices" "${AUTH[@]}" -H 'Content-Type: application/json' -d "{\"portalSlug\":\"vip-coaching\",\"payerEmail\":\"$CUSTA_EMAIL\",\"amount\":\"150.00\",\"currency\":\"USD\",\"paymentMethodId\":\"$METHOD_ID\",\"items\":[{\"description\":\"Coaching — November\",\"amount\":\"150.00\"}]}")
check "9. ADMIN creates invoice for blocked customer" 201 "$code"
INV_ID=$(jget "$TMP/invoice.json" "d.data.invoice.id")
expect "9. invoice number is JAR-1001" "JAR-1001" "$(jget "$TMP/invoice.json" "d.data.invoice.number")"
code=$(curl -s -o "$TMP/confirm.json" -w "%{http_code}" -X POST "$BASE/api/payments/$INV_ID/confirm" "${AUTH[@]}" -H 'Content-Type: application/json' -d '{"reference":"manual-test-ref","method":"CASH_APP","adminConfirm":true}')
check "9. blocked payer confirm -> 403" 403 "$code"
code=$(curl -s -o "$TMP/invoice-get.json" -w "%{http_code}" "$BASE/api/invoices/$INV_ID" "${AUTH[@]}")
check "9. invoice still readable" 200 "$code"
expect "9. blocked invoice stays PENDING" "PENDING" "$(jget "$TMP/invoice-get.json" "d.data.invoice.status")"

# 10. Unblock, then re-invite: the old code stays dead, the fresh one works.
code=$(curl -s -o "$TMP/unblock.json" -w "%{http_code}" -X POST "$BASE/api/security/unblock" "${AUTH[@]}" -H 'Content-Type: application/json' -d "{\"blockedId\":\"$BLOCKED_ID\"}")
check "10. unblock customer A" 200 "$code"
code=$(curl -s -o "$TMP/old-login.json" -w "%{http_code}" -X POST "$BASE/api/access/login" -H 'Content-Type: application/json' -d "{\"portalSlug\":\"vip-coaching\",\"email\":\"$CUSTA_EMAIL\",\"code\":\"$CODE_A\"}")
check "10. old code after unblock -> 401 (grant stays TERMINATED)" 401 "$code"
code=$(curl -s -o "$TMP/reinvite.json" -w "%{http_code}" -X POST "$BASE/api/access/invite" "${AUTH[@]}" -H 'Content-Type: application/json' -d "{\"portalId\":\"$PORTAL_A_ID\",\"email\":\"$CUSTA_EMAIL\"}")
check "10. re-invite" 201 "$code"
CODE_A2=$(jget "$TMP/reinvite.json" "d.data.code")
code=$(curl -s -o "$TMP/fresh-login.json" -w "%{http_code}" -X POST "$BASE/api/access/login" -H 'Content-Type: application/json' -d "{\"portalSlug\":\"vip-coaching\",\"email\":\"$CUSTA_EMAIL\",\"code\":\"$CODE_A2\"}")
check "10. fresh-code login" 200 "$code"

# 11. Negatives the app must survive with generic denials.
code=$(curl -s -o "$TMP/cust-portals.json" -w "%{http_code}" "$BASE/api/portals" -H "Authorization: Bearer $CUST_TOKEN")
check "11. CUSTOMER list portals -> 403" 403 "$code"
code=$(curl -s -o "$TMP/wrong-login.json" -w "%{http_code}" -X POST "$BASE/api/access/login" -H 'Content-Type: application/json' -d "{\"portalSlug\":\"vip-coaching\",\"email\":\"$CUSTA_EMAIL\",\"code\":\"AAAA-AAAA-AAAA\"}")
check "11. wrong-code login -> 401" 401 "$code"
grep -q "Invalid credentials" "$TMP/wrong-login.json" && echo "PASS: 11. wrong-code denial is generic" || { echo "FAIL: 11. wrong-code denial is not generic"; FAIL=$((FAIL+1)); }
code=$(curl -s -o "$TMP/invite-bad.json" -w "%{http_code}" -X POST "$BASE/api/access/invite" "${AUTH[@]}" -H 'Content-Type: application/json' -d '{"portalId":"no-such-portal","email":"x@test.local"}')
check "11. invite to unknown portal -> 404" 404 "$code"
code=$(curl -s -o "$TMP/block-bad.json" -w "%{http_code}" -X POST "$BASE/api/security/block" "${AUTH[@]}" -H 'Content-Type: application/json' -d '{"portalId":"no-such-portal","email":"x@test.local","reason":"Policy violation"}')
check "11. block on unknown portal -> 404" 404 "$code"
code=$(curl -s -o "$TMP/unassign.json" -w "%{http_code}" -X DELETE "$BASE/api/portals/$PORTAL_A_ID/methods/$METHOD_ID" "${AUTH[@]}")
check "11. unassign method" 200 "$code"
code=$(curl -s -o "$TMP/portal-a-full2.json" -w "%{http_code}" "$BASE/api/portals/$PORTAL_A_ID" "${AUTH[@]}")
if grep -q "CASH_APP" "$TMP/portal-a-full2.json"; then echo "FAIL: 11. method still assigned after unassign"; FAIL=$((FAIL+1));
else echo "PASS: 11. portal A has no assigned methods after unassign"; fi

# 12. DB check (absolute path, errors shown): grant ACTIVE after re-invite,
#     the unauthorised visit is stored, the invoice is still PENDING.
DB_JSON=$(PID="$PORTAL_A_ID" CUST_EMAIL="$CUSTA_EMAIL" DATABASE_URL="file:$DB_FILE" node -e "
  const { PrismaClient } = require('@prisma/client');
  (async () => {
    const p = new PrismaClient();
    const grant = await p.accessGrant.findFirst({ where: { portalId: process.env.PID, email: process.env.CUST_EMAIL } });
    const logs = await p.trafficLog.findMany({ where: { portalId: process.env.PID } });
    const unauth = logs.find(l => l.ip === '203.0.113.10' && !l.hasAccess);
    const invoice = await p.invoice.findFirst({ where: { portalId: process.env.PID } });
    console.log(JSON.stringify({
      grantStatus: grant ? grant.status : null,
      logCount: logs.length,
      unauthStored: !!unauth,
      invoiceStatus: invoice ? invoice.status : null,
    }));
    await p.\$disconnect();
  })();
" 2>/tmp/p10-db-err.log)
if [ -s /tmp/p10-db-err.log ]; then echo "FAIL: 12. DB query failed:"; cat /tmp/p10-db-err.log; FAIL=$((FAIL+1)); fi
expect "12. DB: grant is ACTIVE after re-invite" "ACTIVE" "$(node -e "console.log(JSON.parse(process.argv[1]).grantStatus)" "$DB_JSON" 2>/dev/null)"
expect "12. DB: unauthorised visit stored" "true" "$(node -e "console.log(JSON.parse(process.argv[1]).unauthStored)" "$DB_JSON" 2>/dev/null)"
expect "12. DB: invoice stays PENDING" "PENDING" "$(node -e "console.log(JSON.parse(process.argv[1]).invoiceStatus)" "$DB_JSON" 2>/dev/null)"

echo "== Summary: $FAIL failure(s) =="
[ "$FAIL" = 0 ] && echo "ALL PROMPT 10 ANDROID COMMAND CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$FAIL"
