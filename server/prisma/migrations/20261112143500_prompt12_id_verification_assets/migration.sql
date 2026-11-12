-- CreateTable
CREATE TABLE "IdVerification" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "portalId" TEXT NOT NULL,
    "email" TEXT NOT NULL,
    "idType" TEXT NOT NULL,
    "frontPath" TEXT NOT NULL,
    "backPath" TEXT NOT NULL,
    "selfiePath" TEXT NOT NULL,
    "status" TEXT NOT NULL DEFAULT 'PENDING',
    "reviewedById" TEXT,
    "reviewedAt" DATETIME,
    "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" DATETIME NOT NULL,
    CONSTRAINT "IdVerification_portalId_fkey" FOREIGN KEY ("portalId") REFERENCES "Portal" ("id") ON DELETE CASCADE ON UPDATE CASCADE
);

-- CreateTable
CREATE TABLE "PortalAsset" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "portalId" TEXT NOT NULL,
    "kind" TEXT NOT NULL,
    "originalName" TEXT NOT NULL,
    "storedPath" TEXT NOT NULL,
    "mimeType" TEXT NOT NULL,
    "size" INTEGER NOT NULL,
    "uploadedById" TEXT NOT NULL,
    "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "PortalAsset_portalId_fkey" FOREIGN KEY ("portalId") REFERENCES "Portal" ("id") ON DELETE CASCADE ON UPDATE CASCADE
);

-- CreateIndex
CREATE INDEX "IdVerification_portalId_idx" ON "IdVerification"("portalId");

-- CreateIndex
CREATE UNIQUE INDEX "IdVerification_portalId_email_key" ON "IdVerification"("portalId", "email");

-- CreateIndex
CREATE INDEX "PortalAsset_portalId_idx" ON "PortalAsset"("portalId");

