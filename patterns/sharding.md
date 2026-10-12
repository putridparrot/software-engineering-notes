# Sharding

> Divide a data store into a set of horizontal partitions, or shards, each holding a distinct subset of the data, so that storage and load are spread across multiple servers.

## The problem

A single database or cache server eventually hits a limit:

- **storage:** the data no longer fits
- **throughput:** too many reads or writes per second for one server
- **contention:** many writers fighting over the same rows or keys
- **geography:** users far from the single server get high latency, or data must stay in a region for compliance

Scaling *up* to a bigger server works for a while, but has a ceiling and gets expensive. Sharding scales *out*.

## How it works

Each item is assigned to a shard by a **shard key**. A routing layer, which may live in the application, a client library or the database itself, sends each request to the right shard.

| Strategy | How the shard is chosen | Good for | Watch out for |
|---|---|---|---|
| **Hash** | `hash(key) mod N`, or a hash ring | Even spread of data and load | Range queries hit every shard. Changing N moves lots of data (unless you use consistent hashing or slots). |
| **Range** | Key ranges (A–F, G–M...; or by date) | Range queries, time-series | Hot shards: all of today's writes land on one shard |
| **Lookup / directory** | A map of key to shard | Flexibility, moving tenants individually, geo-placement | The map is an extra dependency and lookup |

```
                       hash(tenantId) → slot
  request ──▶ router ───────────────────────────┬────────────┬────────────┐
                                                ▼            ▼            ▼
                                           ┌────────┐   ┌────────┐   ┌────────┐
                                           │shard A │   │shard B │   │shard C │
                                           │slots   │   │slots   │   │slots   │
                                           │0-5460  │   │5461-   │   │10923-  │
                                           └────────┘   │10922   │   │16383   │
                                                        └────────┘   └────────┘
```

**Choosing the shard key is the most important decision**, and the hardest to change later. A good key:

- has **high cardinality** (many distinct values)
- spreads **load** evenly, not just data
- matches the **access pattern**, so most queries need only one shard. For example, if every query includes `tenantId`, shard by `tenantId`.

## In our sample

### The hot key problem: a sharded counter

The sample has a single key, `visits`, that *every* request increments. Redis is very fast, so this is fine at demo scale. But on a sharded cluster, one key always lives on **one** shard. Adding servers would not help, because all the writes would still hit the same one. This is a **hot partition**.

The classic fix is to shard the counter itself. Writes go to one of N sub-keys at random, and reads sum them:

```csharp
const int CounterShards = 16;

app.MapGet("/api/visits", async (IConnectionMultiplexer redis) =>
{
    var db = redis.GetDatabase();
    var shard = Random.Shared.Next(CounterShards);
    await db.StringIncrementAsync($"visits:{shard}");            // write: one random shard

    var keys = Enumerable.Range(0, CounterShards).Select(i => (RedisKey)$"visits:{i}").ToArray();
    var values = await db.StringGetAsync(keys);                  // read: all shards
    var visits = values.Sum(v => v.HasValue ? (long)v : 0);
    return Results.Ok(new { visits });
});
```

```typescript
const COUNTER_SHARDS = 16;

app.get("/api/visits", async (_req, res) => {
  const shard = Math.floor(Math.random() * COUNTER_SHARDS);
  await redis.incr(`visits:${shard}`);                           // write: one random shard

  const keys = Array.from({ length: COUNTER_SHARDS }, (_, i) => `visits:${i}`);
  const values = await redis.mget(keys);                         // read: all shards
  const visits = values.reduce((sum, v) => sum + Number(v ?? 0), 0);
  res.json({ visits });
});
```

After three test requests, the keys in Redis were `visits:3 visits:5 visits:6`, with the total still correct at 3.

This shows the fundamental trade-off of sharding. **Writes became cheap and parallel, and reads became more expensive** (16 keys instead of 1). Sharding optimises one access pattern at the cost of another.

> On a real Redis Cluster, the multi-key `MGET` above would fail with a `CROSSSLOT` error, because the keys live on different nodes. You would either read the keys individually, or keep the counter shards on separate nodes deliberately (which is the point), and maintain a periodically aggregated total.

### Redis Cluster: sharding built into the store

Redis Cluster (and the clustered tiers of Azure Cache for Redis / Azure Managed Redis) splits the keyspace into **16,384 hash slots**, spread across the nodes. Client libraries are cluster-aware: StackExchange.Redis automatically, and ioredis via `new Redis.Cluster([...])`. They route each command to the node that owns the key's slot.

**Hash tags** force related keys into the same slot, so multi-key operations and transactions still work. Only the part inside `{}` is hashed:

```
cart:{user42}:items    ─┐
cart:{user42}:total    ─┴─ same slot → same node → MULTI/EXEC and MGET work
```

This is the general sharding rule in miniature. **Data that is used together should live together.**

## Sharding in Azure data services

| Service | How sharding appears |
|---|---|
| **Cosmos DB** | Every container has a **partition key**, and Cosmos distributes logical partitions across physical partitions automatically. Hot partitions cause `429`s even when total capacity is free. Hierarchical partition keys help with large tenants. |
| **Azure Managed Redis / Cache for Redis** | Clustering, with hash slots as above |
| **Azure SQL** | No automatic sharding. Use the Elastic Database tools (shard map manager) or Hyperscale for scale-up. A **database per tenant** is a common lookup-style approach. |
| **Azure Storage / Event Hubs / Service Bus** | Partitions: Event Hubs partition keys and Service Bus partitioned entities and sessions |
| **PostgreSQL** | Azure Cosmos DB for PostgreSQL (Citus) distributes tables by a distribution column |

## Risks

| Risk | Mitigation |
|---|---|
| **Hot shards / partitions** | Choose high-cardinality keys. Shard hot keys further (as with the counter). Monitor load per shard. |
| **Cross-shard queries are slow and complex** | Choose the key to match the main access pattern. Maintain separate read models for other patterns (see [Event sourcing](event-sourcing.md) / CQRS). |
| **No cross-shard transactions** | Keep transactional data in one shard (hash tags, partition keys). Otherwise use sagas and eventual consistency. |
| **Rebalancing** when adding shards | Use stores that rebalance for you (Cosmos DB, Redis Cluster slots). Use consistent hashing if doing it yourself. |
| **Operational complexity:** backups, schema changes and monitoring multiply | Prefer managed services that shard internally. Do not shard until the numbers require it. |

## When not to use it

Most applications **should not** shard their own data. Scale up, add read replicas, add a [cache](cache-aside.md), or use a database that partitions internally first. Sharding is a one-way door, so introduce it when measurements show a single node cannot cope. Do choose good partition keys from day one in stores that require them, such as Cosmos DB.

## Related patterns

- [Cache-aside](cache-aside.md): large caches are themselves sharded.
- **Index table:** secondary lookups across shards.
- **Materialised view / CQRS:** read models shaped for queries that do not match the shard key.
- **Deployment stamps:** sharding whole application stacks per tenant group or region.
