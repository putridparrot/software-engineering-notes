# Throttling

> Control the consumption of resources used by an instance of an application, an individual tenant, or an entire service, so the system keeps working (and meets its service-level objectives) even when demand exceeds capacity.

## The problem

Every service has a capacity limit. Past that point, a service that accepts every request does not just slow down for the extra users. It slows down for **everyone**:

- Queues grow, latency climbs, and timeouts begin.
- Memory fills up, the garbage collector thrashes, and the container is OOM-killed.
- Clients time out and [retry](retry.md), adding more load.
- The service tips over completely, and recovery is slow because the backlog is still waiting.

Autoscaling helps, but it takes time to react (minutes to add pods or nodes), it has limits, and some dependencies, such as a database, cannot scale at all.

## How it works

Decide in advance what happens when demand exceeds capacity, and **degrade deliberately** instead of collapsing:

| Strategy | What it does |
|---|---|
| **Reject (load shedding)** | Over the limit, return `503` (or `429`) with `Retry-After` immediately. It is cheap for the server, and the client can back off. |
| **Queue** | Hold a limited number of excess requests briefly, then reject when the queue is full |
| **Degrade** | Switch off non-essential features under load: recommendations, rich search, analytics |
| **Prioritise** | Shed low-priority work first, e.g. background jobs and free-tier users before checkout |
| **Defer** | Accept the work and process it asynchronously via a queue (queue-based load levelling) |

Throttling and autoscaling work together. Throttling protects the system **while** autoscaling catches up, and caps the damage if it cannot.

### Throttling vs rate limiting

These terms overlap and are often used interchangeably. In the Azure Architecture Center's terms:

- **Throttling** (this page) is a service **protecting itself**: "I can handle N things at once."
- **[Rate limiting](rate-limiting.md)** is about **controlling a rate of calls**: either a client deliberately pacing its calls to a throttled service, or, as most people use the term, per-client quotas such as "each API key gets 100 requests per minute".

## In our sample

### Kubernetes: resource limits are throttling

The sample's manifests already throttle at the infrastructure level:

```yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    memory: 256Mi
```

- The **memory limit** stops one pod consuming the node, at the cost of an OOM kill.
- A **CPU limit**, deliberately not set in the sample, throttles the container's CPU time. It protects neighbours, but causes latency spikes. See [Kubernetes.md](../Kubernetes.md).
- `maxReplicas` on the **HPA** ([Helm.md](../Helm.md)) caps cost and protects downstream dependencies from too many pods.

None of these know about *requests*, though. A pod at its CPU share simply gets slower for every caller. Request-level throttling makes the degradation explicit.

### .NET: concurrency limiter

ASP.NET Core's rate-limiting middleware includes a **concurrency limiter**. It caps how many requests this instance processes at once, with a small queue:

```csharp
builder.Services.AddRateLimiter(options =>
{
    options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;

    // Throttling: never process more than 100 requests at once in this instance
    options.GlobalLimiter = PartitionedRateLimiter.Create<HttpContext, string>(_ =>
        RateLimitPartition.GetConcurrencyLimiter("global", _ => new ConcurrencyLimiterOptions
        {
            PermitLimit = 100,
            QueueLimit = 50,
            QueueProcessingOrder = QueueProcessingOrder.OldestFirst
        }));

    options.OnRejected = (context, _) =>
    {
        context.HttpContext.Response.Headers.RetryAfter = "1";
        return ValueTask.CompletedTask;
    };
});

var app = builder.Build();
app.UseRateLimiter();
```

Request 151 arriving while 100 are in progress and 50 are queued gets an immediate `429` with `Retry-After: 1`, instead of joining an ever-growing backlog. Many teams prefer `503` for "the server is overloaded" and reserve `429` for per-client limits. Pick one convention and document it.

### TypeScript: in-flight limit middleware

Node's single event loop makes overload especially visible, since every request shares one thread. A simple load shedder:

```typescript
const MAX_IN_FLIGHT = 100;
let inFlight = 0;

app.use((_req, res, next) => {
  if (inFlight >= MAX_IN_FLIGHT) {
    res.set("Retry-After", "1").status(503).json({ error: "Server busy, try again shortly" });
    return;
  }
  inFlight++;
  res.on("close", () => inFlight--);
  next();
});
```

Register it **before** the routes. Express middleware only applies to routes registered after it. For more sophisticated shedding based on event-loop lag rather than a fixed count, see libraries such as `@fastify/under-pressure` or `toobusy-js`.

### Choosing the numbers

Limits should come from **measurement**, not guesses. Load-test one pod (for example with k6 against the sample on Docker Desktop) and find where latency starts to climb. Set the limit a little below that. The limit is **per instance**: 3 replicas × 100 means 300 concurrent requests in total.

## Risks

| Risk | Mitigation |
|---|---|
| **Limits too low:** rejecting traffic the system could have served | Base them on load tests. Monitor the rejection rate. Revisit when the code or resources change. |
| **Limits too high:** they never trigger before the collapse | Same as above |
| **Clients that ignore `Retry-After`** and retry immediately | Publish client guidance. Combine with per-client [rate limiting](rate-limiting.md). |
| **Throttling hides capacity problems** | Alert on sustained throttling. It means capacity planning or autoscaling needs attention. |
| **Readiness interaction** | Do not fail readiness just because the pod is busy. If every pod is pulled from rotation at once, a load spike becomes an outage. |

## Azure services

- **Azure API Management:** `rate-limit-by-key`, `quota-by-key` and concurrency policies at the gateway.
- **Azure Front Door / Application Gateway WAF:** rate-limit rules at the edge.
- **Azure Service Bus / Storage Queues:** for queue-based load levelling.
- Many Azure services throttle *you*: Cosmos DB returns `429` when RUs are exhausted, and Azure Resource Manager has request limits. Clients must handle that with [retry](retry.md) and back-off.

## Related patterns

- [Rate limiting](rate-limiting.md): per-client fairness, plus the client-side view.
- [Circuit breaker](circuit-breaker.md): the caller's protection when a dependency is overloaded.
- **Queue-based load levelling:** buffer bursts in a queue and process at a steady rate.
- **Bulkhead:** separate limits per feature or dependency, so one cannot starve the others.
