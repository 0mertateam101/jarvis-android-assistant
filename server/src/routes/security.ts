import { Router } from "express";
import { z } from "zod";
import { prisma } from "../db";
import { AuthedRequest, authMiddleware } from "../middleware/auth";
import { requireAdmin } from "../middleware/requireAdmin";
import { reverseLookup } from "../services/ipLookup";

// Security — visit logging, reverse lookup on unauthorised traffic,
// per-portal reports, blocklist + termination.
// Every login / payment attempt also checks BlockedUser first (access.ts,
// payments.ts). A blocked or TERMINATED user is always denied with a
// generic message — never with the reason.

export const securityRouter = Router();

const visitSchema = z.object({
  portalSlug: z.string().min(1),
  ip: z.string().min(1).max(45).optional(),
  userAgent: z.string().max(500).optional(),
  path: z.string().max(200).optional(),
  hasAccess: z.boolean().default(false),
});

const blockSchema = z.object({
  portalId: z.string().min(1).optional(),
  email: z.string().email().optional(),
  ip: z.string().min(1).max(45).optional(),
  reason: z.string().min(1).max(300),
});

function clientIp(req: { ip?: string; headers: Record<string, string | string[] | undefined> }): string {
  const forwarded = req.headers["x-forwarded-for"];
  const first = Array.isArray(forwarded) ? forwarded[0] : forwarded?.split(",")[0]?.trim();
  return first ?? req.ip ?? "UNKNOWN";
}

securityRouter.post("/visit", async (req, res) => {
  const parsed = visitSchema.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: "Invalid body" } });
    return;
  }
  const portal = await prisma.portal.findUnique({ where: { slug: parsed.data.portalSlug } });
  if (!portal) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Portal not found" } });
    return;
  }
  const ip = parsed.data.ip ?? clientIp(req);
  let lookup = { ptr: "UNKNOWN", country: "UNKNOWN", region: "UNKNOWN", city: "UNKNOWN", isp: "UNKNOWN", org: "UNKNOWN", lat: null as number | null, lon: null as number | null, source: "FALLBACK", simulated: true };
  if (!parsed.data.hasAccess) {
    // Unauthorised traffic only — authorised visits are logged without a lookup.
    lookup = await reverseLookup(ip);
  }
  const log = await prisma.trafficLog.create({
    data: {
      portalId: portal.id,
      ip,
      userAgent: parsed.data.userAgent ?? null,
      path: parsed.data.path ?? null,
      hasAccess: parsed.data.hasAccess,
      ptr: lookup.ptr,
      country: lookup.country,
      region: lookup.region,
      city: lookup.city,
      isp: lookup.isp,
      org: lookup.org,
      lat: lookup.lat,
      lon: lookup.lon,
      lookupSource: parsed.data.hasAccess ? "SKIPPED-HAS-ACCESS" : lookup.source,
      lookupSimulated: lookup.simulated,
    },
  });
  res.status(201).json({ ok: true, data: { log } });
});

securityRouter.get("/portals/:portalId/traffic", authMiddleware, requireAdmin, async (req, res) => {
  const hasAccess = req.query.hasAccess === "true" ? true : req.query.hasAccess === "false" ? false : undefined;
  const limit = Math.min(Number(req.query.limit ?? 100) || 100, 500);
  const logs = await prisma.trafficLog.findMany({
    where: { portalId: req.params.portalId, ...(hasAccess !== undefined ? { hasAccess } : {}) },
    orderBy: { createdAt: "desc" },
    take: limit,
  });
  res.json({ ok: true, data: { logs } });
});

securityRouter.post("/block", authMiddleware, requireAdmin, async (req: AuthedRequest, res) => {
  const parsed = blockSchema.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: "Invalid body" } });
    return;
  }
  if (!parsed.data.email && !parsed.data.ip) {
    res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: "Provide an email or an IP to block" } });
    return;
  }
  const blocked = await prisma.blockedUser.create({
    data: {
      portalId: parsed.data.portalId ?? null,
      email: parsed.data.email?.toLowerCase() ?? null,
      ip: parsed.data.ip ?? null,
      reason: parsed.data.reason,
      blockedById: req.auth!.sub,
    },
  });
  // Terminate that email's grants on the portal (policy termination).
  if (parsed.data.email && parsed.data.portalId) {
    await prisma.accessGrant.updateMany({
      where: { portalId: parsed.data.portalId, email: parsed.data.email.toLowerCase() },
      data: { status: "TERMINATED" },
    });
  }
  res.status(201).json({ ok: true, data: { blocked } });
});

securityRouter.get("/blocked", authMiddleware, requireAdmin, async (_req, res) => {
  const blocked = await prisma.blockedUser.findMany({ orderBy: { createdAt: "desc" } });
  res.json({ ok: true, data: { blocked } });
});

securityRouter.post("/unblock", authMiddleware, requireAdmin, async (req, res) => {
  const { blockedId } = z.object({ blockedId: z.string().min(1) }).parse(req.body);
  await prisma.blockedUser.delete({ where: { id: blockedId } });
  // Note: unblocking does NOT reactivate a TERMINATED grant. Re-invite
  // the customer (POST /api/access/invite) to give them a fresh code.
  res.json({ ok: true, data: { ok: true } });
});
