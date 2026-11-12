import { Router } from "express";
import { z } from "zod";
import { prisma } from "../db";
import { AuthedRequest, authMiddleware } from "../middleware/auth";
import { requireAdmin } from "../middleware/requireAdmin";

// Linked accounts — "link all necessary information on my app for all
// accounts on each portal". Public identifiers / URLs only.
// NEVER store secrets, passwords, private keys, or seed phrases here.
// Every read / delete is scoped to the portal the account belongs to —
// an account id that does not belong to the requested portal is a 404.

export const accountsRouter = Router();

const createSchema = z.object({
  type: z.string().min(1).max(40), // STRIPE | CASH_APP | EMAIL | DOMAIN | OTHER …
  label: z.string().min(1).max(120),
  handle: z.string().min(1).max(300),
  notes: z.string().max(500).optional(),
});

// Anything that looks like a secret — reject with a clear 400, never store it.
const SECRET_PATTERNS: RegExp[] = [
  /private\s*key/i,
  /seed\s*phrase/i,
  /\bmnemonic\b/i,
  /\bpassword\b/i,
  /api[-_ ]?key/i,
  /client\s*secret/i,
  /secret\s*key/i,
  /-----BEGIN[^-]*PRIVATE KEY-----/i,
  /\b[0-9a-f]{64}\b/i, // raw 64-hex private key
];

function looksLikeSecret(value: string): boolean {
  return SECRET_PATTERNS.some((re) => re.test(value));
}

accountsRouter.use(authMiddleware, requireAdmin);

accountsRouter.post("/portals/:portalId/accounts", async (req: AuthedRequest, res) => {
  const parsed = createSchema.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: parsed.error.issues[0]?.message ?? "Invalid body" } });
    return;
  }
  if (looksLikeSecret(`${parsed.data.handle} ${parsed.data.notes ?? ""}`)) {
    res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: "Never store secrets in linked accounts — public handle or URL only" } });
    return;
  }
  const portal = await prisma.portal.findFirst({ where: { id: req.params.portalId, ownerId: req.auth!.sub } });
  if (!portal) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Portal not found" } });
    return;
  }
  const account = await prisma.linkedAccount.create({ data: { portalId: portal.id, ...parsed.data } });
  res.status(201).json({ ok: true, data: { account } });
});

accountsRouter.get("/portals/:portalId/accounts", async (req: AuthedRequest, res) => {
  // Scoped read: unknown portal (or one the admin does not own) is a 404,
  // so accounts can never leak across portals.
  const portal = await prisma.portal.findFirst({ where: { id: req.params.portalId, ownerId: req.auth!.sub } });
  if (!portal) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Portal not found" } });
    return;
  }
  const accounts = await prisma.linkedAccount.findMany({ where: { portalId: portal.id }, orderBy: { createdAt: "desc" } });
  res.json({ ok: true, data: { accounts } });
});

accountsRouter.delete("/accounts/:id", async (req: AuthedRequest, res) => {
  // Scoped delete: the account must exist AND belong to a portal this
  // admin owns. If ?portalId= is supplied and the account belongs to a
  // different portal, that is also a 404 — never a cross-portal delete.
  const account = await prisma.linkedAccount.findFirst({
    where: { id: req.params.id },
    include: { portal: { select: { id: true, ownerId: true } } },
  });
  if (!account || account.portal.ownerId !== req.auth!.sub) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Linked account not found" } });
    return;
  }
  const requestedPortalId = typeof req.query.portalId === "string" ? req.query.portalId : undefined;
  if (requestedPortalId && account.portalId !== requestedPortalId) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Linked account not found on this portal" } });
    return;
  }
  await prisma.linkedAccount.delete({ where: { id: account.id } });
  res.json({ ok: true, data: { ok: true } });
});
