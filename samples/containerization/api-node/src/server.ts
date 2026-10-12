import express from "express";
import { Redis } from "ioredis";
import os from "node:os";

// Supplied by docker-compose / Kubernetes via the REDIS_URL environment variable
const redisUrl = process.env.REDIS_URL ?? "redis://localhost:6379";
const port = Number(process.env.PORT ?? 8080);

// Fail fast when Redis is unavailable rather than queueing commands until it returns
const redis = new Redis(redisUrl, { enableOfflineQueue: false, maxRetriesPerRequest: 1 });
redis.on("error", (err) => console.error(`redis: ${err.message}`));

const app = express();

// Increments a counter held in Redis and reports which container handled the request
app.get("/api/visits", async (_req, res) => {
  const visits = await redis.incr("visits");
  res.json({ visits, servedBy: os.hostname() });
});

// Liveness: is the process able to serve requests at all? Deliberately has no dependencies.
app.get("/health", (_req, res) => {
  res.json("healthy");
});

// Readiness: can this instance do useful work right now? Checks its dependency (Redis).
app.get("/health/ready", async (_req, res) => {
  try {
    await redis.ping();
    res.json("ready");
  } catch {
    res.sendStatus(503);
  }
});

const server = app.listen(port, () => console.log(`listening on ${port}`));

// Docker / Kubernetes send SIGTERM to stop a container. Node running as PID 1 has no
// default handler for it, so without this the container is killed only after the timeout.
process.on("SIGTERM", () => {
  console.log("SIGTERM received, shutting down");
  server.close(() => {
    redis.disconnect();
    process.exit(0);
  });
});
