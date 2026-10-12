# Cloud design patterns

One page per pattern from the competency framework. Each page explains the problem the pattern solves, how it works, how it applies to the **visits sample** from [Containerization.md](../Containerization.md), [Kubernetes.md](../Kubernetes.md) and [Helm.md](../Helm.md), and, just as importantly, its risks and when *not* to use it.

| Pattern | Problem it solves | Where it shows up in the sample |
|---|---|---|
| [Strangler fig](strangler-fig.md) | Replacing a legacy system without a big-bang rewrite | nginx routes `/api/visits` to the new Node API and everything else to the legacy .NET API |
| [Retry (and timeouts)](retry.md) | Transient failures: blips, restarts, failovers | Redis client reconnect settings; Polly / cockatiel retry around Redis calls |
| [Circuit breaker](circuit-breaker.md) | A failing dependency dragging the caller down with it | Breaker around Redis returns a fast 503 instead of piling up timeouts |
| [Cache-aside](cache-aside.md) | Slow or expensive reads from a data store | Redis as a cache in front of a product repository |
| [Throttling](throttling.md) | A service overwhelmed by more load than it can handle | Concurrency limiter in the API, Kubernetes resource limits, HPA |
| [Rate limiting](rate-limiting.md) | Clients using more than their share, or a caller overrunning a downstream quota | nginx `limit_req`, ASP.NET Core rate limiter, express-rate-limit with a Redis store |
| [Sharding](sharding.md) | One data store (or one key) becoming a scale or contention limit | Sharded visit counter; Redis Cluster; Cosmos DB partition keys |
| [Sidecar](sidecar.md) | Adding cross-cutting capabilities without changing the app | Redis metrics exporter running as a Kubernetes native sidecar |
| [Event sourcing](event-sourcing.md) | Needing history, audit and multiple views of the same data | Visits recorded as events in a Redis Stream and replayed or projected |

## How the patterns fit together

They are rarely used alone. A typical call from the API to Redis in a production-grade version of the sample stacks several of them:

```
 client ──▶ [rate limiter] ──▶ [throttle] ──▶ handler ──▶ [timeout ▸ retry ▸ circuit breaker] ──▶ Redis
             per-client        protect this               protect against a failing dependency
             fairness          instance
```

Order matters, and every layer adds latency and failure modes of its own. Several pages below include something that went wrong when the code was tested, because those are the lessons that matter most in practice.

## About the code

The C# (.NET 10) and TypeScript (Node 24) snippets were compiled and run against Redis 7. The nginx and Kubernetes snippets were run on Docker and on the local Docker Desktop cluster. They are **illustrations**, not part of the sample application, so the sample stays simple. Libraries used:

| Concern | .NET | Node / TypeScript |
|---|---|---|
| Retry, timeout, circuit breaker | [Polly](https://www.pollydocs.org/) v8 (`Polly.Core`), `Microsoft.Extensions.Http.Resilience` | [cockatiel](https://github.com/connor4312/cockatiel) |
| Caching | `HybridCache` (`Microsoft.Extensions.Caching.Hybrid`) or StackExchange.Redis | ioredis |
| Rate limiting / throttling | Built-in `Microsoft.AspNetCore.RateLimiting` | `express-rate-limit` + `rate-limit-redis` |

Further reading: the [Azure Architecture Center cloud design patterns catalogue](https://learn.microsoft.com/azure/architecture/patterns/), which these pages follow for definitions.
