import bcrypt from "bcrypt";
import { Router } from "express";
import { z } from "zod";
import { prisma } from "../db";
import { AuthedRequest, authMiddleware, signToken } from "../middleware/auth";
import { requireAdmin } from "../middleware/requireAdmin";

// Don / admin auth. First registered user becomes ADMIN; later
// registrations require an ADMIN token. Passwords are bcrypt-hashed
// and never logged or returned.

export const authRouter = Router();

const registerSchema = z.object({
  email: z.string().email(),
  password: z.string().min(8),
  name: z.string().min(1).max(100).optional(),
});

const loginSchema = z.object({
  email: z.string().email(),
  password: z.string().min(1),
});

function publicUser(u: { id: string; email: string; name: string | null; role: string }) {
  return { id: u.id, email: u.email, name: u.name, role: u.role };
}

authRouter.post("/register", async (req, res) => {
  const parsed = registerSchema.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: parsed.error.issues[0]?.message ?? "Invalid body" } });
    return;
  }
  const userCount = await prisma.user.count();
  if (userCount > 0) {
    // After the first user, registration is admin-only (future invite flow).
    // For now, block it outright so no stranger can self-register as ADMIN.
    res.status(403).json({ ok: false, error: { code: "FORBIDDEN", message: "Registration is closed — ask an admin" } });
    return;
  }
  const { email, password, name } = parsed.data;
  const existing = await prisma.user.findUnique({ where: { email } });
  if (existing) {
    res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: "Email already registered" } });
    return;
  }
  const user = await prisma.user.create({
    data: { email, passwordHash: await bcrypt.hash(password, 12), name: name ?? null, role: "ADMIN" },
  });
  const token = signToken({ sub: user.id, role: "ADMIN", email: user.email }, "7d");
  res.status(201).json({ ok: true, data: { user: publicUser(user), token } });
});

authRouter.post("/login", async (req, res) => {
  const parsed = loginSchema.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: "Invalid body" } });
    return;
  }
  const user = await prisma.user.findUnique({ where: { email: parsed.data.email } });
  if (!user || !(await bcrypt.compare(parsed.data.password, user.passwordHash))) {
    res.status(401).json({ ok: false, error: { code: "INVALID_CREDENTIALS", message: "Invalid credentials" } });
    return;
  }
  const token = signToken({ sub: user.id, role: user.role as "ADMIN" | "CUSTOMER", email: user.email }, "7d");
  res.json({ ok: true, data: { user: publicUser(user), token } });
});

authRouter.get("/me", authMiddleware, async (req: AuthedRequest, res) => {
  const user = await prisma.user.findUnique({ where: { id: req.auth!.sub } });
  if (!user) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "User not found" } });
    return;
  }
  res.json({ ok: true, data: { user: publicUser(user) } });
});

// Placeholder for a future admin-invite flow — intentionally not wired
// until Don approves it. Kept behind requireAdmin so it cannot be abused.
authRouter.post("/invite-admin", authMiddleware, requireAdmin, (_req, res) => {
  res.status(501).json({ ok: false, error: { code: "INTERNAL", message: "Admin invite is not enabled yet" } });
});
