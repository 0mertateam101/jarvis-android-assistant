import { Router } from "express";
import { z } from "zod";
import { prisma } from "../db";
import { AuthedRequest, authMiddleware } from "../middleware/auth";
import { requireAdmin } from "../middleware/requireAdmin";

// Portals — one custom website / payment portal each.
// ADMIN only for create/update/archive. Public/customer reads go through
// the portal app's own endpoints (see access.ts + payments.ts).

export const portalsRouter = Router();

const createSchema = z.object({
  name: z.string().min(1).max(120),
  slug: z
    .string()
    .min(1)
    .max(80)
    .regex(/^[a-z0-9-]+$/, "slug must be lowercase letters, numbers and hyphens")
    .optional(),
  description: z.string().max(500).optional(),
  currency: z.string().length(3).default("USD"),
});

const updateSchema = z.object({
  name: z.string().min(1).max(120).optional(),
  description: z.string().max(500).nullable().optional(),
  currency: z.string().length(3).optional(),
  status: z.enum(["ACTIVE", "ARCHIVED"]).optional(),
});

function slugify(name: string): string {
  return name.toLowerCase().trim().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 80) || "portal";
}

// Look a portal up by id OR slug, scoped to the calling admin.
// The :id param accepts either — unknown ids AND unknown slugs both 404.
async function findOwnedPortal(ownerId: string, idOrSlug: string) {
  const byId = await prisma.portal.findFirst({ where: { id: idOrSlug, ownerId } });
  if (byId) return byId;
  return prisma.portal.findFirst({ where: { slug: idOrSlug, ownerId } });
}

portalsRouter.use(authMiddleware, requireAdmin);

portalsRouter.post("/", async (req: AuthedRequest, res) => {
  const parsed = createSchema.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: parsed.error.issues[0]?.message ?? "Invalid body" } });
    return;
  }
  const slug = parsed.data.slug ?? slugify(parsed.data.name);
  const existing = await prisma.portal.findUnique({ where: { slug } });
  if (existing) {
    res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: "Slug already in use" } });
    return;
  }
  const portal = await prisma.portal.create({
    data: { ...parsed.data, slug, ownerId: req.auth!.sub },
  });
  res.status(201).json({ ok: true, data: { portal } });
});

portalsRouter.get("/", async (req: AuthedRequest, res) => {
  const portals = await prisma.portal.findMany({
    where: { ownerId: req.auth!.sub },
    orderBy: { createdAt: "desc" },
  });
  res.json({ ok: true, data: { portals } });
});

portalsRouter.get("/:id", async (req: AuthedRequest, res) => {
  const portal = await findOwnedPortal(req.auth!.sub, req.params.id);
  if (!portal) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Portal not found" } });
    return;
  }
  // Always include linked accounts + assigned payment methods (see docs/API.md),
  // plus the portal's customisation assets — the logo/banner ids are
  // what the customer portal renders (Prompt 12).
  const full = await prisma.portal.findUnique({
    where: { id: portal.id },
    include: { accounts: true, methods: { include: { paymentMethod: true } }, assets: true },
  });
  if (!full) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Portal not found" } });
    return;
  }
  const logo = full.assets.find((a) => a.kind === "LOGO") ?? null;
  const banner = full.assets.find((a) => a.kind === "BANNER") ?? null;
  res.json({
    ok: true,
    data: {
      portal: {
        ...full,
        logoAssetId: logo?.id ?? null,
        bannerAssetId: banner?.id ?? null,
      },
    },
  });
});

// Canonical invoice list for a portal (see docs/API.md). :id accepts the
// portal id or slug. ADMIN only (router guard above), owner-scoped.
portalsRouter.get("/:id/invoices", async (req: AuthedRequest, res) => {
  const portal = await findOwnedPortal(req.auth!.sub, req.params.id);
  if (!portal) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Portal not found" } });
    return;
  }
  const invoices = await prisma.invoice.findMany({ where: { portalId: portal.id }, orderBy: { createdAt: "desc" } });
  res.json({ ok: true, data: { invoices } });
});

portalsRouter.patch("/:id", async (req: AuthedRequest, res) => {
  const parsed = updateSchema.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: "Invalid body" } });
    return;
  }
  const portal = await findOwnedPortal(req.auth!.sub, req.params.id);
  if (!portal) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Portal not found" } });
    return;
  }
  const updated = await prisma.portal.update({ where: { id: portal.id }, data: parsed.data });
  res.json({ ok: true, data: { portal: updated } });
});

portalsRouter.delete("/:id", async (req: AuthedRequest, res) => {
  // Archive, never hard-delete — invoices and traffic logs must survive.
  const portal = await findOwnedPortal(req.auth!.sub, req.params.id);
  if (!portal) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Portal not found" } });
    return;
  }
  const archived = await prisma.portal.update({ where: { id: portal.id }, data: { status: "ARCHIVED" } });
  res.json({ ok: true, data: { portal: archived } });
});
