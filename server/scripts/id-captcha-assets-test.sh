#!/usr/bin/env bash
# Jarvis Prompt 12 — ID verification uploads + reCAPTCHA before payment +
# portal file uploads (Don customises portals).
#
# Usage (from server/) — SIMULATED captcha mode (default, no reCAPTCHA keys):
#   DATABASE_URL="file:$PWD/prisma/test-p12.db" npx prisma migrate deploy
#   DATABASE_URL="file:$PWD/prisma/test-p12.db" PORT=4001 npm run dev > /tmp/jarvis-p12-server.log 2>&1 &
#       JWT_SECRET is NOT exported here — it must come from server/.env
#       via dotenv. Start the server with its log at $LOG_FILE below so
#       the receipt-email check can prove the receipt was queued.
#   BASE_URL=http://localhost:4001 bash scripts/id-captcha-assets-test.sh
#
# CONFIGURED captcha mode run (dummy secret, NO real key — Google rejects
# the token, or the call fails; either way the server must answer 400):
#   Start the server with RECAPTCHA_SECRET_KEY=dummy-secret in its
#   environment, plus the absolute DATABASE_URL with a FRESH db file
#   (e.g. test-p12-captcha.db), then run with CAPTCHA_TEST=1 — the
#   configured-mode cases run instead of the simulated ones. The DB check
#   must read the SAME file the server wrote, so pass it explicitly:
#   P12_DB_FILE="$PWD/prisma/test-p12-captcha.db" CAPTCHA_TEST=1 \
#     LOG_FILE=/tmp/jarvis-p12c-server.log BASE_URL=http://localhost:4001 \
#     bash scripts/id-captcha-assets-test.sh
#
# The DATABASE_URL must be ABSOLUTE (Prompt 4 lesson). Prisma resolves a
# relative SQLite path against the schema dir (server/prisma/), not the
# cwd, so a relative URL in the server and a relative URL in this script
# can silently open two different files.
#
# Uses a separate test database (test-p12.db) — never touches dev.db.
# Uploaded files land in server/uploads/ (gitignored) — they are test
# fixtures only and are never committed.
# Tokens and access codes are NEVER printed in full; only a masked
# prefix and the HTTP status are shown.
set -u
cd "$(dirname "$0")/.." # always run from server/ so dotenv finds ./.env
BASE="${BASE_URL:-http://localhost:4001}"
# The DB file the server was started with. Default is the simulated-run
# file; the configured run MUST pass its own file (see header) or the DB
# check would read a different (possibly empty) database.
DB_FILE="${P12_DB_FILE:-$(pwd)/prisma/test-p12.db}"
LOG_FILE="${LOG_FILE:-/tmp/jarvis-p12-server.log}"
CAPTCHA_MODE="${CAPTCHA_TEST:-0}"
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

# absent <name> <file> <string> — PASS when the string is NOT in the file
absent() {
  if grep -q "$3" "$2"; then echo "FAIL: $1 — '$3' leaked into the response"; FAIL=$((FAIL+1));
  else echo "PASS: $1"; fi
}

ADMIN_EMAIL="prompt12-admin@test.local"
ADMIN_PASS="TestAdmin123!"
CUSTA_EMAIL="prompt12-customer-a@test.local"
CUSTB_EMAIL="prompt12-customer-b@test.local"
CUSTC_EMAIL="prompt12-customer-c@test.local"

# --- fixtures: a 1x1 PNG, a minimal PDF, a text file, an 11 MB PNG ---
PNG_B64="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
printf '%s' "$PNG_B64" | base64 -d > /tmp/p12-front.png
printf '%s' "$PNG_B64" | base64 -d > /tmp/p12-back.png
printf '%s' "$PNG_B64" | base64 -d > /tmp/p12-selfie.png
printf '%%PDF-1.4\n1 0 obj\n<<>>\nendobj\ntrailer\n<<>>\n%%%%EOF\n' > /tmp/p12-doc.pdf
printf 'not an image, just text\n' > /tmp/p12-note.txt
truncate -s 11M /tmp/p12-big.png # sparse file, over the 10 MB limit

cleanup() {
  rm -f /tmp/p12-*.json /tmp/p12-img*.png /tmp/p12-img.hdr /tmp/p12-asset* /tmp/p12-db-err.log
}
trap cleanup EXIT

if [ "$CAPTCHA_MODE" = "1" ]; then
  echo "== Prompt 12 ID + captcha + assets checks against $BASE (CONFIGURED captcha mode, dummy secret) =="
else
  echo "== Prompt 12 ID + captcha + assets checks against $BASE (SIMULATED captcha mode) =="
fi

# 0. Health (no auth)
code=$(curl -s -o /tmp/p12-health.json -w "%{http_code}" "$BASE/health")
check "0. GET /health, no auth" 200 "$code"

# 1. First register -> ADMIN, login
code=$(curl -s -o /tmp/p12-reg.json -w "%{http_code}" -X POST "$BASE/api/auth/register" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\",\"name\":\"Prompt Twelve\"}")
check "1. first register -> 201" 201 "$code"
ADMIN_TOKEN=$(jget /tmp/p12-reg.json "d.data.token")
echo "   admin token: $(mask "$ADMIN_TOKEN")"

code=$(curl -s -o /tmp/p12-login.json -w "%{http_code}" -X POST "$BASE/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\"}")
check "1. login -> 200" 200 "$code"
ADMIN_TOKEN=$(jget /tmp/p12-login.json "d.data.token")

# 2. Create portals A + B
code=$(curl -s -o /tmp/p12-portal-a.json -w "%{http_code}" -X POST "$BASE/api/portals" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"Prompt Twelve Portal A","slug":"p12-portal-a","currency":"USD"}')
check "2. create portal A -> 201" 201 "$code"
PORTAL_A_ID=$(jget /tmp/p12-portal-a.json "d.data.portal.id")

code=$(curl -s -o /tmp/p12-portal-b.json -w "%{http_code}" -X POST "$BASE/api/portals" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"Prompt Twelve Portal B","slug":"p12-portal-b","currency":"USD"}')
check "2. create portal B -> 201" 201 "$code"
PORTAL_B_ID=$(jget /tmp/p12-portal-b.json "d.data.portal.id")

# 3. CASH_APP method, assigned to portal A
code=$(curl -s -o /tmp/p12-cash.json -w "%{http_code}" -X POST "$BASE/api/payment-methods" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"type":"CASH_APP","handle":"$MsCarterb","label":"Cash App"}')
check "3. create CASH_APP method -> 201" 201 "$code"
CASH_ID=$(jget /tmp/p12-cash.json "d.data.method.id")
code=$(curl -s -o /tmp/p12-assign.json -w "%{http_code}" -X POST "$BASE/api/portals/$PORTAL_A_ID/methods" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"paymentMethodId\":\"$CASH_ID\"}")
check "3. assign CASH_APP to portal A -> 201" 201 "$code"

# 4. Invite customers A + B to portal A, C to portal B; log each in
invite_login() { # invite_login <portal-id> <portal-slug> <email> <out-prefix> -> sets TOKEN var via eval
  local pid="$1" pslug="$2" email="$3" pfx="$4"
  code=$(curl -s -o "/tmp/p12-$pfx-invite.json" -w "%{http_code}" -X POST "$BASE/api/access/invite" \
    -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
    -d "{\"portalId\":\"$pid\",\"email\":\"$email\"}")
  check "4. invite $email -> 201" 201 "$code"
  local c
  c=$(jget "/tmp/p12-$pfx-invite.json" "d.data.code")
  code=$(curl -s -o "/tmp/p12-$pfx-login.json" -w "%{http_code}" -X POST "$BASE/api/access/login" \
    -H 'Content-Type: application/json' \
    -d "{\"portalSlug\":\"$pslug\",\"email\":\"$email\",\"code\":\"$c\"}")
  check "4. login $email -> 200" 200 "$code"
  eval "${pfx}_TOKEN=\$(jget /tmp/p12-$pfx-login.json \"d.data.token\")"
}
invite_login "$PORTAL_A_ID" "p12-portal-a" "$CUSTA_EMAIL" "custa"
invite_login "$PORTAL_A_ID" "p12-portal-a" "$CUSTB_EMAIL" "custb"
invite_login "$PORTAL_B_ID" "p12-portal-b" "$CUSTC_EMAIL" "custc"
CUSTA_TOKEN="$custa_TOKEN"; CUSTB_TOKEN="$custb_TOKEN"; CUSTC_TOKEN="$custc_TOKEN"
echo "   customer A token: $(mask "$CUSTA_TOKEN")"

# ============ 1. ID verification ============

# 5. A uploads ID (DRIVERS_LICENSE, front/back/selfie) -> 201 PENDING, no paths returned
code=$(curl -s -o /tmp/p12-id1.json -w "%{http_code}" -X POST "$BASE/api/portals/$PORTAL_A_ID/id-verification" \
  -H "Authorization: Bearer $CUSTA_TOKEN" \
  -F "idType=DRIVERS_LICENSE" -F "front=@/tmp/p12-front.png" -F "back=@/tmp/p12-back.png" -F "selfie=@/tmp/p12-selfie.png")
check "5. A uploads ID (drivers licence) -> 201" 201 "$code"
ID_STATUS=$(jget /tmp/p12-id1.json "d.data.verification.status")
[ "$ID_STATUS" = "PENDING" ] && echo "PASS: 5. verification status is PENDING" || { echo "FAIL: 5. status is '$ID_STATUS'"; FAIL=$((FAIL+1)); }
ID_TYPE=$(jget /tmp/p12-id1.json "d.data.verification.idType")
[ "$ID_TYPE" = "DRIVERS_LICENSE" ] && echo "PASS: 5. idType is DRIVERS_LICENSE" || { echo "FAIL: 5. idType is '$ID_TYPE'"; FAIL=$((FAIL+1)); }
ID_A_ID=$(jget /tmp/p12-id1.json "d.data.verification.id")
absent "5. no frontPath in the customer response" /tmp/p12-id1.json "frontPath"
absent "5. no backPath in the customer response" /tmp/p12-id1.json "backPath"
absent "5. no selfiePath in the customer response" /tmp/p12-id1.json "selfiePath"

# 6. A re-uploads with STATE_ID -> 201, resets to PENDING, new idType
code=$(curl -s -o /tmp/p12-id2.json -w "%{http_code}" -X POST "$BASE/api/portals/$PORTAL_A_ID/id-verification" \
  -H "Authorization: Bearer $CUSTA_TOKEN" \
  -F "idType=STATE_ID" -F "front=@/tmp/p12-front.png" -F "back=@/tmp/p12-back.png" -F "selfie=@/tmp/p12-selfie.png")
check "6. A re-uploads ID (state id) -> 201" 201 "$code"
ID2_STATUS=$(jget /tmp/p12-id2.json "d.data.verification.status")
ID2_TYPE=$(jget /tmp/p12-id2.json "d.data.verification.idType")
[ "$ID2_STATUS" = "PENDING" ] && [ "$ID2_TYPE" = "STATE_ID" ] && echo "PASS: 6. re-upload replaces the record and resets to PENDING (STATE_ID)" || { echo "FAIL: 6. status='$ID2_STATUS' idType='$ID2_TYPE'"; FAIL=$((FAIL+1)); }
ID_A_ID=$(jget /tmp/p12-id2.json "d.data.verification.id")

# 7. PASSPORT idType -> 400 (no passports, ever)
code=$(curl -s -o /tmp/p12-id-passport.json -w "%{http_code}" -X POST "$BASE/api/portals/$PORTAL_A_ID/id-verification" \
  -H "Authorization: Bearer $CUSTA_TOKEN" \
  -F "idType=PASSPORT" -F "front=@/tmp/p12-front.png" -F "back=@/tmp/p12-back.png" -F "selfie=@/tmp/p12-selfie.png")
check "7. idType PASSPORT -> 400" 400 "$code"

# 8. Missing selfie -> 400
code=$(curl -s -o /tmp/p12-id-missing.json -w "%{http_code}" -X POST "$BASE/api/portals/$PORTAL_A_ID/id-verification" \
  -H "Authorization: Bearer $CUSTA_TOKEN" \
  -F "idType=DRIVERS_LICENSE" -F "front=@/tmp/p12-front.png" -F "back=@/tmp/p12-back.png")
check "8. missing selfie image -> 400" 400 "$code"

# 9. Non-image file (text) -> 400
code=$(curl -s -o /tmp/p12-id-nonimg.json -w "%{http_code}" -X POST "$BASE/api/portals/$PORTAL_A_ID/id-verification" \
  -H "Authorization: Bearer $CUSTA_TOKEN" \
  -F "idType=DRIVERS_LICENSE" -F "front=@/tmp/p12-note.txt;type=text/plain" -F "back=@/tmp/p12-back.png" -F "selfie=@/tmp/p12-selfie.png")
check "9. non-image file (text) -> 400" 400 "$code"

# 10. Oversized image (11 MB) -> 400
code=$(curl -s -o /tmp/p12-id-big.json -w "%{http_code}" -X POST "$BASE/api/portals/$PORTAL_A_ID/id-verification" \
  -H "Authorization: Bearer $CUSTA_TOKEN" \
  -F "idType=DRIVERS_LICENSE" -F "front=@/tmp/p12-big.png" -F "back=@/tmp/p12-back.png" -F "selfie=@/tmp/p12-selfie.png")
check "10. oversized image (11 MB) -> 400" 400 "$code"

# 11. B (same portal, different email) uploads their own ID -> 201
code=$(curl -s -o /tmp/p12-id-b.json -w "%{http_code}" -X POST "$BASE/api/portals/$PORTAL_A_ID/id-verification" \
  -H "Authorization: Bearer $CUSTB_TOKEN" \
  -F "idType=NATIONAL_ID" -F "front=@/tmp/p12-front.png" -F "back=@/tmp/p12-back.png" -F "selfie=@/tmp/p12-selfie.png")
check "11. B uploads their own ID (national id) -> 201" 201 "$code"
ID_B_ID=$(jget /tmp/p12-id-b.json "d.data.verification.id")

# 12. C (portal B) uploads to portal A -> 403
code=$(curl -s -o /tmp/p12-id-c.json -w "%{http_code}" -X POST "$BASE/api/portals/$PORTAL_A_ID/id-verification" \
  -H "Authorization: Bearer $CUSTC_TOKEN" \
  -F "idType=DRIVERS_LICENSE" -F "front=@/tmp/p12-front.png" -F "back=@/tmp/p12-back.png" -F "selfie=@/tmp/p12-selfie.png")
check "12. C (other portal) uploads to portal A -> 403" 403 "$code"

# 13. A reads their own record -> 200 PENDING STATE_ID
code=$(curl -s -o /tmp/p12-id-me.json -w "%{http_code}" "$BASE/api/portals/$PORTAL_A_ID/id-verification/me" \
  -H "Authorization: Bearer $CUSTA_TOKEN")
check "13. A GET /me -> 200" 200 "$code"
ME_STATUS=$(jget /tmp/p12-id-me.json "d.data.verification.status")
ME_TYPE=$(jget /tmp/p12-id-me.json "d.data.verification.idType")
[ "$ME_STATUS" = "PENDING" ] && [ "$ME_TYPE" = "STATE_ID" ] && echo "PASS: 13. /me shows PENDING STATE_ID" || { echo "FAIL: 13. status='$ME_STATUS' idType='$ME_TYPE'"; FAIL=$((FAIL+1)); }

# 14. B fetches A's front image -> 403 (different email)
code=$(curl -s -o /tmp/p12-img-b.json -w "%{http_code}" "$BASE/api/portals/$PORTAL_A_ID/id-verification/$ID_A_ID/image/front" \
  -H "Authorization: Bearer $CUSTB_TOKEN")
check "14. B fetches A's front image -> 403" 403 "$code"

# 15. A fetches their own front image -> 200 image/png, non-empty
code=$(curl -s -o /tmp/p12-img-a.png -D /tmp/p12-img.hdr -w "%{http_code}" "$BASE/api/portals/$PORTAL_A_ID/id-verification/$ID_A_ID/image/front" \
  -H "Authorization: Bearer $CUSTA_TOKEN")
check "15. A fetches their own front image -> 200" 200 "$code"
IMG_CT=$(grep -i '^content-type:' /tmp/p12-img.hdr | tr -d '\r' | awk '{print $2}')
[ "$IMG_CT" = "image/png" ] && echo "PASS: 15. image content-type is image/png" || { echo "FAIL: 15. image content-type is '$IMG_CT'"; FAIL=$((FAIL+1)); }
[ -s /tmp/p12-img-a.png ] && echo "PASS: 15. image file is non-empty" || { echo "FAIL: 15. image file is empty"; FAIL=$((FAIL+1)); }

# 16. ADMIN lists portal A verifications -> 200, two records, no paths
code=$(curl -s -o /tmp/p12-id-list.json -w "%{http_code}" "$BASE/api/portals/$PORTAL_A_ID/id-verification" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "16. ADMIN lists portal A verifications -> 200" 200 "$code"
LIST_N=$(jget /tmp/p12-id-list.json "d.data.verifications.length")
[ "$LIST_N" = "2" ] && echo "PASS: 16. list has 2 verifications (A + B)" || { echo "FAIL: 16. list length is '$LIST_N'"; FAIL=$((FAIL+1)); }
absent "16. no frontPath in the admin list" /tmp/p12-id-list.json "frontPath"

# 17. ADMIN fetches A's front image -> 200 image/png
code=$(curl -s -o /tmp/p12-img-admin.png -D /tmp/p12-img.hdr -w "%{http_code}" "$BASE/api/portals/$PORTAL_A_ID/id-verification/$ID_A_ID/image/front" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "17. ADMIN fetches A's front image -> 200" 200 "$code"
IMG_CT=$(grep -i '^content-type:' /tmp/p12-img.hdr | tr -d '\r' | awk '{print $2}')
[ "$IMG_CT" = "image/png" ] && echo "PASS: 17. admin image content-type is image/png" || { echo "FAIL: 17. image content-type is '$IMG_CT'"; FAIL=$((FAIL+1)); }

# 18. ADMIN reviews A VERIFIED -> 200, status VERIFIED, reviewer set
code=$(curl -s -o /tmp/p12-id-review.json -w "%{http_code}" -X POST "$BASE/api/portals/$PORTAL_A_ID/id-verification/$ID_A_ID/review" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"status":"VERIFIED"}')
check "18. ADMIN reviews A VERIFIED -> 200" 200 "$code"
REV_STATUS=$(jget /tmp/p12-id-review.json "d.data.verification.status")
REV_BY=$(jget /tmp/p12-id-review.json "d.data.verification.reviewedById")
[ "$REV_STATUS" = "VERIFIED" ] && [ -n "$REV_BY" ] && [ "$REV_BY" != "null" ] && echo "PASS: 18. status VERIFIED with reviewer set" || { echo "FAIL: 18. status='$REV_STATUS' reviewedById='$REV_BY'"; FAIL=$((FAIL+1)); }

# 19. A /me now shows VERIFIED
code=$(curl -s -o /tmp/p12-id-me2.json -w "%{http_code}" "$BASE/api/portals/$PORTAL_A_ID/id-verification/me" \
  -H "Authorization: Bearer $CUSTA_TOKEN")
check "19. A GET /me after review -> 200" 200 "$code"
ME2_STATUS=$(jget /tmp/p12-id-me2.json "d.data.verification.status")
[ "$ME2_STATUS" = "VERIFIED" ] && echo "PASS: 19. /me shows VERIFIED" || { echo "FAIL: 19. status is '$ME2_STATUS'"; FAIL=$((FAIL+1)); }

# 20. Review with a bad status -> 400
code=$(curl -s -o /tmp/p12-id-review-bad.json -w "%{http_code}" -X POST "$BASE/api/portals/$PORTAL_A_ID/id-verification/$ID_A_ID/review" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"status":"MAYBE"}')
check "20. review with bad status -> 400" 400 "$code"

# 21. Review unknown id -> 404
code=$(curl -s -o /tmp/p12-id-review-404.json -w "%{http_code}" -X POST "$BASE/api/portals/$PORTAL_A_ID/id-verification/no-such-id/review" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"status":"VERIFIED"}')
check "21. review unknown id -> 404" 404 "$code"

# 22. CUSTOMER B tries to review -> 403
code=$(curl -s -o /tmp/p12-id-review-cust.json -w "%{http_code}" -X POST "$BASE/api/portals/$PORTAL_A_ID/id-verification/$ID_B_ID/review" \
  -H "Authorization: Bearer $CUSTB_TOKEN" -H 'Content-Type: application/json' \
  -d '{"status":"VERIFIED"}')
check "22. customer review attempt -> 403" 403 "$code"

# 23. Unknown image field -> 404
code=$(curl -s -o /tmp/p12-img-field.json -w "%{http_code}" "$BASE/api/portals/$PORTAL_A_ID/id-verification/$ID_A_ID/image/passport" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "23. image with unknown field -> 404" 404 "$code"

# ============ 2. reCAPTCHA before payment ============

# 24. B (PENDING — never reviewed) creates an invoice: payment is NOT
#     blocked by verification.
code=$(curl -s -o /tmp/p12-inv1.json -w "%{http_code}" -X POST "$BASE/api/invoices" \
  -H "Authorization: Bearer $CUSTB_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"p12-portal-a\",\"payerEmail\":\"$CUSTB_EMAIL\",\"amount\":\"150.00\",\"currency\":\"USD\",\"items\":[{\"description\":\"Coaching — Jan\",\"amount\":\"150.00\"}],\"paymentMethodId\":\"$CASH_ID\"}")
check "24. B (unverified) creates invoice -> 201" 201 "$code"
NUM1=$(jget /tmp/p12-inv1.json "d.data.invoice.number")
[ "$NUM1" = "JAR-1001" ] && echo "PASS: 24. invoice number is JAR-1001" || { echo "FAIL: 24. invoice number is '$NUM1'"; FAIL=$((FAIL+1)); }
INV1_ID=$(jget /tmp/p12-inv1.json "d.data.invoice.id")

if [ "$CAPTCHA_MODE" = "1" ]; then
  # 25c. Configured mode: customer submit without token -> 400
  code=$(curl -s -o /tmp/p12-cap-notoken.json -w "%{http_code}" -X POST "$BASE/api/payments/$INV1_ID/confirm" \
    -H "Authorization: Bearer $CUSTB_TOKEN" -H 'Content-Type: application/json' \
    -d '{"reference":"CashAppPayment123"}')
  check "25c. configured: customer submit without captcha token -> 400" 400 "$code"
  # 26c. Configured mode: garbage token -> 400 (Google rejects it, or the call fails — either way, rejected)
  code=$(curl -s -o /tmp/p12-cap-garbage.json -w "%{http_code}" -X POST "$BASE/api/payments/$INV1_ID/confirm" \
    -H "Authorization: Bearer $CUSTB_TOKEN" -H 'Content-Type: application/json' \
    -d '{"reference":"CashAppPayment123","captchaToken":"garbage-token-not-from-google"}')
  check "26c. configured: customer submit with garbage captcha token -> 400" 400 "$code"
else
  # 25s. Simulated mode: customer submit without token succeeds and says simulated
  code=$(curl -s -o /tmp/p12-cap-sim.json -w "%{http_code}" -X POST "$BASE/api/payments/$INV1_ID/confirm" \
    -H "Authorization: Bearer $CUSTB_TOKEN" -H 'Content-Type: application/json' \
    -d '{"reference":"CashAppPayment123"}')
  check "25s. simulated: customer submit without captcha token -> 200" 200 "$code"
  CAP_SIM=$(jget /tmp/p12-cap-sim.json "d.data.captcha.simulated")
  [ "$CAP_SIM" = "true" ] && echo "PASS: 25s. response says captcha.simulated=true" || { echo "FAIL: 25s. captcha.simulated is '$CAP_SIM'"; FAIL=$((FAIL+1)); }
  CAP_REQ=$(jget /tmp/p12-cap-sim.json "d.data.captcha.required")
  [ "$CAP_REQ" = "false" ] && echo "PASS: 25s. response says captcha.required=false" || { echo "FAIL: 25s. captcha.required is '$CAP_REQ'"; FAIL=$((FAIL+1)); }
fi

# 27. Invoice still PENDING after the customer submit (both modes)
code=$(curl -s -o /tmp/p12-inv1-get.json -w "%{http_code}" "$BASE/api/invoices/$INV1_ID" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "27. GET invoice after customer submit -> 200" 200 "$code"
INV1_STATUS=$(jget /tmp/p12-inv1-get.json "d.data.invoice.status")
[ "$INV1_STATUS" = "PENDING" ] && echo "PASS: 27. invoice still PENDING (reference alone never pays)" || { echo "FAIL: 27. invoice status is '$INV1_STATUS'"; FAIL=$((FAIL+1)); }

# 28. ADMIN manual confirm needs NO captcha -> 200 PAID + proofHash (both modes)
code=$(curl -s -o /tmp/p12-cap-manual.json -w "%{http_code}" -X POST "$BASE/api/payments/$INV1_ID/confirm" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"reference":"CashAppPayment123","adminConfirm":true}')
check "28. ADMIN manual confirm (no captcha) -> 200" 200 "$code"
MAN_STATUS=$(jget /tmp/p12-cap-manual.json "d.data.invoice.status")
[ "$MAN_STATUS" = "PAID" ] && echo "PASS: 28. invoice PAID by Don's manual confirm" || { echo "FAIL: 28. invoice status is '$MAN_STATUS'"; FAIL=$((FAIL+1)); }
MAN_PROOF=$(jget /tmp/p12-cap-manual.json "d.data.invoice.proofHash")
[ -n "$MAN_PROOF" ] && [ "$MAN_PROOF" != "null" ] && echo "PASS: 28. PAID invoice has a proofHash" || { echo "FAIL: 28. proofHash missing"; FAIL=$((FAIL+1)); }

# 29. B reads the receipt -> 200 PAID
code=$(curl -s -o /tmp/p12-receipt.json -w "%{http_code}" "$BASE/api/invoices/$INV1_ID" \
  -H "Authorization: Bearer $CUSTB_TOKEN")
check "29. B reads the receipt -> 200" 200 "$code"
REC_STATUS=$(jget /tmp/p12-receipt.json "d.data.invoice.status")
[ "$REC_STATUS" = "PAID" ] && echo "PASS: 29. receipt shows PAID" || { echo "FAIL: 29. receipt status is '$REC_STATUS'"; FAIL=$((FAIL+1)); }

# ============ 3. Portal file uploads (Don customises portals) ============

# 30. ADMIN uploads a LOGO -> 201, no storedPath in the response
code=$(curl -s -o /tmp/p12-asset-logo.json -w "%{http_code}" -X POST "$BASE/api/portals/$PORTAL_A_ID/assets" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -F "kind=LOGO" -F "file=@/tmp/p12-front.png")
check "30. ADMIN uploads LOGO -> 201" 201 "$code"
LOGO_KIND=$(jget /tmp/p12-asset-logo.json "d.data.asset.kind")
[ "$LOGO_KIND" = "LOGO" ] && echo "PASS: 30. asset kind is LOGO" || { echo "FAIL: 30. kind is '$LOGO_KIND'"; FAIL=$((FAIL+1)); }
LOGO_ID=$(jget /tmp/p12-asset-logo.json "d.data.asset.id")
absent "30. no storedPath in the asset response" /tmp/p12-asset-logo.json "storedPath"

# 31. ADMIN uploads a BANNER -> 201
code=$(curl -s -o /tmp/p12-asset-banner.json -w "%{http_code}" -X POST "$BASE/api/portals/$PORTAL_A_ID/assets" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -F "kind=BANNER" -F "file=@/tmp/p12-back.png")
check "31. ADMIN uploads BANNER -> 201" 201 "$code"
BANNER_ID=$(jget /tmp/p12-asset-banner.json "d.data.asset.id")

# 32. ADMIN uploads a DOCUMENT (pdf) -> 201
code=$(curl -s -o /tmp/p12-asset-doc.json -w "%{http_code}" -X POST "$BASE/api/portals/$PORTAL_A_ID/assets" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -F "kind=DOCUMENT" -F "file=@/tmp/p12-doc.pdf;type=application/pdf")
check "32. ADMIN uploads DOCUMENT (pdf) -> 201" 201 "$code"
DOC_ID=$(jget /tmp/p12-asset-doc.json "d.data.asset.id")

# 33. A second LOGO replaces the first: old file 404s, list has exactly one LOGO
code=$(curl -s -o /tmp/p12-asset-logo2.json -w "%{http_code}" -X POST "$BASE/api/portals/$PORTAL_A_ID/assets" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -F "kind=LOGO" -F "file=@/tmp/p12-selfie.png")
check "33. ADMIN uploads a second LOGO -> 201" 201 "$code"
LOGO2_ID=$(jget /tmp/p12-asset-logo2.json "d.data.asset.id")
code=$(curl -s -o /tmp/p12-asset-oldlogo.json -w "%{http_code}" "$BASE/api/portals/p12-portal-a/assets/$LOGO_ID/file")
check "33. old LOGO file after replacement -> 404" 404 "$code"
code=$(curl -s -o /tmp/p12-asset-list1.json -w "%{http_code}" "$BASE/api/portals/$PORTAL_A_ID/assets" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
LOGO_N=$(node -e "const d=require('/tmp/p12-asset-list1.json'); console.log(d.data.assets.filter(a=>a.kind==='LOGO').length)" 2>/dev/null)
[ "$LOGO_N" = "1" ] && echo "PASS: 33. exactly one LOGO remains after replacement" || { echo "FAIL: 33. LOGO count is '$LOGO_N'"; FAIL=$((FAIL+1)); }

# 34. Executable (.exe) -> 400
code=$(curl -s -o /tmp/p12-asset-exe.json -w "%{http_code}" -X POST "$BASE/api/portals/$PORTAL_A_ID/assets" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -F "kind=FILE" -F "file=@/tmp/p12-note.txt;type=application/octet-stream;filename=evil.exe")
check "34. executable (.exe) upload -> 400" 400 "$code"

# 35. Image filed as DOCUMENT -> 400 (kind/type mismatch)
code=$(curl -s -o /tmp/p12-asset-mismatch1.json -w "%{http_code}" -X POST "$BASE/api/portals/$PORTAL_A_ID/assets" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -F "kind=DOCUMENT" -F "file=@/tmp/p12-front.png")
check "35. image filed as DOCUMENT -> 400" 400 "$code"

# 36. Document filed as LOGO -> 400
code=$(curl -s -o /tmp/p12-asset-mismatch2.json -w "%{http_code}" -X POST "$BASE/api/portals/$PORTAL_A_ID/assets" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -F "kind=LOGO" -F "file=@/tmp/p12-doc.pdf;type=application/pdf")
check "36. document filed as LOGO -> 400" 400 "$code"

# 37. ADMIN lists assets -> 200, three assets (LOGO + BANNER + DOCUMENT)
code=$(curl -s -o /tmp/p12-asset-list.json -w "%{http_code}" "$BASE/api/portals/$PORTAL_A_ID/assets" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "37. ADMIN lists portal A assets -> 200" 200 "$code"
ASSET_N=$(jget /tmp/p12-asset-list.json "d.data.assets.length")
[ "$ASSET_N" = "3" ] && echo "PASS: 37. list has 3 assets" || { echo "FAIL: 37. list length is '$ASSET_N'"; FAIL=$((FAIL+1)); }
absent "37. no storedPath in the asset list" /tmp/p12-asset-list.json "storedPath"

# 38. GET portal A (admin) includes logoAssetId + bannerAssetId
code=$(curl -s -o /tmp/p12-portal-a-get.json -w "%{http_code}" "$BASE/api/portals/$PORTAL_A_ID" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "38. GET portal A -> 200" 200 "$code"
P_LOGO=$(jget /tmp/p12-portal-a-get.json "d.data.portal.logoAssetId")
P_BANNER=$(jget /tmp/p12-portal-a-get.json "d.data.portal.bannerAssetId")
[ "$P_LOGO" = "$LOGO2_ID" ] && [ "$P_BANNER" = "$BANNER_ID" ] && echo "PASS: 38. portal read carries logoAssetId + bannerAssetId" || { echo "FAIL: 38. logo='$P_LOGO' (want $LOGO2_ID) banner='$P_BANNER' (want $BANNER_ID)"; FAIL=$((FAIL+1)); }

# 39. Public portal read carries logo/banner/documents
code=$(curl -s -o /tmp/p12-public.json -w "%{http_code}" "$BASE/api/portals/p12-portal-a/public-methods")
check "39. GET public-methods -> 200" 200 "$code"
PUB_LOGO=$(jget /tmp/p12-public.json "d.data.logoAssetId")
PUB_DOCS=$(jget /tmp/p12-public.json "d.data.documents.length")
[ "$PUB_LOGO" = "$LOGO2_ID" ] && [ "$PUB_DOCS" = "1" ] && echo "PASS: 39. public read carries logoAssetId + 1 document" || { echo "FAIL: 39. logo='$PUB_LOGO' documents='$PUB_DOCS'"; FAIL=$((FAIL+1)); }
PUB_DOC_NAME=$(jget /tmp/p12-public.json "d.data.documents[0].originalName")
[ "$PUB_DOC_NAME" = "p12-doc.pdf" ] && echo "PASS: 39. document listed as p12-doc.pdf" || { echo "FAIL: 39. document name is '$PUB_DOC_NAME'"; FAIL=$((FAIL+1)); }

# 40. Public file fetch: LOGO -> 200 image/png, inline
code=$(curl -s -o /tmp/p12-asset-logo-dl.png -D /tmp/p12-asset.hdr -w "%{http_code}" "$BASE/api/portals/p12-portal-a/assets/$LOGO2_ID/file")
check "40. public LOGO file -> 200" 200 "$code"
A_CT=$(grep -i '^content-type:' /tmp/p12-asset.hdr | tr -d '\r' | awk '{print $2}')
A_CD=$(grep -i '^content-disposition:' /tmp/p12-asset.hdr | tr -d '\r')
[ "$A_CT" = "image/png" ] && echo "PASS: 40. LOGO content-type is image/png" || { echo "FAIL: 40. LOGO content-type is '$A_CT'"; FAIL=$((FAIL+1)); }
case "$A_CD" in *inline*) echo "PASS: 40. LOGO disposition is inline";; *) echo "FAIL: 40. LOGO disposition is '$A_CD'"; FAIL=$((FAIL+1));; esac
[ -s /tmp/p12-asset-logo-dl.png ] && echo "PASS: 40. LOGO download is non-empty" || { echo "FAIL: 40. LOGO download is empty"; FAIL=$((FAIL+1)); }

# 41. Public file fetch: DOCUMENT -> 200 application/pdf, attachment
code=$(curl -s -o /tmp/p12-asset-doc-dl -D /tmp/p12-asset.hdr -w "%{http_code}" "$BASE/api/portals/p12-portal-a/assets/$DOC_ID/file")
check "41. public DOCUMENT file -> 200" 200 "$code"
A_CT=$(grep -i '^content-type:' /tmp/p12-asset.hdr | tr -d '\r' | awk '{print $2}')
A_CD=$(grep -i '^content-disposition:' /tmp/p12-asset.hdr | tr -d '\r')
[ "$A_CT" = "application/pdf" ] && echo "PASS: 41. DOCUMENT content-type is application/pdf" || { echo "FAIL: 41. DOCUMENT content-type is '$A_CT'"; FAIL=$((FAIL+1)); }
case "$A_CD" in *attachment*) echo "PASS: 41. DOCUMENT disposition is attachment";; *) echo "FAIL: 41. DOCUMENT disposition is '$A_CD'"; FAIL=$((FAIL+1));; esac

# 42. An ID verification id is NOT reachable through the asset file route -> 404
code=$(curl -s -o /tmp/p12-asset-idleak.json -w "%{http_code}" "$BASE/api/portals/p12-portal-a/assets/$ID_A_ID/file")
check "42. ID verification id via asset file route -> 404" 404 "$code"

# 43. Unknown asset / unknown portal -> 404
code=$(curl -s -o /tmp/p12-asset-404.json -w "%{http_code}" "$BASE/api/portals/p12-portal-a/assets/no-such-asset/file")
check "43. unknown asset file -> 404" 404 "$code"
code=$(curl -s -o /tmp/p12-asset-404b.json -w "%{http_code}" "$BASE/api/portals/no-such-portal/assets/$LOGO2_ID/file")
check "43. unknown portal asset file -> 404" 404 "$code"

# 44. ADMIN deletes the DOCUMENT -> 200; file then 404s; list drops to 2
code=$(curl -s -o /tmp/p12-asset-del.json -w "%{http_code}" -X DELETE "$BASE/api/portals/$PORTAL_A_ID/assets/$DOC_ID" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "44. ADMIN deletes DOCUMENT -> 200" 200 "$code"
code=$(curl -s -o /tmp/p12-asset-del-file.json -w "%{http_code}" "$BASE/api/portals/p12-portal-a/assets/$DOC_ID/file")
check "44. deleted DOCUMENT file -> 404" 404 "$code"
code=$(curl -s -o /tmp/p12-asset-list2.json -w "%{http_code}" "$BASE/api/portals/$PORTAL_A_ID/assets" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
ASSET2_N=$(jget /tmp/p12-asset-list2.json "d.data.assets.length")
[ "$ASSET2_N" = "2" ] && echo "PASS: 44. list drops to 2 assets after delete" || { echo "FAIL: 44. list length is '$ASSET2_N'"; FAIL=$((FAIL+1)); }

# 45. CUSTOMER delete attempt -> 403
code=$(curl -s -o /tmp/p12-asset-del-cust.json -w "%{http_code}" -X DELETE "$BASE/api/portals/$PORTAL_A_ID/assets/$BANNER_ID" \
  -H "Authorization: Bearer $CUSTB_TOKEN")
check "45. customer delete attempt -> 403" 403 "$code"

# 46. ADMIN upload to unknown portal -> 404
code=$(curl -s -o /tmp/p12-asset-404c.json -w "%{http_code}" -X POST "$BASE/api/portals/no-such-portal/assets" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -F "kind=LOGO" -F "file=@/tmp/p12-front.png")
check "46. upload to unknown portal -> 404" 404 "$code"

# 47. DB check: 2 ID verifications (A VERIFIED, B PENDING) + 2 assets (LOGO + BANNER)
DB_JSON=$(DATABASE_URL="file:$DB_FILE" node -e "
  const { PrismaClient } = require('@prisma/client');
  (async () => {
    const p = new PrismaClient();
    const ids = await p.idVerification.findMany({ where: { portalId: '$PORTAL_A_ID' } });
    const assets = await p.portalAsset.findMany({ where: { portalId: '$PORTAL_A_ID' } });
    console.log(JSON.stringify({
      idCount: ids.length,
      aStatus: (ids.find(x => x.email === '$CUSTA_EMAIL') || {}).status || null,
      bStatus: (ids.find(x => x.email === '$CUSTB_EMAIL') || {}).status || null,
      assetCount: assets.length,
      kinds: assets.map(a => a.kind).sort(),
    }));
    await p.\$disconnect();
  })();
" 2>/tmp/p12-db-err.log)
if [ -s /tmp/p12-db-err.log ]; then echo "FAIL: 47. DB query failed:"; cat /tmp/p12-db-err.log; FAIL=$((FAIL+1)); fi
DB_IDN=$(node -e "console.log(JSON.parse(process.argv[1]).idCount)" "$DB_JSON" 2>/dev/null)
DB_A=$(node -e "console.log(JSON.parse(process.argv[1]).aStatus)" "$DB_JSON" 2>/dev/null)
DB_B=$(node -e "console.log(JSON.parse(process.argv[1]).bStatus)" "$DB_JSON" 2>/dev/null)
DB_ASSETN=$(node -e "console.log(JSON.parse(process.argv[1]).assetCount)" "$DB_JSON" 2>/dev/null)
DB_KINDS=$(node -e "console.log(JSON.parse(process.argv[1]).kinds.join(','))" "$DB_JSON" 2>/dev/null)
if [ "$DB_IDN" = "2" ] && [ "$DB_A" = "VERIFIED" ] && [ "$DB_B" = "PENDING" ]; then
  echo "PASS: 47. DB: 2 verifications, A VERIFIED, B PENDING"
else echo "FAIL: 47. DB verifications: count=$DB_IDN A=$DB_A B=$DB_B"; FAIL=$((FAIL+1)); fi
if [ "$DB_ASSETN" = "2" ] && [ "$DB_KINDS" = "BANNER,LOGO" ]; then
  echo "PASS: 47. DB: 2 assets remain (BANNER + LOGO)"
else echo "FAIL: 47. DB assets: count=$DB_ASSETN kinds='$DB_KINDS'"; FAIL=$((FAIL+1)); fi

# 48. Receipt email: the server log must show the receipt for JAR-1001
if [ -f "$LOG_FILE" ]; then
  if grep -a -q "JAR-1001 paid" "$LOG_FILE"; then
    echo "PASS: 48. server log shows the receipt email for JAR-1001"
  else echo "FAIL: 48. no receipt email for JAR-1001 in server log ($LOG_FILE)"; FAIL=$((FAIL+1)); fi
else echo "FAIL: 48. server log not found at $LOG_FILE — start the server with output there"; FAIL=$((FAIL+1)); fi

# 49. (Prompt 14) ARCHIVED portal stops serving public files: archive
#     portal A -> 200, its public-methods -> 404, and the BANNER file
#     that was public before -> 404. (Last check: nothing after this
#     needs portal A ACTIVE.)
code=$(curl -s -o /tmp/p12-archive-a.json -w "%{http_code}" -X DELETE "$BASE/api/portals/$PORTAL_A_ID" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "49. archive portal A -> 200" 200 "$code"
code=$(curl -s -o /tmp/p12-public-arch.json -w "%{http_code}" "$BASE/api/portals/p12-portal-a/public-methods")
check "49. public-methods ARCHIVED portal A -> 404" 404 "$code"
code=$(curl -s -o /tmp/p12-banner-arch.json -w "%{http_code}" "$BASE/api/portals/p12-portal-a/assets/$BANNER_ID/file")
check "49. BANNER file of ARCHIVED portal A -> 404" 404 "$code"

echo "== Summary: $FAIL failure(s) =="
[ "$FAIL" = 0 ] && echo "ALL PROMPT 12 ID + CAPTCHA + ASSETS CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$FAIL"
