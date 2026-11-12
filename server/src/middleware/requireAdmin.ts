import { NextFunction, Response } from "express";
import { AuthedRequest } from "./auth";

/** Don only. Must run after authMiddleware. Returns 403 for any non-ADMIN role. */
export function requireAdmin(req: AuthedRequest, res: Response, next: NextFunction): void {
  if (req.auth?.role !== "ADMIN") {
    res.status(403).json({ ok: false, error: { code: "FORBIDDEN", message: "Access denied" } });
    return;
  }
  next();
}
