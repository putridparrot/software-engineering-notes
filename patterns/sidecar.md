# Sidecar

> Deploy supporting components of an application into a separate process or container alongside it, to provide isolation and encapsulation, and to add capabilities without changing the application itself.

Like a motorcycle sidecar, it is attached to the main vehicle, shares its journey and lifecycle, but is a separate unit.

## The problem

Every service needs the same cross-cutting capabilities:

- metrics and log shipping
- TLS and mutual TLS between services
- configuration and secrets reloading
- proxies, retries and traffic control
- authentication

Building these into every application means:

- reimplementing them in every language (the sample alone has .NET *and* Node)
- coupling application releases to infrastructure concerns
- inconsistency between teams

Some applications cannot be changed at all, such as third-party images like Redis or nginx.

## How it works

Run the helper as a **second container in the same pod**, or the same task or app on other platforms. Containers in a pod share:

- the **network namespace**, so the sidecar reaches the app on `localhost`, and vice versa
- **volumes**, so they can share files such as logs, sockets and config
- the **lifecycle**, so they are scheduled, started, scaled and stopped together

```
 ┌─────────────────────────── Pod ────────────────────────────┐
 │                                                            │
 │   ┌──────────────┐   localhost:6379    ┌────────────────┐  │  :9121/metrics
 │   │    redis     │ ◀────────────────── │ redis-exporter │◀─┼──────────────── Prometheus
 │   │  (unchanged  │                     │   (sidecar)    │  │
 │   │    image)    │                     └────────────────┘  │
 │   └──────────────┘                                         │
 │          shared network namespace · shared volumes         │
 └────────────────────────────────────────────────────────────┘
```

## In our sample

### A metrics exporter for Redis

Redis does not expose Prometheus metrics. We cannot (and should not) change the official `redis:7-alpine` image. Instead, a sidecar runs `redis_exporter` next to it, connects over `localhost`, and serves metrics on port 9121.

Kubernetes 1.29+ has **native sidecars**. These are init containers with `restartPolicy: Always`. They start *before* the main container, keep running alongside it, and stop *after* it. Older "just add a second container" sidecars had no start or stop ordering. This extends the `redis` Deployment from [redis.yaml](../samples/containerization/k8s/base/redis.yaml):

```yaml
    spec:
      initContainers:
        # Native sidecar: an init container with restartPolicy Always starts before
        # the main container and keeps running alongside it for the pod's lifetime
        - name: redis-exporter
          image: oliver006/redis_exporter:v1.62.0
          restartPolicy: Always
          env:
            - name: REDIS_ADDR
              value: redis://localhost:6379   # same pod = same network namespace
          ports:
            - name: metrics
              containerPort: 9121
      containers:
        - name: redis
          image: redis:7-alpine
          # ... unchanged
```

Tested on the local cluster:

```
NAME                 READY   STATUS    RESTARTS   AGE
redis-sidecar-test   2/2     Running   0          5s        ← two containers, one pod

$ curl localhost:9121/metrics   (via kubectl port-forward)
redis_up 1
redis_connected_clients 1
redis_db_keys{db="db0"} 1
```

Redis gained monitoring without any change to its image or configuration. In the [Helm chart](../Helm.md), this would naturally be an optional value: `redis.metrics.enabled: true`.

### The nginx front end is *not* a sidecar

In the sample, nginx runs as a **separate Deployment**, the `web` service, that proxies to the API Service. An alternative design would put nginx (or Envoy) *inside* each API pod as a sidecar proxy, handling TLS, compression or auth before forwarding to `localhost:8080`. That is exactly what a **service mesh** does automatically for every pod.

| | Separate service (sample) | Sidecar proxy |
|---|---|---|
| Scaling | Independently of the API | 1:1 with each API pod |
| Network hops | Extra hop to reach the API | `localhost` only |
| Resource cost | Shared by all API pods | Paid per pod |
| Typical use | Edge / gateway | Per-service TLS, policy, telemetry |

## Common sidecars

| Sidecar | Purpose |
|---|---|
| Envoy / Linkerd proxy (service mesh: Istio, Linkerd) | mTLS, retries, traffic splitting and telemetry, injected automatically into every pod |
| **Dapr** | Building blocks (state, pub/sub, secrets, service invocation) over HTTP/gRPC on localhost. Built into Azure Container Apps. |
| Log shippers (Fluent Bit) | Tail log files the app writes to a shared volume |
| Exporters (redis_exporter, nginx-prometheus-exporter) | Translate a component's stats into Prometheus metrics |
| Secrets / config agents (Vault agent) | Fetch and refresh secrets into a shared volume |
| Cloud SQL proxy, Azure Workload Identity helpers | Handle authentication to cloud services |

Azure Container Apps and App Service (Linux) both support sidecar containers too. The pattern is not Kubernetes-specific.

## Risks

| Risk | Mitigation |
|---|---|
| **Resource overhead** for every pod | Set small `requests`/`limits` for sidecars. For something needed everywhere, consider a node-level **DaemonSet** instead (one per node, not per pod). |
| **Latency** for proxy sidecars: an extra hop through localhost | Usually sub-millisecond, but measure for latency-sensitive paths |
| **Lifecycle ordering:** the app starts before its proxy, or the sidecar keeps a Job running forever | Use native sidecars (`restartPolicy: Always` init containers), which fix both |
| **Sidecar failure affects the pod** | Give sidecars their own probes. Decide whether a sidecar failure should make the pod unready. |
| **Version sprawl:** hundreds of pods with different sidecar versions | Inject sidecars centrally (mesh injection, Helm library charts). Update them like any other dependency. |

## When not to use it

- The capability is small and language-native: a library is simpler and cheaper.
- It needs very low latency between the app and the helper.
- One instance per node or per cluster would do: use a DaemonSet or a shared service.
- The helper must scale independently of the app.

## Related patterns

- **Ambassador:** a sidecar specialised as an outbound proxy to remote services, adding retries, [circuit breaking](circuit-breaker.md) and routing on the app's behalf.
- **Adapter:** a sidecar that standardises output, as the Redis exporter does for metrics.
- **Gateway offloading:** move shared concerns to a central gateway instead of every pod.
