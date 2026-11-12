#!/usr/bin/env bash
# Jarvis Prompt 3 — portals + linked accounts verification script (curl).
#
# Usage (from server/):
#   DATABASE_URL="file:./test-portals.db" npx prisma migrate deploy
#   DATABASE_URL="file:./test-portals.db" PORT=4001 npm run dev   # plain npm run dev;
#       JWT_SECRET is NOT exported here — it must come from server/.env
#       via dotenv.
#   BASE_URL=http://localhost:4001 bash scripts/portals-test.sh
#
# Uses a separate test database (test-portals.db) — never touches dev.db.
# Tokens and passwords are NEVER printed in full; only a masked prefix
# and the HTTP status are shown. The invite code is held in a variable
# and never echoed.
set -u
cd "$(dirname "$0")/.." # always run from server/ so dotenv finds ./.env
BASE="${BASE_URL:-http://localhost:4001}"
FAIL=0

mask() { # print first 10 chars of a token + its length, nothing more
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

ADMIN_EMAIL="prompt3-admin@test.local"
ADMIN_PASS="TestAdmin123!"
CUST_EMAIL="prompt3-customer@test.local"

echo "== Prompt 3 portal + linked-account checks against $BASE =="

# 0. Health (no auth)
code=$(curl -s -o /tmp/p3-health.json -w "%{http_code}" "$BASE/health")
check "0. GET /health, no auth" 200 "$code"

# 1. Register first ADMIN + login (setup, same flow as auth-test.sh)
code=$(curl -s -o /tmp/p3-reg.json -w "%{http_code}" -X POST "$BASE/api/auth/register" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\",\"name\":\"Prompt Three\"}")
check "1. first register -> 201" 201 "$code"
ADMIN_TOKEN=$(jget /tmp/p3-reg.json "d.data.token")
echo "   admin token: $(mask "$ADMIN_TOKEN")"

code=$(curl -s -o /tmp/p3-login.json -w "%{http_code}" -X POST "$BASE/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\"}")
check "1. login -> 200" 200 "$code"
ADMIN_TOKEN=$(jget /tmp/p3-login.json "d.data.token")

# 2. Create portal A -> 201
code=$(curl -s -o /tmp/p3-portal-a.json -w "%{http_code}" -X POST "$BASE/api/portals" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"Prompt Three Portal A","slug":"p3-portal-a","description":"First test portal","currency":"USD"}')
check "2. create portal A -> 201" 201 "$code"
PORTAL_A_ID=$(jget /tmp/p3-portal-a.json "d.data.portal.id")
PORTAL_A_SLUG=$(jget /tmp/p3-portal-a.json "d.data.portal.slug")
[ "$PORTAL_A_SLUG" = "p3-portal-a" ] && echo "PASS: 2. portal A slug is p3-portal-a" || { echo "FAIL: 2. portal A slug is '$PORTAL_A_SLUG'"; FAIL=$((FAIL+1)); }

# 3. Duplicate slug -> rejected (400)
code=$(curl -s -o /tmp/p3-dup.json -w "%{http_code}" -X POST "$BASE/api/portals" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"Copy of A","slug":"p3-portal-a","currency":"USD"}')
check "3. duplicate slug -> 400" 400 "$code"

# 4. Create portal B -> 201
code=$(curl -s -o /tmp/p3-portal-b.json -w "%{http_code}" -X POST "$BASE/api/portals" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"Prompt Three Portal B","slug":"p3-portal-b","currency":"USD"}')
check "4. create portal B -> 201" 201 "$code"
PORTAL_B_ID=$(jget /tmp/p3-portal-b.json "d.data.portal.id")

# 5. List portals -> 200, contains both
code=$(curl -s -o /tmp/p3-list.json -w "%{http_code}" "$BASE/api/portals" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "5. list portals -> 200" 200 "$code"
LISTED=$(node -e "const d=require('/tmp/p3-list.json');console.log(d.data.portals.map(p=>p.slug).sort().join(','))" 2>/dev/null)
[ "$LISTED" = "p3-portal-a,p3-portal-b" ] && echo "PASS: 5. list contains both portals" || { echo "FAIL: 5. list is '$LISTED'"; FAIL=$((FAIL+1)); }

# 6. Get portal A by slug -> 200
code=$(curl -s -o /tmp/p3-get-slug.json -w "%{http_code}" "$BASE/api/portals/p3-portal-a" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "6. get portal A by slug -> 200" 200 "$code"

# 7. Get portal A by id -> 200
code=$(curl -s -o /tmp/p3-get-id.json -w "%{http_code}" "$BASE/api/portals/$PORTAL_A_ID" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "7. get portal A by id -> 200" 200 "$code"

# 8. Get unknown slug -> 404
code=$(curl -s -o /tmp/p3-get-404.json -w "%{http_code}" "$BASE/api/portals/no-such-portal" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "8. get unknown slug -> 404" 404 "$code"

# 9. Update portal A (name + description) -> 200
code=$(curl -s -o /tmp/p3-patch.json -w "%{http_code}" -X PATCH "$BASE/api/portals/$PORTAL_A_ID" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"Prompt Three Portal A (Renamed)","description":"Updated description"}')
check "9. PATCH portal A -> 200" 200 "$code"
NEW_NAME=$(jget /tmp/p3-patch.json "d.data.portal.name")
[ "$NEW_NAME" = "Prompt Three Portal A (Renamed)" ] && echo "PASS: 9. name updated" || { echo "FAIL: 9. name is '$NEW_NAME'"; FAIL=$((FAIL+1)); }

# 10. Create portal with no token -> 401
code=$(curl -s -o /tmp/p3-noauth.json -w "%{http_code}" -X POST "$BASE/api/portals" \
  -H 'Content-Type: application/json' \
  -d '{"name":"No Auth Portal","slug":"p3-no-auth","currency":"USD"}')
check "10. create portal, no token -> 401" 401 "$code"

# 11. CUSTOMER token cannot create / edit portals -> 403
code=$(curl -s -o /tmp/p3-invite.json -w "%{http_code}" -X POST "$BASE/api/access/invite" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalId\":\"$PORTAL_A_ID\",\"email\":\"$CUST_EMAIL\"}")
check "11. ADMIN invites customer -> 201" 201 "$code"
CUST_CODE=$(jget /tmp/p3-invite.json "d.data.code")
# The code is never echoed. It lives only in $CUST_CODE for the next call.

code=$(curl -s -o /tmp/p3-custlogin.json -w "%{http_code}" -X POST "$BASE/api/access/login" \
  -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"p3-portal-a\",\"email\":\"$CUST_EMAIL\",\"code\":\"$CUST_CODE\"}")
check "11. customer login with code -> 200" 200 "$code"
CUST_TOKEN=$(jget /tmp/p3-custlogin.json "d.data.token")
echo "   customer token: $(mask "$CUST_TOKEN")"

code=$(curl -s -o /tmp/p3-cust-create.json -w "%{http_code}" -X POST "$BASE/api/portals" \
  -H "Authorization: Bearer $CUST_TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"Customer Portal","slug":"p3-customer-portal","currency":"USD"}')
check "11. CUSTOMER create portal -> 403" 403 "$code"

code=$(curl -s -o /tmp/p3-cust-patch.json -w "%{http_code}" -X PATCH "$BASE/api/portals/$PORTAL_A_ID" \
  -H "Authorization: Bearer $CUST_TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"Hacked Name"}')
check "11. CUSTOMER PATCH portal -> 403" 403 "$code"

# 12. Add linked account to portal A -> 201
code=$(curl -s -o /tmp/p3-acct-a.json -w "%{http_code}" -X POST "$BASE/api/portals/$PORTAL_A_ID/accounts" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"type":"CASH_APP","label":"Cash App","handle":"$TestOnlyA","notes":"Portal A account"}')
check "12. add linked account to portal A -> 201" 201 "$code"
ACCT_ID=$(jget /tmp/p3-acct-a.json "d.data.account.id")
ACCT_PORTAL=$(jget /tmp/p3-acct-a.json "d.data.account.portalId")
[ "$ACCT_PORTAL" = "$PORTAL_A_ID" ] && echo "PASS: 12. account attached to portal A" || { echo "FAIL: 12. account portalId is '$ACCT_PORTAL'"; FAIL=$((FAIL+1)); }

# 13. Add linked account to unknown portal -> 404
code=$(curl -s -o /tmp/p3-acct-404.json -w "%{http_code}" -X POST "$BASE/api/portals/no-such-portal/accounts" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"type":"VENMO","label":"Venmo","handle":"@TestOnly"}')
check "13. add account to unknown portal -> 404" 404 "$code"

# 14. Secret-looking handle rejected -> 400
code=$(curl -s -o /tmp/p3-acct-secret.json -w "%{http_code}" -X POST "$BASE/api/portals/$PORTAL_A_ID/accounts" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"type":"OTHER","label":"Bad","handle":"my private key is abc123"}')
check "14. secret-looking handle -> 400" 400 "$code"

# 15. List accounts for portal A -> 200, shows the account
code=$(curl -s -o /tmp/p3-accts-a.json -w "%{http_code}" "$BASE/api/portals/$PORTAL_A_ID/accounts" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "15. list accounts for portal A -> 200" 200 "$code"
COUNT_A=$(node -e "const d=require('/tmp/p3-accts-a.json');console.log(d.data.accounts.length)" 2>/dev/null)
[ "$COUNT_A" = "1" ] && echo "PASS: 15. portal A has 1 account" || { echo "FAIL: 15. portal A has $COUNT_A accounts"; FAIL=$((FAIL+1)); }

# 16. List accounts for portal B -> 200, does NOT show portal A's account
code=$(curl -s -o /tmp/p3-accts-b.json -w "%{http_code}" "$BASE/api/portals/$PORTAL_B_ID/accounts" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "16. list accounts for portal B -> 200" 200 "$code"
COUNT_B=$(node -e "const d=require('/tmp/p3-accts-b.json');console.log(d.data.accounts.length)" 2>/dev/null)
[ "$COUNT_B" = "0" ] && echo "PASS: 16. portal B has 0 accounts" || { echo "FAIL: 16. portal B has $COUNT_B accounts"; FAIL=$((FAIL+1)); }

# 17. List accounts for unknown portal -> 404
code=$(curl -s -o /tmp/p3-accts-404.json -w "%{http_code}" "$BASE/api/portals/no-such-portal/accounts" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "17. list accounts for unknown portal -> 404" 404 "$code"

# 18. Delete account from the WRONG portal (?portalId=B) -> 404
code=$(curl -s -o /tmp/p3-del-wrong.json -w "%{http_code}" -X DELETE "$BASE/api/accounts/$ACCT_ID?portalId=$PORTAL_B_ID" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "18. delete account from wrong portal -> 404" 404 "$code"

# 19. Delete account from the RIGHT portal (?portalId=A) -> 200
code=$(curl -s -o /tmp/p3-del-right.json -w "%{http_code}" -X DELETE "$BASE/api/accounts/$ACCT_ID?portalId=$PORTAL_A_ID" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "19. delete account from right portal -> 200" 200 "$code"

# 20. Portal A now has 0 accounts; deleting the same account again -> 404
code=$(curl -s -o /tmp/p3-accts-a2.json -w "%{http_code}" "$BASE/api/portals/$PORTAL_A_ID/accounts" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "20. list accounts for portal A again -> 200" 200 "$code"
COUNT_A2=$(node -e "const d=require('/tmp/p3-accts-a2.json');console.log(d.data.accounts.length)" 2>/dev/null)
[ "$COUNT_A2" = "0" ] && echo "PASS: 20. portal A has 0 accounts after delete" || { echo "FAIL: 20. portal A has $COUNT_A2 accounts"; FAIL=$((FAIL+1)); }

code=$(curl -s -o /tmp/p3-del-again.json -w "%{http_code}" -X DELETE "$BASE/api/accounts/$ACCT_ID" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "20. delete same account again -> 404" 404 "$code"

# 21. Archive portal A via DELETE -> 200, status ARCHIVED (never hard-deleted)
code=$(curl -s -o /tmp/p3-archive.json -w "%{http_code}" -X DELETE "$BASE/api/portals/$PORTAL_A_ID" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "21. DELETE (archive) portal A -> 200" 200 "$code"
ARCH_STATUS=$(jget /tmp/p3-archive.json "d.data.portal.status")
[ "$ARCH_STATUS" = "ARCHIVED" ] && echo "PASS: 21. portal A status is ARCHIVED" || { echo "FAIL: 21. portal A status is '$ARCH_STATUS'"; FAIL=$((FAIL+1)); }

# 22. Archived portal is still retrievable, and can be re-activated via PATCH
code=$(curl -s -o /tmp/p3-get-arch.json -w "%{http_code}" "$BASE/api/portals/p3-portal-a" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "22. get archived portal A -> 200" 200 "$code"
code=$(curl -s -o /tmp/p3-reactivate.json -w "%{http_code}" -X PATCH "$BASE/api/portals/$PORTAL_A_ID" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"status":"ACTIVE"}')
check "22. PATCH archived portal back to ACTIVE -> 200" 200 "$code"
REACT_STATUS=$(jget /tmp/p3-reactivate.json "d.data.portal.status")
[ "$REACT_STATUS" = "ACTIVE" ] && echo "PASS: 22. portal A status is ACTIVE again" || { echo "FAIL: 22. portal A status is '$REACT_STATUS'"; FAIL=$((FAIL+1)); }

echo "== Summary: $FAIL failure(s) =="
rm -f /tmp/p3-*.json
[ "$FAIL" = 0 ] && echo "ALL PROMPT 3 PORTAL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$FAIL"
