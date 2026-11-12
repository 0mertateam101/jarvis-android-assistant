// Load server/.env first so ADMIN_SEED_* come from .env, not defaults.
import "dotenv/config";
// Dev seed: creates the first ADMIN user and Don's example payment methods.
// Run: npm run seed   (after `prisma migrate dev`)
// The example handles below are Don's already-known PUBLIC handles — not
// secrets. Change the seed password after first login.
import bcrypt from "bcrypt";
import { prisma } from "./db";

async function main(): Promise<void> {
  const email = process.env.ADMIN_SEED_EMAIL ?? "don@jarvis.local";
  const password = process.env.ADMIN_SEED_PASSWORD ?? "change-me-after-first-login";
  if (password === "change-me-after-first-login") {
    console.warn("[seed] Using the default seed password — change it after first login.");
  }
  const existing = await prisma.user.findUnique({ where: { email } });
  const admin =
    existing ??
    (await prisma.user.create({
      data: { email, passwordHash: await bcrypt.hash(password, 12), name: "Don", role: "ADMIN" },
    }));
  console.log(`[seed] admin user: ${admin.email} (${admin.id})`);

  const examples = [
    { type: "CASH_APP" as const, label: "Cash App — APF", handle: "$MsCarterb" },
    { type: "CHIME" as const, label: "Chime — APF", handle: "$apfmoneygoat" },
    { type: "VENMO" as const, label: "Venmo — APF", handle: "@Plummer2002" },
  ];
  for (const m of examples) {
    const found = await prisma.paymentMethod.findFirst({
      where: { ownerId: admin.id, type: m.type, handle: m.handle },
    });
    if (!found) {
      await prisma.paymentMethod.create({
        data: { ...m, ownerId: admin.id, details: JSON.stringify({ note: "All Pockets Full Consulting" }) },
      });
      console.log(`[seed] payment method: ${m.type} ${m.handle}`);
    }
  }
  console.log("[seed] done.");
}

main()
  .catch((e) => {
    console.error("[seed] failed:", e);
    process.exit(1);
  })
  .finally(() => prisma.$disconnect());
