# Event sourcing

> Instead of storing just the current state of data, store the full sequence of events that changed it, in an append-only log. Current state is derived by replaying the events.

## The problem

A conventional system stores **current state** and overwrites it: `UPDATE accounts SET balance = 70`. This loses information:

- *How* did the balance become 70? What happened before?
- What did the data look like last Tuesday?
- A bug corrupted some records: what were the correct values?
- The business wants a new report or view over historical behaviour, but the history no longer exists.

Audit tables and change logs are often bolted on afterwards, and drift from the real data.

## How it works

Every change is recorded as an immutable **event**, a fact in the past tense, appended to an **event store**:

```
 Event stream "account-123"                       Current state (derived)
 ─────────────────────────────────────────        ───────────────────────
 1  AccountOpened      { owner: "Ana" }     ─┐
 2  MoneyDeposited     { amount: 100 }       │     replay / fold
 3  MoneyWithdrawn     { amount: 30 }        ├──▶  balance = 70
 4  ...                                     ─┘     transactions = 2
```

- **Events are never updated or deleted.** Corrections are new events, such as `WithdrawalReversed`.
- **State is a left fold over events.** Start empty, then apply each event in order.
- **Projections** (read models) listen to events and maintain views shaped for queries: a balance table, a monthly report, a search index. This is the **CQRS** split between the write side (events) and read side (projections).
- **Snapshots** store state every N events, so a long stream does not have to be replayed from the start every time.

## In our sample

Currently `GET /api/visits` runs `INCR visits`. It stores the **current state**, a number, and nothing else. We cannot answer "how many visits came from mobile browsers yesterday?" because that information was never kept.

An event-sourced version records each visit as an event in a **Redis Stream**, Redis's append-only log type, and derives the count from the events.

### Append events

```csharp
app.MapPost("/api/visits", async (IConnectionMultiplexer redis, HttpRequest request) =>
{
    var db = redis.GetDatabase();
    var id = await db.StreamAddAsync("visit-events",
    [
        new NameValueEntry("type", "VisitRecorded"),
        new NameValueEntry("at", DateTimeOffset.UtcNow.ToString("O")),
        new NameValueEntry("userAgent", request.Headers.UserAgent.ToString())
    ]);
    return Results.Accepted(value: new { eventId = id.ToString() });
});
```

```typescript
app.post("/api/visits", async (req, res) => {
  const eventId = await redis.xadd(
    "visit-events", "*",
    "type", "VisitRecorded",
    "at", new Date().toISOString(),
    "userAgent", req.get("user-agent") ?? "",
  );
  res.status(202).json({ eventId });
});
```

The endpoint becomes a `POST` because it records a fact, while reads go elsewhere. Redis assigns each event an ordered ID such as `1791658195500-0`.

### Rebuild state by replaying

```typescript
// Rebuild state by replaying every event from the start
async function replayVisits(): Promise<number> {
  const events = await redis.xrange("visit-events", "-", "+");
  let visits = 0;
  for (const [, fields] of events) {
    const type = fields[fields.indexOf("type") + 1];
    if (type === "VisitRecorded") visits++;
  }
  return visits;
}
```

Tested: three `POST`s, then a replay returned `{"visits":3}`. Because the user agent was kept, a *new* question ("visits by browser") can be answered from the past events by writing a new replay. No data was lost by choosing the "wrong" schema up front.

### Keep a read model up to date with a projection

Replaying everything on every read does not scale. A **projection** consumes new events and maintains a ready-made view. Redis Streams **consumer groups** let several API replicas share the work, with each event processed once:

```typescript
// Projection: a consumer group reads new events and updates a read model
async function runProjection(): Promise<void> {
  await redis.xgroup("CREATE", "visit-events", "visits-projection", "0", "MKSTREAM").catch(() => {});
  for (;;) {
    const batch = (await redis.xreadgroup(
      "GROUP", "visits-projection", os.hostname(),
      "COUNT", 100, "BLOCK", 5_000,
      "STREAMS", "visit-events", ">",
    )) as [string, [string, string[]][]][] | null;
    if (!batch) continue;

    for (const [, entries] of batch) {
      for (const [id] of entries) {
        await redis.incr("visits:projection");
        await redis.xack("visit-events", "visits-projection", id);
      }
    }
  }
}
```

`GET /api/visits` then reads `visits:projection`, which is as fast as the original `INCR` design. The read model can be deleted and rebuilt from the events at any time, for example after fixing a bug in the projection.

Note that the projection `INCR` and the `XACK` are separate commands. If a pod dies between them, the event is redelivered and counted twice. Real projections record the last processed event ID atomically with the update (e.g. in a `MULTI`/`EXEC`), or make the update idempotent. This is the same issue as in [Retry](retry.md).

> **Redis Streams illustrates the idea, but is not a full event store.** It lacks per-entity streams with optimistic concurrency ("append only if the stream is still at version 7"), long-term durability guarantees by default, and schema tooling. Purpose-built options include **KurrentDB** (formerly EventStoreDB), **Marten** (.NET, on PostgreSQL), or Cosmos DB with its change feed driving projections. **Azure Event Hubs** and **Kafka** are excellent event *logs* for streaming, but are not usually the system of record for an event-sourced domain.

## Benefits

- A **complete audit trail**, by construction
- **Temporal queries:** replay up to any point to see past state
- **New read models from old data:** projections can be added later and built from history
- **Debugging:** replay the exact events that led to a bug
- **Integration:** other services subscribe to the same events

## Risks and costs

| Risk | Mitigation |
|---|---|
| **Complexity.** It is a very different model from CRUD, with a learning curve for the whole team. | Use it only for the parts of the domain that benefit. Most of the system can stay CRUD. |
| **Eventual consistency.** Projections lag behind writes. | Design the UI for it ("your change is being processed"). Read your own writes from the stream where needed. |
| **Event schema evolution.** Old events live forever, so new code must read every historical version. | Version events. Use upcasters to transform old formats on read. Never change the meaning of an existing event type. |
| **Replay time** grows with history | Snapshots. Projections built incrementally. |
| **Deleting data (GDPR)** in an immutable log | Keep personal data out of events (store a reference), or use **crypto-shredding**: encrypt per user and delete the key. |
| **Duplicate processing** | Idempotent projections. Track the last processed position atomically. |

## When not to use it

- Simple CRUD with no audit or history requirements.
- The team is unfamiliar with it and the domain does not justify the investment.
- Strong, immediate consistency is required everywhere.
- "We want an audit log" alone: an audit table or change data capture is far simpler.

Good fits include financial ledgers, order lifecycles, booking systems, regulatory audit, and collaborative or undoable editing. These are domains where the *history of changes* is the business.

## Related patterns

- **CQRS:** separating writes (commands and events) from reads (projections). Commonly paired with event sourcing, but usable without it.
- **Materialised view:** the projection.
- **Outbox / change data capture:** publish events reliably from a conventional database, often a better first step.
- [Strangler fig](strangler-fig.md): events are a good way to keep a new service's data in sync with a legacy system during migration.
- [Sharding](sharding.md): event stores partition by stream (entity) ID.
