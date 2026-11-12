import bcrypt from "bcrypt";
import crypto from "node:crypto";

// Access-code rules (see docs/ARCHITECTURE.md):
// - Format XXXX-XXXX-XXXX, uppercase, no ambiguous chars (I, O, 0, 1).
// - Generated with crypto.randomBytes. Hashed with bcrypt before storage.
// - The plain code is shown ONCE (invite response, to Don only) and is
//   never stored, never logged, never emailed by the server.

const ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // no I/O/0/1
const BCRYPT_ROUNDS = 12;

function randomChunk(length: number): string {
  const bytes = crypto.randomBytes(length);
  let out = "";
  for (const b of bytes) out += ALPHABET[b % ALPHABET.length];
  return out;
}

/** Generate a new access code, e.g. "7HLM-BN8B-2V9X". */
export function generateAccessCode(): string {
  return `${randomChunk(4)}-${randomChunk(4)}-${randomChunk(4)}`;
}

/** Hash a code for storage. Never store the plain code. */
export async function hashCode(code: string): Promise<string> {
  return bcrypt.hash(code, BCRYPT_ROUNDS);
}

/** Verify a presented code against the stored hash. Constant-time via bcrypt. */
export async function verifyCode(code: string, hash: string): Promise<boolean> {
  try {
    return await bcrypt.compare(code, hash);
  } catch {
    return false;
  }
}

/** Proof hash for a completed payment (printed on the receipt / PDF). */
export function proofHash(input: string): string {
  return crypto.createHash("sha256").update(input).digest("hex");
}
