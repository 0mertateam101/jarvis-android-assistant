#!/usr/bin/env bash
# Jarvis Prompt 5 — payment-methods verification script (curl).
#
# Usage (from server/):
#   DATABASE_URL="file:$PWD/prisma/test-payments.db" npx prisma migrate deploy
#   DATABASE_URL="file:$PWD/prisma/test-payments.db" PORT=4001 npm run dev > /tmp/jarvis-p5-server.log 2>&1 &
#       JWT_SECRET is NOT exported here — it must come from server/.env
#       via dotenv.
#   BASE_URL=http://localhost:4001 bash scripts/payments-test.sh
#
# The DATABASE_URL must be ABSOLUTE (see above). Prisma resolves a relative
# SQLite path against the schema dir (server/prisma/), not the cwd, so a
# relative URL in the server and a relative URL in this script can silently
# open two different files.
#
# Uses a separate test database (test-payments.db) — never touches dev.db.
# Tokens and handles are NEVER printed in full; only a masked prefix and
# the HTTP status are shown.
set -u
cd "$(dirname "$0")/.." # always run from server/ so dotenv finds ./.env
BASE="${BASE_URL:-http://localhost:4001}"
DB_FILE="$(pwd)/prisma/test-payments.db"
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

# mcount <json-file> — number of methods in a list response
mcount() { node -e "console.log(require('$1').data.methods.length)" 2>/dev/null; }

# has_id <json-file> <id> — 0 if the methods list contains the id
has_id() { node -e "process.exit(require('$1').data.methods.some(m=>m.id==='$2')?0:1)" 2>/dev/null; }

ADMIN_EMAIL="prompt5-admin@test.local"
ADMIN_PASS="TestAdmin123!"
CUST_EMAIL="prompt5-customer@test.local"
XMR_ADDR="4$(printf 'A%.0s' $(seq 1 94))" # 95-char test-shaped XMR address
USDT_ADDR="0x742d35Cc6634C0532925a3b844Bc454e4438f44e" # 0x + 40 hex (ERC-20 style)
USDC_ADDR="TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t" # T + 33 base58 (Tron style)
DOGE_ADDR="DH5yaieqoZN36fDVciNyRueRG4G6y3oEya" # D + 33 base58

echo "== Prompt 5 payment-method checks against $BASE =="

# 0. Health (no auth)
code=$(curl -s -o /tmp/p5-health.json -w "%{http_code}" "$BASE/health")
check "0. GET /health, no auth" 200 "$code"

# 1. First registration becomes ADMIN + login
code=$(curl -s -o /tmp/p5-reg.json -w "%{http_code}" -X POST "$BASE/api/auth/register" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\",\"name\":\"Prompt Five\"}")
check "1. first register -> 201" 201 "$code"
ADMIN_TOKEN=$(jget /tmp/p5-reg.json "d.data.token")
echo "   admin token: $(mask "$ADMIN_TOKEN")"

code=$(curl -s -o /tmp/p5-login.json -w "%{http_code}" -X POST "$BASE/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\"}")
check "1. login -> 200" 200 "$code"
ADMIN_TOKEN=$(jget /tmp/p5-login.json "d.data.token")

# 2. Create portals A and B
code=$(curl -s -o /tmp/p5-portal-a.json -w "%{http_code}" -X POST "$BASE/api/portals" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"Prompt Five Portal A","slug":"p5-portal-a","currency":"USD"}')
check "2. create portal A -> 201" 201 "$code"
PORTAL_A=$(jget /tmp/p5-portal-a.json "d.data.portal.id")
SLUG_A=$(jget /tmp/p5-portal-a.json "d.data.portal.slug")

code=$(curl -s -o /tmp/p5-portal-b.json -w "%{http_code}" -X POST "$BASE/api/portals" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"Prompt Five Portal B","slug":"p5-portal-b","currency":"USD"}')
check "2. create portal B -> 201" 201 "$code"
PORTAL_B=$(jget /tmp/p5-portal-b.json "d.data.portal.id")
SLUG_B=$(jget /tmp/p5-portal-b.json "d.data.portal.slug")

# 3. Create one method of each of several types -> 201 each
create_method() { # create_method <outfile> <type> <label> <handle>
  curl -s -o "$1" -w "%{http_code}" -X POST "$BASE/api/payment-methods" \
    -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
    -d "{\"type\":\"$2\",\"label\":\"$3\",\"handle\":\"$4\"}"
}
code=$(create_method /tmp/p5-m1.json CASH_APP "Cash App P5" "\$p5cash")
check "3. create CASH_APP -> 201" 201 "$code"
M1=$(jget /tmp/p5-m1.json "d.data.method.id")
code=$(create_method /tmp/p5-m2.json VENMO "Venmo P5" "@p5venmo")
check "3. create VENMO -> 201" 201 "$code"
M2=$(jget /tmp/p5-m2.json "d.data.method.id")
code=$(create_method /tmp/p5-m3.json CHIME "Chime P5" "\$p5chime")
check "3. create CHIME -> 201" 201 "$code"
M3=$(jget /tmp/p5-m3.json "d.data.method.id")
code=$(create_method /tmp/p5-m4.json ZELLE "Zelle P5" "p5zelle@test.local")
check "3. create ZELLE -> 201" 201 "$code"
M4=$(jget /tmp/p5-m4.json "d.data.method.id")
code=$(create_method /tmp/p5-m5.json BTC "BTC P5" "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq")
check "3. create BTC -> 201" 201 "$code"
M5=$(jget /tmp/p5-m5.json "d.data.method.id")
code=$(create_method /tmp/p5-m6.json LTC "LTC P5" "LVg2kJoFNg45Nbpy53h7Fe1wKyeXVRhZq")
check "3. create LTC -> 201" 201 "$code"
M6=$(jget /tmp/p5-m6.json "d.data.method.id")
code=$(create_method /tmp/p5-m7.json XMR "XMR P5" "$XMR_ADDR")
check "3. create XMR -> 201" 201 "$code"
M7=$(jget /tmp/p5-m7.json "d.data.method.id")
code=$(create_method /tmp/p5-m8.json ETH "ETH P5" "0x742d35Cc6634C0532925a3b844Bc454e4438f44e")
check "3. create ETH -> 201" 201 "$code"
M8=$(jget /tmp/p5-m8.json "d.data.method.id")
code=$(create_method /tmp/p5-m9.json USDT "USDT P5" "$USDT_ADDR")
check "3. create USDT (0x address) -> 201" 201 "$code"
M9=$(jget /tmp/p5-m9.json "d.data.method.id")
code=$(create_method /tmp/p5-m10.json USDC "USDC P5" "$USDC_ADDR")
check "3. create USDC (Tron T-address) -> 201" 201 "$code"
M10=$(jget /tmp/p5-m10.json "d.data.method.id")
code=$(create_method /tmp/p5-m11.json DOGE "DOGE P5" "$DOGE_ADDR")
check "3. create DOGE (D-address) -> 201" 201 "$code"
M11=$(jget /tmp/p5-m11.json "d.data.method.id")

# 4. Invalid type / secret handle / wrong format -> 400 each
code=$(create_method /tmp/p5-badtype.json SHIB "Shib P5" "0x12345")
check "4. invalid type SHIB -> 400" 400 "$code"
code=$(create_method /tmp/p5-secret.json CASH_APP "Secret P5" "my private key is abc123")
check "4. private-key-looking handle -> 400" 400 "$code"
code=$(create_method /tmp/p5-hex.json ETH "Hex P5" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
check "4. raw 64-hex handle -> 400" 400 "$code"
code=$(create_method /tmp/p5-hexusdt.json USDT "Hex USDT P5" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
check "4. raw 64-hex USDT handle -> 400" 400 "$code"
code=$(create_method /tmp/p5-nope.json CASH_APP "No Dollar P5" "p5cash")
check "4. CASH_APP without \$ -> 400" 400 "$code"
code=$(create_method /tmp/p5-noat.json VENMO "No At P5" "p5venmo")
check "4. VENMO without @ -> 400" 400 "$code"
code=$(create_method /tmp/p5-badeth.json ETH "Bad ETH P5" "0x1234")
check "4. short ETH address -> 400" 400 "$code"
code=$(create_method /tmp/p5-badusdt.json USDT "Bad USDT P5" "0x1234")
check "4. short USDT address -> 400" 400 "$code"
code=$(create_method /tmp/p5-badusdc.json USDC "Bad USDC P5" "not-an-address")
check "4. bad USDC address -> 400" 400 "$code"
code=$(create_method /tmp/p5-baddoge.json DOGE "Bad DOGE P5" "Xh5yaieqoZN36fDVciNyRueRG4G6y3oEya")
check "4. DOGE with wrong prefix -> 400" 400 "$code"
code=$(create_method /tmp/p5-shortdoge.json DOGE "Short DOGE P5" "D123")
check "4. short DOGE address -> 400" 400 "$code"

# 5. List methods -> 200, all 11 created ones present
code=$(curl -s -o /tmp/p5-list.json -w "%{http_code}" "$BASE/api/payment-methods" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "5. list methods -> 200" 200 "$code"
N=$(mcount /tmp/p5-list.json)
[ "$N" = "11" ] && echo "PASS: 5. list has 11 methods" || { echo "FAIL: 5. list has $N methods, expected 11"; FAIL=$((FAIL+1)); }

# 6. Get one method -> 200; unknown id -> 404
code=$(curl -s -o /tmp/p5-get1.json -w "%{http_code}" "$BASE/api/payment-methods/$M1" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "6. get method M1 -> 200" 200 "$code"
code=$(curl -s -o /tmp/p5-getx.json -w "%{http_code}" "$BASE/api/payment-methods/no-such-method" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "6. get unknown method -> 404" 404 "$code"

# 7. Assign M1+M2+M9 to portal A, M2+M3 to portal B
assign() { # assign <portal-id-or-slug> <method-id>
  curl -s -o /tmp/p5-assign.json -w "%{http_code}" -X POST "$BASE/api/portals/$1/methods" \
    -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
    -d "{\"paymentMethodId\":\"$2\"}"
}
code=$(assign "$PORTAL_A" "$M1"); check "7. assign M1 to portal A -> 201" 201 "$code"
code=$(assign "$PORTAL_A" "$M2"); check "7. assign M2 to portal A -> 201" 201 "$code"
code=$(assign "$PORTAL_A" "$M9"); check "7. assign M9 (USDT) to portal A -> 201" 201 "$code"
code=$(assign "$PORTAL_B" "$M2"); check "7. assign M2 to portal B -> 201" 201 "$code"
code=$(assign "$PORTAL_B" "$M3"); check "7. assign M3 to portal B -> 201" 201 "$code"

# 8. Pay-page listings: A shows ONLY M1+M2+M9, B shows ONLY M2+M3
code=$(curl -s -o /tmp/p5-pub-a.json -w "%{http_code}" "$BASE/api/portals/$SLUG_A/public-methods")
check "8. public-methods portal A -> 200" 200 "$code"
N=$(mcount /tmp/p5-pub-a.json)
[ "$N" = "3" ] && echo "PASS: 8. portal A shows 3 methods" || { echo "FAIL: 8. portal A shows $N methods, expected 3"; FAIL=$((FAIL+1)); }
has_id /tmp/p5-pub-a.json "$M1" && has_id /tmp/p5-pub-a.json "$M2" && has_id /tmp/p5-pub-a.json "$M9" && ! has_id /tmp/p5-pub-a.json "$M3" \
  && echo "PASS: 8. portal A shows exactly M1+M2+M9 (incl. USDT)" || { echo "FAIL: 8. portal A method set wrong"; FAIL=$((FAIL+1)); }
code=$(curl -s -o /tmp/p5-pub-b.json -w "%{http_code}" "$BASE/api/portals/$SLUG_B/public-methods")
check "8. public-methods portal B -> 200" 200 "$code"
N=$(mcount /tmp/p5-pub-b.json)
[ "$N" = "2" ] && echo "PASS: 8. portal B shows 2 methods" || { echo "FAIL: 8. portal B shows $N methods, expected 2"; FAIL=$((FAIL+1)); }
has_id /tmp/p5-pub-b.json "$M2" && has_id /tmp/p5-pub-b.json "$M3" && ! has_id /tmp/p5-pub-b.json "$M1" \
  && echo "PASS: 8. portal B shows exactly M2+M3" || { echo "FAIL: 8. portal B method set wrong"; FAIL=$((FAIL+1)); }

# 9. Assign M1 to A again -> 201, no duplicate (A still shows 3)
code=$(assign "$PORTAL_A" "$M1"); check "9. assign M1 to portal A again -> 201" 201 "$code"
code=$(curl -s -o /tmp/p5-pub-a2.json -w "%{http_code}" "$BASE/api/portals/$SLUG_A/public-methods")
N=$(mcount /tmp/p5-pub-a2.json)
[ "$N" = "3" ] && echo "PASS: 9. portal A still shows 3 methods (no duplicate)" || { echo "FAIL: 9. portal A shows $N methods after re-assign"; FAIL=$((FAIL+1)); }

# 10. Unassign M2 from A -> 200; A now shows only M1+M9
code=$(curl -s -o /tmp/p5-unassign.json -w "%{http_code}" -X DELETE "$BASE/api/portals/$PORTAL_A/methods/$M2" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "10. unassign M2 from portal A -> 200" 200 "$code"
code=$(curl -s -o /tmp/p5-pub-a3.json -w "%{http_code}" "$BASE/api/portals/$SLUG_A/public-methods")
N=$(mcount /tmp/p5-pub-a3.json)
[ "$N" = "2" ] && echo "PASS: 10. portal A now shows 2 methods" || { echo "FAIL: 10. portal A shows $N methods after unassign"; FAIL=$((FAIL+1)); }
has_id /tmp/p5-pub-a3.json "$M1" && has_id /tmp/p5-pub-a3.json "$M9" && ! has_id /tmp/p5-pub-a3.json "$M2" \
  && echo "PASS: 10. portal A shows only M1+M9" || { echo "FAIL: 10. portal A method set wrong after unassign"; FAIL=$((FAIL+1)); }

# 11. Assign/unassign with unknown portal or method -> 404
code=$(assign "no-such-portal" "$M1"); check "11. assign to unknown portal -> 404" 404 "$code"
code=$(assign "$PORTAL_A" "no-such-method"); check "11. assign unknown method -> 404" 404 "$code"
code=$(curl -s -o /tmp/p5-unx.json -w "%{http_code}" -X DELETE "$BASE/api/portals/no-such-portal/methods/$M1" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "11. unassign from unknown portal -> 404" 404 "$code"
code=$(curl -s -o /tmp/p5-unx2.json -w "%{http_code}" -X DELETE "$BASE/api/portals/$PORTAL_A/methods/no-such-method" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "11. unassign unknown method -> 404" 404 "$code"

# 12. CUSTOMER token cannot create / assign / delete / get methods -> 403
code=$(curl -s -o /tmp/p5-invite.json -w "%{http_code}" -X POST "$BASE/api/access/invite" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalId\":\"$PORTAL_A\",\"email\":\"$CUST_EMAIL\"}")
check "12. ADMIN invites customer -> 201" 201 "$code"
CUST_CODE=$(jget /tmp/p5-invite.json "d.data.code")
code=$(curl -s -o /tmp/p5-custlogin.json -w "%{http_code}" -X POST "$BASE/api/access/login" \
  -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"$SLUG_A\",\"email\":\"$CUST_EMAIL\",\"code\":\"$CUST_CODE\"}")
check "12. customer login with code -> 200" 200 "$code"
CUST_TOKEN=$(jget /tmp/p5-custlogin.json "d.data.token")
echo "   customer token: $(mask "$CUST_TOKEN")"
code=$(curl -s -o /tmp/p5-cust-create.json -w "%{http_code}" -X POST "$BASE/api/payment-methods" \
  -H "Authorization: Bearer $CUST_TOKEN" -H 'Content-Type: application/json' \
  -d '{"type":"CASH_APP","label":"Cust","handle":"$cust"}')
check "12. CUSTOMER create method -> 403" 403 "$code"
code=$(curl -s -o /tmp/p5-cust-assign.json -w "%{http_code}" -X POST "$BASE/api/portals/$PORTAL_A/methods" \
  -H "Authorization: Bearer $CUST_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"paymentMethodId\":\"$M1\"}")
check "12. CUSTOMER assign method -> 403" 403 "$code"
code=$(curl -s -o /tmp/p5-cust-del.json -w "%{http_code}" -X DELETE "$BASE/api/payment-methods/$M1" \
  -H "Authorization: Bearer $CUST_TOKEN")
check "12. CUSTOMER delete method -> 403" 403 "$code"
code=$(curl -s -o /tmp/p5-cust-get.json -w "%{http_code}" "$BASE/api/payment-methods/$M1" \
  -H "Authorization: Bearer $CUST_TOKEN")
check "12. CUSTOMER get method -> 403" 403 "$code"

# 13. Delete M3 (assigned to B) -> 200; gone from list, from B's listing, get -> 404
code=$(curl -s -o /tmp/p5-del.json -w "%{http_code}" -X DELETE "$BASE/api/payment-methods/$M3" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "13. delete method M3 -> 200" 200 "$code"
code=$(curl -s -o /tmp/p5-list2.json -w "%{http_code}" "$BASE/api/payment-methods" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
N=$(mcount /tmp/p5-list2.json)
[ "$N" = "10" ] && echo "PASS: 13. list now has 10 methods" || { echo "FAIL: 13. list has $N methods, expected 10"; FAIL=$((FAIL+1)); }
code=$(curl -s -o /tmp/p5-pub-b2.json -w "%{http_code}" "$BASE/api/portals/$SLUG_B/public-methods")
N=$(mcount /tmp/p5-pub-b2.json)
[ "$N" = "1" ] && echo "PASS: 13. portal B now shows 1 method" || { echo "FAIL: 13. portal B shows $N methods after delete"; FAIL=$((FAIL+1)); }
has_id /tmp/p5-pub-b2.json "$M2" && ! has_id /tmp/p5-pub-b2.json "$M3" \
  && echo "PASS: 13. portal B shows only M2" || { echo "FAIL: 13. portal B method set wrong after delete"; FAIL=$((FAIL+1)); }
code=$(curl -s -o /tmp/p5-getdel.json -w "%{http_code}" "$BASE/api/payment-methods/$M3" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "13. get deleted method -> 404" 404 "$code"
code=$(curl -s -o /tmp/p5-del2.json -w "%{http_code}" -X DELETE "$BASE/api/payment-methods/$M3" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "13. delete method again -> 404" 404 "$code"

# 14. No token -> 401
code=$(curl -s -o /tmp/p5-notok.json -w "%{http_code}" -X POST "$BASE/api/payment-methods" \
  -H 'Content-Type: application/json' \
  -d '{"type":"CASH_APP","label":"NoTok","handle":"$notok"}')
check "14. create method, no token -> 401" 401 "$code"

echo "== Summary: $FAIL failure(s) =="
rm -f /tmp/p5-*.json
[ "$FAIL" = 0 ] && echo "ALL PROMPT 5 PAYMENT CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$FAIL"
