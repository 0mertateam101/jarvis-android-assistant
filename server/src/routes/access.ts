import { Router } from "express";
import { z } from "zod";
import { prisma } from "../db";
import { AuthedRequest, authMiddleware, signToken } from "../middleware/auth";
import { requireAdmin } from "../middleware/requireAdmin";
import { generateAccessCode, hashCode, verifyCode } from "../utils/codes";

// Access grants — the invite / code system.
// Don enters an email → code generated → email = username, code = password.
// The plain code is returned ONCE (invite response, to Don only) and is
// never stored, never logged. Blocklist + TERMINATED are checked BEFORE
// the code is verified, and failures always return the generic message.

export const accessRouter = Router();

const inviteSchema = z.object({
  portalId: z.string().min(1),
  email: z.string().email(),
});

const loginSchema = z.object({
  portalSlug: z.string().min(1),
  email: z.string().email(),
  code: z.string().min(1),
});

const revokeSchema = z.object({ grantId: z.string().min(1) });

async function isBlocked(portalId: string, email: string): Promise<boolean> {
  const blocked = await prisma.blockedUser.findFirst({
    where: { email, OR: [{ portalId }, { portalId: null }] },
  });
  return Boolean(blocked);
}

accessRouter.post("/invite", authMiddleware, requireAdmin, async (req: AuthedRequest, res) => {
  const parsed = inviteSchema.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: "Invalid body" } });
    return;
  }
  const portal = await prisma.portal.findFirst({ where: { id: parsed.data.portalId, ownerId: req.auth!.sub } });
  if (!portal) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Portal not found" } });
    return;
  }
  const email = parsed.data.email.toLowerCase();
  if (await isBlocked(portal.id, email)) {
    res.status(403).json({ ok: false, error: { code: "FORBIDDEN", message: "Access denied" } });
    return;
  }
  const code = generateAccessCode();
  const codeHash = await hashCode(code);
  const grant = await prisma.accessGrant.upsert({
    where: { portalId_email: { portalId: portal.id, email } },
    update: { codeHash, status: "ACTIVE", lastUsedAt: null },
    create: { portalId: portal.id, email, codeHash, status: "ACTIVE" },
  });
  // Plain code leaves the server exactly once, here, to Don. Do not log it.
  res.status(201).json({
    ok: true,
    data: {
      grant: { id: grant.id, portalId: grant.portalId, email: grant.email, status: grant.status, createdAt: grant.createdAt },
      code,
      warning: "Show this code once. It is not stored in plain text.",
    },
  });
});

accessRouter.get("/portals/:portalId/grants", authMiddleware, requireAdmin, async (req: AuthedRequest, res) => {
  // Scoped read, like portals/accounts (Prompt 3): unknown portal, or one
  // the admin does not own, is a 404. Accepts portal id or slug.
  const portal = await prisma.portal.findFirst({
    where: { ownerId: req.auth!.sub, OR: [{ id: req.params.portalId }, { slug: req.params.portalId }] },
  });
  if (!portal) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Portal not found" } });
    return;
  }
  const grants = await prisma.accessGrant.findMany({
    where: { portalId: portal.id },
    orderBy: { createdAt: "desc" },
    select: { id: true, portalId: true, email: true, status: true, lastUsedAt: true, createdAt: true },
  });
  res.json({ ok: true, data: { grants } });
});

accessRouter.post("/login", async (req, res) => {
  const parsed = loginSchema.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: "Invalid body" } });
    return;
  }
  const generic = { ok: false, error: { code: "INVALID_CREDENTIALS", message: "Invalid credentials" } };
  const portal = await prisma.portal.findUnique({ where: { slug: parsed.data.portalSlug } });
  if (!portal || portal.status !== "ACTIVE") {
    res.status(401).json(generic);
    return;
  }
  const email = parsed.data.email.toLowerCase();
  // Blocklist + termination FIRST — never reveal why access was denied.
  if (await isBlocked(portal.id, email)) {
    res.status(401).json(generic);
    return;
  }
  const grant = await prisma.accessGrant.findUnique({ where: { portalId_email: { portalId: portal.id, email } } });
  if (!grant || grant.status !== "ACTIVE") {
    res.status(401).json(generic);
    return;
  }
  if (!(await verifyCode(parsed.data.code, grant.codeHash))) {
    res.status(401).json(generic);
    return;
  }
  await prisma.accessGrant.update({ where: { id: grant.id }, data: { lastUsedAt: new Date() } });
  const token = signToken({ sub: email, role: "CUSTOMER", portalId: portal.id, email }, "12h");
  res.json({
    ok: true,
    data: {
      token,
      portal: { id: portal.id, slug: portal.slug, name: portal.name },
      email,
    },
  });
});

accessRouter.post("/revoke", authMiddleware, requireAdmin, async (req: AuthedRequest, res) => {
  const parsed = revokeSchema.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: "Invalid body" } });
    return;
  }
  // Scoped: a grant on a portal the admin does not own is a 404, never
  // a cross-portal revoke.
  const grant = await prisma.accessGrant.findUnique({
    where: { id: parsed.data.grantId },
    include: { portal: { select: { ownerId: true } } },
  });
  if (!grant || grant.portal.ownerId !== req.auth!.sub) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Grant not found" } });
    return;
  }
  const updated = await prisma.accessGrant.update({ where: { id: grant.id }, data: { status: "REVOKED" } });
  res.json({ ok: true, data: { grant: { id: updated.id, email: updated.email, status: updated.status } } });
});

accessRouter.get("/me", authMiddleware, (req: AuthedRequest, res) => {
  if (req.auth?.role !== "CUSTOMER") {
    res.status(403).json({ ok: false, error: { code: "FORBIDDEN", message: "Access denied" } });
    return;
  }
  res.json({ ok: true, data: { email: req.auth.email, portalId: req.auth.portalId } });
});
