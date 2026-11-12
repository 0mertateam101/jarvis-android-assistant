# Docker end-to-end check — report

Run: https://github.com/0mertateam101/jarvis-android-assistant/actions/runs/43271039730
Commit: 6db07e8e18994ff5d9bdb0e19f21a9706e7dc1bc
Date (UTC): 2026-11-12T17:37:42Z

**Result: PASS — all Docker e2e checks passed.**
**Playwright portal click test: FAIL — exit code 1. See the run log.**

```
PASS: 0. GET /health (HTTP 200)
PASS: 1. first register -> ADMIN (HTTP 201)
PASS: 1. admin login (HTTP 200)
PASS: 2. create portal A (HTTP 201)
PASS: 2. create portal B (HTTP 201)
PASS: 3. create CASH_APP method (HTTP 201)
PASS: 3. create BTC method (HTTP 201)
PASS: 3. assign CASH_APP to portal A (HTTP 201)
PASS: 3. assign BTC to portal B (HTTP 201)
PASS: 4. invite customer A (HTTP 201)
PASS: 4. customer A login (email + code) (HTTP 200)
PASS: 4. login returns portal-a
PASS: 5. invite customer B (HTTP 201)
PASS: 5. customer B login (HTTP 200)
PASS: 6. public methods portal A (HTTP 200)
PASS: 6. portal A shows exactly its CASH_APP method
PASS: 7. public methods portal B (HTTP 200)
PASS: 7. portal B shows exactly its BTC method
PASS: 8. customer A creates invoice on portal A (HTTP 201)
PASS: 8. invoice number is JAR-1001
PASS: 8. barcode payload == Code128 == JARVIS|JAR-1001|150.00|USD
PASS: 8. QR data URL present
PASS: 8. emailStatus is SIMULATED (barcode sent state)
PASS: 9. customer A invoice as another payer -> 403 (HTTP 403)
PASS: 9. denial is generic (Access denied)
PASS: 10. customer B invoice on portal A -> 403 (HTTP 403)
PASS: 11. invoice with unassigned method -> 400 (HTTP 400)
PASS: 12. customer A reads own invoice (HTTP 200)
PASS: 12. customer B reads portal A invoice -> 403 (HTTP 403)
PASS: 13. wrong code login -> 401 (HTTP 401)
PASS: 13. login denial is generic (Invalid credentials)
PASS: 14. customer submits payment reference -> 200 (HTTP 200)
PASS: 14. invoice still PENDING after reference submit (reference alone never pays)
PASS: 15. Don manual confirm (simulated) -> 200 (HTTP 200)
PASS: 15. invoice PAID with proofHash set
PASS: 16. customer A reads receipt (HTTP 200)
PASS: 16. receipt shows JAR-1001 PAID with proofHash
PASS: 17. customer A downloads PDF -> 200 (HTTP 200)
PASS: 17. PDF content-type is application/pdf
PASS: 17. PDF is 1881 bytes
PASS: 17. PDF without token -> 401 (HTTP 401)
PASS: 17. PDF for other portal's customer -> 403 (HTTP 403)
PASS: 18. block customer A (HTTP 201)
PASS: 18. blocked customer login -> 401 (HTTP 401)
PASS: 18. blocked login denial is generic
PASS: 19. admin creates second invoice for blocked customer (HTTP 201)
PASS: 19. second invoice is JAR-1002
PASS: 19. blocked payer confirm -> 403 (HTTP 403)
PASS: 19. blocked invoice stays PENDING
PASS: 20. portal build passes (VITE_API_URL=http://localhost:4000)
PASS: 20. built portal serves / (HTTP 200)
PASS: 20. served page has the app root
PASS: 20. built JS bundle serves (HTTP 200)
PASS: 20. bundle points at the docker server API (http://localhost:4000)
PASS: 20. built bundle has zero localStorage uses (sessionStorage only)
PASS: 20. built bundle uses sessionStorage (6 hits)
PASS: 20. preview server stopped
PASS: 21. CORS allows the portal preview origin (http://localhost:4173)
PASS: 21. CORS preflight for the login call is allowed from the preview origin
PASS: 21. CORS does not allow an unrelated origin (https://evil.example.com)
== Summary: 0 failure(s) ==
ALL DOCKER E2E CHECKS PASSED
```
