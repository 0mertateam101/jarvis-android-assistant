import fs from "node:fs";
import path from "node:path";
import { Router } from "express";
import { z } from "zod";
import { prisma } from "../db";
import { AuthedRequest, authMiddleware } from "../middleware/auth";
import { requireAdmin } from "../middleware/requireAdmin";
import {
  IMAGE_EXTS,
  IMAGE_MAX_BYTES,
  IMAGE_MIMES,
  absoluteUploadPath,
  buildUploader,
  deleteUpload,
  multerErrorMessage,
  relativeUploadPath,
} from "../services/uploads";

// ID verification — a customer uploads pictures of their ID (front,
// back, and a picture of themselves holding the ID) so Don can verify
// who is paying on a portal.
//
// Rules (Prompt 12):
// - idType is DRIVERS_LICENSE | STATE_ID | NATIONAL_ID. NO passport
//   option anywhere — a PASSPORT idType is a 400.
// - All three images are required, jpeg/png/webp only, each <= 10 MB.
// - Files live under server/uploads/id-verifications/<portalId>/ with
//   random server-side filenames. They are NEVER served publicly and
//   NEVER returned to customers — only the status + idType leave the
//   server. Paths are never logged beyond the record id.
// - One record per (portal, email): a re-upload replaces the record
//   (upsert) and resets status to PENDING.
// - Payment is NOT blocked by verification — an unverified customer can
//   still pay. This is a trust record for Don to review.

export const verificationRouter = Router();

const ID_TYPES = ["DRIVERS_LICENSE", "STATE_ID", "NATIONAL_ID"] as const;
const IMAGE_FIELDS = ["front", "back", "selfie"] as const;

const reviewSchema = z.object({
  status: z.enum(["VERIFIED", "REJECTED"]),
});

const EXT_TO_MIME: Record<string, string> = {
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".png": "image/png",
  ".webp": "image/webp",
};

type UploadFiles = { [field: string]: Express.Multer.File[] };

function filesOf(req: AuthedRequest): UploadFiles {
  return (req.files ?? {}) as UploadFiles;
}

/** Delete every file multer just stored (used when validation fails after upload). */
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

// Strip the stored paths — customers and list responses never see them.
function publicVerification(v: {
  id: string;
  portalId: string;
  email: string;
  idType: string;
  status: string;
  reviewedById: string | null;
  reviewedAt: Date | null;
  createdAt: Date;
  updatedAt: Date;
}) {
  return {
    id: v.id,
    portalId: v.portalId,
    email: v.email,
    idType: v.idType,
    status: v.status,
    reviewedById: v.reviewedById,
    reviewedAt: v.reviewedAt,
    createdAt: v.createdAt,
    updatedAt: v.updatedAt,
  };
}

const upload = buildUploader({
  subdir: (req) => {
    // Portal id was verified by the scope middleware before multer runs.
    const portalId = String(req.params.portalId ?? "").replace(/[^A-Za-z0-9_-]/g, "");
    return path.join("id-verifications", portalId);
  },
  fields: {
    front: { mimes: IMAGE_MIMES, exts: IMAGE_EXTS },
    back: { mimes: IMAGE_MIMES, exts: IMAGE_EXTS },
    selfie: { mimes: IMAGE_MIMES, exts: IMAGE_EXTS },
  },
  maxBytes: IMAGE_MAX_BYTES,
});

// --- Upload (CUSTOMER, own portal + own email) ---
verificationRouter.post(
  "/portals/:portalId/id-verification",
  authMiddleware,
  (req: AuthedRequest, res, next) => {
    if (req.auth!.role !== "CUSTOMER") {
      res.status(403).json({ ok: false, error: { code: "FORBIDDEN", message: "Access denied" } });
      return;
    }
    if (req.auth!.portalId !== req.params.portalId) {
      res.status(403).json({ ok: false, error: { code: "FORBIDDEN", message: "Access denied" } });
      return;
    }
    next();
  },
  (req: AuthedRequest, res, next) => {
    upload.fields([
      { name: "front", maxCount: 1 },
      { name: "back", maxCount: 1 },
      { name: "selfie", maxCount: 1 },
    ])(req, res, (err: unknown) => {
      if (err) {
        cleanupUploaded(req);
        res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: multerErrorMessage(err) ?? "Upload failed" } });
        return;
      }
      next();
    });
  },
  async (req: AuthedRequest, res) => {
    const portalId = req.params.portalId;
    const email = (req.auth!.email ?? "").toLowerCase();
    const idType = typeof req.body?.idType === "string" ? req.body.idType : "";
    if (!ID_TYPES.includes(idType as (typeof ID_TYPES)[number])) {
      cleanupUploaded(req);
      res.status(400).json({
        ok: false,
        error: { code: "VALIDATION_ERROR", message: "idType must be DRIVERS_LICENSE, STATE_ID or NATIONAL_ID (passports are not accepted)" },
      });
      return;
    }
    const files = filesOf(req);
    const missing = IMAGE_FIELDS.filter((f) => !files[f]?.[0]);
    if (missing.length > 0) {
      cleanupUploaded(req);
      res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: `Missing required image(s): ${missing.join(", ")}` } });
      return;
    }
    const paths = {
      frontPath: relativeUploadPath(files.front[0].path),
      backPath: relativeUploadPath(files.back[0].path),
      selfiePath: relativeUploadPath(files.selfie[0].path),
    };
    // Re-upload replaces the record and resets it to PENDING. Delete the
    // old files first so no orphan images linger on disk.
    const existing = await prisma.idVerification.findUnique({ where: { portalId_email: { portalId, email } } });
    if (existing) {
      deleteUpload(existing.frontPath);
      deleteUpload(existing.backPath);
      deleteUpload(existing.selfiePath);
    }
    const record = await prisma.idVerification.upsert({
      where: { portalId_email: { portalId, email } },
      update: { ...paths, idType, status: "PENDING", reviewedById: null, reviewedAt: null },
      create: { portalId, email, idType, ...paths, status: "PENDING" },
    });
    res.status(201).json({ ok: true, data: { verification: publicVerification(record) } });
  },
);

// --- Own record (CUSTOMER, own portal + own email) ---
verificationRouter.get("/portals/:portalId/id-verification/me", authMiddleware, async (req: AuthedRequest, res) => {
  if (req.auth!.role !== "CUSTOMER" || req.auth!.portalId !== req.params.portalId) {
    res.status(403).json({ ok: false, error: { code: "FORBIDDEN", message: "Access denied" } });
    return;
  }
  const record = await prisma.idVerification.findUnique({
    where: { portalId_email: { portalId: req.params.portalId, email: (req.auth!.email ?? "").toLowerCase() } },
  });
  if (!record) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "No ID verification found" } });
    return;
  }
  res.json({ ok: true, data: { verification: publicVerification(record) } });
});

// --- List (ADMIN, owner-scoped) ---
verificationRouter.get("/portals/:portalId/id-verification", authMiddleware, requireAdmin, async (req: AuthedRequest, res) => {
  const portal = await findOwnedPortal(req.auth!.sub, req.params.portalId);
  if (!portal) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Portal not found" } });
    return;
  }
  const verifications = await prisma.idVerification.findMany({ where: { portalId: portal.id }, orderBy: { createdAt: "desc" } });
  res.json({ ok: true, data: { verifications: verifications.map(publicVerification) } });
});

// --- Review (ADMIN, owner-scoped) ---
verificationRouter.post("/portals/:portalId/id-verification/:id/review", authMiddleware, requireAdmin, async (req: AuthedRequest, res) => {
  const parsed = reviewSchema.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: parsed.error.issues[0]?.message ?? "Invalid body" } });
    return;
  }
  const portal = await findOwnedPortal(req.auth!.sub, req.params.portalId);
  if (!portal) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Portal not found" } });
    return;
  }
  const record = await prisma.idVerification.findFirst({ where: { id: req.params.id, portalId: portal.id } });
  if (!record) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "ID verification not found" } });
    return;
  }
  const updated = await prisma.idVerification.update({
    where: { id: record.id },
    data: { status: parsed.data.status, reviewedById: req.auth!.sub, reviewedAt: new Date() },
  });
  res.json({ ok: true, data: { verification: publicVerification(updated) } });
});

// --- Stream one image (ADMIN owner-scoped OR the owning CUSTOMER) ---
// Never a public static path — the caller must prove access, and the
// field must be one of front/back/selfie.
verificationRouter.get("/portals/:portalId/id-verification/:id/image/:field", authMiddleware, async (req: AuthedRequest, res) => {
  const field = req.params.field;
  if (!IMAGE_FIELDS.includes(field as (typeof IMAGE_FIELDS)[number])) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Unknown image field" } });
    return;
  }
  const record = await prisma.idVerification.findFirst({ where: { id: req.params.id, portalId: req.params.portalId } });
  if (!record) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "ID verification not found" } });
    return;
  }
  if (req.auth!.role === "ADMIN") {
    const portal = await prisma.portal.findFirst({ where: { id: record.portalId, ownerId: req.auth!.sub } });
    if (!portal) {
      res.status(403).json({ ok: false, error: { code: "FORBIDDEN", message: "Access denied" } });
      return;
    }
  } else if (req.auth!.role === "CUSTOMER") {
    if (req.auth!.portalId !== record.portalId || (req.auth!.email ?? "").toLowerCase() !== record.email.toLowerCase()) {
      res.status(403).json({ ok: false, error: { code: "FORBIDDEN", message: "Access denied" } });
      return;
    }
  } else {
    res.status(403).json({ ok: false, error: { code: "FORBIDDEN", message: "Access denied" } });
    return;
  }
  const storedPath = field === "front" ? record.frontPath : field === "back" ? record.backPath : record.selfiePath;
  const absolute = absoluteUploadPath(storedPath);
  if (!fs.existsSync(absolute)) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Image file not found" } });
    return;
  }
  res.setHeader("Content-Type", EXT_TO_MIME[path.extname(storedPath).toLowerCase()] ?? "application/octet-stream");
  res.setHeader("Content-Disposition", "inline");
  res.sendFile(absolute);
});
