#!/usr/bin/env node
// Sign a webhook payload file with HMAC-SHA256 (test tooling only).
// Usage: node scripts/sign-webhook.mjs <secret> <file>
// Prints: sha256=<hex>  (the exact bytes of <file> are signed, so send
// the same file with curl --data-binary @<file>).
import { createHmac } from "node:crypto";
import { readFileSync } from "node:fs";

const [secret, file] = process.argv.slice(2);
if (!secret || !file) {
  console.error("usage: sign-webhook.mjs <secret> <file>");
  process.exit(2);
}
const body = readFileSync(file);
console.log("sha256=" + createHmac("sha256", secret).update(body).digest("hex"));
