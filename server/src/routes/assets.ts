import fs from "node:fs";
import path from "node:path";
import { Router } from "express";
import { z } from "zod";
import { prisma } from "../db";
import { AuthedRequest, authMiddleware } from "../middleware/auth";
import { requireAdmin } from "../middleware/requireAdmin";
import {
  DOC_EXTS,
  DOC_MAX_BYTES,
  DOC_MIMES,
  IMAGE_EXTS,
  IMAGE_MAX_BYTES,
  IMAGE_MIMES,
  absoluteUploadPath,
  buildUploader,
  deleteUpload,
  multerErrorMessage,
  relativeUploadPath,
} from "../services/uploads";

// Portal customisation files Don uploads — logo, banner, images and
// documents that make a portal his own.
//
// Rules (Prompt 12):
// - ADMIN only for upload/list/delete, owner-scoped. The file itself is
//   public ONLY through GET /api/portals/:slug/assets/:id/file, which
//   streams by asset id — never a static directory listing.
// - Images (jpeg/png/webp/gif, <= 10 MB) for LOGO/BANNER/IMAGE;
//   documents (pdf/doc/docx/txt, <= 25 MB) for DOCUMENT/FILE.
//   Executables, archives and anything else are rejected with 400.
// - One LOGO and one BANNER per portal max: uploading a new one
//   replaces the old (old file + record deleted).
// - ID verification images are a different model and are NEVER
//   reachable through this route — the lookup is PortalAsset only.

export const assetsRouter = Router();

const ASSET_KINDS = ["LOGO", "BANNER", "IMAGE", "DOCUMENT", "FILE"] as const;
const IMAGE_KINDS = new Set(["LOGO", "BANNER", "IMAGE"]);
const GIF_MIMES = new Set([...IMAGE_MIMES, "image/gif"]);
const GIF_EXTS = new Set([...IMAGE_EXTS, ".gif"]);

const uploadSchema = z.object({
  kind: z.enum(ASSET_KINDS),
});

const IMAGE_FILE_EXTS: Record<string, string> = {
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".png": "image/png",
  ".webp": "image/webp",
  ".gif": "image/gif",
};

type UploadFiles = { [field: string]: Express.Multer.File[] };

function filesOf(req: AuthedRequest): UploadFiles {
  return (req.files ?? {}) as UploadFiles;
}

function cleanupUploaded(req: AuthedRequest): void {
  for (const files of Object.values(filesOf(req))) {
    for (const f of files) {
      try {
        fs.unlinkSync(f.path);
      } catch {
        // Already gone — not an error.
      }
    }
  }
}

// Look a portal up by id OR slug, scoped to the calling admin.
async function findOwnedPortal(ownerId: string, idOrSlug: string) {
  const byId = await prisma.portal.findFirst({ where: { id: idOrSlug, ownerId } });
  if (byId) return byId;
  return prisma.portal.findFirst({ where: { slug: idOrSlug, ownerId } });
}

function publicAsset(a: {
  id: string;
  portalId: string;
  kind: string;
  originalName: string;
  mimeType: string;
  size: number;
  createdAt: Date;
}) {
  return {
    id: a.id,
    portalId: a.portalId,
    kind: a.kind,
    originalName: a.originalName,
    mimeType: a.mimeType,
    size: a.size,
    createdAt: a.createdAt,
  };
}

// One uploader for the single `file` field — the allowed type depends on
// the `kind` in the body, so the filter accepts any image or document
// and the handler rejects the mismatched combination with a 400.
const upload = buildUploader({
  subdir: (req) => {
    const portalId = String(req.params.portalId ?? "").replace(/[^A-Za-z0-9_-]/g, "");
    return path.join("portal-assets", portalId);
  },
  fields: {
    file: { mimes: new Set([...GIF_MIMES, ...DOC_MIMES]), exts: new Set([...GIF_EXTS, ...DOC_EXTS]) },
  },
  // Largest allowed size; the handler enforces the tighter image limit.
  maxBytes: DOC_MAX_BYTES,
});

// --- Upload (ADMIN, owner-scoped) ---
assetsRouter.post("/portals/:portalId/assets", authMiddleware, requireAdmin, (req: AuthedRequest, res, next) => {
  upload.fields([{ name: "file", maxCount: 1 }])(req, res, (err: unknown) => {
    if (err) {
      cleanupUploaded(req);
      res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: multerErrorMessage(err) ?? "Upload failed" } });
      return;
    }
    next();
  });
}, async (req: AuthedRequest, res) => {
  const parsed = uploadSchema.safeParse(req.body);
  if (!parsed.success) {
    cleanupUploaded(req);
    res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: parsed.error.issues[0]?.message ?? "Invalid body" } });
    return;
  }
  const kind = parsed.data.kind;
  const file = filesOf(req).file?.[0];
  if (!file) {
    res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: "Missing file" } });
    return;
  }
  // Kind/type pairing + the tighter image size limit. The uploader
  // already rejected executables/archives; this rejects a document
  // filed as LOGO (or an image filed as DOCUMENT) and an oversized image.
  const isImage = IMAGE_FILE_EXTS[path.extname(file.originalname).toLowerCase()] !== undefined || GIF_MIMES.has(file.mimetype);
  if (IMAGE_KINDS.has(kind)) {
    if (!isImage) {
      cleanupUploaded(req);
      res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: `Kind ${kind} needs an image file (jpeg/png/webp/gif)` } });
      return;
    }
    if (file.size > IMAGE_MAX_BYTES) {
      cleanupUploaded(req);
      res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: "Image must be 10 MB or smaller" } });
      return;
    }
  } else if (!DOC_MIMES.has(file.mimetype) || !DOC_EXTS.has(path.extname(file.originalname).toLowerCase())) {
    cleanupUploaded(req);
    res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: `Kind ${kind} needs a document file (pdf/doc/docx/txt)` } });
    return;
  }
  const portal = await findOwnedPortal(req.auth!.sub, req.params.portalId);
  if (!portal) {
    cleanupUploaded(req);
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Portal not found" } });
    return;
  }
  // One LOGO / one BANNER per portal: a new upload replaces the old
  // (old file + record deleted first).
  if (kind === "LOGO" || kind === "BANNER") {
    const old = await prisma.portalAsset.findFirst({ where: { portalId: portal.id, kind } });
    if (old) {
      deleteUpload(old.storedPath);
      await prisma.portalAsset.delete({ where: { id: old.id } });
    }
  }
  const asset = await prisma.portalAsset.create({
    data: {
      portalId: portal.id,
      kind,
      originalName: file.originalname,
      storedPath: relativeUploadPath(file.path),
      mimeType: file.mimetype,
      size: file.size,
      uploadedById: req.auth!.sub,
    },
  });
  res.status(201).json({ ok: true, data: { asset: publicAsset(asset) } });
});

// --- List (ADMIN, owner-scoped) ---
assetsRouter.get("/portals/:portalId/assets", authMiddleware, requireAdmin, async (req: AuthedRequest, res) => {
  const portal = await findOwnedPortal(req.auth!.sub, req.params.portalId);
  if (!portal) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Portal not found" } });
    return;
  }
  const assets = await prisma.portalAsset.findMany({ where: { portalId: portal.id }, orderBy: { createdAt: "desc" } });
  res.json({ ok: true, data: { assets: assets.map(publicAsset) } });
});

// --- Delete (ADMIN, owner-scoped) — deletes the record AND the file ---
assetsRouter.delete("/portals/:portalId/assets/:id", authMiddleware, requireAdmin, async (req: AuthedRequest, res) => {
  const portal = await findOwnedPortal(req.auth!.sub, req.params.portalId);
  if (!portal) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Portal not found" } });
    return;
  }
  const asset = await prisma.portalAsset.findFirst({ where: { id: req.params.id, portalId: portal.id } });
  if (!asset) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Asset not found" } });
    return;
  }
  deleteUpload(asset.storedPath);
  await prisma.portalAsset.delete({ where: { id: asset.id } });
  res.json({ ok: true, data: { ok: true } });
});

// --- Stream a file (public, like public-methods) ---
// The portal must exist and the id must be a PortalAsset on it. ID
// verification images are a different table and can never be reached
// here. Images are inline (the portal renders logo/banner), documents
// download as an attachment.
assetsRouter.get("/portals/:slug/assets/:id/file", async (req, res) => {
  const portal = await prisma.portal.findUnique({ where: { slug: req.params.slug } });
  // Public route: an ARCHIVED portal is a 404, same as a missing one —
  // its logo, banner, and documents stop being served when archived.
  if (!portal || portal.status !== "ACTIVE") {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Portal not found" } });
    return;
  }
  const asset = await prisma.portalAsset.findFirst({ where: { id: req.params.id, portalId: portal.id } });
  if (!asset) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Asset not found" } });
    return;
  }
  const absolute = absoluteUploadPath(asset.storedPath);
  if (!fs.existsSync(absolute)) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "File not found" } });
    return;
  }
  res.setHeader("Content-Type", asset.mimeType);
  const isImage = asset.mimeType.startsWith("image/");
  const safeName = asset.originalName.replace(/["\r\n]/g, "");
  res.setHeader("Content-Disposition", isImage ? "inline" : `attachment; filename="${safeName}"`);
  res.sendFile(absolute);
});
