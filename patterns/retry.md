# Retry (and timeouts)

> Enable an application to handle transient failures when connecting to a service, by transparently retrying a failed operation.

## The problem

In the cloud, many failures are **transient**. They fix themselves within milliseconds or seconds:

- a container restarting during a rolling update (seen in [Kubernetes.md](../Kubernetes.md))
- a Redis or database failover
- a dropped connection or brief network blip
- a service returning `503` or `429` while it scales out

Failing the user's request for something that would have succeeded half a second later is a poor experience.

## How it works

On a failure that is likely to be transient, wait and try again, up to a limit:

```
 attempt 1 ──✗──▶ wait 200ms ──▶ attempt 2 ──✗──▶ wait 400ms ──▶ attempt 3 ──✓──▶ result
                  (+ jitter)                       (+ jitter)
```

The details matter:

- **Only retry transient errors.** Retry timeouts, connection failures, `503`, `429` and `408`. Do **not** retry `400`, `401`, `404` or validation errors, which fail again identically.
- **Exponential backoff** (200ms, 400ms, 800ms...) gives the dependency time to recover.
- **Jitter** (randomising each delay) stops thousands of clients retrying in lockstep, which otherwise produces synchronised spikes known as the *thundering herd*.
- **A small maximum number of attempts.** 2–3 is typical for a user-facing request.
- **Respect `Retry-After`** headers when a service sends them (see [Rate limiting](rate-limiting.md)).

## Timeouts: the other half

A retry only helps if a failed attempt actually *ends*. Without timeouts, a hung call holds a thread, a connection and the user's request until something else gives up. Use two:

- a **per-attempt timeout**, so one slow attempt does not consume the whole budget
- an **overall timeout** covering all attempts, so the user gets an answer within a known time

## In our sample

### Retries that already exist

Retry is already present in several layers of the sample, even before adding any code:

| Layer | Retry behaviour |
|---|---|
| StackExchange.Redis (`abortConnect=false`) | Keeps reconnecting in the background. Commands wait in a backlog until reconnected or timed out. |
| ioredis | Reconnects automatically. `maxRetriesPerRequest: 1` and `enableOfflineQueue: false` in [server.ts](../samples/containerization/api-node/src/server.ts) deliberately make *commands* fail fast instead. |
| Kubernetes | Restarts crashed containers (with backoff). Readiness probes keep traffic away until the pod recovers. |
| Compose | `depends_on: condition: service_healthy` waits for Redis at startup. |

**Before adding retries in code, know what the layers below already do.** Retries multiply: 3 retries in the API × 3 in the client library × 3 in nginx is up to 27 attempts against a dependency that is already struggling.

### .NET with Polly

```csharp
var retryPipeline = new ResiliencePipelineBuilder()
    .AddTimeout(TimeSpan.FromSeconds(5))                   // overall budget for all attempts
    .AddRetry(new RetryStrategyOptions
    {
        ShouldHandle = new PredicateBuilder()
            .Handle<RedisConnectionException>()
            .Handle<RedisTimeoutException>(),
        MaxRetryAttempts = 3,
        BackoffType = DelayBackoffType.Exponential,
        UseJitter = true,
        Delay = TimeSpan.FromMilliseconds(200)
    })
    .AddTimeout(TimeSpan.FromSeconds(1))                   // per attempt
    .Build();

app.MapGet("/api/visits", async (IConnectionMultiplexer redis, CancellationToken ct) =>
{
    var visits = await retryPipeline.ExecuteAsync(
        async _ => await redis.GetDatabase().StringIncrementAsync("visits"), ct);
    return Results.Ok(new { visits, servedBy = Environment.MachineName });
});
```

Strategies wrap each other in the order they are added. The outer timeout covers everything, and the inner one applies to each attempt.

> **Lesson from testing: Polly timeouts are cooperative.** They work by cancelling a `CancellationToken`. StackExchange.Redis commands do not accept one, so the 1-second per-attempt timeout above never fired. With Redis stopped, each attempt waited for the client's own 5-second backlog timeout, and the request took about 6 seconds. The fix is to set timeouts **in the client library** as well:
>
> ```csharp
> var redisOptions = ConfigurationOptions.Parse("redis:6379,abortConnect=false,connectTimeout=1000,asyncTimeout=1000");
> redisOptions.BacklogPolicy = BacklogPolicy.FailFast;   // fail immediately while disconnected, instead of queueing
> builder.Services.AddSingleton<IConnectionMultiplexer>(_ => ConnectionMultiplexer.Connect(redisOptions));
> ```
>
> With that change, the same request failed cleanly after 4 attempts in about 1.1 seconds.

For **HTTP** calls, .NET has a ready-made pipeline that combines retry, timeouts, circuit breaker and rate limiting with sensible defaults:

```csharp
builder.Services.AddHttpClient("payments", c => c.BaseAddress = new Uri("https://payments.internal"))
    .AddStandardResilienceHandler();
```

### TypeScript with cockatiel

```typescript
import { ExponentialBackoff, TimeoutStrategy, handleAll, retry, timeout, wrap } from "cockatiel";

const retryPolicy = retry(handleAll, {
  maxAttempts: 3,
  backoff: new ExponentialBackoff({ initialDelay: 200, maxDelay: 2_000 }),
});
const perAttemptTimeout = timeout(1_000, TimeoutStrategy.Aggressive);
const resilient = wrap(retryPolicy, perAttemptTimeout);

retryPolicy.onRetry((reason) => console.warn("retrying redis call", reason));

app.get("/api/visits", async (_req, res) => {
  const visits = await resilient.execute(() => redis.incr("visits"));
  res.json({ visits, servedBy: os.hostname() });
});
```

`TimeoutStrategy.Aggressive` rejects the promise when time runs out, even if the operation ignores cancellation. The underlying call may still complete in the background. `ExponentialBackoff` applies jitter by default.

## Idempotency: the trap in our own sample

**Only retry operations that are safe to repeat.** `GET /api/visits` calls `INCR`, which is *not* idempotent. Consider this sequence:

1. The API sends `INCR visits`.
2. Redis increments the counter to 42.
3. The response is lost (a network blip, or the timeout fires a moment too early).
4. The retry sends `INCR visits` again, and the counter becomes 43. One visit was counted twice.

For a visit counter that may be acceptable. For "charge the customer" it is not. Options:

- Retry only reads and idempotent writes (`SET`, `PUT` with a full resource, upserts).
- Make writes idempotent with an **idempotency key**. The client sends a unique ID, and the server records processed IDs and ignores duplicates.
- Use [event sourcing](event-sourcing.md) or an outbox, where duplicate events can be detected by ID.

## Risks

| Risk | Mitigation |
|---|---|
| **Retry storms.** Retries multiply load on a dependency that is already failing. | Few attempts, backoff with jitter, a [circuit breaker](circuit-breaker.md), and retries in one layer only |
| **Latency.** Retries make slow requests slower. | An overall timeout. Do not retry when the user-facing deadline has nearly passed. |
| **Duplicate side effects** | Idempotency, as above |
| **Hiding real problems** | Log and measure every retry. A rising retry rate is an early warning. |

## Related patterns

- [Circuit breaker](circuit-breaker.md): stop retrying when failure is clearly not transient.
- [Rate limiting](rate-limiting.md): `429` plus `Retry-After` is the server telling the client how to retry.
- Kubernetes readiness probes and graceful shutdown: these remove many transient errors at the source (see [Kubernetes.md](../Kubernetes.md)).
