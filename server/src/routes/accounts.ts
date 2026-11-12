import { Router } from "express";
import { z } from "zod";
import { prisma } from "../db";
import { authMiddleware } from "../middleware/auth";
import { requireAdmin } from "../middleware/requireAdmin";

// Linked accounts — "link all necessary information on my app for all
// accounts on each portal". Public identifiers / URLs only.
// NEVER store secrets, passwords, private keys, or seed phrases here.

export const accountsRouter = Router();

const createSchema = z.object({
  type: z.string().min(1).max(40), // STRIPE | CASH_APP | EMAIL | DOMAIN | OTHER …
  label: z.string().min(1).max(120),
  handle: z.string().min(1).max(300),
  notes: z.string().max(500).optional(),
});

accountsRouter.use(authMiddleware, requireAdmin);

accountsRouter.post("/portals/:portalId/accounts", async (req, res) => {
  const parsed = createSchema.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: "Invalid body" } });
    return;
  }
  if (/private\s*key|seed\s*phrase|password/i.test(`${parsed.data.handle} ${parsed.data.notes ?? ""}`)) {
    res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: "Never store secrets in linked accounts" } });
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

accountsRouter.get("/portals/:portalId/accounts", async (req, res) => {
  const accounts = await prisma.linkedAccount.findMany({ where: { portalId: req.params.portalId }, orderBy: { createdAt: "desc" } });
  res.json({ ok: true, data: { accounts } });
});

accountsRouter.delete("/accounts/:id", async (req, res) => {
  await prisma.linkedAccount.delete({ where: { id: req.params.id } });
  res.json({ ok: true, data: { ok: true } });
});
