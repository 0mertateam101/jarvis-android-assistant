import { PrismaClient } from "@prisma/client";

// Prisma client singleton — import { prisma } from "./db" everywhere.
// Never create a second PrismaClient in a route or service.
export const prisma = new PrismaClient();
