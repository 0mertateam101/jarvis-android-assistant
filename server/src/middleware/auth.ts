import { NextFunction, Request, Response } from "express";
import jwt from "jsonwebtoken";

export type JwtRole = "ADMIN" | "CUSTOMER";

export interface AuthPayload {
  sub: string; // user id (admin) or grant email (customer)
  role: JwtRole;
  portalId?: string; // customer tokens only — the portal they may access
  email?: string;
}

export interface AuthedRequest extends Request {
  auth?: AuthPayload;
}

function getSecret(): string {
  const secret = process.env.JWT_SECRET;
  if (!secret || secret.length < 16) {
    throw new Error("JWT_SECRET is not set (or too short). Set it in .env.");
  }
  return secret;
}

export function signToken(payload: AuthPayload, expiresIn: jwt.SignOptions["expiresIn"] = "7d"): string {
  return jwt.sign(payload, getSecret(), { expiresIn });
}

/** Verify a Bearer JWT and attach `req.auth`. 401 on missing/invalid token. */
export function authMiddleware(req: AuthedRequest, res: Response, next: NextFunction): void {
  const header = req.headers.authorization;
  if (!header?.startsWith("Bearer ")) {
    res.status(401).json({ ok: false, error: { code: "UNAUTHORIZED", message: "Missing token" } });
    return;
  }
  try {
    const payload = jwt.verify(header.slice(7), getSecret()) as AuthPayload;
    req.auth = payload;
    next();
  } catch {
    res.status(401).json({ ok: false, error: { code: "UNAUTHORIZED", message: "Invalid or expired token" } });
  }
}

/** Require a CUSTOMER token scoped to the portal in the URL/body. */
export function requireCustomerForPortal(getPortalId: (req: AuthedRequest) => string | undefined) {
  return (req: AuthedRequest, res: Response, next: NextFunction): void => {
    if (req.auth?.role !== "CUSTOMER") {
      res.status(403).json({ ok: false, error: { code: "FORBIDDEN", message: "Access denied" } });
      return;
    }
    const portalId = getPortalId(req);
    if (portalId && req.auth.portalId !== portalId) {
      res.status(403).json({ ok: false, error: { code: "FORBIDDEN", message: "Access denied" } });
      return;
    }
    next();
  };
}
