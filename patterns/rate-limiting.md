# Rate limiting

> Limit the number of requests a client can make in a given period, to ensure fair use, protect the service, and enforce quotas. Equally, limit the rate at which *your* code calls a downstream service, so you stay within its limits.

## The problem

Two related problems share the name:

1. **Server side:** one client, whether a buggy script, a scraper, a noisy tenant or an attacker, sends far more requests than everyone else. It degrades the service for all other clients, or runs up costs.
2. **Client side** (the Azure Architecture Center's "Rate Limiting pattern"): your code calls a service that enforces limits, such as Cosmos DB RUs, Microsoft Graph or a third-party API. Sending as fast as possible just produces a stream of `429`s and wasted retries. Pacing the calls to stay under the limit is more efficient.

This page focuses mainly on the server side, as that is what the sample can demonstrate. Client-side pacing is covered at the end.

## How it works

Track requests per **key** (client IP, API key, user ID, tenant) and reject the excess with **`429 Too Many Requests`**, telling the client when to try again.

Common algorithms:

| Algorithm | Behaviour | Trade-off |
|---|---|---|
| **Fixed window** | N requests per calendar window (e.g. per second) | Simple. Allows a 2N burst across a window boundary. |
| **Sliding window** | N requests in any rolling window | Smoother. Slightly more state. |
| **Token bucket** | Tokens refill at a steady rate, each request spends one, and the bucket size allows bursts | Allows controlled bursts. Very common. |
| **Leaky bucket** | Requests drain at a fixed rate, and excess requests queue or drop | Smooth output rate. nginx `limit_req` is a leaky bucket. |

Good responses tell the client what is happening:

```http
HTTP/1.1 429 Too Many Requests
Retry-After: 1
RateLimit-Policy: "10-in-1sec"; q=10; w=1
RateLimit: "10-in-1sec"; r=0; t=1
```

## In our sample

The sample has three places a rate limit can go: the **edge** (nginx), the **application** (.NET or Node), and in production, a **gateway** (APIM or Front Door). Each was tested.

### At the edge: nginx

nginx is the front door of the sample, so it can reject excess traffic before it reaches the API at all:

```nginx
# Rate limiting: 10 requests/second per client IP, shared memory zone "api" (10 MB)
limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;

server {
    listen 80;

    location /api/ {
        limit_req zone=api burst=5 nodelay;   # allow short bursts of 5 above the rate
        limit_req_status 429;                 # default is 503
        proxy_pass http://api:8080;
    }
}
```

Twenty rapid requests from one client gave:

```
200 200 200 200 200 200 200 200 429 429 200 429 429 429 200 429 429 429 200 429
└─ rate + burst allowed ─┘ └─ then about 1 request per 100ms gets through ─┘
```

nginx keeps its counters in each nginx pod's memory. With the sample's 2 web replicas, a client could get up to twice the limit. That is usually acceptable at the edge.

### In the application: ASP.NET Core

The built-in middleware supports fixed window, sliding window, token bucket and concurrency limiters, partitioned by any key:

```csharp
builder.Services.AddRateLimiter(options =>
{
    options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;

    // Rate limiting: each client gets 10 requests per second
    options.AddPolicy("per-client", httpContext =>
        RateLimitPartition.GetFixedWindowLimiter(
            partitionKey: httpContext.Connection.RemoteIpAddress?.ToString() ?? "unknown",
            factory: _ => new FixedWindowRateLimiterOptions
            {
                PermitLimit = 10,
                Window = TimeSpan.FromSeconds(1)
            }));

    options.OnRejected = (context, _) =>
    {
        context.HttpContext.Response.Headers.RetryAfter = "1";
        return ValueTask.CompletedTask;
    };
});

var app = builder.Build();
app.UseRateLimiter();

app.MapGet("/api/visits", ...).RequireRateLimiting("per-client");
```

Tested: 10 × `200`, then `429` with `Retry-After: 1`.

Two catches apply to the sample specifically:

- **Behind nginx, `RemoteIpAddress` is nginx's address**, so every user shares one bucket. Use the forwarded headers middleware (`UseForwardedHeaders`, trusting only the proxy) or partition on an authenticated user or API key instead.
- **The counters are per instance.** With 3 API replicas, a client effectively gets up to 30 requests per second.

### In the application: Node with a shared Redis store

`express-rate-limit` stores counters in memory by default, which has the same per-replica problem. `rate-limit-redis` keeps them in Redis, so the limit holds **across all replicas**:

```typescript
import { rateLimit } from "express-rate-limit";
import { RedisStore, type RedisReply } from "rate-limit-redis";

// Separate client for the rate limiter: rate-limit-redis loads a script at startup,
// before the connection is up, so it needs the offline queue enabled
const limiterRedis = new Redis(process.env.REDIS_URL ?? "redis://localhost:6379", { commandTimeout: 500 });

app.use(
  "/api",
  rateLimit({
    windowMs: 1_000,
    limit: 10,                     // 10 requests per second per client IP
    standardHeaders: "draft-8",    // RateLimit-* response headers
    legacyHeaders: false,
    passOnStoreError: true,        // fail open: if Redis is down, allow the request
    store: new RedisStore({
      sendCommand: (command: string, ...args: string[]) => limiterRedis.call(command, ...args) as Promise<RedisReply>,
    }),
  }),
);

// routes come AFTER the limiter - Express middleware only applies to routes registered later
app.get("/api/visits", ...);
```

Tested: 10 × `200`, then 5 × `429`. Responses carried `RateLimit: "10-in-1sec"; r=9; t=1`.

> **Lessons from testing.** Three problems appeared before this version worked:
>
> 1. **Every request returned `500`.** The sample's Redis client uses `enableOfflineQueue: false`, so that API calls fail fast. `rate-limit-redis` sends a command the moment it is created, before the connection is up, and that command was rejected. Fix: a separate client for the limiter, with the offline queue left on.
> 2. **With Redis stopped, the limiter took the whole API down.** A shared-store rate limiter makes Redis a dependency of *every* request, including ones that do not otherwise touch Redis. Fix: `passOnStoreError: true` to **fail open**, and a `commandTimeout` so a dead Redis cannot hang requests. Even so, every request paid the 500ms timeout while Redis was down. In production, put the limiter's store behind its own [circuit breaker](circuit-breaker.md) or keep the timeout very short.
> 3. **The limiter must be registered before the routes**, or it silently does nothing.
>
> Failing open vs failing closed is a business decision. For abuse protection, letting traffic through during a Redis outage is usually right. For a paid quota, it may not be.

## Client side: pacing calls to a limited service

When your code is the caller, for example bulk-importing into Cosmos DB or calling a partner API with a quota:

- **Honour `429` and `Retry-After`.** [Retry](retry.md) after the stated delay, not immediately.
- **Pace proactively.** Use a token bucket on the client side (`System.Threading.RateLimiting.TokenBucketRateLimiter` in .NET, `bottleneck` or `p-limit` in Node) so most calls succeed first time.
- **For large jobs, queue the work** and have workers drain it at the permitted rate. This is more predictable than many processes each retrying.
- `AddStandardResilienceHandler()` for `HttpClient` already includes a client-side rate limiter stage.

## Where should the limit live?

| Layer | Pros | Cons |
|---|---|---|
| Edge / WAF (Front Door, App Gateway) | Blocks abuse before it costs anything. Absorbs DDoS. | Coarse keys (IP). No business context. |
| API gateway (APIM) | Per API key or subscription, quotas, monetisation, one place for all APIs | Another component and cost |
| Ingress / nginx | Cheap, close to the app, already in the sample | Per-replica counters, IP-based |
| Application | Full context (user, tenant, plan, endpoint cost) | Every service must implement it. Shared state needs a store. |

Production systems usually layer them: a generous IP limit at the edge against abuse, plus precise per-customer limits in the gateway or app.

## Related patterns

- [Throttling](throttling.md): protecting the service as a whole, rather than enforcing per-client fairness.
- [Retry](retry.md): how well-behaved clients respond to `429`.
- **Gateway offloading:** moving rate limiting, auth and TLS into a shared gateway.
