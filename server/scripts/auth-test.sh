#!/usr/bin/env bash
# Jarvis Prompt 2 — auth verification script (curl).
#
# Usage (from server/):
#   DATABASE_URL="file:./test-auth.db" npx prisma migrate deploy
#   DATABASE_URL="file:./test-auth.db" PORT=4001 npm run dev   # plain npm run dev;
#       JWT_SECRET is NOT exported here — it must come from server/.env
#       via dotenv, which is exactly what the register/login steps prove.
#   BASE_URL=http://localhost:4001 bash scripts/auth-test.sh
#
# Uses a separate test database (test-auth.db) — never touches dev.db.
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

ADMIN_EMAIL="prompt2-admin@test.local"
ADMIN_PASS="TestAdmin123!"
CUST_EMAIL="prompt2-customer@test.local"

echo "== Prompt 2 auth checks against $BASE =="

# 0. Health (no auth)
code=$(curl -s -o /tmp/p2-health.json -w "%{http_code}" "$BASE/health")
check "0. GET /health, no auth" 200 "$code"

# 1. (a) First registration becomes ADMIN
code=$(curl -s -o /tmp/p2-reg1.json -w "%{http_code}" -X POST "$BASE/api/auth/register" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\",\"name\":\"Prompt Two\"}")
check "1. (a) first register -> 201" 201 "$code"
ROLE=$(jget /tmp/p2-reg1.json "d.data.user.role")
[ "$ROLE" = "ADMIN" ] && echo "PASS: 1. (a) first user role is ADMIN" || { echo "FAIL: 1. (a) first user role is '$ROLE', expected ADMIN"; FAIL=$((FAIL+1)); }
ADMIN_TOKEN=$(jget /tmp/p2-reg1.json "d.data.token")
echo "   admin token: $(mask "$ADMIN_TOKEN")"

# 2. (a) Second registration (no token) is blocked
code=$(curl -s -o /tmp/p2-reg2.json -w "%{http_code}" -X POST "$BASE/api/auth/register" \
  -H 'Content-Type: application/json' \
  -d '{"email":"second@test.local","password":"TestAdmin123!","name":"Second"}')
check "2. (a) second register, no token -> 403" 403 "$code"

# 3. Login as admin
code=$(curl -s -o /tmp/p2-login.json -w "%{http_code}" -X POST "$BASE/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\"}")
check "3. login with correct password -> 200" 200 "$code"
ADMIN_TOKEN=$(jget /tmp/p2-login.json "d.data.token")
echo "   admin token: $(mask "$ADMIN_TOKEN")"

# 4. Wrong password -> 401
code=$(curl -s -o /tmp/p2-badpass.json -w "%{http_code}" -X POST "$BASE/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"WrongPass123!\"}")
check "4. login with wrong password -> 401" 401 "$code"

# 5. (b) /me with a valid token
code=$(curl -s -o /tmp/p2-me.json -w "%{http_code}" "$BASE/api/auth/me" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "5. (b) GET /me with valid token -> 200" 200 "$code"
ME_ROLE=$(jget /tmp/p2-me.json "d.data.user.role")
[ "$ME_ROLE" = "ADMIN" ] && echo "PASS: 5. (b) /me returns ADMIN user" || { echo "FAIL: 5. (b) /me role is '$ME_ROLE'"; FAIL=$((FAIL+1)); }

# 6. (c) /me with no token -> 401
code=$(curl -s -o /tmp/p2-me-none.json -w "%{http_code}" "$BASE/api/auth/me")
check "6. (c) GET /me, no token -> 401" 401 "$code"

# 7. (c) /me with a garbage token -> 401
code=$(curl -s -o /tmp/p2-me-bad.json -w "%{http_code}" "$BASE/api/auth/me" \
  -H "Authorization: Bearer this.is.not.a.valid.token")
check "7. (c) GET /me, garbage token -> 401" 401 "$code"

# 8. (c) /me with an expired token -> 401 (signed with the real JWT_SECRET
#    from server/.env, expiresIn -10s — so this also proves dotenv loaded it)
EXPIRED=$(node -e "const jwt=require('jsonwebtoken');require('dotenv').config();console.log(jwt.sign({sub:'expired-test',role:'ADMIN',email:'expired@test.local'},process.env.JWT_SECRET,{expiresIn:'-10s'}))")
code=$(curl -s -o /tmp/p2-me-exp.json -w "%{http_code}" "$BASE/api/auth/me" \
  -H "Authorization: Bearer $EXPIRED")
check "8. (c) GET /me, expired token -> 401" 401 "$code"

# 9. Admin can use an admin-only route (sanity check before the customer test)
code=$(curl -s -o /tmp/p2-portals-admin.json -w "%{http_code}" "$BASE/api/portals" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "9. ADMIN GET /api/portals -> 200" 200 "$code"

# 10. Create a portal + invite a customer, to get a real CUSTOMER token.
#     NOTE: there is no /api/admin/* route in this codebase — case (d) is
#     verified against the admin-only routes instead (see cases 11-12).
code=$(curl -s -o /tmp/p2-portal.json -w "%{http_code}" -X POST "$BASE/api/portals" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"Prompt Two Test Portal","slug":"prompt-two-test","currency":"USD"}')
check "10. ADMIN creates portal -> 201" 201 "$code"
PORTAL_ID=$(jget /tmp/p2-portal.json "d.data.portal.id")
PORTAL_SLUG=$(jget /tmp/p2-portal.json "d.data.portal.slug")

code=$(curl -s -o /tmp/p2-invite.json -w "%{http_code}" -X POST "$BASE/api/access/invite" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalId\":\"$PORTAL_ID\",\"email\":\"$CUST_EMAIL\"}")
check "10. ADMIN invites customer -> 201" 201 "$code"
CUST_CODE=$(jget /tmp/p2-invite.json "d.data.code")
# The code is never echoed. It lives only in $CUST_CODE for the next call.

code=$(curl -s -o /tmp/p2-custlogin.json -w "%{http_code}" -X POST "$BASE/api/access/login" \
  -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"$PORTAL_SLUG\",\"email\":\"$CUST_EMAIL\",\"code\":\"$CUST_CODE\"}")
check "10. customer login with code -> 200" 200 "$code"
CUST_TOKEN=$(jget /tmp/p2-custlogin.json "d.data.token")
echo "   customer token: $(mask "$CUST_TOKEN")"

# 11. (d) CUSTOMER token on an admin-only route -> 403
code=$(curl -s -o /tmp/p2-portals-cust.json -w "%{http_code}" "$BASE/api/portals" \
  -H "Authorization: Bearer $CUST_TOKEN")
check "11. (d) CUSTOMER GET /api/portals -> 403" 403 "$code"

# 12. (d) CUSTOMER token on another admin-only route -> 403
code=$(curl -s -o /tmp/p2-methods-cust.json -w "%{http_code}" -X POST "$BASE/api/payment-methods" \
  -H "Authorization: Bearer $CUST_TOKEN" -H 'Content-Type: application/json' \
  -d '{"type":"CASH_APP","label":"Test","handle":"$TestOnly"}')
check "12. (d) CUSTOMER POST /api/payment-methods -> 403" 403 "$code"

# 13. (Prompt 14) invite-admin: ADMIN invites a second admin -> 201,
#     role ADMIN, and the response must NOT contain a password hash.
ADMIN2_EMAIL="prompt2-admin2@test.local"
ADMIN2_PASS="SecondAdmin123!"
code=$(curl -s -o /tmp/p2-invadmin.json -w "%{http_code}" -X POST "$BASE/api/auth/invite-admin" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$ADMIN2_EMAIL\",\"password\":\"$ADMIN2_PASS\",\"name\":\"Second Admin\"}")
check "13. ADMIN invite-admin -> 201" 201 "$code"
ROLE2=$(jget /tmp/p2-invadmin.json "d.data.user.role")
[ "$ROLE2" = "ADMIN" ] && echo "PASS: 13. invited user role is ADMIN" || { echo "FAIL: 13. invited user role is '$ROLE2'"; FAIL=$((FAIL+1)); }
HAS_HASH=$(jget /tmp/p2-invadmin.json "('passwordHash' in d.data.user)")
[ "$HAS_HASH" = "false" ] && echo "PASS: 13. invite-admin response has no passwordHash" || { echo "FAIL: 13. invite-admin response leaks passwordHash"; FAIL=$((FAIL+1)); }

# 14. Second admin can log in and do admin work
code=$(curl -s -o /tmp/p2-login2.json -w "%{http_code}" -X POST "$BASE/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$ADMIN2_EMAIL\",\"password\":\"$ADMIN2_PASS\"}")
check "14. second admin login -> 200" 200 "$code"
ADMIN2_TOKEN=$(jget /tmp/p2-login2.json "d.data.token")
echo "   second admin token: $(mask "$ADMIN2_TOKEN")"
code=$(curl -s -o /tmp/p2-portals2.json -w "%{http_code}" "$BASE/api/portals" \
  -H "Authorization: Bearer $ADMIN2_TOKEN")
check "14. second admin GET /api/portals -> 200" 200 "$code"

# 15. Duplicate email -> 400
code=$(curl -s -o /tmp/p2-invdup.json -w "%{http_code}" -X POST "$BASE/api/auth/invite-admin" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$ADMIN2_EMAIL\",\"password\":\"AnotherPass123!\"}")
check "15. invite-admin duplicate email -> 400" 400 "$code"

# 16. Weak password (7 chars, min is 8) -> 400
code=$(curl -s -o /tmp/p2-invweak.json -w "%{http_code}" -X POST "$BASE/api/auth/invite-admin" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"email":"weak@test.local","password":"short7!"}')
check "16. invite-admin weak password -> 400" 400 "$code"

# 17. CUSTOMER token cannot invite an admin -> 403
code=$(curl -s -o /tmp/p2-invcust.json -w "%{http_code}" -X POST "$BASE/api/auth/invite-admin" \
  -H "Authorization: Bearer $CUST_TOKEN" -H 'Content-Type: application/json' \
  -d '{"email":"cust-admin@test.local","password":"CustAdmin123!"}')
check "17. CUSTOMER invite-admin -> 403" 403 "$code"

# 18. No token -> 401; public registration still blocked -> 403
code=$(curl -s -o /tmp/p2-invnotok.json -w "%{http_code}" -X POST "$BASE/api/auth/invite-admin" \
  -H 'Content-Type: application/json' \
  -d '{"email":"notok@test.local","password":"NoTokAdmin123!"}')
check "18. invite-admin, no token -> 401" 401 "$code"
code=$(curl -s -o /tmp/p2-reg3.json -w "%{http_code}" -X POST "$BASE/api/auth/register" \
  -H 'Content-Type: application/json' \
  -d '{"email":"third@test.local","password":"TestAdmin123!","name":"Third"}')
check "18. register still blocked after invite-admin exists -> 403" 403 "$code"

echo "== Summary: $FAIL failure(s) =="
rm -f /tmp/p2-*.json
[ "$FAIL" = 0 ] && echo "ALL PROMPT 2 AUTH CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$FAIL"
