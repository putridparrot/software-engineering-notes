# Circuit breaker

> Handle faults that might take a variable amount of time to recover from, by stopping calls to a failing dependency for a period, so the application fails fast instead of waiting on something that will not succeed.

## The problem

[Retry](retry.md) is right for brief, transient faults. But suppose Redis is down for five minutes. Every request still:

1. calls Redis
2. waits for a timeout, possibly several times with retries
3. fails anyway

Meanwhile:

- Threads, connections and memory pile up waiting.
- Users wait seconds for an error.
- The struggling dependency is hammered with calls it cannot serve, which slows its recovery.
- The API, which was healthy, becomes slow and eventually unhealthy too. The failure **cascades** upstream.

## How it works

Like an electrical circuit breaker, it trips after too many failures and stops the flow:

```
                 failures exceed threshold
       ┌────────┐ ─────────────────────────▶ ┌────────┐
       │ CLOSED │                             │  OPEN  │  calls fail immediately
       │ calls  │ ◀───┐                       │ (fast) │  without touching the dependency
       │ flow   │     │ trial call            └───┬────┘
       └────────┘     │ succeeds                  │ break duration elapses
                      │                           ▼
                      │                     ┌───────────┐
                      └──────────────────── │ HALF-OPEN │  allow a trial call
                                            └─────┬─────┘
                       trial call fails ──────────┘──▶ back to OPEN
```

- **Closed:** normal operation, with failures counted.
- **Open:** calls are rejected immediately with an exception. The caller can return an error quickly or use a **fallback**, such as cached data, a default value or a degraded feature.
- **Half-open:** after the break duration, a trial call is let through. Success closes the circuit, and failure opens it again.

## In our sample

### .NET with Polly

```csharp
builder.Services.AddSingleton(new ResiliencePipelineBuilder()
    .AddCircuitBreaker(new CircuitBreakerStrategyOptions
    {
        ShouldHandle = new PredicateBuilder()
            .Handle<RedisConnectionException>()
            .Handle<RedisTimeoutException>(),
        FailureRatio = 0.5,                          // open when 50% of calls fail...
        MinimumThroughput = 10,                      // ...out of at least 10 calls...
        SamplingDuration = TimeSpan.FromSeconds(10), // ...within a 10 second window
        BreakDuration = TimeSpan.FromSeconds(15)     // stay open for 15s before a trial call
    })
    .Build());

app.MapGet("/api/visits", async (IConnectionMultiplexer redis, ResiliencePipeline breaker, CancellationToken ct) =>
{
    try
    {
        var visits = await breaker.ExecuteAsync(
            async _ => await redis.GetDatabase().StringIncrementAsync("visits"), ct);
        return Results.Ok(new { visits, servedBy = Environment.MachineName });
    }
    catch (BrokenCircuitException)
    {
        // Fail fast: Redis is known to be unhealthy, don't wait for another timeout
        return Results.Problem("Visit counter temporarily unavailable", statusCode: 503);
    }
});
```

The breaker must be a **singleton**. Its state is shared across all requests in the process. A breaker created per request never trips.

What happened when Redis was stopped during testing:

```
500 500 500 500 500 500 500 500 500 503 503 503 503 503
└────── failures counted (closed) ───────┘ └── open: rejected in ~1.5ms ──┘
```

> **Lesson from testing: the breaker did not trip at first.** With the sample's original Redis settings, each failed call waited about 5 seconds in StackExchange.Redis's reconnect backlog. Only around 2 calls landed in each 10-second sampling window, below `MinimumThroughput = 10`, so the breaker never opened. Slow failures are exactly when a breaker is needed, and here they hid from it. Two fixes:
>
> - Make failures fast with client timeouts and `BacklogPolicy.FailFast` (see [Retry](retry.md)).
> - Choose breaker settings that suit the real traffic volume. A low-traffic service needs a lower `MinimumThroughput` or a consecutive-failure breaker.

### TypeScript with cockatiel

```typescript
import { BrokenCircuitError, CircuitState, ConsecutiveBreaker, circuitBreaker, handleAll } from "cockatiel";

// Open after 5 consecutive failures; try again after 15s.
// (SamplingBreaker gives the ratio-over-a-window behaviour used in the .NET example.)
const breaker = circuitBreaker(handleAll, {
  halfOpenAfter: 15_000,
  breaker: new ConsecutiveBreaker(5),
});
breaker.onStateChange((state) => console.log(`redis circuit is now ${CircuitState[state]}`));

app.get("/api/visits", async (_req, res) => {
  try {
    const visits = await breaker.execute(() => redis.incr("visits"));
    res.json({ visits, servedBy: os.hostname() });
  } catch (err) {
    if (err instanceof BrokenCircuitError) {
      // Fail fast: Redis is known to be unhealthy, don't wait for another timeout
      res.status(503).json({ error: "Visit counter temporarily unavailable" });
      return;
    }
    throw err;
  }
});
```

Tested result: five `500`s, then `503 {"error":"Visit counter temporarily unavailable"}` for every following call, without touching Redis.

### Combining with retry

The usual order is **retry outside, breaker inside**. Each retry attempt passes through the breaker, so once it opens, the remaining retries fail immediately instead of waiting:

```csharp
new ResiliencePipelineBuilder()
    .AddRetry(...)            // outer
    .AddCircuitBreaker(...)   // inner - an open circuit short-circuits each attempt
    .AddTimeout(...)          // per attempt
    .Build();
```

In TypeScript: `wrap(retryPolicy, breaker, perAttemptTimeout)`. Configure the retry to not retry `BrokenCircuitException` / `BrokenCircuitError`.

### Circuit breakers vs readiness probes

The sample's Kubernetes **readiness probe** on `/health/ready` is a breaker at the *platform* level. When Redis is down, the pods are taken out of the Service, so nginx gets no healthy upstream. The in-process breaker works at the *call* level, and can still serve the parts of an API that do not depend on Redis. They complement each other. But do not let an open circuit fail the **liveness** probe, or Kubernetes will restart pods that are behaving correctly.

## Risks

| Risk | Mitigation |
|---|---|
| **Wrong thresholds.** Too sensitive trips on noise. Too lax never trips. | Base them on real traffic. Test by stopping the dependency, as above. |
| **Per-instance state.** Each of the 3 API replicas has its own breaker and trips independently. | Usually fine. Aim for consistent settings, not a shared breaker. |
| **Counting the wrong errors.** A `404` or validation error should not trip the breaker. | Restrict `ShouldHandle` to dependency failures. |
| **No fallback plan.** Failing fast is better than failing slowly, but still a failure. | Decide on a fallback per feature: cached value, default, or hide the feature. |
| **Invisible state** | Log and emit metrics on every state change. An open circuit should alert someone. |

## Related patterns

- [Retry](retry.md): breakers stop retries hammering a dead dependency.
- **Bulkhead:** isolate resources per dependency, so one slow dependency cannot use every thread.
- [Cache-aside](cache-aside.md): a cache is a natural fallback when the circuit to the database is open.
- [Throttling](throttling.md): load shedding protects *this* service, while the breaker protects against *others*.
