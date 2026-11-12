#!/usr/bin/env bash
# Jarvis Prompt 4 — access-grant verification script (curl + DB check).
#
# Usage (from server/):
#   DATABASE_URL="file:$PWD/prisma/test-access.db" npx prisma migrate deploy
#   DATABASE_URL="file:$PWD/prisma/test-access.db" PORT=4001 npm run dev > /tmp/jarvis-p4-server.log 2>&1 &
#       JWT_SECRET is NOT exported here — it must come from server/.env
#       via dotenv. Start the server with its log at $LOG_FILE below so
#       the final check can prove the plain code never reached the logs.
#   BASE_URL=http://localhost:4001 bash scripts/access-test.sh
#
# The DATABASE_URL must be ABSOLUTE (see above). Prisma resolves a relative
# SQLite path against the schema dir (server/prisma/), not the cwd, so a
# relative URL in the server and a relative URL in this script can silently
# open two different files and the DB check would read an empty DB.
#
# Uses a separate test database (test-access.db) — never touches dev.db.
# Tokens, passwords and codes are NEVER printed in full; only a masked
# prefix and the HTTP status are shown. Codes are held in variables and
# never echoed. The DB and log checks grep for the plain codes and must
# find NO match.
set -u
cd "$(dirname "$0")/.." # always run from server/ so dotenv finds ./.env
BASE="${BASE_URL:-http://localhost:4001}"
DB_FILE="$(pwd)/prisma/test-access.db"
LOG_FILE="${LOG_FILE:-/tmp/jarvis-p4-server.log}"
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

ADMIN_EMAIL="prompt4-admin@test.local"
ADMIN_PASS="TestAdmin123!"
CUST_EMAIL="prompt4-customer@test.local"
CUST2_EMAIL="prompt4-blocked@test.local"

echo "== Prompt 4 access-grant checks against $BASE =="

# 0. Health (no auth)
code=$(curl -s -o /tmp/p4-health.json -w "%{http_code}" "$BASE/health")
check "0. GET /health, no auth" 200 "$code"

# 1. First registration becomes ADMIN + login
code=$(curl -s -o /tmp/p4-reg.json -w "%{http_code}" -X POST "$BASE/api/auth/register" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\",\"name\":\"Prompt Four\"}")
check "1. first register -> 201" 201 "$code"
ADMIN_TOKEN=$(jget /tmp/p4-reg.json "d.data.token")
echo "   admin token: $(mask "$ADMIN_TOKEN")"

# 2. Create portal A
code=$(curl -s -o /tmp/p4-portal.json -w "%{http_code}" -X POST "$BASE/api/portals" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"Prompt Four Test Portal","slug":"p4-portal-a","currency":"USD"}')
check "2. create portal A -> 201" 201 "$code"
PORTAL_ID=$(jget /tmp/p4-portal.json "d.data.portal.id")
PORTAL_SLUG=$(jget /tmp/p4-portal.json "d.data.portal.slug")

# 3. Invite -> 201, code format XXXX-XXXX-XXXX, grant ACTIVE
code=$(curl -s -o /tmp/p4-invite1.json -w "%{http_code}" -X POST "$BASE/api/access/invite" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalId\":\"$PORTAL_ID\",\"email\":\"$CUST_EMAIL\"}")
check "3. invite -> 201" 201 "$code"
CODE1=$(jget /tmp/p4-invite1.json "d.data.code")
STATUS1=$(jget /tmp/p4-invite1.json "d.data.grant.status")
[ "$STATUS1" = "ACTIVE" ] && echo "PASS: 3. grant status is ACTIVE" || { echo "FAIL: 3. grant status is '$STATUS1'"; FAIL=$((FAIL+1)); }
if [[ "$CODE1" =~ ^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$ ]]; then
  echo "PASS: 3. code matches XXXX-XXXX-XXXX format (no ambiguous chars)"
else echo "FAIL: 3. code format wrong: '$(mask "$CODE1")'"; FAIL=$((FAIL+1)); fi
GRANT_ID=$(jget /tmp/p4-invite1.json "d.data.grant.id")

# 3b. Invite to unknown portal -> 404
code=$(curl -s -o /tmp/p4-invite-bad.json -w "%{http_code}" -X POST "$BASE/api/access/invite" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalId\":\"no-such-portal\",\"email\":\"$CUST_EMAIL\"}")
check "3b. invite to unknown portal -> 404" 404 "$code"

# 4. Login with the correct code -> 200; token is a short-lived,
#    portal-scoped customer JWT (12h, portalId claim)
code=$(curl -s -o /tmp/p4-login1.json -w "%{http_code}" -X POST "$BASE/api/access/login" \
  -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"$PORTAL_SLUG\",\"email\":\"$CUST_EMAIL\",\"code\":\"$CODE1\"}")
check "4. login with correct code -> 200" 200 "$code"
CUST_TOKEN=$(jget /tmp/p4-login1.json "d.data.token")
echo "   customer token: $(mask "$CUST_TOKEN")"
read -r T_ROLE T_PORTAL T_TTL < <(TOKEN="$CUST_TOKEN" node -e "
  const jwt=require('jsonwebtoken');
  const p=jwt.decode(process.env.TOKEN);
  console.log(p.role, p.portalId, p.exp - p.iat);
")
[ "$T_ROLE" = "CUSTOMER" ] && echo "PASS: 4. token role is CUSTOMER" || { echo "FAIL: 4. token role is '$T_ROLE'"; FAIL=$((FAIL+1)); }
[ "$T_PORTAL" = "$PORTAL_ID" ] && echo "PASS: 4. token portalId matches portal A" || { echo "FAIL: 4. token portalId mismatch"; FAIL=$((FAIL+1)); }
[ "$T_TTL" = "43200" ] && echo "PASS: 4. token TTL is 12h (43200s)" || { echo "FAIL: 4. token TTL is '$T_TTL', expected 43200"; FAIL=$((FAIL+1)); }

# 4b. GET /api/access/me with the customer token -> 200, same portal
code=$(curl -s -o /tmp/p4-me.json -w "%{http_code}" "$BASE/api/access/me" \
  -H "Authorization: Bearer $CUST_TOKEN")
check "4b. GET /api/access/me (customer) -> 200" 200 "$code"
ME_PORTAL=$(jget /tmp/p4-me.json "d.data.portalId")
[ "$ME_PORTAL" = "$PORTAL_ID" ] && echo "PASS: 4b. /me portalId matches portal A" || { echo "FAIL: 4b. /me portalId mismatch"; FAIL=$((FAIL+1)); }

# 5. Wrong code -> 401, generic message
code=$(curl -s -o /tmp/p4-wrong.json -w "%{http_code}" -X POST "$BASE/api/access/login" \
  -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"$PORTAL_SLUG\",\"email\":\"$CUST_EMAIL\",\"code\":\"AAAA-BBBB-CCCC\"}")
check "5. login with wrong code -> 401" 401 "$code"
WRONG_ERR=$(jget /tmp/p4-wrong.json "JSON.stringify(d.error)")

# 6. Unknown email -> 401, SAME generic body as the wrong-code case
code=$(curl -s -o /tmp/p4-unknown.json -w "%{http_code}" -X POST "$BASE/api/access/login" \
  -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"$PORTAL_SLUG\",\"email\":\"nobody@test.local\",\"code\":\"$CODE1\"}")
check "6. login with unknown email -> 401" 401 "$code"
UNKNOWN_ERR=$(jget /tmp/p4-unknown.json "JSON.stringify(d.error)")
if [ "$WRONG_ERR" = "$UNKNOWN_ERR" ] && [ "$WRONG_ERR" = '{"code":"INVALID_CREDENTIALS","message":"Invalid credentials"}' ]; then
  echo "PASS: 5/6. wrong-code and unknown-email failures are identical + generic"
else echo "FAIL: 5/6. failure bodies differ or are not generic: '$WRONG_ERR' vs '$UNKNOWN_ERR'"; FAIL=$((FAIL+1)); fi

# 7. Re-invite rotates the code: old code dies, new code works
code=$(curl -s -o /tmp/p4-invite2.json -w "%{http_code}" -X POST "$BASE/api/access/invite" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalId\":\"$PORTAL_ID\",\"email\":\"$CUST_EMAIL\"}")
check "7. re-invite -> 201" 201 "$code"
CODE2=$(jget /tmp/p4-invite2.json "d.data.code")
code=$(curl -s -o /tmp/p4-oldcode.json -w "%{http_code}" -X POST "$BASE/api/access/login" \
  -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"$PORTAL_SLUG\",\"email\":\"$CUST_EMAIL\",\"code\":\"$CODE1\"}")
check "7. login with rotated-out code -> 401" 401 "$code"
code=$(curl -s -o /tmp/p4-login2.json -w "%{http_code}" -X POST "$BASE/api/access/login" \
  -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"$PORTAL_SLUG\",\"email\":\"$CUST_EMAIL\",\"code\":\"$CODE2\"}")
check "7. login with new code -> 200" 200 "$code"

# 8. Revoke the grant -> login with the same (previously good) code fails
code=$(curl -s -o /tmp/p4-revoke.json -w "%{http_code}" -X POST "$BASE/api/access/revoke" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"grantId\":\"$GRANT_ID\"}")
check "8. revoke grant -> 200" 200 "$code"
REV_STATUS=$(jget /tmp/p4-revoke.json "d.data.grant.status")
[ "$REV_STATUS" = "REVOKED" ] && echo "PASS: 8. grant status is REVOKED" || { echo "FAIL: 8. grant status is '$REV_STATUS'"; FAIL=$((FAIL+1)); }
code=$(curl -s -o /tmp/p4-revoked-login.json -w "%{http_code}" -X POST "$BASE/api/access/login" \
  -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"$PORTAL_SLUG\",\"email\":\"$CUST_EMAIL\",\"code\":\"$CODE2\"}")
check "8. login with revoked grant's code -> 401" 401 "$code"
REV_ERR=$(jget /tmp/p4-revoked-login.json "JSON.stringify(d.error)")
[ "$REV_ERR" = '{"code":"INVALID_CREDENTIALS","message":"Invalid credentials"}' ] && echo "PASS: 8. revoked login failure is generic" || { echo "FAIL: 8. revoked login body: '$REV_ERR'"; FAIL=$((FAIL+1)); }

# 8b. Revoke unknown grant -> 404; grants list is scoped
code=$(curl -s -o /tmp/p4-revoke-bad.json -w "%{http_code}" -X POST "$BASE/api/access/revoke" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"grantId":"no-such-grant"}')
check "8b. revoke unknown grant -> 404" 404 "$code"
code=$(curl -s -o /tmp/p4-grants.json -w "%{http_code}" "$BASE/api/access/portals/$PORTAL_ID/grants" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "8b. list grants for portal A -> 200" 200 "$code"
code=$(curl -s -o /tmp/p4-grants-bad.json -w "%{http_code}" "$BASE/api/access/portals/no-such-portal/grants" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "8b. list grants for unknown portal -> 404" 404 "$code"

# 9. Blocked user: block -> login fails even with a good code; unblock ->
#    login STILL fails (grant TERMINATED, no blocklist row); re-invite
#    restores access with a fresh code.
code=$(curl -s -o /tmp/p4-invite3.json -w "%{http_code}" -X POST "$BASE/api/access/invite" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalId\":\"$PORTAL_ID\",\"email\":\"$CUST2_EMAIL\"}")
check "9. invite second customer -> 201" 201 "$code"
CODE3=$(jget /tmp/p4-invite3.json "d.data.code")
code=$(curl -s -o /tmp/p4-block.json -w "%{http_code}" -X POST "$BASE/api/security/block" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalId\":\"$PORTAL_ID\",\"email\":\"$CUST2_EMAIL\",\"reason\":\"Prompt 4 test block\"}")
check "9. block user -> 201" 201 "$code"
BLOCKED_ID=$(jget /tmp/p4-block.json "d.data.blocked.id")
code=$(curl -s -o /tmp/p4-blocked-login.json -w "%{http_code}" -X POST "$BASE/api/access/login" \
  -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"$PORTAL_SLUG\",\"email\":\"$CUST2_EMAIL\",\"code\":\"$CODE3\"}")
check "9. blocked user login with good code -> 401" 401 "$code"
BLOCKED_ERR=$(jget /tmp/p4-blocked-login.json "JSON.stringify(d.error)")
[ "$BLOCKED_ERR" = '{"code":"INVALID_CREDENTIALS","message":"Invalid credentials"}' ] && echo "PASS: 9. blocked login failure is generic" || { echo "FAIL: 9. blocked login body: '$BLOCKED_ERR'"; FAIL=$((FAIL+1)); }
code=$(curl -s -o /tmp/p4-unblock.json -w "%{http_code}" -X POST "$BASE/api/security/unblock" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"blockedId\":\"$BLOCKED_ID\"}")
check "9. unblock -> 200" 200 "$code"
code=$(curl -s -o /tmp/p4-term-login.json -w "%{http_code}" -X POST "$BASE/api/access/login" \
  -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"$PORTAL_SLUG\",\"email\":\"$CUST2_EMAIL\",\"code\":\"$CODE3\"}")
check "9. unblocked but TERMINATED grant login -> 401" 401 "$code"
code=$(curl -s -o /tmp/p4-invite4.json -w "%{http_code}" -X POST "$BASE/api/access/invite" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalId\":\"$PORTAL_ID\",\"email\":\"$CUST2_EMAIL\"}")
check "9. re-invite after termination -> 201" 201 "$code"
CODE4=$(jget /tmp/p4-invite4.json "d.data.code")
code=$(curl -s -o /tmp/p4-login4.json -w "%{http_code}" -X POST "$BASE/api/access/login" \
  -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"$PORTAL_SLUG\",\"email\":\"$CUST2_EMAIL\",\"code\":\"$CODE4\"}")
check "9. login with fresh code after re-invite -> 200" 200 "$code"

# 10. Customer token cannot invite (ADMIN-only) -> 403
code=$(curl -s -o /tmp/p4-cust-invite.json -w "%{http_code}" -X POST "$BASE/api/access/invite" \
  -H "Authorization: Bearer $CUST_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalId\":\"$PORTAL_ID\",\"email\":\"other@test.local\"}")
check "10. CUSTOMER invite -> 403" 403 "$code"

# 11. DB holds ONLY the hash: query the test DB directly, and grep the raw
#     DB file + server log for every plain code issued — no match allowed.
#     Absolute DATABASE_URL (see header) so this reads the same file the
#     server wrote. Every grant's hash is checked, and a DB error is shown
#     instead of being swallowed.
HASHES=$(DATABASE_URL="file:$DB_FILE" node -e "
  const { PrismaClient } = require('@prisma/client');
  (async () => {
    const p = new PrismaClient();
    const gs = await p.accessGrant.findMany();
    for (const g of gs) console.log(g.codeHash);
    await p.\$disconnect();
  })();
" 2>/tmp/p4-prisma-err.log)
if [ -s /tmp/p4-prisma-err.log ]; then
  echo "FAIL: 11. DB query failed:"; cat /tmp/p4-prisma-err.log; FAIL=$((FAIL+1));
fi
HASH_OK=1; HASH_COUNT=0
while IFS= read -r H; do
  [ -z "$H" ] && continue
  HASH_COUNT=$((HASH_COUNT+1))
  if ! [[ "$H" =~ ^\$2[ab]\$12\$ ]] || [ "${#H}" != 60 ]; then HASH_OK=0; fi
done <<< "$HASHES"
if [ "$HASH_OK" = 1 ] && [ "$HASH_COUNT" -ge 1 ]; then
  echo "PASS: 11. all $HASH_COUNT stored codeHash values are bcrypt hashes (len 60)"
else echo "FAIL: 11. stored codeHash check failed (grants checked: $HASH_COUNT)"; FAIL=$((FAIL+1)); fi
if [ ! -s "$DB_FILE" ]; then
  echo "FAIL: 11. DB file missing or empty at $DB_FILE"; FAIL=$((FAIL+1));
fi
DB_LEAK=0
for C in "$CODE1" "$CODE2" "$CODE3" "$CODE4"; do
  if grep -a -F -q "$C" "$DB_FILE"; then
    echo "FAIL: 11. plain code '$(mask "$C")' FOUND in DB file"; DB_LEAK=1; FAIL=$((FAIL+1));
  fi
done
[ "$DB_LEAK" = 0 ] && echo "PASS: 11. no plain code found in DB file ($DB_FILE)"
if [ -f "$LOG_FILE" ]; then
  LEAK=0
  for C in "$CODE1" "$CODE2" "$CODE3" "$CODE4"; do
    if grep -a -F -q "$C" "$LOG_FILE"; then echo "FAIL: 11. plain code '$(mask "$C")' FOUND in server log"; LEAK=1; FAIL=$((FAIL+1)); fi
  done
  [ "$LEAK" = 0 ] && echo "PASS: 11. no plain code found in server log ($LOG_FILE)"
else echo "FAIL: 11. server log not found at $LOG_FILE — start the server with output there"; FAIL=$((FAIL+1)); fi

echo "== Summary: $FAIL failure(s) =="
rm -f /tmp/p4-*.json
[ "$FAIL" = 0 ] && echo "ALL PROMPT 4 ACCESS CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$FAIL"
