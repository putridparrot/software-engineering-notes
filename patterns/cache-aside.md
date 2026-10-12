# Cache-aside

> Load data on demand into a cache from a data store. The application, not the cache, is responsible for reading from and writing to the cache.

## The problem

Reading from the main data store, such as Azure SQL, Cosmos DB or an external API, can be:

- **slow**, from tens to hundreds of milliseconds, or worse under load
- **expensive**, through Cosmos RUs, DTUs or per-call charges
- **limited**, by connection pools and throttling

Yet most applications read the same data far more often than they change it.

## How it works

The application checks the cache first. On a miss it loads from the data store and populates the cache:

```
 read:                                         write:
 ┌─────┐ 1. GET product:7  ┌───────┐           ┌─────┐ 1. UPDATE  ┌────────────┐
 │ app │ ────────────────▶ │ cache │           │ app │ ─────────▶ │ data store │
 │     │ ◀── hit? return ─ │(Redis)│           │     │            └────────────┘
 │     │                   └───────┘           │     │ 2. DEL     ┌───────┐
 │     │ 2. miss: SELECT   ┌────────────┐      │     │ ─────────▶ │ cache │
 │     │ ────────────────▶ │ data store │      └─────┘            └───────┘
 │     │ 3. SET with TTL   └────────────┘      next read repopulates it
 │     │ ─────▶ cache
 └─────┘
```

The cache is a **copy**. The data store remains the source of truth, so losing the cache loses no data, only speed.

Contrast this with *read-through* and *write-through* caches, where the cache itself loads from and writes to the store. Cache-aside is the most common pattern, because Redis, Memcached and most caches do not know about your database.

## In our sample

The visits counter keeps its data *in* Redis, so it is not cache-aside. Redis is the store. For this pattern, imagine the API also serves products from a slower database, with the same Redis acting as the cache.

### By hand: .NET

```csharp
app.MapGet("/api/products/{id:int}", async (int id, IConnectionMultiplexer redis, ProductRepository repository) =>
{
    var cache = redis.GetDatabase();
    var key = $"product:{id}";

    // 1. Try the cache
    var cached = await cache.StringGetAsync(key);
    if (cached.HasValue)
        return Results.Ok(JsonSerializer.Deserialize<Product>(cached.ToString(), JsonSerializerOptions.Web));

    // 2. Cache miss - load from the source of truth
    var product = await repository.GetAsync(id);
    if (product is null)
        return Results.NotFound();

    // 3. Populate the cache with an expiry, then return
    await cache.StringSetAsync(key, JsonSerializer.Serialize(product, JsonSerializerOptions.Web), TimeSpan.FromMinutes(5));
    return Results.Ok(product);
});
```

`JsonSerializerOptions.Web` keeps the cached JSON camel-cased like the API responses. The first test version used the default options and stored `{"Id":7,...}` in Redis while returning `{"id":7,...}`. That was harmless, but inconsistent for anything else reading the cache.

### With HybridCache: .NET

.NET 9+ has `HybridCache`, which implements cache-aside for you. It combines a fast in-process (L1) cache with an optional distributed (L2) cache such as Redis, and adds **stampede protection** (see below):

```csharp
builder.Services.AddHybridCache();
// For Redis as the L2 cache, also register: builder.Services.AddStackExchangeRedisCache(...)

app.MapGet("/api/products/{id:int}", async (int id, HybridCache cache, ProductRepository repository, CancellationToken ct) =>
{
    var product = await cache.GetOrCreateAsync(
        $"product:{id}",
        async token => await repository.GetAsync(id, token),
        new HybridCacheEntryOptions { Expiration = TimeSpan.FromMinutes(5) },
        cancellationToken: ct);

    return product is null ? Results.NotFound() : Results.Ok(product);
});
```

### By hand: TypeScript

```typescript
app.get("/api/products/:id", async (req, res) => {
  const key = `product:${req.params.id}`;

  // 1. Try the cache
  const cached = await redis.get(key);
  if (cached) {
    res.json(JSON.parse(cached));
    return;
  }

  // 2. Cache miss - load from the source of truth
  const product = await db.getProduct(req.params.id);
  if (!product) {
    res.sendStatus(404);
    return;
  }

  // 3. Populate the cache with an expiry, then return
  await redis.set(key, JSON.stringify(product), "EX", 300);
  res.json(product);
});
```

### Writes: invalidate, don't update

```csharp
app.MapPut("/api/products/{id:int}", async (int id, Product product, IConnectionMultiplexer redis, ProductRepository repository) =>
{
    await repository.SaveAsync(product);
    await redis.GetDatabase().KeyDeleteAsync($"product:{id}");   // invalidate, don't update
    return Results.NoContent();
});
```

```typescript
app.put("/api/products/:id", express.json(), async (req, res) => {
  await db.saveProduct(req.body as Product);
  await redis.del(`product:${req.params.id}`);   // invalidate, don't update
  res.sendStatus(204);
});
```

Deleting is safer than writing the new value into the cache. With two concurrent updates, "write to DB, then write to cache" can leave the cache holding the *older* value indefinitely. Deleting means the next read loads whatever the database now holds.

## Risks and design decisions

| Concern | Guidance |
|---|---|
| **Staleness.** The cache can be out of date. | Always set a **TTL**. Choose it per data type, by asking how stale the business can tolerate. Invalidate on write where possible. |
| **Cache stampede.** A popular key expires and hundreds of requests miss at once, all hitting the database. | Request coalescing (HybridCache does this per instance), early or probabilistic refresh, or jittered TTLs |
| **Cache unavailable** | Treat the cache as optional. On a cache error, fall back to the database (perhaps behind a [circuit breaker](circuit-breaker.md)) rather than failing the request. |
| **Caching nulls / not-found** | Without care, repeated requests for missing IDs always hit the database. Cache a short-lived "not found" marker if needed. |
| **Memory and eviction** | Set Redis `maxmemory` and an eviction policy (`allkeys-lru`) for a pure cache. Note that the sample's Redis is a *store*, which must not evict. Use separate instances or databases for the two roles. |
| **Consistency across services** | If other services write to the same database, they must invalidate too. Alternatively, use change data capture or events to evict. |

## When not to use it

- The data changes constantly, or must always be exactly current (balances, stock levels at checkout).
- The data store is already fast enough. A cache adds infrastructure, failure modes and staleness bugs.
- Each item is read only once.

## Azure services

- **Azure Cache for Redis / Azure Managed Redis:** the usual distributed cache.
- **In-process `IMemoryCache` / HybridCache L1:** fastest, but per instance, so the 3 API replicas each hold their own copy.
- **Azure Front Door / CDN:** cache-aside at the HTTP edge for public, cacheable responses.

## Related patterns

- [Sharding](sharding.md): large caches are sharded (Redis Cluster).
- [Circuit breaker](circuit-breaker.md): the cache can serve as a fallback when the database circuit is open.
- **CQRS / materialised views:** precomputed read models, a more structured alternative to ad-hoc caching. See [Event sourcing](event-sourcing.md).
