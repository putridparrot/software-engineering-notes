# ---- Stage 1: build ----
# Full dependency install (including TypeScript) to compile src/ to dist/
FROM node:24-alpine AS build
WORKDIR /app

# Copy the manifests first and install, so this layer is cached
# until the dependencies change
COPY package.json package-lock.json ./
RUN npm ci

COPY tsconfig.json ./
COPY src ./src
RUN npm run build

# ---- Stage 2: production dependencies only ----
FROM node:24-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

# ---- Stage 3: runtime ----
# No TypeScript compiler, no dev dependencies, no source - just JavaScript and runtime packages
FROM node:24-alpine AS final
ENV NODE_ENV=production
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY package.json ./

# The official image's built-in non-root "node" user. Numeric so that
# Kubernetes' runAsNonRoot can verify it is not root.
USER 1000

EXPOSE 8080
# Exec form, so node is PID 1 and receives SIGTERM directly
CMD ["node", "dist/server.js"]
