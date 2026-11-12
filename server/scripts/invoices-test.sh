#!/usr/bin/env bash
# Jarvis Prompt 6 — invoice + barcode (QR + Code128) + email verification.
#
# Usage (from server/) — SIMULATED email (default, no SMTP):
#   DATABASE_URL="file:$PWD/prisma/test-invoices.db" npx prisma migrate deploy
#   DATABASE_URL="file:$PWD/prisma/test-invoices.db" PORT=4001 npm run dev > /tmp/jarvis-p6-server.log 2>&1 &
#       JWT_SECRET is NOT exported here — it must come from server/.env
#       via dotenv.
#   BASE_URL=http://localhost:4001 bash scripts/invoices-test.sh
#
# SENT email run (local stub SMTP, no real credentials, no real mail):
#   Start the server with SMTP_HOST=127.0.0.1 SMTP_PORT=4025 SMTP_USER=stub
#   SMTP_PASS=stub SMTP_FROM="Jarvis <stub@test.local>" in its environment,
#   then run with SMTP_TEST=1 — the script starts scripts/stub-smtp.mjs
#   itself and asserts emailStatus SENT + the stub received the mail.
#   SMTP_TEST=1 BASE_URL=http://localhost:4001 bash scripts/invoices-test.sh
#
# The DATABASE_URL must be ABSOLUTE (Prompt 4 lesson). Prisma resolves a
# relative SQLite path against the schema dir (server/prisma/), not the
# cwd, so a relative URL in the server and a relative URL in this script
# can silently open two different files.
#
# Uses a separate test database (test-invoices.db) — never touches dev.db.
# Tokens, codes and the QR data URL are NEVER printed in full; only a
# masked prefix and the HTTP status are shown.
set -u
cd "$(dirname "$0")/.." # always run from server/ so dotenv finds ./.env
BASE="${BASE_URL:-http://localhost:4001}"
DB_FILE="$(pwd)/prisma/test-invoices.db"
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

ADMIN_EMAIL="prompt6-admin@test.local"
ADMIN_PASS="TestAdmin123!"
CUSTA_EMAIL="prompt6-customer-a@test.local"
CUSTB_EMAIL="prompt6-customer-b@test.local"

# With SMTP_TEST=1 the server is expected to have real (stub) SMTP env and
# the barcode email must come back SENT; otherwise it must be SIMULATED.
EXPECTED_EMAIL="SIMULATED"
STUB_PID=""
if [ "${SMTP_TEST:-0}" = "1" ]; then
  EXPECTED_EMAIL="SENT"
  rm -f /tmp/p6-stub-mail.txt /tmp/p6-stub.log
  STUB_SMTP_PORT=4025 STUB_SMTP_OUT=/tmp/p6-stub-mail.txt node scripts/stub-smtp.mjs > /tmp/p6-stub.log 2>&1 &
  STUB_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    (echo > /dev/tcp/127.0.0.1/4025) 2>/dev/null && break
    sleep 0.5
  done
  if ! (echo > /dev/tcp/127.0.0.1/4025) 2>/dev/null; then
    echo "FAIL: stub SMTP did not start (see /tmp/p6-stub.log)"; FAIL=$((FAIL+1))
  else echo "PASS: stub SMTP listening on 127.0.0.1:4025"; fi
fi
cleanup() {
  [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null
  rm -f /tmp/p6-*.json /tmp/p6-qr1.txt /tmp/p6-inv1.pdf /tmp/p6-pdf.h
}
trap cleanup EXIT

echo "== Prompt 6 invoice + barcode checks against $BASE (expect email $EXPECTED_EMAIL) =="

# 0. Health (no auth)
code=$(curl -s -o /tmp/p6-health.json -w "%{http_code}" "$BASE/health")
check "0. GET /health, no auth" 200 "$code"

# 1. First register -> ADMIN, login
code=$(curl -s -o /tmp/p6-reg.json -w "%{http_code}" -X POST "$BASE/api/auth/register" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\",\"name\":\"Prompt Six\"}")
check "1. first register -> 201" 201 "$code"
ADMIN_TOKEN=$(jget /tmp/p6-reg.json "d.data.token")
echo "   admin token: $(mask "$ADMIN_TOKEN")"

code=$(curl -s -o /tmp/p6-login.json -w "%{http_code}" -X POST "$BASE/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\"}")
check "1. login -> 200" 200 "$code"
ADMIN_TOKEN=$(jget /tmp/p6-login.json "d.data.token")

# 2. Create portals A + B
code=$(curl -s -o /tmp/p6-portal-a.json -w "%{http_code}" -X POST "$BASE/api/portals" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"Prompt Six Portal A","slug":"p6-portal-a","currency":"USD"}')
check "2. create portal A -> 201" 201 "$code"
PORTAL_A_ID=$(jget /tmp/p6-portal-a.json "d.data.portal.id")

code=$(curl -s -o /tmp/p6-portal-b.json -w "%{http_code}" -X POST "$BASE/api/portals" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"Prompt Six Portal B","slug":"p6-portal-b","currency":"USD"}')
check "2. create portal B -> 201" 201 "$code"
PORTAL_B_ID=$(jget /tmp/p6-portal-b.json "d.data.portal.id")

# 3. Create a CASH_APP method + assign to portal A; create an unassigned VENMO method
code=$(curl -s -o /tmp/p6-method.json -w "%{http_code}" -X POST "$BASE/api/payment-methods" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"type":"CASH_APP","label":"Cash App — Test","handle":"$P6Test"}')
check "3. create CASH_APP method -> 201" 201 "$code"
METHOD_ID=$(jget /tmp/p6-method.json "d.data.method.id")

code=$(curl -s -o /tmp/p6-assign.json -w "%{http_code}" -X POST "$BASE/api/portals/$PORTAL_A_ID/methods" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"paymentMethodId\":\"$METHOD_ID\"}")
check "3. assign method to portal A -> 201" 201 "$code"

code=$(curl -s -o /tmp/p6-method2.json -w "%{http_code}" -X POST "$BASE/api/payment-methods" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"type":"VENMO","label":"Venmo — Unassigned","handle":"@P6Unassigned"}')
check "3. create unassigned VENMO method -> 201" 201 "$code"
METHOD2_ID=$(jget /tmp/p6-method2.json "d.data.method.id")

# 4. Invite customers A + B, log them in (2 logins — under the 10/min limit)
code=$(curl -s -o /tmp/p6-invite-a.json -w "%{http_code}" -X POST "$BASE/api/access/invite" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalId\":\"$PORTAL_A_ID\",\"email\":\"$CUSTA_EMAIL\"}")
check "4. invite customer A -> 201" 201 "$code"
CODE_A=$(jget /tmp/p6-invite-a.json "d.data.code")

code=$(curl -s -o /tmp/p6-login-a.json -w "%{http_code}" -X POST "$BASE/api/access/login" \
  -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"p6-portal-a\",\"email\":\"$CUSTA_EMAIL\",\"code\":\"$CODE_A\"}")
check "4. customer A login -> 200" 200 "$code"
CUSTA_TOKEN=$(jget /tmp/p6-login-a.json "d.data.token")
echo "   customer A token: $(mask "$CUSTA_TOKEN")"

code=$(curl -s -o /tmp/p6-invite-b.json -w "%{http_code}" -X POST "$BASE/api/access/invite" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalId\":\"$PORTAL_B_ID\",\"email\":\"$CUSTB_EMAIL\"}")
check "4. invite customer B -> 201" 201 "$code"
CODE_B=$(jget /tmp/p6-invite-b.json "d.data.code")

code=$(curl -s -o /tmp/p6-login-b.json -w "%{http_code}" -X POST "$BASE/api/access/login" \
  -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"p6-portal-b\",\"email\":\"$CUSTB_EMAIL\",\"code\":\"$CODE_B\"}")
check "4. customer B login -> 200" 200 "$code"
CUSTB_TOKEN=$(jget /tmp/p6-login-b.json "d.data.token")

# 5. Create invoice 1 as ADMIN -> 201, JAR-1001, payload, QR, Code128, email status
code=$(curl -s -o /tmp/p6-inv1.json -w "%{http_code}" -X POST "$BASE/api/invoices" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"p6-portal-a\",\"payerEmail\":\"$CUSTA_EMAIL\",\"payerName\":\"P6 Customer\",\"amount\":\"150.00\",\"currency\":\"USD\",\"items\":[{\"description\":\"Coaching — November\",\"amount\":\"150.00\"}],\"paymentMethodId\":\"$METHOD_ID\"}")
check "5. create invoice 1 -> 201" 201 "$code"
NUM1=$(jget /tmp/p6-inv1.json "d.data.invoice.number")
[ "$NUM1" = "JAR-1001" ] && echo "PASS: 5. invoice 1 number is JAR-1001" || { echo "FAIL: 5. invoice 1 number is '$NUM1'"; FAIL=$((FAIL+1)); }
PAYLOAD1=$(jget /tmp/p6-inv1.json "d.data.invoice.barcodePayload")
[ "$PAYLOAD1" = "JARVIS|JAR-1001|150.00|USD" ] && echo "PASS: 5. payload is JARVIS|JAR-1001|150.00|USD" || { echo "FAIL: 5. payload is '$PAYLOAD1'"; FAIL=$((FAIL+1)); }
CODE128=$(jget /tmp/p6-inv1.json "d.data.code128")
[ "$CODE128" = "$PAYLOAD1" ] && echo "PASS: 5. code128 equals payload" || { echo "FAIL: 5. code128 is '$CODE128'"; FAIL=$((FAIL+1)); }
QR1=$(jget /tmp/p6-inv1.json "d.data.invoice.barcodeQrDataUrl")
QR_PREFIX="data:image/png;base64,"
if [[ "$QR1" == "$QR_PREFIX"* ]]; then echo "PASS: 5. QR data URL present";
else echo "FAIL: 5. QR data URL missing/wrong prefix"; FAIL=$((FAIL+1)); fi
STATUS1=$(jget /tmp/p6-inv1.json "d.data.invoice.status")
[ "$STATUS1" = "PENDING" ] && echo "PASS: 5. invoice 1 is PENDING (not paid on creation)" || { echo "FAIL: 5. invoice 1 status is '$STATUS1'"; FAIL=$((FAIL+1)); }
EMAIL1=$(jget /tmp/p6-inv1.json "d.data.invoice.emailStatus")
[ "$EMAIL1" = "$EXPECTED_EMAIL" ] && echo "PASS: 5. emailStatus is $EXPECTED_EMAIL" || { echo "FAIL: 5. emailStatus is '$EMAIL1', expected $EXPECTED_EMAIL"; FAIL=$((FAIL+1)); }
INV1_ID=$(jget /tmp/p6-inv1.json "d.data.invoice.id")
printf '%s' "$QR1" > /tmp/p6-qr1.txt

# 6. Decode the QR with a real decoder and assert it equals the payload exactly
DECODED=$(node scripts/decode-qr.mjs /tmp/p6-qr1.txt 2>/tmp/p6-decode-err.log)
if [ "$DECODED" = "$PAYLOAD1" ]; then
  echo "PASS: 6. QR decodes to exact payload: $DECODED"
else
  echo "FAIL: 6. QR decoded to '$DECODED', expected '$PAYLOAD1'"; cat /tmp/p6-decode-err.log; FAIL=$((FAIL+1))
fi

# 7. Create invoice 2 -> JAR-1002
code=$(curl -s -o /tmp/p6-inv2.json -w "%{http_code}" -X POST "$BASE/api/invoices" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"p6-portal-a\",\"payerEmail\":\"$CUSTA_EMAIL\",\"amount\":\"75.50\",\"currency\":\"USD\",\"items\":[{\"description\":\"Coaching — December\",\"amount\":\"75.50\"}],\"paymentMethodId\":\"$METHOD_ID\"}")
check "7. create invoice 2 -> 201" 201 "$code"
NUM2=$(jget /tmp/p6-inv2.json "d.data.invoice.number")
[ "$NUM2" = "JAR-1002" ] && echo "PASS: 7. invoice 2 number is JAR-1002" || { echo "FAIL: 7. invoice 2 number is '$NUM2'"; FAIL=$((FAIL+1)); }
INV2_ID=$(jget /tmp/p6-inv2.json "d.data.invoice.id")

# 7b. (Prompt 14) Create invoice 3 -> JAR-1003: the atomic counter
#      allocates sequentially, no duplicates. Restart continuation is
#      verified manually (see the header): stop the server, start it
#      again on the SAME test DB, create one more invoice — it must be
#      JAR-1004, because the counter lives in the DB, not memory.
code=$(curl -s -o /tmp/p6-inv3.json -w "%{http_code}" -X POST "$BASE/api/invoices" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"p6-portal-a\",\"payerEmail\":\"$CUSTA_EMAIL\",\"amount\":\"25.00\",\"currency\":\"USD\",\"items\":[{\"description\":\"Coaching — January\",\"amount\":\"25.00\"}],\"paymentMethodId\":\"$METHOD_ID\"}")
check "7b. create invoice 3 -> 201" 201 "$code"
NUM3=$(jget /tmp/p6-inv3.json "d.data.invoice.number")
[ "$NUM3" = "JAR-1003" ] && echo "PASS: 7b. invoice 3 number is JAR-1003" || { echo "FAIL: 7b. invoice 3 number is '$NUM3'"; FAIL=$((FAIL+1)); }
INV3_ID=$(jget /tmp/p6-inv3.json "d.data.invoice.id")

# 8. GET invoice as its customer -> 200; as another portal's customer -> 403; as ADMIN -> 200; unknown -> 404
code=$(curl -s -o /tmp/p6-get-a.json -w "%{http_code}" "$BASE/api/invoices/$INV1_ID" \
  -H "Authorization: Bearer $CUSTA_TOKEN")
check "8. GET invoice as its customer -> 200" 200 "$code"
code=$(curl -s -o /tmp/p6-get-b.json -w "%{http_code}" "$BASE/api/invoices/$INV1_ID" \
  -H "Authorization: Bearer $CUSTB_TOKEN")
check "8. GET invoice as other portal's customer -> 403" 403 "$code"
code=$(curl -s -o /tmp/p6-get-admin.json -w "%{http_code}" "$BASE/api/invoices/$INV1_ID" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "8. GET invoice as ADMIN -> 200" 200 "$code"
code=$(curl -s -o /tmp/p6-get-404.json -w "%{http_code}" "$BASE/api/invoices/does-not-exist" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "8. GET unknown invoice -> 404" 404 "$code"

# 9. GET pdf as customer A -> 200 application/pdf, real bytes, contains the invoice number
code=$(curl -s -D /tmp/p6-pdf.h -o /tmp/p6-inv1.pdf -w "%{http_code}" "$BASE/api/invoices/$INV1_ID/pdf" \
  -H "Authorization: Bearer $CUSTA_TOKEN")
check "9. GET pdf as customer -> 200" 200 "$code"
if grep -qi "content-type: application/pdf" /tmp/p6-pdf.h; then echo "PASS: 9. pdf content-type is application/pdf";
else echo "FAIL: 9. pdf content-type wrong"; grep -i "content-type" /tmp/p6-pdf.h; FAIL=$((FAIL+1)); fi
PDF_SIZE=$(stat -c%s /tmp/p6-inv1.pdf)
if [ "$PDF_SIZE" -gt 1000 ]; then echo "PASS: 9. pdf is $PDF_SIZE bytes";
else echo "FAIL: 9. pdf only $PDF_SIZE bytes"; FAIL=$((FAIL+1)); fi
# PDFKit compresses + hex-encodes the text, so plain grep cannot see it —
# scripts/check-pdf.mjs inflates the streams and decodes the text.
if node scripts/check-pdf.mjs /tmp/p6-inv1.pdf "JAR-1001" "150.00" "INVOICE RECEIPT" > /tmp/p6-pdf-check.log 2>&1; then
  echo "PASS: 9. pdf contains JAR-1001, 150.00 and INVOICE RECEIPT ($(cat /tmp/p6-pdf-check.log))"
else echo "FAIL: 9. pdf content check failed"; cat /tmp/p6-pdf-check.log; FAIL=$((FAIL+1)); fi
code=$(curl -s -o /tmp/p6-pdf-b.json -w "%{http_code}" "$BASE/api/invoices/$INV1_ID/pdf" \
  -H "Authorization: Bearer $CUSTB_TOKEN")
check "9. GET pdf as other portal's customer -> 403" 403 "$code"

# 10. Canonical list + deprecated alias (ADMIN), unknown portal -> 404
code=$(curl -s -o /tmp/p6-list.json -w "%{http_code}" "$BASE/api/portals/p6-portal-a/invoices" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "10. canonical list GET /api/portals/p6-portal-a/invoices -> 200" 200 "$code"
LIST_COUNT=$(node -e "console.log(require('/tmp/p6-list.json').data.invoices.length)" 2>/dev/null)
[ "$LIST_COUNT" = "3" ] && echo "PASS: 10. canonical list has 3 invoices" || { echo "FAIL: 10. canonical list has '$LIST_COUNT'"; FAIL=$((FAIL+1)); }
code=$(curl -s -o /tmp/p6-list-alias.json -w "%{http_code}" "$BASE/api/invoices/portals/$PORTAL_A_ID/list" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "10. alias list GET /api/invoices/portals/:id/list -> 200" 200 "$code"
ALIAS_COUNT=$(node -e "console.log(require('/tmp/p6-list-alias.json').data.invoices.length)" 2>/dev/null)
[ "$ALIAS_COUNT" = "3" ] && echo "PASS: 10. alias list has 3 invoices" || { echo "FAIL: 10. alias list has '$ALIAS_COUNT'"; FAIL=$((FAIL+1)); }
code=$(curl -s -o /tmp/p6-list-404.json -w "%{http_code}" "$BASE/api/portals/no-such-portal/invoices" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "10. canonical list unknown portal -> 404" 404 "$code"
code=$(curl -s -o /tmp/p6-list-404b.json -w "%{http_code}" "$BASE/api/invoices/portals/no-such-portal/list" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "10. alias list unknown portal -> 404" 404 "$code"

# 11. Bad invoice creates -> 400/404
code=$(curl -s -o /tmp/p6-bad1.json -w "%{http_code}" -X POST "$BASE/api/invoices" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"p6-portal-a\",\"payerEmail\":\"$CUSTA_EMAIL\",\"amount\":\"abc\",\"currency\":\"USD\",\"items\":[{\"description\":\"X\",\"amount\":\"1.00\"}],\"paymentMethodId\":\"$METHOD_ID\"}")
check "11. bad amount -> 400" 400 "$code"
code=$(curl -s -o /tmp/p6-bad2.json -w "%{http_code}" -X POST "$BASE/api/invoices" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"p6-portal-a\",\"payerEmail\":\"$CUSTA_EMAIL\",\"amount\":\"150.00\",\"currency\":\"US\",\"items\":[{\"description\":\"X\",\"amount\":\"1.00\"}],\"paymentMethodId\":\"$METHOD_ID\"}")
check "11. bad currency -> 400" 400 "$code"
code=$(curl -s -o /tmp/p6-bad3.json -w "%{http_code}" -X POST "$BASE/api/invoices" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"no-such-portal\",\"payerEmail\":\"$CUSTA_EMAIL\",\"amount\":\"150.00\",\"currency\":\"USD\",\"items\":[{\"description\":\"X\",\"amount\":\"1.00\"}],\"paymentMethodId\":\"$METHOD_ID\"}")
check "11. unknown portal -> 404" 404 "$code"
code=$(curl -s -o /tmp/p6-bad4.json -w "%{http_code}" -X POST "$BASE/api/invoices" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"p6-portal-a\",\"payerEmail\":\"$CUSTA_EMAIL\",\"amount\":\"150.00\",\"currency\":\"USD\",\"items\":[{\"description\":\"X\",\"amount\":\"1.00\"}],\"paymentMethodId\":\"$METHOD2_ID\"}")
check "11. unassigned method -> 400" 400 "$code"

# 12. (Prompt 14 — corrected) CUSTOMER create invoice: since Prompt 9 a
#     customer MAY create an invoice for their OWN portal as THEMSELVES
#     (-> 201, the old 403 expectation predates that fix and contradicts
#     portal-e2e-test.sh case 8). The negatives still hold: creating as
#     a different payer -> 403, and on another portal -> 403.
code=$(curl -s -o /tmp/p6-cust-create.json -w "%{http_code}" -X POST "$BASE/api/invoices" \
  -H "Authorization: Bearer $CUSTA_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"p6-portal-a\",\"payerEmail\":\"$CUSTA_EMAIL\",\"amount\":\"150.00\",\"currency\":\"USD\",\"items\":[{\"description\":\"X\",\"amount\":\"1.00\"}],\"paymentMethodId\":\"$METHOD_ID\"}")
check "12. CUSTOMER create invoice, own portal as self -> 201" 201 "$code"
NUMC=$(jget /tmp/p6-cust-create.json "d.data.invoice.number")
[ "$NUMC" = "JAR-1004" ] && echo "PASS: 12. customer-created invoice number is JAR-1004 (counter continues)" || { echo "FAIL: 12. customer-created invoice number is '$NUMC', expected JAR-1004"; FAIL=$((FAIL+1)); }
code=$(curl -s -o /tmp/p6-cust-create-other.json -w "%{http_code}" -X POST "$BASE/api/invoices" \
  -H "Authorization: Bearer $CUSTA_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"p6-portal-a\",\"payerEmail\":\"$CUSTB_EMAIL\",\"amount\":\"150.00\",\"currency\":\"USD\",\"items\":[{\"description\":\"X\",\"amount\":\"1.00\"}],\"paymentMethodId\":\"$METHOD_ID\"}")
check "12. CUSTOMER create invoice as another payer -> 403" 403 "$code"
code=$(curl -s -o /tmp/p6-cust-create-b.json -w "%{http_code}" -X POST "$BASE/api/invoices" \
  -H "Authorization: Bearer $CUSTB_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"p6-portal-a\",\"payerEmail\":\"$CUSTB_EMAIL\",\"amount\":\"150.00\",\"currency\":\"USD\",\"items\":[{\"description\":\"X\",\"amount\":\"1.00\"}],\"paymentMethodId\":\"$METHOD_ID\"}")
check "12. CUSTOMER B create invoice on portal A -> 403" 403 "$code"

# 13. SENT mode only: the stub must have received the barcode mail
if [ "${SMTP_TEST:-0}" = "1" ]; then
  sleep 1
  if [ -f /tmp/p6-stub-mail.txt ] && grep -a -q "JAR-1001" /tmp/p6-stub-mail.txt; then
    echo "PASS: 13. stub SMTP received mail containing JAR-1001"
  else echo "FAIL: 13. stub SMTP did not receive mail with JAR-1001"; FAIL=$((FAIL+1)); fi
  if [ -f /tmp/p6-stub-mail.txt ] && grep -a -q "JARVIS|JAR-1001|150.00|USD" /tmp/p6-stub-mail.txt; then
    echo "PASS: 13. stub mail contains the barcode payload"
  else echo "FAIL: 13. stub mail missing the barcode payload"; FAIL=$((FAIL+1)); fi
fi

echo "== Summary: $FAIL failure(s) =="
[ "$FAIL" = 0 ] && echo "ALL PROMPT 6 INVOICE CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$FAIL"
