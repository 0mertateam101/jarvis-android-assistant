#!/usr/bin/env bash
# Jarvis Prompt 7 — crypto checkout verification (never PAID on scan alone).
#
# Usage (from server/) — SIMULATED mode (default, no provider keys):
#   DATABASE_URL="file:$PWD/prisma/test-crypto.db" npx prisma migrate deploy
#   DATABASE_URL="file:$PWD/prisma/test-crypto.db" PORT=4001 npm run dev > /tmp/jarvis-p7-server.log 2>&1 &
#       JWT_SECRET is NOT exported here — it must come from server/.env
#       via dotenv. Start the server with its log at $LOG_FILE below so
#       the receipt-email check can prove the receipt was queued.
#   BASE_URL=http://localhost:4001 bash scripts/crypto-test.sh
#
# PROVIDER mode run (stub provider keys + webhook secret, NO real provider):
#   Start the server with BTCPAY_URL=https://stub.local BTCPAY_API_KEY=stub-key
#   BTCPAY_WEBHOOK_SECRET=stub-webhook-secret in its environment, plus the
#   absolute DATABASE_URL with a FRESH db file (e.g. test-crypto-provider.db),
#   then run with PROVIDER_TEST=1 — the provider-mode cases run instead of
#   the simulated manual-confirm cases. The DB check must read the SAME file
#   the server wrote, so pass it explicitly:
#   CRYPTO_DB_FILE="$PWD/prisma/test-crypto-provider.db" PROVIDER_TEST=1 \
#     LOG_FILE=/tmp/jarvis-p7p-server.log BASE_URL=http://localhost:4001 \
#     bash scripts/crypto-test.sh
#
# The DATABASE_URL must be ABSOLUTE (Prompt 4 lesson). Prisma resolves a
# relative SQLite path against the schema dir (server/prisma/), not the
# cwd, so a relative URL in the server and a relative URL in this script
# can silently open two different files.
#
# Uses a separate test database (test-crypto.db) — never touches dev.db.
# Tokens, codes and txHashes are NEVER printed in full; only a masked
# prefix and the HTTP status are shown.
set -u
cd "$(dirname "$0")/.." # always run from server/ so dotenv finds ./.env
BASE="${BASE_URL:-http://localhost:4001}"
# The DB file the server was started with. Default is the simulated-run
# file; the provider run MUST pass its own file (see header) or the DB
# check would read a different (possibly empty) database.
DB_FILE="${CRYPTO_DB_FILE:-$(pwd)/prisma/test-crypto.db}"
LOG_FILE="${LOG_FILE:-/tmp/jarvis-p7-server.log}"
PROVIDER_MODE="${PROVIDER_TEST:-0}"
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

ADMIN_EMAIL="prompt7-admin@test.local"
ADMIN_PASS="TestAdmin123!"
CUSTA_EMAIL="prompt7-customer-a@test.local"
CUSTB_EMAIL="prompt7-customer-b@test.local"
BTC_ADDR="bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq"
ETH_ADDR="0x742d35Cc6634C0532925a3b844Bc454e4438f44e"
USDT_ADDR="0x742d35Cc6634C0532925a3b844Bc454e4438f44e" # 0x + 40 hex (ERC-20 style)
DOGE_ADDR="DH5yaieqoZN36fDVciNyRueRG4G6y3oEya" # D + 33 base58
TXHASH=$(printf 'ab%.0s' $(seq 1 32)) # 64 hex chars
WEBHOOK_SECRET="stub-webhook-secret"

cleanup() {
  rm -f /tmp/p7-*.json /tmp/p7-hook-*.json /tmp/p7-db-err.log
}
trap cleanup EXIT

if [ "$PROVIDER_MODE" = "1" ]; then
  echo "== Prompt 7 crypto checks against $BASE (PROVIDER mode, stub BTCPay) =="
else
  echo "== Prompt 7 crypto checks against $BASE (SIMULATED mode) =="
fi

# 0. Health (no auth)
code=$(curl -s -o /tmp/p7-health.json -w "%{http_code}" "$BASE/health")
check "0. GET /health, no auth" 200 "$code"

# 1. First register -> ADMIN, login
code=$(curl -s -o /tmp/p7-reg.json -w "%{http_code}" -X POST "$BASE/api/auth/register" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\",\"name\":\"Prompt Seven\"}")
check "1. first register -> 201" 201 "$code"
ADMIN_TOKEN=$(jget /tmp/p7-reg.json "d.data.token")
echo "   admin token: $(mask "$ADMIN_TOKEN")"

code=$(curl -s -o /tmp/p7-login.json -w "%{http_code}" -X POST "$BASE/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\"}")
check "1. login -> 200" 200 "$code"
ADMIN_TOKEN=$(jget /tmp/p7-login.json "d.data.token")

# 2. Create portals A + B
code=$(curl -s -o /tmp/p7-portal-a.json -w "%{http_code}" -X POST "$BASE/api/portals" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"Prompt Seven Portal A","slug":"p7-portal-a","currency":"USD"}')
check "2. create portal A -> 201" 201 "$code"
PORTAL_A_ID=$(jget /tmp/p7-portal-a.json "d.data.portal.id")

code=$(curl -s -o /tmp/p7-portal-b.json -w "%{http_code}" -X POST "$BASE/api/portals" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"Prompt Seven Portal B","slug":"p7-portal-b","currency":"USD"}')
check "2. create portal B -> 201" 201 "$code"
PORTAL_B_ID=$(jget /tmp/p7-portal-b.json "d.data.portal.id")

# 3. BTC + ETH + USDT + DOGE + CASH_APP methods, all assigned to portal A
code=$(curl -s -o /tmp/p7-btc.json -w "%{http_code}" -X POST "$BASE/api/payment-methods" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"type\":\"BTC\",\"label\":\"Bitcoin — Test\",\"handle\":\"$BTC_ADDR\"}")
check "3. create BTC method -> 201" 201 "$code"
BTC_ID=$(jget /tmp/p7-btc.json "d.data.method.id")

code=$(curl -s -o /tmp/p7-assign-btc.json -w "%{http_code}" -X POST "$BASE/api/portals/$PORTAL_A_ID/methods" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"paymentMethodId\":\"$BTC_ID\"}")
check "3. assign BTC to portal A -> 201" 201 "$code"

code=$(curl -s -o /tmp/p7-eth.json -w "%{http_code}" -X POST "$BASE/api/payment-methods" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"type\":\"ETH\",\"label\":\"Ethereum — Test\",\"handle\":\"$ETH_ADDR\"}")
check "3. create ETH method -> 201" 201 "$code"
ETH_ID=$(jget /tmp/p7-eth.json "d.data.method.id")

code=$(curl -s -o /tmp/p7-assign-eth.json -w "%{http_code}" -X POST "$BASE/api/portals/$PORTAL_A_ID/methods" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"paymentMethodId\":\"$ETH_ID\"}")
check "3. assign ETH to portal A -> 201" 201 "$code"

code=$(curl -s -o /tmp/p7-usdt.json -w "%{http_code}" -X POST "$BASE/api/payment-methods" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"type\":\"USDT\",\"label\":\"Tether — Test\",\"handle\":\"$USDT_ADDR\"}")
check "3. create USDT method -> 201" 201 "$code"
USDT_ID=$(jget /tmp/p7-usdt.json "d.data.method.id")

code=$(curl -s -o /tmp/p7-assign-usdt.json -w "%{http_code}" -X POST "$BASE/api/portals/$PORTAL_A_ID/methods" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"paymentMethodId\":\"$USDT_ID\"}")
check "3. assign USDT to portal A -> 201" 201 "$code"

code=$(curl -s -o /tmp/p7-doge.json -w "%{http_code}" -X POST "$BASE/api/payment-methods" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"type\":\"DOGE\",\"label\":\"Dogecoin — Test\",\"handle\":\"$DOGE_ADDR\"}")
check "3. create DOGE method -> 201" 201 "$code"
DOGE_ID=$(jget /tmp/p7-doge.json "d.data.method.id")

code=$(curl -s -o /tmp/p7-assign-doge.json -w "%{http_code}" -X POST "$BASE/api/portals/$PORTAL_A_ID/methods" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"paymentMethodId\":\"$DOGE_ID\"}")
check "3. assign DOGE to portal A -> 201" 201 "$code"

code=$(curl -s -o /tmp/p7-cash.json -w "%{http_code}" -X POST "$BASE/api/payment-methods" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"type":"CASH_APP","label":"Cash App — Test","handle":"$P7Test"}')
check "3. create CASH_APP method -> 201" 201 "$code"
CASH_ID=$(jget /tmp/p7-cash.json "d.data.method.id")

code=$(curl -s -o /tmp/p7-assign-cash.json -w "%{http_code}" -X POST "$BASE/api/portals/$PORTAL_A_ID/methods" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"paymentMethodId\":\"$CASH_ID\"}")
check "3. assign CASH_APP to portal A -> 201" 201 "$code"

# 4. Invite customers A + B, log them in (2 logins — under the 10/min limit)
code=$(curl -s -o /tmp/p7-invite-a.json -w "%{http_code}" -X POST "$BASE/api/access/invite" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalId\":\"$PORTAL_A_ID\",\"email\":\"$CUSTA_EMAIL\"}")
check "4. invite customer A -> 201" 201 "$code"
CODE_A=$(jget /tmp/p7-invite-a.json "d.data.code")

code=$(curl -s -o /tmp/p7-login-a.json -w "%{http_code}" -X POST "$BASE/api/access/login" \
  -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"p7-portal-a\",\"email\":\"$CUSTA_EMAIL\",\"code\":\"$CODE_A\"}")
check "4. customer A login -> 200" 200 "$code"
CUSTA_TOKEN=$(jget /tmp/p7-login-a.json "d.data.token")
echo "   customer A token: $(mask "$CUSTA_TOKEN")"

code=$(curl -s -o /tmp/p7-invite-b.json -w "%{http_code}" -X POST "$BASE/api/access/invite" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalId\":\"$PORTAL_B_ID\",\"email\":\"$CUSTB_EMAIL\"}")
check "4. invite customer B -> 201" 201 "$code"
CODE_B=$(jget /tmp/p7-invite-b.json "d.data.code")

code=$(curl -s -o /tmp/p7-login-b.json -w "%{http_code}" -X POST "$BASE/api/access/login" \
  -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"p7-portal-b\",\"email\":\"$CUSTB_EMAIL\",\"code\":\"$CODE_B\"}")
check "4. customer B login -> 200" 200 "$code"
CUSTB_TOKEN=$(jget /tmp/p7-login-b.json "d.data.token")

# 5. Create BTC crypto invoice -> 201, JAR-1001, checkout shows address + amount + reference
code=$(curl -s -o /tmp/p7-inv1.json -w "%{http_code}" -X POST "$BASE/api/invoices" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"p7-portal-a\",\"payerEmail\":\"$CUSTA_EMAIL\",\"payerName\":\"P7 Customer\",\"amount\":\"150.00\",\"currency\":\"USD\",\"items\":[{\"description\":\"Crypto coaching\",\"amount\":\"150.00\"}],\"paymentMethodId\":\"$BTC_ID\"}")
check "5. create BTC invoice -> 201" 201 "$code"
NUM1=$(jget /tmp/p7-inv1.json "d.data.invoice.number")
[ "$NUM1" = "JAR-1001" ] && echo "PASS: 5. invoice 1 number is JAR-1001" || { echo "FAIL: 5. invoice 1 number is '$NUM1'"; FAIL=$((FAIL+1)); }
ADDR1=$(jget /tmp/p7-inv1.json "d.data.crypto.address")
[ "$ADDR1" = "$BTC_ADDR" ] && echo "PASS: 5. checkout shows the portal's BTC address" || { echo "FAIL: 5. checkout address is '$ADDR1'"; FAIL=$((FAIL+1)); }
AMT1=$(jget /tmp/p7-inv1.json "d.data.crypto.amount")
[ "$AMT1" = "0.00250000" ] && echo "PASS: 5. checkout shows exact crypto amount 0.00250000 BTC" || { echo "FAIL: 5. checkout amount is '$AMT1'"; FAIL=$((FAIL+1)); }
REF1=$(jget /tmp/p7-inv1.json "d.data.crypto.reference")
[ "$REF1" = "JAR-1001" ] && echo "PASS: 5. checkout reference is JAR-1001" || { echo "FAIL: 5. checkout reference is '$REF1'"; FAIL=$((FAIL+1)); }
STATUS1=$(jget /tmp/p7-inv1.json "d.data.invoice.status")
[ "$STATUS1" = "PENDING" ] && echo "PASS: 5. invoice 1 is PENDING (not paid on creation)" || { echo "FAIL: 5. invoice 1 status is '$STATUS1'"; FAIL=$((FAIL+1)); }
INV1_ID=$(jget /tmp/p7-inv1.json "d.data.invoice.id")

# 5b. Create a CASH_APP invoice -> JAR-1002 (non-crypto regression + 400 case for /crypto)
code=$(curl -s -o /tmp/p7-inv2.json -w "%{http_code}" -X POST "$BASE/api/invoices" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"p7-portal-a\",\"payerEmail\":\"$CUSTA_EMAIL\",\"amount\":\"25.00\",\"currency\":\"USD\",\"items\":[{\"description\":\"Cash coaching\",\"amount\":\"25.00\"}],\"paymentMethodId\":\"$CASH_ID\"}")
check "5b. create CASH_APP invoice -> 201" 201 "$code"
NUM2=$(jget /tmp/p7-inv2.json "d.data.invoice.number")
[ "$NUM2" = "JAR-1002" ] && echo "PASS: 5b. invoice 2 number is JAR-1002" || { echo "FAIL: 5b. invoice 2 number is '$NUM2'"; FAIL=$((FAIL+1)); }
INV2_ID=$(jget /tmp/p7-inv2.json "d.data.invoice.id")

# 6. GET /:id/crypto — re-fetch checkout details (customer A -> 200, B -> 403, unknown -> 404, ADMIN -> 200, cash invoice -> 400)
code=$(curl -s -o /tmp/p7-crypto-a.json -w "%{http_code}" "$BASE/api/invoices/$INV1_ID/crypto" \
  -H "Authorization: Bearer $CUSTA_TOKEN")
check "6. GET crypto checkout as its customer -> 200" 200 "$code"
CADDR=$(jget /tmp/p7-crypto-a.json "d.data.crypto.address")
[ "$CADDR" = "$BTC_ADDR" ] && echo "PASS: 6. re-fetched checkout shows the BTC address" || { echo "FAIL: 6. re-fetched address is '$CADDR'"; FAIL=$((FAIL+1)); }
CAMT=$(jget /tmp/p7-crypto-a.json "d.data.crypto.amount")
[ "$CAMT" = "0.00250000" ] && echo "PASS: 6. re-fetched checkout shows 0.00250000 BTC" || { echo "FAIL: 6. re-fetched amount is '$CAMT'"; FAIL=$((FAIL+1)); }
CSIM=$(jget /tmp/p7-crypto-a.json "d.data.simulated")
if [ "$PROVIDER_MODE" = "1" ]; then
  [ "$CSIM" = "false" ] && echo "PASS: 6. checkout says simulated=false in provider mode" || { echo "FAIL: 6. simulated flag is '$CSIM', expected false"; FAIL=$((FAIL+1)); }
else
  [ "$CSIM" = "true" ] && echo "PASS: 6. checkout says simulated=true (no provider configured)" || { echo "FAIL: 6. simulated flag is '$CSIM', expected true"; FAIL=$((FAIL+1)); }
fi
code=$(curl -s -o /tmp/p7-crypto-b.json -w "%{http_code}" "$BASE/api/invoices/$INV1_ID/crypto" \
  -H "Authorization: Bearer $CUSTB_TOKEN")
check "6. GET crypto checkout as other portal's customer -> 403" 403 "$code"
code=$(curl -s -o /tmp/p7-crypto-404.json -w "%{http_code}" "$BASE/api/invoices/does-not-exist/crypto" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "6. GET crypto checkout unknown invoice -> 404" 404 "$code"
code=$(curl -s -o /tmp/p7-crypto-admin.json -w "%{http_code}" "$BASE/api/invoices/$INV1_ID/crypto" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "6. GET crypto checkout as ADMIN -> 200" 200 "$code"
code=$(curl -s -o /tmp/p7-crypto-cash.json -w "%{http_code}" "$BASE/api/invoices/$INV2_ID/crypto" \
  -H "Authorization: Bearer $CUSTA_TOKEN")
check "6. GET crypto checkout for a cash invoice -> 400" 400 "$code"

# 7. QR-scan negative: viewing the invoice + PDF (i.e. scanning the QR) must NOT pay it
code=$(curl -s -o /tmp/p7-get1.json -w "%{http_code}" "$BASE/api/invoices/$INV1_ID" \
  -H "Authorization: Bearer $CUSTA_TOKEN")
check "7. GET invoice (view QR) -> 200" 200 "$code"
code=$(curl -s -o /tmp/p7-pdf1.pdf -w "%{http_code}" "$BASE/api/invoices/$INV1_ID/pdf" \
  -H "Authorization: Bearer $CUSTA_TOKEN")
check "7. GET pdf (view QR) -> 200" 200 "$code"
SCAN_STATUS=$(jget /tmp/p7-get1.json "d.data.invoice.status")
[ "$SCAN_STATUS" = "PENDING" ] && echo "PASS: 7. invoice still PENDING after viewing/scanning the QR" || { echo "FAIL: 7. invoice status after scan is '$SCAN_STATUS'"; FAIL=$((FAIL+1)); }

if [ "$PROVIDER_MODE" = "1" ]; then
  # ---------- PROVIDER MODE CASES ----------
  # P8. Customer submits a txHash -> 200, PENDING record, invoice stays PENDING
  code=$(curl -s -o /tmp/p7-tx1.json -w "%{http_code}" -X POST "$BASE/api/payments/$INV1_ID/confirm" \
    -H "Authorization: Bearer $CUSTA_TOKEN" -H 'Content-Type: application/json' \
    -d "{\"reference\":\"$TXHASH\"}")
  check "P8. customer submits txHash (provider mode) -> 200" 200 "$code"
  TXPAY_STATUS=$(jget /tmp/p7-tx1.json "d.data.payment.status")
  [ "$TXPAY_STATUS" = "PENDING" ] && echo "PASS: P8. txHash recorded as PENDING payment" || { echo "FAIL: P8. payment status is '$TXPAY_STATUS'"; FAIL=$((FAIL+1)); }
  TXINV_STATUS=$(jget /tmp/p7-tx1.json "d.data.invoice.status")
  [ "$TXINV_STATUS" = "PENDING" ] && echo "PASS: P8. invoice still PENDING after txHash submit" || { echo "FAIL: P8. invoice status is '$TXINV_STATUS'"; FAIL=$((FAIL+1)); }

  # P9. Invalid txHash -> 400
  code=$(curl -s -o /tmp/p7-badtx.json -w "%{http_code}" -X POST "$BASE/api/payments/$INV1_ID/confirm" \
    -H "Authorization: Bearer $CUSTA_TOKEN" -H 'Content-Type: application/json' \
    -d '{"reference":"abc"}')
  check "P9. invalid txHash 'abc' -> 400" 400 "$code"

  # P10. ADMIN manual confirm is REFUSED in provider mode -> 400, invoice still PENDING
  code=$(curl -s -o /tmp/p7-manual.json -w "%{http_code}" -X POST "$BASE/api/payments/$INV1_ID/confirm" \
    -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
    -d "{\"reference\":\"$TXHASH\",\"adminConfirm\":true}")
  check "P10. ADMIN manual confirm in provider mode -> 400 refused" 400 "$code"
  code=$(curl -s -o /tmp/p7-get2.json -w "%{http_code}" "$BASE/api/invoices/$INV1_ID" \
    -H "Authorization: Bearer $ADMIN_TOKEN")
  MANUAL_STATUS=$(jget /tmp/p7-get2.json "d.data.invoice.status")
  [ "$MANUAL_STATUS" = "PENDING" ] && echo "PASS: P10. invoice still PENDING after refused manual confirm" || { echo "FAIL: P10. invoice status is '$MANUAL_STATUS'"; FAIL=$((FAIL+1)); }

  # P11. Webhook without a signature -> 401, still PENDING
  printf '%s' "{\"reference\":\"JAR-1001\",\"txHash\":\"$TXHASH\",\"status\":\"confirmed\"}" > /tmp/p7-hook-1.json
  code=$(curl -s -o /tmp/p7-hook-nosig.json -w "%{http_code}" -X POST "$BASE/api/webhooks/crypto/btcpay" \
    -H 'Content-Type: application/json' --data-binary @/tmp/p7-hook-1.json)
  check "P11. webhook without signature -> 401" 401 "$code"

  # P12. Webhook with a BAD signature -> 401, still PENDING
  code=$(curl -s -o /tmp/p7-hook-badsig.json -w "%{http_code}" -X POST "$BASE/api/webhooks/crypto/btcpay" \
    -H 'Content-Type: application/json' -H "BTCPay-Sig: sha256=deadbeef" --data-binary @/tmp/p7-hook-1.json)
  check "P12. webhook with bad signature -> 401" 401 "$code"

  # P13. Webhook with a VALID signature, confirmed -> 200, invoice PAID, payment CONFIRMED + NOT simulated
  SIG=$(node scripts/sign-webhook.mjs "$WEBHOOK_SECRET" /tmp/p7-hook-1.json)
  code=$(curl -s -o /tmp/p7-hook-ok.json -w "%{http_code}" -X POST "$BASE/api/webhooks/crypto/btcpay" \
    -H 'Content-Type: application/json' -H "BTCPay-Sig: $SIG" --data-binary @/tmp/p7-hook-1.json)
  check "P13. webhook with valid signature -> 200" 200 "$code"
  HOOK_STATUS=$(jget /tmp/p7-hook-ok.json "d.data.invoice.status")
  [ "$HOOK_STATUS" = "PAID" ] && echo "PASS: P13. invoice PAID by provider webhook" || { echo "FAIL: P13. invoice status is '$HOOK_STATUS'"; FAIL=$((FAIL+1)); }
  HOOK_SIM=$(jget /tmp/p7-hook-ok.json "d.data.payment.simulated")
  [ "$HOOK_SIM" = "false" ] && echo "PASS: P13. webhook confirmation is NOT simulated (simulated=false)" || { echo "FAIL: P13. payment simulated flag is '$HOOK_SIM'"; FAIL=$((FAIL+1)); }
  HOOK_PROOF=$(jget /tmp/p7-hook-ok.json "d.data.invoice.proofHash")
  [ -n "$HOOK_PROOF" ] && [ "$HOOK_PROOF" != "null" ] && echo "PASS: P13. webhook PAID invoice has a proofHash" || { echo "FAIL: P13. proofHash missing"; FAIL=$((FAIL+1)); }

  # P14. Webhook replay (same signed body) -> 200 alreadyPaid, still exactly one CONFIRMED payment
  code=$(curl -s -o /tmp/p7-hook-replay.json -w "%{http_code}" -X POST "$BASE/api/webhooks/crypto/btcpay" \
    -H 'Content-Type: application/json' -H "BTCPay-Sig: $SIG" --data-binary @/tmp/p7-hook-1.json)
  check "P14. webhook replay -> 200" 200 "$code"
  REPLAY=$(jget /tmp/p7-hook-replay.json "d.data.alreadyPaid")
  [ "$REPLAY" = "true" ] && echo "PASS: P14. replay reports alreadyPaid=true" || { echo "FAIL: P14. alreadyPaid is '$REPLAY'"; FAIL=$((FAIL+1)); }

  # P15. Webhook unknown reference -> 404
  printf '%s' "{\"reference\":\"JAR-9999\",\"txHash\":\"$TXHASH\",\"status\":\"confirmed\"}" > /tmp/p7-hook-2.json
  SIG2=$(node scripts/sign-webhook.mjs "$WEBHOOK_SECRET" /tmp/p7-hook-2.json)
  code=$(curl -s -o /tmp/p7-hook-404.json -w "%{http_code}" -X POST "$BASE/api/webhooks/crypto/btcpay" \
    -H 'Content-Type: application/json' -H "BTCPay-Sig: $SIG2" --data-binary @/tmp/p7-hook-2.json)
  check "P15. webhook unknown reference -> 404" 404 "$code"

  # P16. Webhook valid signature but non-confirmation event -> 200 ignored, second invoice stays PENDING
  printf '%s' "{\"reference\":\"JAR-1002\",\"txHash\":\"$TXHASH\",\"status\":\"created\"}" > /tmp/p7-hook-3.json
  SIG3=$(node scripts/sign-webhook.mjs "$WEBHOOK_SECRET" /tmp/p7-hook-3.json)
  code=$(curl -s -o /tmp/p7-hook-ign.json -w "%{http_code}" -X POST "$BASE/api/webhooks/crypto/btcpay" \
    -H 'Content-Type: application/json' -H "BTCPay-Sig: $SIG3" --data-binary @/tmp/p7-hook-3.json)
  check "P16. webhook non-confirmation event -> 200" 200 "$code"
  IGN=$(jget /tmp/p7-hook-ign.json "d.data.ignored")
  [ "$IGN" = "true" ] && echo "PASS: P16. non-confirmation event ignored" || { echo "FAIL: P16. ignored is '$IGN'"; FAIL=$((FAIL+1)); }
  code=$(curl -s -o /tmp/p7-get3.json -w "%{http_code}" "$BASE/api/invoices/$INV2_ID" \
    -H "Authorization: Bearer $ADMIN_TOKEN")
  IGN_STATUS=$(jget /tmp/p7-get3.json "d.data.invoice.status")
  [ "$IGN_STATUS" = "PENDING" ] && echo "PASS: P16. cash invoice still PENDING after ignored webhook" || { echo "FAIL: P16. invoice 2 status is '$IGN_STATUS'"; FAIL=$((FAIL+1)); }

  # P17. Provider DB check: JAR-1001 has exactly one CONFIRMED payment and it is NOT simulated
  DB_JSON=$(DATABASE_URL="file:$DB_FILE" node -e "
    const { PrismaClient } = require('@prisma/client');
    (async () => {
      const p = new PrismaClient();
      const inv1 = await p.invoice.findUnique({ where: { number: 'JAR-1001' }, include: { payments: true } });
      console.log(JSON.stringify(inv1 ? { status: inv1.status, proof: !!inv1.proofHash, confirmed: inv1.payments.filter(x => x.status === 'CONFIRMED').length, realConfirmed: inv1.payments.filter(x => x.status === 'CONFIRMED' && !x.simulated).length } : null));
      await p.\$disconnect();
    })();
  " 2>/tmp/p7-db-err.log)
  if [ -s /tmp/p7-db-err.log ]; then echo "FAIL: P17. DB query failed:"; cat /tmp/p7-db-err.log; FAIL=$((FAIL+1)); fi
  P17_STATUS=$(node -e "console.log(JSON.parse(process.argv[1]).status)" "$DB_JSON" 2>/dev/null)
  P17_CONF=$(node -e "console.log(JSON.parse(process.argv[1]).confirmed)" "$DB_JSON" 2>/dev/null)
  P17_REAL=$(node -e "console.log(JSON.parse(process.argv[1]).realConfirmed)" "$DB_JSON" 2>/dev/null)
  P17_PROOF=$(node -e "console.log(JSON.parse(process.argv[1]).proof)" "$DB_JSON" 2>/dev/null)
  if [ "$P17_STATUS" = "PAID" ] && [ "$P17_CONF" = "1" ] && [ "$P17_REAL" = "1" ] && [ "$P17_PROOF" = "true" ]; then
    echo "PASS: P17. DB: JAR-1001 PAID with exactly one CONFIRMED payment, simulated=false, proofHash set"
  else echo "FAIL: P17. DB check: status=$P17_STATUS confirmed=$P17_CONF realConfirmed=$P17_REAL proof=$P17_PROOF"; FAIL=$((FAIL+1)); fi
else
  # ---------- SIMULATED MODE CASES ----------
  # 8. Customer submits a valid txHash -> 200, PENDING record, invoice stays PENDING (txHash alone never pays)
  code=$(curl -s -o /tmp/p7-tx1.json -w "%{http_code}" -X POST "$BASE/api/payments/$INV1_ID/confirm" \
    -H "Authorization: Bearer $CUSTA_TOKEN" -H 'Content-Type: application/json' \
    -d "{\"reference\":\"$TXHASH\"}")
  check "8. customer submits txHash -> 200" 200 "$code"
  TXPAY_STATUS=$(jget /tmp/p7-tx1.json "d.data.payment.status")
  [ "$TXPAY_STATUS" = "PENDING" ] && echo "PASS: 8. txHash recorded as PENDING payment" || { echo "FAIL: 8. payment status is '$TXPAY_STATUS'"; FAIL=$((FAIL+1)); }
  TXNOTE=$(jget /tmp/p7-tx1.json "d.data.note")
  case "$TXNOTE" in *SIMULATED*) echo "PASS: 8. note says SIMULATED";; *) echo "FAIL: 8. note is '$TXNOTE'"; FAIL=$((FAIL+1));; esac
  TXINV_STATUS=$(jget /tmp/p7-tx1.json "d.data.invoice.status")
  [ "$TXINV_STATUS" = "PENDING" ] && echo "PASS: 8. invoice still PENDING after txHash submit (txHash alone never pays)" || { echo "FAIL: 8. invoice status is '$TXINV_STATUS'"; FAIL=$((FAIL+1)); }

  # 9. Invalid txHash -> 400
  code=$(curl -s -o /tmp/p7-badtx1.json -w "%{http_code}" -X POST "$BASE/api/payments/$INV1_ID/confirm" \
    -H "Authorization: Bearer $CUSTA_TOKEN" -H 'Content-Type: application/json' \
    -d '{"reference":"abc"}')
  check "9. invalid txHash 'abc' -> 400" 400 "$code"
  code=$(curl -s -o /tmp/p7-badtx2.json -w "%{http_code}" -X POST "$BASE/api/payments/$INV1_ID/confirm" \
    -H "Authorization: Bearer $CUSTA_TOKEN" -H 'Content-Type: application/json' \
    -d '{"reference":"not a hash!!!"}')
  check "9. invalid txHash 'not a hash!!!' -> 400" 400 "$code"

  # 10. Customer tries adminConfirm -> 403 (self-confirming is forbidden)
  code=$(curl -s -o /tmp/p7-selfconfirm.json -w "%{http_code}" -X POST "$BASE/api/payments/$INV1_ID/confirm" \
    -H "Authorization: Bearer $CUSTA_TOKEN" -H 'Content-Type: application/json' \
    -d "{\"reference\":\"$TXHASH\",\"adminConfirm\":true}")
  check "10. CUSTOMER adminConfirm -> 403" 403 "$code"

  # 11. Unknown invoice confirm -> 404
  code=$(curl -s -o /tmp/p7-confirm-404.json -w "%{http_code}" -X POST "$BASE/api/payments/does-not-exist/confirm" \
    -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
    -d "{\"reference\":\"$TXHASH\"}")
  check "11. confirm unknown invoice -> 404" 404 "$code"

  # 12. ADMIN manual confirm (SIMULATED) -> 200, invoice PAID, payment CONFIRMED + simulated, proofHash set
  code=$(curl -s -o /tmp/p7-manual.json -w "%{http_code}" -X POST "$BASE/api/payments/$INV1_ID/confirm" \
    -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
    -d "{\"reference\":\"$TXHASH\",\"adminConfirm\":true}")
  check "12. ADMIN manual confirm (simulated) -> 200" 200 "$code"
  MAN_STATUS=$(jget /tmp/p7-manual.json "d.data.invoice.status")
  [ "$MAN_STATUS" = "PAID" ] && echo "PASS: 12. invoice PAID by Don's manual confirm" || { echo "FAIL: 12. invoice status is '$MAN_STATUS'"; FAIL=$((FAIL+1)); }
  MAN_PAY=$(jget /tmp/p7-manual.json "d.data.payment.status")
  [ "$MAN_PAY" = "CONFIRMED" ] && echo "PASS: 12. payment is CONFIRMED" || { echo "FAIL: 12. payment status is '$MAN_PAY'"; FAIL=$((FAIL+1)); }
  MAN_SIM=$(jget /tmp/p7-manual.json "d.data.payment.simulated")
  [ "$MAN_SIM" = "true" ] && echo "PASS: 12. manual confirmation is labelled SIMULATED (simulated=true)" || { echo "FAIL: 12. payment simulated flag is '$MAN_SIM'"; FAIL=$((FAIL+1)); }
  MAN_PROOF=$(jget /tmp/p7-manual.json "d.data.invoice.proofHash")
  [ -n "$MAN_PROOF" ] && [ "$MAN_PROOF" != "null" ] && echo "PASS: 12. PAID invoice has a proofHash" || { echo "FAIL: 12. proofHash missing"; FAIL=$((FAIL+1)); }
  MAN_NOTE=$(jget /tmp/p7-manual.json "d.data.note")
  case "$MAN_NOTE" in *SIMULATED*) echo "PASS: 12. note says SIMULATED";; *) echo "FAIL: 12. note is '$MAN_NOTE'"; FAIL=$((FAIL+1));; esac
  # Confirming again -> "Already paid", still PAID
  code=$(curl -s -o /tmp/p7-manual2.json -w "%{http_code}" -X POST "$BASE/api/payments/$INV1_ID/confirm" \
    -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
    -d "{\"reference\":\"$TXHASH\",\"adminConfirm\":true}")
  check "12. confirm an already-PAID invoice -> 200" 200 "$code"
  MAN2_NOTE=$(jget /tmp/p7-manual2.json "d.data.note")
  [ "$MAN2_NOTE" = "Already paid" ] && echo "PASS: 12. second confirm reports Already paid" || { echo "FAIL: 12. second confirm note is '$MAN2_NOTE'"; FAIL=$((FAIL+1)); }

  # 13. Second crypto invoice -> JAR-1003; txHash submit only -> stays PENDING (the unconfirmed one for the DB check)
  code=$(curl -s -o /tmp/p7-inv3.json -w "%{http_code}" -X POST "$BASE/api/invoices" \
    -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
    -d "{\"portalSlug\":\"p7-portal-a\",\"payerEmail\":\"$CUSTA_EMAIL\",\"amount\":\"75.50\",\"currency\":\"USD\",\"items\":[{\"description\":\"Crypto coaching — Dec\",\"amount\":\"75.50\"}],\"paymentMethodId\":\"$BTC_ID\"}")
  check "13. create second BTC invoice -> 201" 201 "$code"
  NUM3=$(jget /tmp/p7-inv3.json "d.data.invoice.number")
  [ "$NUM3" = "JAR-1003" ] && echo "PASS: 13. invoice 3 number is JAR-1003" || { echo "FAIL: 13. invoice 3 number is '$NUM3'"; FAIL=$((FAIL+1)); }
  INV3_ID=$(jget /tmp/p7-inv3.json "d.data.invoice.id")
  code=$(curl -s -o /tmp/p7-tx3.json -w "%{http_code}" -X POST "$BASE/api/payments/$INV3_ID/confirm" \
    -H "Authorization: Bearer $CUSTA_TOKEN" -H 'Content-Type: application/json' \
    -d "{\"reference\":\"$TXHASH\"}")
  check "13. customer submits txHash for invoice 3 -> 200" 200 "$code"
  TX3_STATUS=$(jget /tmp/p7-tx3.json "d.data.invoice.status")
  [ "$TX3_STATUS" = "PENDING" ] && echo "PASS: 13. invoice 3 still PENDING after txHash submit" || { echo "FAIL: 13. invoice 3 status is '$TX3_STATUS'"; FAIL=$((FAIL+1)); }

  # 13b. USDT end-to-end (Prompt 11): checkout → txHash stays PENDING → Don manual confirm → PAID + proofHash
  code=$(curl -s -o /tmp/p7-inv4.json -w "%{http_code}" -X POST "$BASE/api/invoices" \
    -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
    -d "{\"portalSlug\":\"p7-portal-a\",\"payerEmail\":\"$CUSTA_EMAIL\",\"amount\":\"150.00\",\"currency\":\"USD\",\"items\":[{\"description\":\"USDT coaching\",\"amount\":\"150.00\"}],\"paymentMethodId\":\"$USDT_ID\"}")
  check "13b. create USDT invoice -> 201" 201 "$code"
  NUM4=$(jget /tmp/p7-inv4.json "d.data.invoice.number")
  [ "$NUM4" = "JAR-1004" ] && echo "PASS: 13b. USDT invoice number is JAR-1004" || { echo "FAIL: 13b. USDT invoice number is '$NUM4'"; FAIL=$((FAIL+1)); }
  ADDR4=$(jget /tmp/p7-inv4.json "d.data.crypto.address")
  [ "$ADDR4" = "$USDT_ADDR" ] && echo "PASS: 13b. checkout shows the portal's USDT address" || { echo "FAIL: 13b. checkout address is '$ADDR4'"; FAIL=$((FAIL+1)); }
  AMT4=$(jget /tmp/p7-inv4.json "d.data.crypto.amount")
  [ "$AMT4" = "150.00000000" ] && echo "PASS: 13b. checkout shows exact crypto amount 150.00000000 USDT (dev rate 1)" || { echo "FAIL: 13b. checkout amount is '$AMT4'"; FAIL=$((FAIL+1)); }
  REF4=$(jget /tmp/p7-inv4.json "d.data.crypto.reference")
  [ "$REF4" = "JAR-1004" ] && echo "PASS: 13b. checkout reference is JAR-1004" || { echo "FAIL: 13b. checkout reference is '$REF4'"; FAIL=$((FAIL+1)); }
  INV4_ID=$(jget /tmp/p7-inv4.json "d.data.invoice.id")
  code=$(curl -s -o /tmp/p7-tx4.json -w "%{http_code}" -X POST "$BASE/api/payments/$INV4_ID/confirm" \
    -H "Authorization: Bearer $CUSTA_TOKEN" -H 'Content-Type: application/json' \
    -d "{\"reference\":\"$TXHASH\"}")
  check "13b. customer submits txHash for USDT invoice -> 200" 200 "$code"
  TX4_STATUS=$(jget /tmp/p7-tx4.json "d.data.invoice.status")
  [ "$TX4_STATUS" = "PENDING" ] && echo "PASS: 13b. USDT invoice still PENDING after txHash submit (txHash alone never pays)" || { echo "FAIL: 13b. USDT invoice status is '$TX4_STATUS'"; FAIL=$((FAIL+1)); }
  code=$(curl -s -o /tmp/p7-manual4.json -w "%{http_code}" -X POST "$BASE/api/payments/$INV4_ID/confirm" \
    -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
    -d "{\"reference\":\"$TXHASH\",\"adminConfirm\":true}")
  check "13b. ADMIN manual confirm USDT (simulated) -> 200" 200 "$code"
  MAN4_STATUS=$(jget /tmp/p7-manual4.json "d.data.invoice.status")
  [ "$MAN4_STATUS" = "PAID" ] && echo "PASS: 13b. USDT invoice PAID by Don's manual confirm" || { echo "FAIL: 13b. USDT invoice status is '$MAN4_STATUS'"; FAIL=$((FAIL+1)); }
  MAN4_SIM=$(jget /tmp/p7-manual4.json "d.data.payment.simulated")
  [ "$MAN4_SIM" = "true" ] && echo "PASS: 13b. USDT manual confirmation is labelled SIMULATED" || { echo "FAIL: 13b. USDT payment simulated flag is '$MAN4_SIM'"; FAIL=$((FAIL+1)); }
  MAN4_PROOF=$(jget /tmp/p7-manual4.json "d.data.invoice.proofHash")
  [ -n "$MAN4_PROOF" ] && [ "$MAN4_PROOF" != "null" ] && echo "PASS: 13b. PAID USDT invoice has a proofHash" || { echo "FAIL: 13b. USDT proofHash missing"; FAIL=$((FAIL+1)); }

  # 13c. DOGE checkout (Prompt 11): quote shows the D-address + amount at the fake 0.2 dev rate
  code=$(curl -s -o /tmp/p7-inv5.json -w "%{http_code}" -X POST "$BASE/api/invoices" \
    -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
    -d "{\"portalSlug\":\"p7-portal-a\",\"payerEmail\":\"$CUSTA_EMAIL\",\"amount\":\"150.00\",\"currency\":\"USD\",\"items\":[{\"description\":\"DOGE coaching\",\"amount\":\"150.00\"}],\"paymentMethodId\":\"$DOGE_ID\"}")
  check "13c. create DOGE invoice -> 201" 201 "$code"
  NUM5=$(jget /tmp/p7-inv5.json "d.data.invoice.number")
  [ "$NUM5" = "JAR-1005" ] && echo "PASS: 13c. DOGE invoice number is JAR-1005" || { echo "FAIL: 13c. DOGE invoice number is '$NUM5'"; FAIL=$((FAIL+1)); }
  ADDR5=$(jget /tmp/p7-inv5.json "d.data.crypto.address")
  [ "$ADDR5" = "$DOGE_ADDR" ] && echo "PASS: 13c. checkout shows the portal's DOGE address" || { echo "FAIL: 13c. checkout address is '$ADDR5'"; FAIL=$((FAIL+1)); }
  AMT5=$(jget /tmp/p7-inv5.json "d.data.crypto.amount")
  [ "$AMT5" = "750.00000000" ] && echo "PASS: 13c. checkout shows exact crypto amount 750.00000000 DOGE (dev rate 0.2)" || { echo "FAIL: 13c. checkout amount is '$AMT5'"; FAIL=$((FAIL+1)); }
  REF5=$(jget /tmp/p7-inv5.json "d.data.crypto.reference")
  [ "$REF5" = "JAR-1005" ] && echo "PASS: 13c. checkout reference is JAR-1005" || { echo "FAIL: 13c. checkout reference is '$REF5'"; FAIL=$((FAIL+1)); }
  STATUS5=$(jget /tmp/p7-inv5.json "d.data.invoice.status")
  [ "$STATUS5" = "PENDING" ] && echo "PASS: 13c. DOGE invoice is PENDING (not paid on creation)" || { echo "FAIL: 13c. DOGE invoice status is '$STATUS5'"; FAIL=$((FAIL+1)); }

  # 14. DB check: JAR-1001 PAID with a SIMULATED CONFIRMED payment; JAR-1003 has NO CONFIRMED payment
  DB_JSON=$(DATABASE_URL="file:$DB_FILE" node -e "
    const { PrismaClient } = require('@prisma/client');
    (async () => {
      const p = new PrismaClient();
      const inv1 = await p.invoice.findUnique({ where: { number: 'JAR-1001' }, include: { payments: true } });
      const inv3 = await p.invoice.findUnique({ where: { number: 'JAR-1003' }, include: { payments: true } });
      console.log(JSON.stringify({
        inv1: inv1 ? { status: inv1.status, proof: !!inv1.proofHash, confirmed: inv1.payments.filter(x => x.status === 'CONFIRMED').length, simConfirmed: inv1.payments.filter(x => x.status === 'CONFIRMED' && x.simulated).length } : null,
        inv3: inv3 ? { status: inv3.status, confirmed: inv3.payments.filter(x => x.status === 'CONFIRMED').length } : null,
      }));
      await p.\$disconnect();
    })();
  " 2>/tmp/p7-db-err.log)
  if [ -s /tmp/p7-db-err.log ]; then echo "FAIL: 14. DB query failed:"; cat /tmp/p7-db-err.log; FAIL=$((FAIL+1)); fi
  D1_STATUS=$(node -e "console.log(JSON.parse(process.argv[1]).inv1.status)" "$DB_JSON" 2>/dev/null)
  D1_CONF=$(node -e "console.log(JSON.parse(process.argv[1]).inv1.confirmed)" "$DB_JSON" 2>/dev/null)
  D1_SIM=$(node -e "console.log(JSON.parse(process.argv[1]).inv1.simConfirmed)" "$DB_JSON" 2>/dev/null)
  D1_PROOF=$(node -e "console.log(JSON.parse(process.argv[1]).inv1.proof)" "$DB_JSON" 2>/dev/null)
  D3_STATUS=$(node -e "console.log(JSON.parse(process.argv[1]).inv3.status)" "$DB_JSON" 2>/dev/null)
  D3_CONF=$(node -e "console.log(JSON.parse(process.argv[1]).inv3.confirmed)" "$DB_JSON" 2>/dev/null)
  if [ "$D1_STATUS" = "PAID" ] && [ "$D1_CONF" = "1" ] && [ "$D1_SIM" = "1" ] && [ "$D1_PROOF" = "true" ]; then
    echo "PASS: 14. DB: JAR-1001 PAID with one SIMULATED CONFIRMED payment + proofHash"
  else echo "FAIL: 14. DB JAR-1001: status=$D1_STATUS confirmed=$D1_CONF simConfirmed=$D1_SIM proof=$D1_PROOF"; FAIL=$((FAIL+1)); fi
  if [ "$D3_STATUS" = "PENDING" ] && [ "$D3_CONF" = "0" ]; then
    echo "PASS: 14. DB: JAR-1003 PENDING with NO confirmation record (txHash alone created none)"
  else echo "FAIL: 14. DB JAR-1003: status=$D3_STATUS confirmed=$D3_CONF"; FAIL=$((FAIL+1)); fi
fi

# 16. Non-crypto regression (both modes): CASH_APP invoice JAR-1002 —
#     customer reference -> PENDING; ADMIN manual confirm -> PAID.
code=$(curl -s -o /tmp/p7-cash-tx.json -w "%{http_code}" -X POST "$BASE/api/payments/$INV2_ID/confirm" \
  -H "Authorization: Bearer $CUSTA_TOKEN" -H 'Content-Type: application/json' \
  -d '{"reference":"CashAppPayment123"}')
check "16. CASH_APP customer reference -> 200" 200 "$code"
CASH_TX=$(jget /tmp/p7-cash-tx.json "d.data.invoice.status")
[ "$CASH_TX" = "PENDING" ] && echo "PASS: 16. cash invoice still PENDING after reference submit" || { echo "FAIL: 16. cash invoice status is '$CASH_TX'"; FAIL=$((FAIL+1)); }
code=$(curl -s -o /tmp/p7-cash-manual.json -w "%{http_code}" -X POST "$BASE/api/payments/$INV2_ID/confirm" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"reference":"CashAppPayment123","adminConfirm":true}')
check "16. CASH_APP ADMIN manual confirm -> 200" 200 "$code"
CASH_MAN=$(jget /tmp/p7-cash-manual.json "d.data.invoice.status")
[ "$CASH_MAN" = "PAID" ] && echo "PASS: 16. cash invoice PAID by manual confirm (non-crypto flow unchanged)" || { echo "FAIL: 16. cash invoice status is '$CASH_MAN'"; FAIL=$((FAIL+1)); }

# 15. Receipt email: the server log must show the receipt for JAR-1001 (SIMULATED unless SMTP is set)
if [ -f "$LOG_FILE" ]; then
  if grep -a -q "JAR-1001 paid" "$LOG_FILE"; then
    echo "PASS: 15. server log shows the receipt email for JAR-1001"
  else echo "FAIL: 15. no receipt email for JAR-1001 in server log ($LOG_FILE)"; FAIL=$((FAIL+1)); fi
  # JAR-1004 (USDT, Prompt 11) is only paid in the simulated branch — skip in provider mode.
  if [ "$PROVIDER_MODE" != "1" ]; then
    if grep -a -q "JAR-1004 paid" "$LOG_FILE"; then
      echo "PASS: 15. server log shows the receipt email for JAR-1004 (USDT)"
    else echo "FAIL: 15. no receipt email for JAR-1004 in server log ($LOG_FILE)"; FAIL=$((FAIL+1)); fi
  fi
else echo "FAIL: 15. server log not found at $LOG_FILE — start the server with output there"; FAIL=$((FAIL+1)); fi

echo "== Summary: $FAIL failure(s) =="
[ "$FAIL" = 0 ] && echo "ALL PROMPT 7 CRYPTO CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$FAIL"
