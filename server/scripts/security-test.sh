#!/usr/bin/env bash
# Jarvis Prompt 8 — security verification (visit logging, reverse lookup,
# blocklist + termination, blocklist enforced on login and payment).
#
# Usage (from server/):
#   DATABASE_URL="file:$PWD/prisma/test-security.db" npx prisma migrate deploy
#   IP_LOOKUP_BASE_URL=http://127.0.0.1:9 DATABASE_URL="file:$PWD/prisma/test-security.db" PORT=4001 npm run dev > /tmp/jarvis-p8-server.log 2>&1 &
#       JWT_SECRET is NOT exported here — it must come from server/.env
#       via dotenv.
#   SECURITY_DB_FILE="$PWD/prisma/test-security.db" BASE_URL=http://localhost:4001 bash scripts/security-test.sh
#
# The DATABASE_URL must be ABSOLUTE (Prompt 4 lesson). Prisma resolves a
# relative SQLite path against the schema dir (server/prisma/), not the
# cwd, so a relative URL in the server and a relative URL in this script
# can silently open two different files. Pass the DB file explicitly via
# SECURITY_DB_FILE (Prompt 7 lesson) or the DB check reads the wrong file.
#
# Lookup note: the server MUST be started with IP_LOOKUP_BASE_URL pointed
# at an unreachable address (above) so the geo lookup deterministically
# fails and the FALLBACK path is proven — the test must not depend on live
# internet. (ip-api.com actually answers for TEST-NET-3 with real data, so
# a TEST-NET IP alone does NOT force the fallback; the unreachable base
# URL does.) Unauthorised visits use TEST-NET IPs (203.0.113.x), which have
# no PTR record, and the stored lookup fields are asserted to be UNKNOWN
# rather than empty/missing.
#
# Uses a separate test database (test-security.db) — never touches dev.db.
# Tokens, codes and IPs are NEVER printed in full beyond the test IPs;
# tokens are masked, codes are held in variables and never echoed.
set -u
cd "$(dirname "$0")/.." # always run from server/ so dotenv finds ./.env
BASE="${BASE_URL:-http://localhost:4001}"
DB_FILE="${SECURITY_DB_FILE:-$(pwd)/prisma/test-security.db}"
FAIL=0

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

ADMIN_EMAIL="prompt8-admin@test.local"
ADMIN_PASS="TestAdmin123!"
CUSTA_EMAIL="prompt8-customer-a@test.local"
CUSTB_EMAIL="prompt8-customer-b@test.local"
UNKNOWN_EMAIL="prompt8-nobody@test.local"
UNK_IP="203.0.113.10"
UNK_IP_B="203.0.113.20"
BLOCKED_IP="203.0.113.99"
GENERIC_ERR='{"code":"INVALID_CREDENTIALS","message":"Invalid credentials"}'

cleanup() {
  rm -f /tmp/p8-*.json /tmp/p8-db-err.log
}
trap cleanup EXIT

echo "== Prompt 8 security checks against $BASE =="

# 0. Health (no auth)
code=$(curl -s -o /tmp/p8-health.json -w "%{http_code}" "$BASE/health")
check "0. GET /health, no auth" 200 "$code"

# 1. First register -> ADMIN, login
code=$(curl -s -o /tmp/p8-reg.json -w "%{http_code}" -X POST "$BASE/api/auth/register" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\",\"name\":\"Prompt Eight\"}")
check "1. first register -> 201" 201 "$code"
ADMIN_TOKEN=$(jget /tmp/p8-reg.json "d.data.token")
code=$(curl -s -o /tmp/p8-login.json -w "%{http_code}" -X POST "$BASE/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\"}")
check "1. login -> 200" 200 "$code"
ADMIN_TOKEN=$(jget /tmp/p8-login.json "d.data.token")
echo "   admin token: $(mask "$ADMIN_TOKEN")"

# 2. Create portals A + B
code=$(curl -s -o /tmp/p8-portal-a.json -w "%{http_code}" -X POST "$BASE/api/portals" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"Prompt Eight Portal A","slug":"p8-portal-a","currency":"USD"}')
check "2. create portal A -> 201" 201 "$code"
PORTAL_A_ID=$(jget /tmp/p8-portal-a.json "d.data.portal.id")
code=$(curl -s -o /tmp/p8-portal-b.json -w "%{http_code}" -X POST "$BASE/api/portals" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"Prompt Eight Portal B","slug":"p8-portal-b","currency":"USD"}')
check "2. create portal B -> 201" 201 "$code"
PORTAL_B_ID=$(jget /tmp/p8-portal-b.json "d.data.portal.id")

# 3. CASH_APP method + assign to portal A
code=$(curl -s -o /tmp/p8-method.json -w "%{http_code}" -X POST "$BASE/api/payment-methods" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"type":"CASH_APP","label":"Cash App Test","handle":"$P8TestCash"}')
check "3. create CASH_APP method -> 201" 201 "$code"
METHOD_ID=$(jget /tmp/p8-method.json "d.data.method.id")
code=$(curl -s -o /tmp/p8-assign.json -w "%{http_code}" -X POST "$BASE/api/portals/$PORTAL_A_ID/methods" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"paymentMethodId\":\"$METHOD_ID\"}")
check "3. assign method to portal A -> 201" 201 "$code"

# 4. Invite + log in customers A and B
code=$(curl -s -o /tmp/p8-invite-a.json -w "%{http_code}" -X POST "$BASE/api/access/invite" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalId\":\"$PORTAL_A_ID\",\"email\":\"$CUSTA_EMAIL\"}")
check "4. invite customer A -> 201" 201 "$code"
CODE_A=$(jget /tmp/p8-invite-a.json "d.data.code")
code=$(curl -s -o /tmp/p8-cust-a-login.json -w "%{http_code}" -X POST "$BASE/api/access/login" \
  -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"p8-portal-a\",\"email\":\"$CUSTA_EMAIL\",\"code\":\"$CODE_A\"}")
check "4. customer A login -> 200" 200 "$code"
CUSTA_TOKEN=$(jget /tmp/p8-cust-a-login.json "d.data.token")
echo "   customer A token: $(mask "$CUSTA_TOKEN")"
code=$(curl -s -o /tmp/p8-invite-b.json -w "%{http_code}" -X POST "$BASE/api/access/invite" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalId\":\"$PORTAL_B_ID\",\"email\":\"$CUSTB_EMAIL\"}")
check "4. invite customer B -> 201" 201 "$code"
CODE_B=$(jget /tmp/p8-invite-b.json "d.data.code")
code=$(curl -s -o /tmp/p8-cust-b-login.json -w "%{http_code}" -X POST "$BASE/api/access/login" \
  -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"p8-portal-b\",\"email\":\"$CUSTB_EMAIL\",\"code\":\"$CODE_B\"}")
check "4. customer B login -> 200" 200 "$code"
CUSTB_TOKEN=$(jget /tmp/p8-cust-b-login.json "d.data.token")

# 5. Invoice for customer A (used for the payment-block check)
code=$(curl -s -o /tmp/p8-inv.json -w "%{http_code}" -X POST "$BASE/api/invoices" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"p8-portal-a\",\"payerEmail\":\"$CUSTA_EMAIL\",\"payerName\":\"P8 Customer\",\"amount\":\"150.00\",\"currency\":\"USD\",\"items\":[{\"description\":\"Coaching — November\",\"amount\":\"150.00\"}],\"paymentMethodId\":\"$METHOD_ID\"}")
check "5. create invoice for customer A -> 201" 201 "$code"
INV_A_ID=$(jget /tmp/p8-inv.json "d.data.invoice.id")
INV_A_NUM=$(jget /tmp/p8-inv.json "d.data.invoice.number")
expect "5. invoice number is JAR-1001" "JAR-1001" "$INV_A_NUM"

# 6. Unauthorised visit to A (TEST-NET IP, no grant) -> 201, lookup runs, FALLBACK/UNKNOWN
code=$(curl -s -o /tmp/p8-visit-unauth.json -w "%{http_code}" -X POST "$BASE/api/security/visit" \
  -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"p8-portal-a\",\"ip\":\"$UNK_IP\",\"userAgent\":\"P8TestAgent/1.0\",\"path\":\"/pay\"}")
check "6. unauthorised visit -> 201" 201 "$code"
expect "6. unauthorised visit hasAccess=false" "false" "$(jget /tmp/p8-visit-unauth.json "d.data.log.hasAccess")"
expect "6. unauthorised visit ptr is UNKNOWN (fallback)" "UNKNOWN" "$(jget /tmp/p8-visit-unauth.json "d.data.log.ptr")"
expect "6. unauthorised visit country is UNKNOWN (fallback)" "UNKNOWN" "$(jget /tmp/p8-visit-unauth.json "d.data.log.country")"
expect "6. unauthorised visit isp is UNKNOWN (fallback)" "UNKNOWN" "$(jget /tmp/p8-visit-unauth.json "d.data.log.isp")"
expect "6. unauthorised visit lookupSource is FALLBACK" "FALLBACK" "$(jget /tmp/p8-visit-unauth.json "d.data.log.lookupSource")"

# 7. Authorised visit (hasAccess flag) -> 201, NO lookup
code=$(curl -s -o /tmp/p8-visit-auth.json -w "%{http_code}" -X POST "$BASE/api/security/visit" \
  -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"p8-portal-a\",\"ip\":\"$UNK_IP\",\"userAgent\":\"P8TestAgent/1.0\",\"path\":\"/pay\",\"hasAccess\":true}")
check "7. authorised visit (flag) -> 201" 201 "$code"
expect "7. authorised visit lookupSource is SKIPPED-HAS-ACCESS" "SKIPPED-HAS-ACCESS" "$(jget /tmp/p8-visit-auth.json "d.data.log.lookupSource")"

# 8. Authorised visit verified server-side via email (no hasAccess flag)
code=$(curl -s -o /tmp/p8-visit-email.json -w "%{http_code}" -X POST "$BASE/api/security/visit" \
  -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"p8-portal-a\",\"ip\":\"$UNK_IP\",\"userAgent\":\"P8TestAgent/1.0\",\"path\":\"/pay\",\"email\":\"$CUSTA_EMAIL\"}")
check "8. authorised visit (email verified) -> 201" 201 "$code"
expect "8. server verified the grant: hasAccess=true" "true" "$(jget /tmp/p8-visit-email.json "d.data.log.hasAccess")"
expect "8. no lookup ran for the verified visit" "SKIPPED-HAS-ACCESS" "$(jget /tmp/p8-visit-email.json "d.data.log.lookupSource")"

# 9. Visit with an unknown email -> 201, lookup runs (grant check fails server-side)
code=$(curl -s -o /tmp/p8-visit-unkemail.json -w "%{http_code}" -X POST "$BASE/api/security/visit" \
  -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"p8-portal-a\",\"ip\":\"$UNK_IP\",\"userAgent\":\"P8TestAgent/1.0\",\"path\":\"/pay\",\"email\":\"$UNKNOWN_EMAIL\"}")
check "9. visit with unknown email -> 201" 201 "$code"
expect "9. unknown email is unauthorised" "false" "$(jget /tmp/p8-visit-unkemail.json "d.data.log.hasAccess")"
expect "9. lookup ran for the unknown email" "FALLBACK" "$(jget /tmp/p8-visit-unkemail.json "d.data.log.lookupSource")"

# 10. Visit to an unknown portal -> 404
code=$(curl -s -o /tmp/p8-visit-unkportal.json -w "%{http_code}" -X POST "$BASE/api/security/visit" \
  -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"no-such-portal\",\"ip\":\"$UNK_IP\",\"path\":\"/pay\"}")
check "10. visit to unknown portal -> 404" 404 "$code"

# 11. Unauthorised visit to portal B (isolation: B's report must not leak into A's)
code=$(curl -s -o /tmp/p8-visit-b.json -w "%{http_code}" -X POST "$BASE/api/security/visit" \
  -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"p8-portal-b\",\"ip\":\"$UNK_IP_B\",\"userAgent\":\"P8TestAgent/1.0\",\"path\":\"/pay\"}")
check "11. unauthorised visit to portal B -> 201" 201 "$code"
expect "11. portal B visit lookupSource is FALLBACK" "FALLBACK" "$(jget /tmp/p8-visit-b.json "d.data.log.lookupSource")"

# 12. Traffic list for A (ADMIN) -> 200, 4 logs, has the unauthorised visit with lookup data, no B visit
code=$(curl -s -o /tmp/p8-traffic-a.json -w "%{http_code}" "$BASE/api/security/portals/$PORTAL_A_ID/traffic" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "12. ADMIN traffic list for A -> 200" 200 "$code"
expect "12. portal A has 4 visit logs" "4" "$(jget /tmp/p8-traffic-a.json "d.data.logs.length")"
expect "12. portal A report contains the unauthorised IP" "true" "$(jget /tmp/p8-traffic-a.json "d.data.logs.some(l=>l.ip==='$UNK_IP')")"
expect "12. portal A report does NOT contain portal B's visit" "false" "$(jget /tmp/p8-traffic-a.json "d.data.logs.some(l=>l.ip==='$UNK_IP_B')")"
expect "12. unauthorised log in the report has country UNKNOWN" "UNKNOWN" "$(jget /tmp/p8-traffic-a.json "d.data.logs.find(l=>l.ip==='$UNK_IP'&&!l.hasAccess).country")"

# 13. Traffic list for B (ADMIN) -> 200, 1 log
code=$(curl -s -o /tmp/p8-traffic-b.json -w "%{http_code}" "$BASE/api/security/portals/$PORTAL_B_ID/traffic" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "13. ADMIN traffic list for B -> 200" 200 "$code"
expect "13. portal B has 1 visit log" "1" "$(jget /tmp/p8-traffic-b.json "d.data.logs.length")"

# 14. Traffic list by slug -> 200; unknown portal -> 404; CUSTOMER -> 403; no token -> 401
code=$(curl -s -o /tmp/p8-traffic-slug.json -w "%{http_code}" "$BASE/api/security/portals/p8-portal-a/traffic" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "14. traffic list by slug -> 200" 200 "$code"
code=$(curl -s -o /tmp/p8-traffic-unk.json -w "%{http_code}" "$BASE/api/security/portals/no-such-portal/traffic" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "14. traffic list for unknown portal -> 404" 404 "$code"
code=$(curl -s -o /tmp/p8-traffic-cust.json -w "%{http_code}" "$BASE/api/security/portals/$PORTAL_A_ID/traffic" \
  -H "Authorization: Bearer $CUSTA_TOKEN")
check "14. CUSTOMER traffic list -> 403" 403 "$code"
code=$(curl -s -o /tmp/p8-traffic-notok.json -w "%{http_code}" "$BASE/api/security/portals/$PORTAL_A_ID/traffic")
check "14. traffic list with no token -> 401" 401 "$code"

# 15. Block customer A (email, portal A) -> 201; grant becomes TERMINATED
code=$(curl -s -o /tmp/p8-block-a.json -w "%{http_code}" -X POST "$BASE/api/security/block" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalId\":\"$PORTAL_A_ID\",\"email\":\"$CUSTA_EMAIL\",\"reason\":\"Prompt 8 test block\"}")
check "15. block customer A -> 201" 201 "$code"
BLOCKED_ID_A=$(jget /tmp/p8-block-a.json "d.data.blocked.id")
code=$(curl -s -o /tmp/p8-grants-a.json -w "%{http_code}" "$BASE/api/access/portals/$PORTAL_A_ID/grants" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "15. grants list -> 200" 200 "$code"
expect "15. customer A grant is TERMINATED" "TERMINATED" "$(jget /tmp/p8-grants-a.json "d.data.grants.find(g=>g.email==='$CUSTA_EMAIL').status")"

# 16. Blocked customer A login with the good code -> 401 generic
code=$(curl -s -o /tmp/p8-blocked-login.json -w "%{http_code}" -X POST "$BASE/api/access/login" \
  -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"p8-portal-a\",\"email\":\"$CUSTA_EMAIL\",\"code\":\"$CODE_A\"}")
check "16. blocked customer A login -> 401" 401 "$code"
BLOCKED_ERR=$(jget /tmp/p8-blocked-login.json "JSON.stringify(d.error)")
[ "$BLOCKED_ERR" = "$GENERIC_ERR" ] && echo "PASS: 16. blocked login failure is generic" || { echo "FAIL: 16. blocked login body: '$BLOCKED_ERR'"; FAIL=$((FAIL+1)); }

# 17. Blocked customer A payment confirm -> 403 generic; invoice stays PENDING
code=$(curl -s -o /tmp/p8-blocked-confirm.json -w "%{http_code}" -X POST "$BASE/api/payments/$INV_A_ID/confirm" \
  -H "Authorization: Bearer $CUSTA_TOKEN" -H 'Content-Type: application/json' \
  -d '{"reference":"CashAppRefBlocked1"}')
check "17. blocked payer payment confirm -> 403" 403 "$code"
code=$(curl -s -o /tmp/p8-inv-check.json -w "%{http_code}" "$BASE/api/invoices/$INV_A_ID" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "17. GET invoice as ADMIN -> 200" 200 "$code"
expect "17. invoice stays PENDING after blocked confirm" "PENDING" "$(jget /tmp/p8-inv-check.json "d.data.invoice.status")"

# 18. Block an unknown email (no grant) -> 201, no crash, unrelated users unaffected
code=$(curl -s -o /tmp/p8-block-unk.json -w "%{http_code}" -X POST "$BASE/api/security/block" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalId\":\"$PORTAL_A_ID\",\"email\":\"$UNKNOWN_EMAIL\",\"reason\":\"Prompt 8 test block unknown\"}")
check "18. block unknown email -> 201" 201 "$code"
code=$(curl -s -o /tmp/p8-cust-b-still-ok.json -w "%{http_code}" -X POST "$BASE/api/access/login" \
  -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"p8-portal-b\",\"email\":\"$CUSTB_EMAIL\",\"code\":\"$CODE_B\"}")
check "18. unrelated customer B login still works -> 200" 200 "$code"

# 19. Block with unknown portalId -> 404 (not a 500); no email/ip -> 400; CUSTOMER block -> 403
code=$(curl -s -o /tmp/p8-block-unkportal.json -w "%{http_code}" -X POST "$BASE/api/security/block" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"portalId":"no-such-portal","email":"x@test.local","reason":"bad portal"}')
check "19. block with unknown portal -> 404" 404 "$code"
code=$(curl -s -o /tmp/p8-block-empty.json -w "%{http_code}" -X POST "$BASE/api/security/block" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"portalId":"p8-portal-a","reason":"nothing to block"}')
check "19. block with neither email nor IP -> 400" 400 "$code"
code=$(curl -s -o /tmp/p8-block-cust.json -w "%{http_code}" -X POST "$BASE/api/security/block" \
  -H "Authorization: Bearer $CUSTA_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalId\":\"$PORTAL_A_ID\",\"email\":\"$CUSTB_EMAIL\",\"reason\":\"customer trying to block\"}")
check "19. CUSTOMER block attempt -> 403" 403 "$code"

# 20. Block by IP (global — no portalId, so it applies to every portal) -> 201
code=$(curl -s -o /tmp/p8-block-ip.json -w "%{http_code}" -X POST "$BASE/api/security/block" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"ip\":\"$BLOCKED_IP\",\"reason\":\"Prompt 8 test IP block\"}")
check "20. block by IP (global) -> 201" 201 "$code"
BLOCKED_ID_IP=$(jget /tmp/p8-block-ip.json "d.data.blocked.id")

# 21. Visit from the blocked IP -> 403 (denied) but still logged in portal A's report
code=$(curl -s -o /tmp/p8-visit-blocked-ip.json -w "%{http_code}" -X POST "$BASE/api/security/visit" \
  -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"p8-portal-a\",\"ip\":\"$BLOCKED_IP\",\"userAgent\":\"P8TestAgent/1.0\",\"path\":\"/pay\"}")
check "21. visit from blocked IP -> 403" 403 "$code"
code=$(curl -s -o /tmp/p8-traffic-a2.json -w "%{http_code}" "$BASE/api/security/portals/$PORTAL_A_ID/traffic" \
  -H "Authorization: Bearer $ADMIN_TOKEN")
check "21. traffic list again -> 200" 200 "$code"
expect "21. portal A now has 5 visit logs" "5" "$(jget /tmp/p8-traffic-a2.json "d.data.logs.length")"
expect "21. blocked-IP visit is in the report" "true" "$(jget /tmp/p8-traffic-a2.json "d.data.logs.some(l=>l.ip==='$BLOCKED_IP')")"

# 22. Login from the blocked IP (X-Forwarded-For) -> 401 generic
code=$(curl -s -o /tmp/p8-ip-blocked-login.json -w "%{http_code}" -X POST "$BASE/api/access/login" \
  -H 'Content-Type: application/json' -H "X-Forwarded-For: $BLOCKED_IP" \
  -d "{\"portalSlug\":\"p8-portal-b\",\"email\":\"$CUSTB_EMAIL\",\"code\":\"$CODE_B\"}")
check "22. login from blocked IP -> 401" 401 "$code"
IPBLOCKED_ERR=$(jget /tmp/p8-ip-blocked-login.json "JSON.stringify(d.error)")
[ "$IPBLOCKED_ERR" = "$GENERIC_ERR" ] && echo "PASS: 22. IP-blocked login failure is generic" || { echo "FAIL: 22. IP-blocked login body: '$IPBLOCKED_ERR'"; FAIL=$((FAIL+1)); }

# 23. Unblock the IP -> 200; login from that IP works again -> 200
code=$(curl -s -o /tmp/p8-unblock-ip.json -w "%{http_code}" -X POST "$BASE/api/security/unblock" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"blockedId\":\"$BLOCKED_ID_IP\"}")
check "23. unblock IP -> 200" 200 "$code"
code=$(curl -s -o /tmp/p8-ip-unblocked-login.json -w "%{http_code}" -X POST "$BASE/api/access/login" \
  -H 'Content-Type: application/json' -H "X-Forwarded-For: $BLOCKED_IP" \
  -d "{\"portalSlug\":\"p8-portal-b\",\"email\":\"$CUSTB_EMAIL\",\"code\":\"$CODE_B\"}")
check "23. login from unblocked IP -> 200" 200 "$code"

# 24. Unblock customer A -> 200; old code still fails (grant stays TERMINATED); re-invite -> new code works
code=$(curl -s -o /tmp/p8-unblock-a.json -w "%{http_code}" -X POST "$BASE/api/security/unblock" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"blockedId\":\"$BLOCKED_ID_A\"}")
check "24. unblock customer A -> 200" 200 "$code"
code=$(curl -s -o /tmp/p8-term-login.json -w "%{http_code}" -X POST "$BASE/api/access/login" \
  -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"p8-portal-a\",\"email\":\"$CUSTA_EMAIL\",\"code\":\"$CODE_A\"}")
check "24. unblocked but TERMINATED login -> 401" 401 "$code"
code=$(curl -s -o /tmp/p8-reinvite-a.json -w "%{http_code}" -X POST "$BASE/api/access/invite" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"portalId\":\"$PORTAL_A_ID\",\"email\":\"$CUSTA_EMAIL\"}")
check "24. re-invite after termination -> 201" 201 "$code"
CODE_A2=$(jget /tmp/p8-reinvite-a.json "d.data.code")
code=$(curl -s -o /tmp/p8-login-a2.json -w "%{http_code}" -X POST "$BASE/api/access/login" \
  -H 'Content-Type: application/json' \
  -d "{\"portalSlug\":\"p8-portal-a\",\"email\":\"$CUSTA_EMAIL\",\"code\":\"$CODE_A2\"}")
check "24. login with fresh code after re-invite -> 200" 200 "$code"

# 25. Unblock unknown id -> 404; unblock with bad body -> 400
code=$(curl -s -o /tmp/p8-unblock-unk.json -w "%{http_code}" -X POST "$BASE/api/security/unblock" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"blockedId":"no-such-block"}')
check "25. unblock unknown id -> 404" 404 "$code"
code=$(curl -s -o /tmp/p8-unblock-bad.json -w "%{http_code}" -X POST "$BASE/api/security/unblock" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{}')
check "25. unblock with bad body -> 400" 400 "$code"

# 26. DB check (absolute path, errors shown): the unauthorised visit is
#     stored with UNKNOWN lookup fields + FALLBACK; the authorised visit
#     stored SKIPPED-HAS-ACCESS; portal A has 5 logs, portal B has 1.
DB_JSON=$(PID="$PORTAL_A_ID" UNK_IP="$UNK_IP" DATABASE_URL="file:$DB_FILE" node -e "
  const { PrismaClient } = require('@prisma/client');
  (async () => {
    const p = new PrismaClient();
    const logs = await p.trafficLog.findMany({ where: { portalId: process.env.PID } });
    const unauth = logs.find(l => l.ip === process.env.UNK_IP && !l.hasAccess);
    const auth = logs.find(l => l.hasAccess === true);
    console.log(JSON.stringify({
      count: logs.length,
      unauthCountry: unauth ? unauth.country : null,
      unauthSource: unauth ? unauth.lookupSource : null,
      authSource: auth ? auth.lookupSource : null,
    }));
    await p.\$disconnect();
  })();
" 2>/tmp/p8-db-err.log)
if [ -s /tmp/p8-db-err.log ]; then echo "FAIL: 26. DB query failed:"; cat /tmp/p8-db-err.log; FAIL=$((FAIL+1)); fi
expect "26. DB: portal A has 5 traffic logs" "5" "$(node -e "console.log(JSON.parse(process.argv[1]).count)" "$DB_JSON" 2>/dev/null)"
expect "26. DB: unauthorised log country is UNKNOWN" "UNKNOWN" "$(node -e "console.log(JSON.parse(process.argv[1]).unauthCountry)" "$DB_JSON" 2>/dev/null)"
expect "26. DB: unauthorised log lookupSource is FALLBACK" "FALLBACK" "$(node -e "console.log(JSON.parse(process.argv[1]).unauthSource)" "$DB_JSON" 2>/dev/null)"
expect "26. DB: authorised log lookupSource is SKIPPED-HAS-ACCESS" "SKIPPED-HAS-ACCESS" "$(node -e "console.log(JSON.parse(process.argv[1]).authSource)" "$DB_JSON" 2>/dev/null)"

echo "== Summary: $FAIL failure(s) =="
[ "$FAIL" = 0 ] && echo "ALL PROMPT 8 SECURITY CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$FAIL"
