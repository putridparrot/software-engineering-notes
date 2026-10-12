# Strangler fig

> Incrementally migrate a legacy system by gradually replacing pieces of functionality with new services, behind a façade that routes each request to the old or new implementation.

The name comes from the strangler fig tree. It grows around a host tree, and over years replaces it entirely, until the original can be removed.

## The problem

A large legacy application needs replacing. Perhaps it is on an unsupported framework, hard to change, or cannot scale. A **big-bang rewrite** is high risk:

- Nothing ships for months or years.
- The old system keeps changing underneath the rewrite.
- Cut-over day is a single, huge, hard-to-roll-back event.

## How it works

Put a **façade** (routing layer) in front of the legacy system. Then repeat:

1. Pick one slice of functionality, such as an endpoint, page or feature.
2. Build it in the new system.
3. Change the façade to route that slice to the new system.
4. Monitor. If something is wrong, route back.
5. Delete the legacy code for that slice.

```
  Phase 1                     Phase 2                       Phase 3
  ┌────────┐                  ┌────────┐                    ┌────────┐
  │ façade │                  │ façade │                    │ façade │
  └───┬────┘                  └─┬────┬─┘                    └───┬────┘
      │ everything        /visits │    │ everything else        │ everything
      ▼                         ▼    ▼                          ▼
  ┌────────┐             ┌──────┐  ┌────────┐               ┌──────┐
  │ legacy │             │ new  │  │ legacy │               │ new  │     legacy
  └────────┘             └──────┘  └────────┘               └──────┘     retired
```

Each step is small, reversible and delivers value on its own.

## In our sample

The sample already has the two halves. `api` is the "legacy" .NET service and `api-node` is the "new" TypeScript service, and both implement the same contract. nginx already sits in front as a reverse proxy, so it can serve as the façade.

### nginx as the façade

Path-based routing: the migrated endpoint goes to the new service, and everything else stays on the legacy one. nginx picks the most specific `location`, and `=` is an exact match:

```nginx
server {
    listen 80;
    resolver 127.0.0.11 valid=5s;

    # Strangler fig: the visits endpoint has been migrated to the new Node service...
    location = /api/visits {
        set $new_api http://api-node:8080;
        proxy_pass $new_api;
    }

    # ...everything else under /api still goes to the legacy .NET service
    location /api/ {
        set $legacy_api http://api:8080;
        proxy_pass $legacy_api;
    }
}
```

With both services running in Compose, `/api/visits` was answered by the Node service, and other `/api/*` paths reached the .NET service. Rolling back the migration is a one-line config change.

### Gradual traffic shifting (canary)

For riskier slices, move a *percentage* of traffic rather than all of it:

```nginx
# 10% of clients (by IP) go to the new implementation
split_clients "${remote_addr}" $visits_backend {
    10%     http://api-node:8080;
    *       http://api:8080;
}
```

Platforms offer the same capability:

| Platform | Mechanism |
|---|---|
| Kubernetes | Ingress / Gateway API path routing; weighted `HTTPRoute` backends; ingress-nginx canary annotations |
| Azure Container Apps | Revisions with traffic splitting |
| Azure App Service | Deployment slots with "% of traffic" routing |
| Azure Front Door / API Management | Path-based routing to different origins / backends |

With the [Helm chart](../Helm.md), the routing rules could become values (`routes.visits: new`), so each migrated slice is a reviewed, versioned values change.

## Risks and how to handle them

| Risk | Mitigation |
|---|---|
| **Shared data.** Old and new both need the same data during migration. | Start with the new service reading the legacy data store, then migrate data ownership later. Or sync with change data capture or events. Avoid two systems writing the same tables. |
| **Behaviour differences.** The new implementation subtly differs. | Contract tests run against both. Optionally "shadow" traffic: send to both, compare responses, return the legacy one. |
| **The façade becomes a bottleneck or single point of failure.** | Use a highly available gateway (multiple nginx replicas, Front Door, APIM). Keep it thin: routing only, no business logic. |
| **The migration never finishes.** You end up running two systems forever. | Track the remaining slices visibly. Delete legacy code as each slice moves. Budget time for the last, hardest pieces. |
| **Cross-cutting concerns** (auth, sessions) must work across both. | Use token-based auth that both understand. Keep session state out of process. |

## When not to use it

- The system is small enough to replace in one go safely.
- Requests cannot be intercepted and routed, e.g. a tightly coupled desktop app or a batch process with no seams.
- The legacy system is being retired, not replaced.

## Related patterns

- **Anti-corruption layer:** translates between the legacy model and the new one so the new code is not polluted by legacy concepts.
- **Gateway routing:** the façade itself.
- [Event sourcing](event-sourcing.md) and change data capture are ways to keep data in sync during migration.

## Evidence idea

Pick one endpoint of a real legacy service and migrate it behind a routing layer (APIM, Front Door, ingress or nginx). Use a canary percentage, a dashboard comparing error rates, and a documented rollback step. Write up how the data was handled during the transition.
