#!/usr/bin/env bash
# Jarvis — Docker end-to-end verification (login → pay → receipt against the
# docker compose stack: server container + real Postgres).
#
# Usage (from server/): the stack must already be up — see
# .github/workflows/docker-e2e.yml, which runs `docker compose up --build`
# and then this script with BASE_URL=http://localhost:4000.
#
#   BASE_URL=http://localhost:4000 bash scripts/docker-e2e-test.sh
#
# This is the Prompt 9 portal flow (server/scripts/portal-e2e-test.sh)
# adapted for Docker: no test DB file, no dev server to start — the server
# under test is the container, and invoice state is verified through the
# API (GET invoice / receipt), not by reading a database file. The built
# portal is also served (vite preview) against the same BASE_URL and its
# bundle is grepped for localStorage (must be zero — the customer JWT
# lives in sessionStorage only). There is no headless browser here, so
# the UI itself is verified by exercising the exact API call sequence
# the UI performs, in order, plus serving the built app. Checks 21
# verify CORS: the portal preview origin is allowed (otherwise the
# browser blocks the login call — Prompt 15) and unrelated origins are
# not. If a case cannot be verified as written it is reported as a
# failure, never faked.
#
# Prerequisite: `npm ci` has been run in apps/portal/ (node_modules is
# gitignored). Tokens and codes are NEVER printed in full; only a masked
# prefix and the HTTP status are shown.
set -u
cd "$(dirname "$0")/.." # always run from server/
BASE="${BASE_URL:-http://localhost:4000}"
PORTAL_DIR="$(pwd)/../apps/portal"
PREVIEW_PORT="${PORTAL_PREVIEW_PORT:-4173}"
PREVIEW_URL="http://localhost:${PREVIEW_PORT}"
FAIL=0

mask() { # print first 10 chars of a secret + its length, nothing more
  local t="$1"
  printf '%s...(len %s)' "${t:0:10}" "${#t}"
}

check() { # check <name> <expected-status> <actual-status>
  if [ "$2" = "$3" ]; then echo "PASS: $1 (HTTP $3)";
  else echo "FAIL: $1 — expected HTTP $2, got HTTP $3"; FAIL=$((FAIL+1)); fi
}

jget() { # jget <json-file> <node-expr> — extract a field without printing secrets
  node -e "const d=require('$1'); console.log($2)" 2>/dev/null
}

ADMIN_EMAIL="docker-admin@test.local"
ADMIN_PASS="TestAdmin123!"
CUSTA_EMAIL="docker-customer-a@test.local"
CUSTB_EMAIL="docker-customer-b@test.local"

# 0. Health
code=$(curl -s -o /tmp/de2e-health.json -w "%{http_code}" "$BASE/health")
check "0. GET /health" 200 "$code"

# 1. Register the first ADMIN + login
code=$(curl -s -o /tmp/de2e-reg.json -w "%{http_code}" -X POST "$BASE/api/auth/register" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\",\"name\":\"Don\"}")
check "1. first register -> ADMIN" 201 "$code"
code=$(curl -s -o /tmp/de2e-admin-login.json -w "%{http_code}" -X POST "$BASE/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\"}")
check "1. admin login" 200 "$code"
ADMIN_TOKEN=$(jget /tmp/de2e-admin-login.json "d.data.token")
echo "admin token: $(mask "$ADMIN_TOKEN")"

# 2. Create portals A + B
code=$(curl -s -o /tmp/de2e-portal-a.json -w "%{http_code}" -X POST "$BASE/api/portals" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"Portal A","slug":"portal-a","currency":"USD"}')
check "2. create portal A" 201 "$code"
PORTAL_A_ID=$(jget /tmp/de2e-portal-a.json "d.data.portal.id")
code=$(curl -s -o /tmp/de2e-portal-b.json -w "%{http_code}" -X POST "$BASE/api/portals" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"Portal B","slug":"portal-b","currency":"USD"}')
check "2. create portal B" 201 "$code"
PORTAL_B_ID=$(jget /tmp/de2e-portal-b.json "d.data.portal.id")

# 3. Payment methods: CASH_APP assigned to A only, BTC assigned to B only
code=$(curl -s -o /tmp/de2e-m1.json -w "%{http_code}" -X POST "$BASE/api/payment-methods" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"type":"CASH_APP","label":"Cash App — APF","handle":"$MsCarterb"}')
check "3. create CASH_APP method" 201 "$code"
M1_ID=$(jget /tmp/de2e-m1.json "d.data.method.id")
code=$(curl -s -o /tmp/de2e-m2.json -w "%{http_code}" -X POST "$BASE/api/payment-methods" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"type":"BTC","label":"Bitcoin","handle":"bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq"}')
check "3. create BTC method" 201 "$code"
M2_ID=$(jget /tmp/de2e-m2.json "d.data.method.id")
code=$(curl -s -o /tmp/de2e-assign1.json -w "%{http_code}" -X POST "$BASE/api/portals/portal-a/methods" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"paymentMethodId\":\"$M1_ID\"}")
check "3. assign CASH_APP to portal A" 201 "$code"
code=$(curl -s -o /tmp/de2e-assign2.json -w "%{http_code}" -X POST "$BASE/api/portals/portal-b/methods" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"paymentMethodId\":\"$M2_ID\"}")
check "3. assign BTC to portal B" 201 "$code"

# 4. Invite + log in customer A (portal A)
code=$(curl -s -o /tmp/de2e-invite-a.json -w "%{http_code}" -X POST "$BASE/api/access/invite" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalId\":\"$PORTAL_A_ID\",\"email\":\"$CUSTA_EMAIL\"}")
check "4. invite customer A" 201 "$code"
CODE_A=$(jget /tmp/de2e-invite-a.json "d.data.code")
echo "customer A code: $(mask "$CODE_A")"
code=$(curl -s -o /tmp/de2e-login-a.json -w "%{http_code}" -X POST "$BASE/api/access/login" \
  -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"portal-a\",\"email\":\"$CUSTA_EMAIL\",\"code\":\"$CODE_A\"}")
check "4. customer A login (email + code)" 200 "$code"
CUSTA_TOKEN=$(jget /tmp/de2e-login-a.json "d.data.token")
echo "customer A token: $(mask "$CUSTA_TOKEN")"
LOGIN_PORTAL=$(jget /tmp/de2e-login-a.json "d.data.portal.slug")
[ "$LOGIN_PORTAL" = "portal-a" ] && echo "PASS: 4. login returns portal-a" || { echo "FAIL: 4. login portal is '$LOGIN_PORTAL'"; FAIL=$((FAIL+1)); }

# 5. Invite + log in customer B (portal B)
code=$(curl -s -o /tmp/de2e-invite-b.json -w "%{http_code}" -X POST "$BASE/api/access/invite" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalId\":\"$PORTAL_B_ID\",\"email\":\"$CUSTB_EMAIL\"}")
check "5. invite customer B" 201 "$code"
CODE_B=$(jget /tmp/de2e-invite-b.json "d.data.code")
code=$(curl -s -o /tmp/de2e-login-b.json -w "%{http_code}" -X POST "$BASE/api/access/login" \
  -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"portal-b\",\"email\":\"$CUSTB_EMAIL\",\"code\":\"$CODE_B\"}")
check "5. customer B login" 200 "$code"
CUSTB_TOKEN=$(jget /tmp/de2e-login-b.json "d.data.token")

# 6. Portal home: A shows exactly its own method (CASH_APP, no BTC)
code=$(curl -s -o /tmp/de2e-methods-a.json -w "%{http_code}" "$BASE/api/portals/portal-a/public-methods")
check "6. public methods portal A" 200 "$code"
MA_COUNT=$(jget /tmp/de2e-methods-a.json "d.data.methods.length")
MA_TYPE=$(jget /tmp/de2e-methods-a.json "d.data.methods[0].type")
if [ "$MA_COUNT" = "1" ] && [ "$MA_TYPE" = "CASH_APP" ]; then
  echo "PASS: 6. portal A shows exactly its CASH_APP method"
else echo "FAIL: 6. portal A methods: count=$MA_COUNT type=$MA_TYPE"; FAIL=$((FAIL+1)); fi

# 7. Portal home: B shows exactly its own method (BTC, no CASH_APP)
code=$(curl -s -o /tmp/de2e-methods-b.json -w "%{http_code}" "$BASE/api/portals/portal-b/public-methods")
check "7. public methods portal B" 200 "$code"
MB_COUNT=$(jget /tmp/de2e-methods-b.json "d.data.methods.length")
MB_TYPE=$(jget /tmp/de2e-methods-b.json "d.data.methods[0].type")
if [ "$MB_COUNT" = "1" ] && [ "$MB_TYPE" = "BTC" ]; then
  echo "PASS: 7. portal B shows exactly its BTC method"
else echo "FAIL: 7. portal B methods: count=$MB_COUNT type=$MB_TYPE"; FAIL=$((FAIL+1)); fi

# 8. Pay page: customer A creates an invoice on portal A (customer token)
code=$(curl -s -o /tmp/de2e-inv1.json -w "%{http_code}" -X POST "$BASE/api/invoices" \
  -H "Authorization: Bearer $CUSTA_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"portal-a\",\"payerEmail\":\"$CUSTA_EMAIL\",\"amount\":\"150.00\",\"currency\":\"USD\",\"items\":[{\"description\":\"Coaching — November\",\"amount\":\"150.00\"}],\"paymentMethodId\":\"$M1_ID\"}")
check "8. customer A creates invoice on portal A" 201 "$code"
INV1_ID=$(jget /tmp/de2e-inv1.json "d.data.invoice.id")
INV1_NUM=$(jget /tmp/de2e-inv1.json "d.data.invoice.number")
[ "$INV1_NUM" = "JAR-1001" ] && echo "PASS: 8. invoice number is JAR-1001" || { echo "FAIL: 8. invoice number is '$INV1_NUM'"; FAIL=$((FAIL+1)); }
PAYLOAD=$(jget /tmp/de2e-inv1.json "d.data.invoice.barcodePayload")
CODE128=$(jget /tmp/de2e-inv1.json "d.data.code128")
if [ "$PAYLOAD" = "JARVIS|JAR-1001|150.00|USD" ] && [ "$CODE128" = "$PAYLOAD" ]; then
  echo "PASS: 8. barcode payload == Code128 == JARVIS|JAR-1001|150.00|USD"
else echo "FAIL: 8. payload='$PAYLOAD' code128='$CODE128'"; FAIL=$((FAIL+1)); fi
QR=$(jget /tmp/de2e-inv1.json "d.data.qrDataUrl")
case "$QR" in "data:image/png;base64,"*) echo "PASS: 8. QR data URL present";; *) echo "FAIL: 8. QR data URL missing"; FAIL=$((FAIL+1));; esac
EMAIL_STATUS=$(jget /tmp/de2e-inv1.json "d.data.invoice.emailStatus")
[ "$EMAIL_STATUS" = "SIMULATED" ] && echo "PASS: 8. emailStatus is SIMULATED (barcode sent state)" || { echo "FAIL: 8. emailStatus is '$EMAIL_STATUS'"; FAIL=$((FAIL+1)); }

# 9. Customer A cannot create an invoice as someone else -> 403 generic
code=$(curl -s -o /tmp/de2e-inv-other.json -w "%{http_code}" -X POST "$BASE/api/invoices" \
  -H "Authorization: Bearer $CUSTA_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"portal-a\",\"payerEmail\":\"someone-else@test.local\",\"amount\":\"150.00\",\"currency\":\"USD\",\"items\":[{\"description\":\"X\",\"amount\":\"150.00\"}],\"paymentMethodId\":\"$M1_ID\"}")
check "9. customer A invoice as another payer -> 403" 403 "$code"
MSG9=$(jget /tmp/de2e-inv-other.json "d.error.message")
[ "$MSG9" = "Access denied" ] && echo "PASS: 9. denial is generic (Access denied)" || { echo "FAIL: 9. denial message is '$MSG9'"; FAIL=$((FAIL+1)); }

# 10. Customer B cannot create an invoice on portal A -> 403
code=$(curl -s -o /tmp/de2e-inv-cross.json -w "%{http_code}" -X POST "$BASE/api/invoices" \
  -H "Authorization: Bearer $CUSTB_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"portal-a\",\"payerEmail\":\"$CUSTB_EMAIL\",\"amount\":\"150.00\",\"currency\":\"USD\",\"items\":[{\"description\":\"X\",\"amount\":\"150.00\"}],\"paymentMethodId\":\"$M1_ID\"}")
check "10. customer B invoice on portal A -> 403" 403 "$code"

# 11. Customer A cannot use portal B's method on portal A -> 400
code=$(curl -s -o /tmp/de2e-inv-badmethod.json -w "%{http_code}" -X POST "$BASE/api/invoices" \
  -H "Authorization: Bearer $CUSTA_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"portal-a\",\"payerEmail\":\"$CUSTA_EMAIL\",\"amount\":\"150.00\",\"currency\":\"USD\",\"items\":[{\"description\":\"X\",\"amount\":\"150.00\"}],\"paymentMethodId\":\"$M2_ID\"}")
check "11. invoice with unassigned method -> 400" 400 "$code"

# 12. Receipt read: owner 200, other portal's customer 403
code=$(curl -s -o /tmp/de2e-get1.json -w "%{http_code}" "$BASE/api/invoices/$INV1_ID" \
  -H "Authorization: Bearer $CUSTA_TOKEN")
check "12. customer A reads own invoice" 200 "$code"
code=$(curl -s -o /tmp/de2e-get1b.json -w "%{http_code}" "$BASE/api/invoices/$INV1_ID" \
  -H "Authorization: Bearer $CUSTB_TOKEN")
check "12. customer B reads portal A invoice -> 403" 403 "$code"

# 13. Wrong code login -> 401 generic
code=$(curl -s -o /tmp/de2e-badlogin.json -w "%{http_code}" -X POST "$BASE/api/access/login" \
  -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"portal-a\",\"email\":\"$CUSTA_EMAIL\",\"code\":\"AAAA-BBBB-CCCC\"}")
check "13. wrong code login -> 401" 401 "$code"
MSG13=$(jget /tmp/de2e-badlogin.json "d.error.message")
[ "$MSG13" = "Invalid credentials" ] && echo "PASS: 13. login denial is generic (Invalid credentials)" || { echo "FAIL: 13. login denial message is '$MSG13'"; FAIL=$((FAIL+1)); }

# 14. Simulated payment: customer submits a reference -> 200, invoice stays PENDING
code=$(curl -s -o /tmp/de2e-confirm1.json -w "%{http_code}" -X POST "$BASE/api/payments/$INV1_ID/confirm" \
  -H "Authorization: Bearer $CUSTA_TOKEN" -H 'Content-Type: application/json' \
  -d '{"reference":"CASHAPP-RECEIPT-001"}')
check "14. customer submits payment reference -> 200" 200 "$code"
S14=$(jget /tmp/de2e-confirm1.json "d.data.invoice.status")
[ "$S14" = "PENDING" ] && echo "PASS: 14. invoice still PENDING after reference submit (reference alone never pays)" || { echo "FAIL: 14. invoice status is '$S14'"; FAIL=$((FAIL+1)); }

# 15. Simulated completion: Don's manual confirm (ADMIN, simulated mode) -> PAID + proofHash
code=$(curl -s -o /tmp/de2e-confirm2.json -w "%{http_code}" -X POST "$BASE/api/payments/$INV1_ID/confirm" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"reference":"CASHAPP-RECEIPT-001","adminConfirm":true}')
check "15. Don manual confirm (simulated) -> 200" 200 "$code"
S15=$(jget /tmp/de2e-confirm2.json "d.data.invoice.status")
P15=$(jget /tmp/de2e-confirm2.json "d.data.invoice.proofHash")
if [ "$S15" = "PAID" ] && [ -n "$P15" ] && [ "$P15" != "null" ]; then
  echo "PASS: 15. invoice PAID with proofHash set"
else echo "FAIL: 15. status='$S15' proofHash='$P15'"; FAIL=$((FAIL+1)); fi

# 16. Receipt: customer A reads the PAID invoice with proofHash (API proof of state)
code=$(curl -s -o /tmp/de2e-receipt.json -w "%{http_code}" "$BASE/api/invoices/$INV1_ID" \
  -H "Authorization: Bearer $CUSTA_TOKEN")
check "16. customer A reads receipt" 200 "$code"
S16=$(jget /tmp/de2e-receipt.json "d.data.invoice.status")
P16=$(jget /tmp/de2e-receipt.json "d.data.invoice.proofHash")
N16=$(jget /tmp/de2e-receipt.json "d.data.invoice.number")
if [ "$S16" = "PAID" ] && [ "$N16" = "JAR-1001" ] && [ -n "$P16" ] && [ "$P16" != "null" ]; then
  echo "PASS: 16. receipt shows JAR-1001 PAID with proofHash"
else echo "FAIL: 16. receipt status='$S16' number='$N16' proofHash='$P16'"; FAIL=$((FAIL+1)); fi

# 17. PDF download: customer token -> 200 application/pdf; no token -> 401; other customer -> 403
code=$(curl -s -o /tmp/de2e-receipt.pdf -w "%{http_code}" -D /tmp/de2e-pdf-headers.txt "$BASE/api/invoices/$INV1_ID/pdf" \
  -H "Authorization: Bearer $CUSTA_TOKEN")
check "17. customer A downloads PDF -> 200" 200 "$code"
CTYPE=$(grep -i '^content-type:' /tmp/de2e-pdf-headers.txt | tr -d '\r' | awk '{print $2}')
[ "$CTYPE" = "application/pdf" ] && echo "PASS: 17. PDF content-type is application/pdf" || { echo "FAIL: 17. content-type is '$CTYPE'"; FAIL=$((FAIL+1)); }
PDFSIZE=$(wc -c < /tmp/de2e-receipt.pdf)
if [ "$PDFSIZE" -gt 1000 ]; then echo "PASS: 17. PDF is $PDFSIZE bytes"; else echo "FAIL: 17. PDF is only $PDFSIZE bytes"; FAIL=$((FAIL+1)); fi
code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/api/invoices/$INV1_ID/pdf")
check "17. PDF without token -> 401" 401 "$code"
code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/api/invoices/$INV1_ID/pdf" \
  -H "Authorization: Bearer $CUSTB_TOKEN")
check "17. PDF for other portal's customer -> 403" 403 "$code"

# 18. Blocked customer (Prompt 8 contract): block A, login fails generically
code=$(curl -s -o /tmp/de2e-block.json -w "%{http_code}" -X POST "$BASE/api/security/block" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalId\":\"portal-a\",\"email\":\"$CUSTA_EMAIL\",\"reason\":\"Docker e2e test\"}")
check "18. block customer A" 201 "$code"
code=$(curl -s -o /tmp/de2e-blocked-login.json -w "%{http_code}" -X POST "$BASE/api/access/login" \
  -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"portal-a\",\"email\":\"$CUSTA_EMAIL\",\"code\":\"$CODE_A\"}")
check "18. blocked customer login -> 401" 401 "$code"
MSG18=$(jget /tmp/de2e-blocked-login.json "d.error.message")
[ "$MSG18" = "Invalid credentials" ] && echo "PASS: 18. blocked login denial is generic" || { echo "FAIL: 18. blocked login message is '$MSG18'"; FAIL=$((FAIL+1)); }

# 19. Blocked payer cannot pay: Don creates a second invoice for A, the
#     pre-block customer token confirms -> 403, invoice stays PENDING
code=$(curl -s -o /tmp/de2e-inv2.json -w "%{http_code}" -X POST "$BASE/api/invoices" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"portal-a\",\"payerEmail\":\"$CUSTA_EMAIL\",\"amount\":\"50.00\",\"currency\":\"USD\",\"items\":[{\"description\":\"Follow-up\",\"amount\":\"50.00\"}],\"paymentMethodId\":\"$M1_ID\"}")
check "19. admin creates second invoice for blocked customer" 201 "$code"
INV2_ID=$(jget /tmp/de2e-inv2.json "d.data.invoice.id")
INV2_NUM=$(jget /tmp/de2e-inv2.json "d.data.invoice.number")
[ "$INV2_NUM" = "JAR-1002" ] && echo "PASS: 19. second invoice is JAR-1002" || { echo "FAIL: 19. second invoice number is '$INV2_NUM'"; FAIL=$((FAIL+1)); }
code=$(curl -s -o /tmp/de2e-blocked-confirm.json -w "%{http_code}" -X POST "$BASE/api/payments/$INV2_ID/confirm" \
  -H "Authorization: Bearer $CUSTA_TOKEN" -H 'Content-Type: application/json' \
  -d '{"reference":"CASHAPP-RECEIPT-002"}')
check "19. blocked payer confirm -> 403" 403 "$code"
code=$(curl -s -o /tmp/de2e-get2.json -w "%{http_code}" "$BASE/api/invoices/$INV2_ID" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
S19=$(jget /tmp/de2e-get2.json "d.data.invoice.status")
[ "$S19" = "PENDING" ] && echo "PASS: 19. blocked invoice stays PENDING" || { echo "FAIL: 19. invoice status is '$S19'"; FAIL=$((FAIL+1)); }

# 20. Built portal: rebuild with VITE_API_URL pointing at this docker server,
#     serve it, fetch its pages, and grep the bundle for localStorage (0).
if [ ! -d "$PORTAL_DIR/node_modules" ]; then
  echo "FAIL: 20. apps/portal/node_modules missing — run npm ci in apps/portal first"; FAIL=$((FAIL+1))
else
  (cd "$PORTAL_DIR" && VITE_API_URL="$BASE" npm run build > /tmp/de2e-portal-build.log 2>&1)
  BUILD_EXIT=$?
  if [ "$BUILD_EXIT" != "0" ]; then echo "FAIL: 20. portal build failed (see /tmp/de2e-portal-build.log)"; FAIL=$((FAIL+1));
  else
    echo "PASS: 20. portal build passes (VITE_API_URL=$BASE)"
    (cd "$PORTAL_DIR" && npx vite preview --port "$PREVIEW_PORT" --strictPort > /tmp/de2e-preview.log 2>&1 & echo $! > /tmp/de2e-preview.pid)
    sleep 3
    code=$(curl -s -o /tmp/de2e-page.html -w "%{http_code}" "$PREVIEW_URL/")
    check "20. built portal serves /" 200 "$code"
    grep -q 'id="root"' /tmp/de2e-page.html && echo "PASS: 20. served page has the app root" || { echo "FAIL: 20. served page has no app root"; FAIL=$((FAIL+1)); }
    JS_ASSET=$(grep -o '/assets/index-[^"]*\.js' /tmp/de2e-page.html | head -1)
    if [ -n "$JS_ASSET" ]; then
      code=$(curl -s -o /tmp/de2e-bundle.js -w "%{http_code}" "$PREVIEW_URL$JS_ASSET")
      check "20. built JS bundle serves" 200 "$code"
      grep -q "$BASE" /tmp/de2e-bundle.js && echo "PASS: 20. bundle points at the docker server API ($BASE)" || { echo "FAIL: 20. bundle does not point at $BASE"; FAIL=$((FAIL+1)); }
    else echo "FAIL: 20. no JS asset found in served page"; FAIL=$((FAIL+1)); fi
    LS_HITS=$(grep -o "localStorage" "$PORTAL_DIR"/dist/assets/*.js | wc -l)
    if [ "$LS_HITS" = "0" ]; then echo "PASS: 20. built bundle has zero localStorage uses (sessionStorage only)";
    else echo "FAIL: 20. built bundle has $LS_HITS localStorage uses"; FAIL=$((FAIL+1)); fi
    SS_HITS=$(grep -o "sessionStorage" "$PORTAL_DIR"/dist/assets/*.js | wc -l)
    if [ "$SS_HITS" -gt 0 ]; then echo "PASS: 20. built bundle uses sessionStorage ($SS_HITS hits)";
    else echo "FAIL: 20. built bundle has no sessionStorage use"; FAIL=$((FAIL+1)); fi
    pkill -f "vite preview --port ${PREVIEW_PORT}" 2>/dev/null; sleep 2
    curl -s -m 3 "$PREVIEW_URL/" >/dev/null 2>&1 && { echo "FAIL: 20. preview server still running"; FAIL=$((FAIL+1)); } || echo "PASS: 20. preview server stopped"
  fi
fi

# 21. CORS (Prompt 15): the portal preview origin must be allowed or the
#     browser blocks the login call; an unrelated origin must not be.
#     A simple GET with an Origin header must echo that origin back in
#     Access-Control-Allow-Origin; the browser's preflight (OPTIONS with
#     Access-Control-Request-Method) must be answered the same way.
curl -s -D /tmp/de2e-cors-4173.txt -o /dev/null "$BASE/health" -H "Origin: http://localhost:${PREVIEW_PORT}"
ACO4173=$(grep -i '^access-control-allow-origin:' /tmp/de2e-cors-4173.txt | tr -d '\r' | awk '{print $2}')
if [ "$ACO4173" = "http://localhost:${PREVIEW_PORT}" ]; then
  echo "PASS: 21. CORS allows the portal preview origin (http://localhost:${PREVIEW_PORT})"
else echo "FAIL: 21. CORS allow-origin for preview is '$ACO4173'"; FAIL=$((FAIL+1)); fi
curl -s -D /tmp/de2e-cors-preflight.txt -o /dev/null -X OPTIONS "$BASE/api/access/login" \
  -H "Origin: http://localhost:${PREVIEW_PORT}" \
  -H "Access-Control-Request-Method: POST" -H "Access-Control-Request-Headers: content-type"
ACOPF=$(grep -i '^access-control-allow-origin:' /tmp/de2e-cors-preflight.txt | tr -d '\r' | awk '{print $2}')
if [ "$ACOPF" = "http://localhost:${PREVIEW_PORT}" ]; then
  echo "PASS: 21. CORS preflight for the login call is allowed from the preview origin"
else echo "FAIL: 21. CORS preflight allow-origin is '$ACOPF'"; FAIL=$((FAIL+1)); fi
curl -s -D /tmp/de2e-cors-evil.txt -o /dev/null "$BASE/health" -H "Origin: https://evil.example.com"
ACOEVIL=$(grep -i '^access-control-allow-origin:' /tmp/de2e-cors-evil.txt | tr -d '\r' | awk '{print $2}')
if [ -z "$ACOEVIL" ]; then
  echo "PASS: 21. CORS does not allow an unrelated origin (https://evil.example.com)"
else echo "FAIL: 21. CORS allowed unrelated origin: '$ACOEVIL'"; FAIL=$((FAIL+1)); fi

echo ""
echo "== Summary: $FAIL failure(s) =="
if [ "$FAIL" = "0" ]; then echo "ALL DOCKER E2E CHECKS PASSED"; exit 0;
else echo "SOME DOCKER E2E CHECKS FAILED"; exit 1; fi
