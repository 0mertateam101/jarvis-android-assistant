// Decode a QR code PNG and print its text.
// Usage: node scripts/decode-qr.mjs <file>
// The file holds a `data:image/png;base64,…` URL (as returned by the
// invoice API) or raw base64 PNG bytes. Exit 1 if no QR code is found.
import { readFileSync } from "node:fs";
import { PNG } from "pngjs";
import jsQR from "jsqr";

const file = process.argv[2];
if (!file) {
  console.error("usage: decode-qr.mjs <file>");
  process.exit(2);
}
let raw = readFileSync(file, "utf8").trim();
if (raw.includes(",")) raw = raw.split(",").slice(1).join(",");
const png = PNG.sync.read(Buffer.from(raw, "base64"));
const code = jsQR(new Uint8ClampedArray(png.data), png.width, png.height);
if (!code) {
  console.error("NO_QR_FOUND");
  process.exit(1);
}
process.stdout.write(code.data);
