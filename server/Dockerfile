# JARVIS server — production image (Node 20)
#
# DATABASE / Prisma — DUAL SCHEMA (see docs/ARCHITECTURE.md "Data model"):
#   - Local dev / tests use prisma/schema.prisma (SQLite).
#   - THIS image (Docker / production) uses prisma/postgres/schema.prisma
#     (Postgres). The client MUST be generated from the Postgres schema:
#     a SQLite-generated client rejects a postgresql:// DATABASE_URL at
#     startup with Prisma error P1012 ("the URL must start with the
#     protocol `file:`") — that is exactly what killed the first GitHub
#     Actions docker run (run 43210865406, 2026-11-12).
#   - The compose file bind-mounts ./server:/app, which hides the image's
#     own /app/prisma — but the host ./server/prisma ALSO contains the
#     postgres/ folder, so `prisma/postgres/schema.prisma` resolves at
#     runtime too. /app/node_modules is an anonymous volume, so the
#     runtime Prisma client is the one generated in the build stage below.
#   - OpenSSL is REQUIRED in BOTH stages (see the RUN lines below):
#     Prisma's engine binaries (schema engine + query engine) link
#     against libssl/libcrypto, and node:20-alpine ships NEITHER. That
#     is what killed the second GitHub Actions docker run (run
#     43215195831, 2026-11-12): `migrate deploy` crashed at Prisma
#     engine startup with "Could not parse schema engine response ...
#     'Error load'..." plus a warning the libssl/OpenSSL version could
#     not be detected. Switching to node:20-slim alone does NOT fix
#     this — slim also ships without libssl — so openssl is installed
#     explicitly in both stages instead.
FROM node:20-alpine AS build
# Prisma `generate` runs the schema engine, which links libssl/libcrypto.
# node:20-alpine ships neither — install openssl (see header note).
RUN apk add --no-cache openssl && openssl version
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm install
COPY prisma ./prisma
RUN npx prisma generate --schema=prisma/postgres/schema.prisma
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

FROM node:20-alpine
# `migrate deploy` (schema engine) and the Prisma query engine both need
# libssl/libcrypto at RUNTIME — this is the stage that crashed in run #2.
RUN apk add --no-cache openssl && openssl version
WORKDIR /app
ENV NODE_ENV=production
COPY package.json package-lock.json* ./
# prisma CLI is a devDependency, so --omit=dev leaves `npx prisma` with
# nothing local to run — it would download prisma@latest from the
# registry on every container start. Pin the same CLI version the build
# stage used (5.22.0) so `migrate deploy` below is deterministic.
RUN npm install --omit=dev && npm install --no-save prisma@5.22.0
COPY --from=build /app/node_modules/.prisma ./node_modules/.prisma
COPY --from=build /app/dist ./dist
COPY prisma ./prisma
EXPOSE 4000
CMD ["sh", "-c", "npx prisma migrate deploy --schema=prisma/postgres/schema.prisma && node dist/index.js"]
