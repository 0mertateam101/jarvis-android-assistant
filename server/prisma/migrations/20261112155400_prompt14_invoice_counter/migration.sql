-- CreateTable
CREATE TABLE "InvoiceCounter" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "nextNumber" INTEGER NOT NULL,
    "updatedAt" DATETIME NOT NULL
);

-- Seed the single counter row from the existing invoice count, so a
-- database created before the counter keeps its numbering sequence.
-- A fresh database (0 invoices) starts at JAR-1001.
INSERT INTO "InvoiceCounter" ("id", "nextNumber", "updatedAt")
SELECT 'main', 1001 + (SELECT COUNT(*) FROM "Invoice"), CURRENT_TIMESTAMP;
