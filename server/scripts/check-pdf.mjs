// Check a PDF receipt contains expected text.
// Usage: node scripts/check-pdf.mjs <pdf-file> <text1> [text2...]
// PDFKit compresses content streams (FlateDecode) AND writes text as
// hex-encoded chunks (e.g. "INVOICE RECEIPT" arrives as <494e56> +
// <4f4943452052454345495054>), so plain grep on the file cannot see the
// text — this inflates the streams, hex-decodes the TJ strings, joins
// the fragments in order, and then greps. Exit 1 if any text is missing.
import { readFileSync } from "node:fs";
import { inflateSync } from "node:zlib";

const [file, ...needles] = process.argv.slice(2);
if (!file || needles.length === 0) {
  console.error("usage: check-pdf.mjs <pdf-file> <text1> [text2...]");
  process.exit(2);
}
const buf = readFileSync(file);
const latin = buf.toString("latin1");
if (!latin.startsWith("%PDF")) {
  console.error("NOT_A_PDF");
  process.exit(2);
}

// Collect decompressed content-stream text.
let content = "";
const streamRe = /stream\r?\n([\s\S]*?)\r?\nendstream/g;
let m;
while ((m = streamRe.exec(latin)) !== null) {
  const raw = Buffer.from(m[1], "latin1");
  try {
    content += inflateSync(raw).toString("latin1");
  } catch {
    content += m[1];
  }
}

// Decode hex strings <48656c6c6f> and literal (strings), in order, and
// join the fragments — PDFKit splits words across TJ chunks.
let decoded = "";
const hexRe = /<([0-9A-Fa-f]+)>/g;
while ((m = hexRe.exec(content)) !== null) {
  decoded += Buffer.from(m[1], "hex").toString("latin1");
}
const litRe = /\((?:\\.|[^\\()])*\)/g;
while ((m = litRe.exec(content)) !== null) {
  decoded += m[0].slice(1, -1).replace(/\\([()\\])/g, "$1");
}
const haystack = content + "\n" + decoded;

let ok = true;
for (const n of needles) {
  if (!haystack.includes(n)) {
    console.error(`MISSING: ${n}`);
    ok = false;
  }
}
if (!ok) process.exit(1);
console.log(`PDF_OK (${buf.length} bytes, ${decoded.length} chars of text)`);
