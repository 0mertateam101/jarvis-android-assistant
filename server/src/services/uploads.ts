// Shared upload handling for Jarvis — ID verification images and portal
// customisation files. One multer setup, reused by verification.ts and
// assets.ts.
//
// Security rules (Prompt 12):
// - Files live under server/uploads/ (gitignored, never committed).
// - Server-side random filenames (cuid + field), never the user-supplied
//   name — the original name is stored in the DB record only.
// - Uploads are NEVER served as a public static path. Files are streamed
//   only through authenticated / explicitly-scoped routes.
// - ID verification images are sensitive PII: never log file contents or
//   paths beyond the record id, and never include image bytes in any API
//   response.

import { randomUUID } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import type { Request } from "express";
import multer, { type FileFilterCallback, type MulterError } from "multer";

/** Absolute path of the uploads root (server/uploads/). */
export function uploadsRoot(): string {
  // src/services/../../uploads in dev (tsx), dist/services/../../uploads
  // in the built server — both resolve to server/uploads/.
  return path.resolve(__dirname, "..", "..", "uploads");
}

export const IMAGE_MIMES = new Set(["image/jpeg", "image/png", "image/webp"]);
export const IMAGE_EXTS = new Set([".jpg", ".jpeg", ".png", ".webp"]);
export const DOC_MIMES = new Set(["application/pdf", "application/msword", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "text/plain"]);
export const DOC_EXTS = new Set([".pdf", ".doc", ".docx", ".txt"]);

export const IMAGE_MAX_BYTES = 10 * 1024 * 1024; // 10 MB per image
export const DOC_MAX_BYTES = 25 * 1024 * 1024; // 25 MB per document

function extOf(filename: string): string {
  return path.extname(filename).toLowerCase();
}

/** Extension the server is willing to store for this upload, or null. */
function allowedExt(mimeType: string, filename: string, allowedMimes: Set<string>, allowedExts: Set<string>): string | null {
  const ext = extOf(filename);
  if (!allowedMimes.has(mimeType) || !allowedExts.has(ext)) return null;
  return ext;
}

/**
 * Build a multer uploader for one set of fields. `fields` maps the
 * multipart field name to its allowed mime/extension sets. Rejects
 * anything else with a 400-friendly error (the route translates it).
 * The per-file size limit is enforced by multer and surfaces as a
 * MulterError (LIMIT_FILE_SIZE) — also translated to 400 by the route.
 */
export function buildUploader(opts: { subdir: (req: Request) => string; fields: Record<string, { mimes: Set<string>; exts: Set<string> }>; maxBytes: number }): multer.Multer {
  return multer({
    storage: multer.diskStorage({
      destination: (req, _file, cb) => {
        const dir = path.join(uploadsRoot(), opts.subdir(req));
        fs.mkdirSync(dir, { recursive: true });
        cb(null, dir);
      },
      filename: (_req, file, cb) => {
        cb(null, `${randomUUID()}-${file.fieldname}${extOf(file.originalname)}`);
      },
    }),
    limits: { fileSize: opts.maxBytes },
    fileFilter: (_req, file, cb: FileFilterCallback) => {
      const spec = opts.fields[file.fieldname];
      if (!spec) return cb(new Error(`Unexpected field "${file.fieldname}"`));
      if (allowedExt(file.mimetype, file.originalname, spec.mimes, spec.exts) === null) {
        return cb(new Error(`File "${file.originalname}" is not an allowed type for field "${file.fieldname}"`));
      }
      cb(null, true);
    },
  });
}

/** Translate a multer failure into an HTTP 400 message (null = not a multer error). */
export function multerErrorMessage(err: unknown): string | null {
  if (err instanceof multer.MulterError) {
    if (err.code === "LIMIT_FILE_SIZE") return "Uploaded file is too large";
    if (err.code === "LIMIT_UNEXPECTED_FILE") return "Unexpected file field";
    return `Upload failed: ${err.message}`;
  }
  if (err instanceof Error) return err.message;
  return null;
}

/** Relative path (from the uploads root) for a stored file — what the DB holds. */
export function relativeUploadPath(absolutePath: string): string {
  return path.relative(uploadsRoot(), absolutePath);
}

/** Absolute path for a stored relative path. */
export function absoluteUploadPath(relativePath: string): string {
  return path.join(uploadsRoot(), relativePath);
}

/** Delete a stored file if it exists. Never throws. */
export function deleteUpload(relativePath: string): void {
  try {
    fs.unlinkSync(absoluteUploadPath(relativePath));
  } catch {
    // Already gone (or never existed) — not an error.
  }
}
