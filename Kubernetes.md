# Kubernetes

A practical guide to Kubernetes, building on [Containerization.md](Containerization.md). It deploys the same sample application (nginx, a .NET or TypeScript/Node API, and Redis) to Kubernetes, explains the health checks that keep it available, and compares Kubernetes with the other ways of running containers. The manifests are in [samples/containerization/k8s/](samples/containerization/k8s/). They have been tested on a local Docker Desktop cluster.

---

## 1. What is Kubernetes?

**Kubernetes** (often written **K8s**) is an open-source **container orchestrator**. It started at Google and is now maintained by the Cloud Native Computing Foundation (CNCF).

Docker runs containers on *one* machine. Production systems need more than that:

- run several copies of each service, spread across several machines
- restart or replace containers that crash or stop responding
- replace a whole machine's workload when the machine dies
- roll out a new version without downtime, and roll back if it is bad
- give services stable names and load-balance traffic between their copies
- scale up and down with demand
- supply configuration, secrets and storage

Kubernetes does all of this. You describe the **desired state** in YAML ("3 copies of `visits-api:1.0`, each with 128Mi of memory, only receiving traffic when `/health/ready` passes"). Kubernetes then runs **control loops** that continually compare the actual state with the desired state and correct any difference.

```
   You:  kubectl apply -f api.yaml        "I want 3 api pods"
                    │
                    ▼
   ┌────────────────────────────────┐
   │   desired state (stored)       │◀──────────┐
   └───────────────┬────────────────┘           │
                   │ compare                    │  observe
                   ▼                            │
   ┌────────────────────────────────┐   ┌───────┴────────┐
   │ controller: 2 running, want 3  ├──▶│ start 1 more   │   ...forever
   └────────────────────────────────┘   └────────────────┘
```

This **declarative** model is the most important idea in Kubernetes. You do not tell it "start a container". You tell it what should exist, and it works out how to get there and how to keep it that way.

### Architecture

```
 ┌──────────────────────── Control plane ─────────────────────────┐
 │  API server ── the front door; kubectl and everything else      │
 │                talk to it                                       │
 │  etcd ──────── key-value store holding the desired + actual     │
 │                state                                            │
 │  scheduler ─── decides which node each new pod runs on          │
 │  controller ── the reconciliation loops (Deployments,           │
 │    manager     ReplicaSets, Nodes, ...)                         │
 └─────────────────────────────┬───────────────────────────────────┘
                               │
        ┌──────────────────────┼──────────────────────┐
        ▼                      ▼                      ▼
 ┌─── Node 1 ────┐      ┌─── Node 2 ────┐      ┌─── Node 3 ────┐
 │ kubelet       │      │ kubelet       │      │ kubelet       │
 │ kube-proxy    │      │ kube-proxy    │      │ kube-proxy    │
 │ containerd    │      │ containerd    │      │ containerd    │
 │ [pod] [pod]   │      │ [pod] [pod]   │      │ [pod]         │
 └───────────────┘      └───────────────┘      └───────────────┘
```

- **Control plane:** the "brain". On a managed service such as **Azure Kubernetes Service (AKS)**, Azure runs and patches the control plane for you, and you only manage the worker nodes and workloads.
- **Nodes:** the VMs that actually run containers. On each node:
  - the **kubelet** makes sure the pods assigned to the node are running and runs their health probes
  - **kube-proxy** (or a CNI such as Cilium) implements Service networking
  - a **container runtime** (usually containerd) pulls images and starts containers

### Core objects

| Object | What it is | Compose equivalent |
|---|---|---|
| **Pod** | The smallest deployable unit: one or more containers that share a network address and storage. Pods are disposable and are replaced rather than repaired. | a container |
| **Deployment** | Manages a set of identical pods: the replica count, rolling updates and rollback. Creates **ReplicaSets** under the hood. | a service with `--scale` |
| **Service** | A stable DNS name and virtual IP that load-balances across the pods matching a label selector. | service name on the Compose network |
| **ConfigMap** / **Secret** | Configuration and sensitive values, injected as environment variables or files. | `environment:` / `env_file:` |
| **PersistentVolumeClaim** | A request for storage. The cluster provisions a disk to satisfy it. | named volume |
| **Namespace** | A logical partition of the cluster for grouping, access control and quotas. | a Compose project |
| **Ingress** / **Gateway** | HTTP routing from outside the cluster (host and path rules, TLS). | a reverse proxy container |
| **HorizontalPodAutoscaler** | Scales a Deployment's replica count based on CPU, memory or custom metrics. | – |
| **StatefulSet** | Like a Deployment, but pods have stable identities and their own disks. Used for databases. | – |
| **DaemonSet** / **Job** / **CronJob** | One pod per node (agents) / run to completion / run on a schedule. | – |

Every object is identified by `apiVersion`, `kind`, `metadata.name`, and usually a `spec` (desired state). Kubernetes adds a `status` (actual state).

---

## 2. How Kubernetes relates to containers and registries

Kubernetes **does not build images** and **does not store images**. It runs images that already exist in a registry:

```
 Developer / CI pipeline                Registry                  Kubernetes cluster
 ───────────────────────          ────────────────────          ──────────────────────────────
 docker build -t ...api:1.4  ──▶   myregistry.azurecr.io   ◀──  kubelet on each node asks the
 docker push ...api:1.4            /visits-api:1.4               container runtime to pull the
                                                                 image named in the pod spec,
 kubectl apply (or a pipeline) ───────────────────────────────▶ then starts the container
 with  image: ...api:1.4
```

- **Images are the contract.** The Dockerfiles from [Containerization.md](Containerization.md) are used unchanged. Any OCI image runs on Kubernetes, whether it was built with Docker, Podman, BuildKit or `az acr build`.
- **Docker is not required in the cluster.** Since Kubernetes 1.24, nodes talk to runtimes such as **containerd** or **CRI-O** through the Container Runtime Interface (CRI). Images built with Docker still run, because they are standard OCI images.
- **Pulling from a private registry:**
  - **AKS + ACR:** `az aks update --attach-acr myregistry` grants the cluster's managed identity the `AcrPull` role. No secrets are involved, and this is the recommended approach.
  - **Other registries (GHCR, Docker Hub private repos):** create a `docker-registry` Secret and reference it with `imagePullSecrets` in the pod spec.
- **Tags vs digests matter more here.** If a Deployment uses a mutable tag such as `latest`, different nodes can end up running different images. Deploy unique tags (build ID or Git SHA) or digests.
- **`imagePullPolicy`.** `IfNotPresent` uses a cached image if the node has one. `Always` checks the registry every time a pod starts, and is the default for `:latest`.
- **Registry availability is now a production dependency.** A new pod cannot start if its image cannot be pulled. Keep the registry in the same region as the cluster, or geo-replicated with ACR Premium.

---

## 3. The sample on Kubernetes

The Compose application from [Containerization.md](Containerization.md) maps directly onto Kubernetes objects:

```
                   LoadBalancer Service "web"  (localhost:8000 / public IP on AKS)
                                │
                  ┌─────────────┴─────────────┐
                  ▼                           ▼
            [web pod] [web pod]      ← Deployment "web", 2 replicas, nginx config from a ConfigMap
                  │ proxy_pass http://api:8080
                  ▼
           ClusterIP Service "api"   ← stable virtual IP, load-balances across ready pods
         ┌────────┼────────┐
         ▼        ▼        ▼
     [api pod] [api pod] [api pod]   ← Deployment "api", 3 replicas, .NET or Node image
                  │ redis:6379
                  ▼
           ClusterIP Service "redis"
                  │
             [redis pod] ── PersistentVolumeClaim "redis-data" (1Gi disk)
```

### Files

```
samples/containerization/k8s/
├── base/                   # the application, using the .NET api image
│   ├── kustomization.yaml  # lists the files + sets the namespace
│   ├── namespace.yaml
│   ├── redis.yaml          # PVC + Deployment + Service
│   ├── api.yaml            # Deployment + Service
│   └── web.yaml            # ConfigMap + Deployment + LoadBalancer Service
└── node/
    └── kustomization.yaml  # overlay: same app, TypeScript/Node api image instead
```

### api.yaml

[api.yaml](samples/containerization/k8s/base/api.yaml) is the most instructive file:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
spec:
  replicas: 3
  selector:
    matchLabels:
      app: api
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0      # never drop below 3 ready pods during a deployment
      maxSurge: 1
  template:
    metadata:
      labels:
        app: api
    spec:
      securityContext:
        runAsNonRoot: true   # refuse to start if the image would run as root
      containers:
        - name: api
          # Built locally - in a real cluster this would be e.g. myregistry.azurecr.io/visits-api:1.0
          image: visits-api:1.0
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
          env:
            - name: ConnectionStrings__Redis
              value: "redis:6379,abortConnect=false"
          # Gives the app time to start before liveness checks begin
          startupProbe:
            httpGet:
              path: /health
              port: 8080
            periodSeconds: 2
            failureThreshold: 15
          # Failing -> pod is removed from the Service (no traffic), but NOT restarted
          readinessProbe:
            httpGet:
              path: /health/ready
              port: 8080
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 2
          # Failing -> container is killed and restarted
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            periodSeconds: 10
            failureThreshold: 3
          # Keep serving for a few seconds after termination starts, while the pod is
          # removed from the Service endpoints - avoids dropped requests during rollouts
          lifecycle:
            preStop:
              sleep:
                seconds: 5
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: api
spec:
  selector:
    app: api
  ports:
    - port: 8080
      targetPort: 8080
```

Points to notice:

- **Labels connect everything.** The Deployment creates pods labelled `app: api`. The Service's `selector: app: api` finds them, whichever node they are on and however often they are replaced.
- **`maxUnavailable: 0`, `maxSurge: 1`.** During a rollout Kubernetes starts one new pod, waits for it to become *ready*, then removes one old pod, and repeats. Capacity never drops below 3. If the new version never becomes ready, the rollout stalls and the old pods keep serving.
- **`resources`.**
  - `requests` is what the scheduler reserves on a node, so pods are placed where they fit.
  - The memory `limit` means a leaking container is killed (OOMKilled) rather than starving its neighbours.
  - There is deliberately no CPU limit. CPU limits cause throttling and latency spikes, and requests already guarantee each pod its share.
- **`runAsNonRoot`.** This works because both Dockerfiles set a *numeric* non-root `USER`. Kubernetes cannot verify a user name such as `node`.
- **No `ports` to the outside.** As in Compose, only `web` is exposed.

### Configuration: the nginx ConfigMap

[web.yaml](samples/containerization/k8s/base/web.yaml) **mounts a ConfigMap over the image's nginx config**. The Compose version relied on Docker's embedded DNS server (`resolver 127.0.0.11`) to spread load across scaled API containers. Kubernetes does not need that: the `api` Service has one stable virtual IP, and kube-proxy load-balances behind it. The image stays the same, and the platform-specific configuration is supplied by the platform:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: web-nginx
data:
  default.conf: |
    server {
        listen 80;
        location / {
            root  /usr/share/nginx/html;
            index index.html;
        }
        location /api/ {
            proxy_pass http://api:8080;
        }
    }
```

```yaml
          volumeMounts:
            - name: nginx-config
              mountPath: /etc/nginx/conf.d
      ...
      volumes:
        - name: nginx-config
          configMap:
            name: web-nginx
```

### Storage: Redis

[redis.yaml](samples/containerization/k8s/base/redis.yaml) uses a **PersistentVolumeClaim** for the data, with an `exec` probe (`redis-cli ping`). Its Deployment uses `strategy: Recreate` because a `ReadWriteOnce` disk can only be attached to one pod at a time. A single-replica Redis is fine for a demo. In production you would use a managed service (Azure Cache for Redis), or a StatefulSet or operator with replication.

### Swapping in the TypeScript / Node API with Kustomize

**Kustomize** is built into `kubectl` (`-k`). It builds variants of a set of manifests without copying them. The [node overlay](samples/containerization/k8s/node/kustomization.yaml) takes the base, replaces the API image, and adds the environment variable the Node app reads:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../base
images:
  - name: visits-api
    newName: visits-api-node
    newTag: "1.0"
patches:
  - target:
      kind: Deployment
      name: api
    patch: |-
      - op: add
        path: /spec/template/spec/containers/0/env/-
        value:
          name: REDIS_URL
          value: redis://redis:6379
```

The same mechanism is normally used for **environments**, for example `overlays/dev`, `overlays/prod` with different replica counts, image tags and resource sizes. **Helm** is the main alternative. It is a templating and package tool, better suited to distributing reusable charts, but more complex. See [Helm.md](Helm.md), which converts these manifests into a chart.

---

## 4. Running it

### Locally on Docker Desktop

Enable Kubernetes in Docker Desktop's settings. Its cluster shares the Docker engine's image store, so locally built images can be used without a registry.

```bash
cd samples/containerization

kubectl config use-context docker-desktop        # make sure you are NOT pointing at a real cluster

docker build -t visits-api:1.0 ./api
docker build -t visits-web:1.0 ./web
kubectl apply -k k8s/base

kubectl -n visits rollout status deploy/api      # wait until all replicas are ready
kubectl -n visits get pods,svc,pvc

curl http://localhost:8000/api/visits
# {"visits":1,"servedBy":"api-7c84644cb7-vwbp9"}   ← pod names, spread across replicas
```

To run the TypeScript/Node API instead, build its image and apply the overlay. Kubernetes performs a rolling update from the .NET pods to the Node pods:

```bash
docker build -t visits-api-node:1.0 ./api-node
kubectl apply -k k8s/node
kubectl -n visits rollout status deploy/api
```

Useful commands:

```bash
kubectl -n visits get pods -o wide              # which node each pod is on
kubectl -n visits describe pod <name>           # events: scheduling, pulls, probe failures
kubectl -n visits logs -f deploy/api            # logs (from one pod of the deployment)
kubectl -n visits exec -it deploy/redis -- redis-cli get visits
kubectl -n visits port-forward svc/api 8080:8080   # reach an internal service from your machine
kubectl -n visits scale deploy/api --replicas=5
kubectl -n visits rollout undo deploy/api       # roll back to the previous version
kubectl delete -k k8s/base                      # remove everything, including the namespace
```

### On AKS

The manifests are the same. Only the image location changes:

```bash
az acr build -r myregistry -t visits-api:1.0 ./api
az acr build -r myregistry -t visits-web:1.0 ./web
az aks update -g my-rg -n my-aks --attach-acr myregistry
az aks get-credentials -g my-rg -n my-aks
```

Then, in an overlay (`images: newName: myregistry.azurecr.io/visits-api`), point the images at the registry and apply. The `web` Service of type `LoadBalancer` gets a public Azure IP. For real HTTP traffic you would put an **Ingress** or **Gateway** with TLS in front instead, for example the AKS application routing add-on or Application Gateway for Containers.

---

## 5. Health checks

Health checks are how Kubernetes delivers its promise of self-healing, zero-downtime operation. Without them, Kubernetes only knows whether a *process* is running, not whether it *works*.

### The three probes

| Probe | Question it answers | When it fails | Typical endpoint |
|---|---|---|---|
| **startupProbe** | "Has the app finished starting?" | Keeps checking up to `failureThreshold × periodSeconds` (30s here), then restarts the container. Liveness and readiness checks do not run until it passes. | `/health` |
| **readinessProbe** | "Should this pod receive traffic *right now*?" | The pod is **removed from the Service's endpoints**. It keeps running and is **not restarted**. It rejoins automatically when the probe passes. | `/health/ready`, which checks dependencies |
| **livenessProbe** | "Is this process broken beyond recovery?" | The container is **killed and restarted**. | `/health`, with no dependency checks |

Probes can be `httpGet` (2xx/3xx is a pass), `tcpSocket`, `exec` (exit code 0 is a pass, as for Redis) or `grpc`.

### Why the API has two endpoints

Both API implementations expose a **liveness** endpoint with no dependencies and a **readiness** endpoint that checks Redis.

In .NET ([Program.cs](samples/containerization/api/Program.cs)):

```csharp
// Liveness: is the process able to serve requests at all? Deliberately has no dependencies.
app.MapGet("/health", () => Results.Ok("healthy"));

// Readiness: can this instance do useful work right now? Checks its dependency (Redis).
app.MapGet("/health/ready", async (IConnectionMultiplexer redis) =>
{
    try
    {
        await redis.GetDatabase().PingAsync();
        return Results.Ok("ready");
    }
    catch (RedisException)
    {
        return Results.StatusCode(StatusCodes.Status503ServiceUnavailable);
    }
});
```

In TypeScript ([server.ts](samples/containerization/api-node/src/server.ts)):

```typescript
// Liveness: is the process able to serve requests at all? Deliberately has no dependencies.
app.get("/health", (_req, res) => {
  res.json("healthy");
});

// Readiness: can this instance do useful work right now? Checks its dependency (Redis).
app.get("/health/ready", async (_req, res) => {
  try {
    await redis.ping();
    res.json("ready");
  } catch {
    res.sendStatus(503);
  }
});
```

> In a real .NET service, use the built-in `AddHealthChecks()` / `MapHealthChecks()` with tags to separate live and ready checks. In Node, libraries such as `@godaddy/terminus` or `lightship` provide the same structure. The hand-written versions above keep the idea visible.

**Never put dependency checks in the liveness probe.** If Redis goes down and liveness checks Redis, Kubernetes restarts every API pod. That does not fix Redis. It just turns a dependency outage into a restart storm. When Redis comes back, every pod is cold-starting at once. Readiness is the right signal: "do not send me traffic", not "kill me".

This was tested on the sample by stopping Redis:

```
$ kubectl -n visits scale deploy/redis --replicas=0
$ kubectl -n visits get pods -l app=api
NAME                   READY   STATUS    RESTARTS   AGE
api-7c84644cb7-8x6c4   0/1     Running   0          29s    ← not ready: no traffic
api-7c84644cb7-s72vc   0/1     Running   0          29s       but NOT restarted
api-7c84644cb7-vwbp9   0/1     Running   0          29s

$ kubectl -n visits scale deploy/redis --replicas=1
$ kubectl -n visits get pods -l app=api
NAME                   READY   STATUS    RESTARTS   AGE
api-7c84644cb7-8x6c4   1/1     Running   0          45s    ← ready again automatically
...
$ curl http://localhost:8000/api/visits
{"visits":7,"servedBy":"api-7c84644cb7-s72vc"}            ← count survived on the PVC
```

The pods marked themselves unready, nothing restarted, and they recovered on their own once Redis was back. Deleting a pod (`kubectl delete pod ...`) showed the other half of self-healing: the Deployment replaced it within seconds.

### Readiness for an app's own state

Readiness should also fail while an instance cannot serve, for example while it is warming a cache, running migrations or shedding load. A common refinement is to fail readiness immediately on SIGTERM, before shutting down.

### Graceful shutdown: the other half of zero downtime

When a pod is deleted (rollout, scale-down, node drain), two things happen **in parallel**:

1. the container receives SIGTERM
2. the pod is removed from Service endpoints, and that change propagates to every node's kube-proxy and to any ingress

If the app exits before step 2 finishes, a few requests are still routed to a pod that no longer exists. The sample showed this. Rolling the API while sending 400 requests produced:

| Rollout under load | Results |
|---|---|
| Without `preStop` | 398 × 200, **1 × 502, 1 × 504** |
| With `preStop: sleep: 5` | **400 × 200** (and the same for a `web` rollout) |

The `preStop` hook delays SIGTERM by 5 seconds, so traffic drains away first. The native `sleep` action (Kubernetes 1.30+) does not even need a `sleep` binary in the image. After that, the app has to handle SIGTERM properly and finish in-flight requests:

- **.NET** does this automatically. The generic host stops Kestrel gracefully on SIGTERM.
- **Node** does *not*, when it runs as PID 1. That is why [server.ts](samples/containerization/api-node/src/server.ts) handles it explicitly:

```typescript
process.on("SIGTERM", () => {
  console.log("SIGTERM received, shutting down");
  server.close(() => {
    redis.disconnect();
    process.exit(0);
  });
});
```

If the app has not exited after `terminationGracePeriodSeconds` (default 30s, *including* the preStop time), it is killed with SIGKILL.

### Probe tuning checklist

- Use a **startupProbe** for slow starters, rather than a long `initialDelaySeconds` on liveness.
- Keep probes **cheap and fast**. They run every few seconds on every pod.
- Set `timeoutSeconds` deliberately. The default of 1s can fail under GC pauses or CPU pressure.
- Liveness should be **less sensitive** than readiness (higher `failureThreshold`), so a busy pod is taken out of rotation before it is killed.
- Do not expose health endpoints publicly with sensitive detail. nginx in the sample only forwards `/api/`.

---

## 6. Scaling

Manual scaling is just a field in the Deployment's spec:

```bash
kubectl -n visits scale deploy/api --replicas=5
```

A **HorizontalPodAutoscaler** adjusts the replica count automatically. It needs the metrics-server, which AKS includes but Docker Desktop does not by default. Utilisation is measured against the pod's CPU **request**, which is another reason to set requests accurately:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: api
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api
  minReplicas: 3
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

Related tools:

- **KEDA** scales on events such as queue length or Service Bus messages, including scaling to zero.
- The **cluster autoscaler** (on AKS) adds and removes *nodes* when pods cannot be scheduled.
- A **PodDisruptionBudget** keeps a minimum number of pods running during voluntary disruptions such as node upgrades.
- **Topology spread constraints** spread replicas across nodes and availability zones.

---

## 7. Trade-offs: orchestration approaches

Kubernetes is powerful, but it is not free. Someone has to understand networking, RBAC, upgrades, observability and security for the cluster *and* for everything running on it. The question is not "is Kubernetes good?", but "what is the least complex platform that meets the requirements?".

### The options

| Approach | Examples | You manage | Strengths | Weaknesses | Good fit |
|---|---|---|---|---|---|
| **Single host + Compose** | `docker compose` on a VM | Everything | Simple, fast to set up, the same file as local development | One machine: no failover, manual scaling, no rolling updates | Local development, CI integration tests, small internal tools |
| **PaaS for containers** | Azure App Service (containers), AWS App Runner | Image + app settings | Very low ops. Deployment slots, autoscale, TLS, auth built in. Familiar to App Service teams. | One container per app (sidecars limited). Less control over networking and scaling. | Web apps and APIs, especially a small number of them |
| **Serverless containers** | **Azure Container Apps**, Google Cloud Run, AWS Fargate | Image + scaling rules | Scale to zero, KEDA-based event scaling, revisions and traffic splitting, Dapr, no cluster to run. Container Apps runs on Kubernetes under the hood. | No direct Kubernetes API. Fewer knobs. Cold starts on scale-from-zero. Per-request pricing can cost more at high steady load. | Microservices, event-driven workers, APIs with variable load. **Often the best default on Azure.** |
| **Simple container instances** | Azure Container Instances | Each container group | Seconds to start, per-second billing, no cluster | No built-in scaling, load balancing or rolling updates | Batch jobs, build agents, burst capacity |
| **Managed Kubernetes** | **AKS**, EKS, GKE | Nodes, workloads, add-ons, upgrades | Full Kubernetes API and ecosystem (Helm, operators, service mesh, GitOps). Portable across clouds. Fine-grained control. | Significant learning curve and operational load. Must keep up with Kubernetes versions (roughly 3 minor releases a year). Easy to misconfigure security. | Many services, platform teams, complex networking or scheduling, multi-cloud or hybrid, special workloads (GPU, stateful operators) |
| **Self-managed Kubernetes** | kubeadm, k3s, OpenShift (on-prem) | Also the control plane, etcd and backups | Runs anywhere, including on-premises and at the edge | Highest effort. You are responsible for control plane availability and upgrades. | Regulatory or on-premises requirements, edge devices (k3s) |
| **Other orchestrators** | AWS ECS, HashiCorp Nomad, Docker Swarm | Varies | ECS: simpler than Kubernetes and deeply AWS-integrated. Nomad: simple, and runs non-container workloads too. | Smaller ecosystems. Swarm is effectively in maintenance mode. | Teams already invested in that ecosystem |

### A rough decision guide (Azure)

```
 One or a few web apps/APIs, team knows App Service?
        └── yes ─▶ App Service for Containers (slots, autoscale, health check built in)

 Several microservices / background workers, event-driven or spiky load,
 no dedicated platform team?
        └── yes ─▶ Azure Container Apps

 Need the Kubernetes API itself: operators, Helm charts from vendors, service mesh,
 custom scheduling, GPUs, many teams sharing a platform, or portability?
        └── yes ─▶ AKS (with a team that owns the platform)

 Short-lived job or burst task?
        └── yes ─▶ Container Apps Jobs or Azure Container Instances
```

**The image is portable across all of them.** The same `visits-api` image runs on Compose, App Service, Container Apps and AKS. Starting on a simpler platform and moving to Kubernetes later is a reasonable path, and the reverse is common too. Investing in good images (health endpoints, configuration from environment variables, graceful shutdown, non-root user) pays off on every platform.

### Things that are easy to underestimate with Kubernetes

- **Upgrades.** Kubernetes versions go out of support after roughly a year, so cluster and node upgrades are recurring work. Removed APIs can break manifests.
- **Security.** RBAC, network policies, pod security standards, secret management (e.g. Azure Key Vault CSI driver plus workload identity) and image scanning are all your responsibility.
- **Observability.** Logs, metrics and traces have to be collected deliberately, e.g. with Azure Monitor / Container Insights, Prometheus or OpenTelemetry.
- **Cost.** Nodes cost money whether or not pods use them. Right-sizing requests and node pools is ongoing work.
- **Stateful workloads.** Running databases in Kubernetes is possible but hard. Prefer managed databases and caches.

---

## 8. Trade-offs: runtime choices

"Runtime" covers several layers, each with its own trade-offs.

### Container runtime (what actually runs containers on a node)

| Runtime | Notes |
|---|---|
| **containerd** | The default on AKS, EKS, GKE and Docker Desktop's engine. Mature, lightweight, CRI-native. |
| **CRI-O** | A minimal CRI runtime built for Kubernetes. The default on OpenShift. |
| **Docker Engine** | Developer tooling. No longer used directly by Kubernetes nodes since 1.24 (dockershim removed). |
| **runc / crun** | The low-level OCI runtimes the above use to create the container process. crun is faster and smaller. |
| **Sandboxed: gVisor, Kata Containers** | Stronger isolation (a user-space kernel or a lightweight VM per pod) at the cost of some performance and compatibility. On AKS, *Pod Sandboxing* uses Kata. Use for untrusted or multi-tenant code. |

For most teams this choice is made by the platform. The main decision is whether some workloads need **sandboxed isolation**, because standard containers share the node's kernel.

### Operating system

- **Linux containers** are the norm: smaller, faster to start, and broadly supported.
- **Windows containers** are needed only for .NET Framework or other Windows-only dependencies. Images are much larger, the image's OS version must match the host's, and support on serverless platforms is limited. Modern .NET runs on Linux, so prefer migrating to that.
- **CPU architecture:** arm64 nodes (e.g. Azure Cobalt or Ampere VMs, AWS Graviton) are often cheaper for the same performance. Use multi-platform images (`docker buildx build --platform linux/amd64,linux/arm64`) so the same tag works on both.

### Base images

| Base image style | Example | Trade-off |
|---|---|---|
| Full distribution | `node:24`, `dotnet/aspnet:10.0` (Debian) | Most compatible and includes debugging tools, but larger and with more CVEs to patch |
| Slim | `node:24-slim` | Smaller Debian with glibc. A good default for Node. |
| Alpine | `node:24-alpine`, `nginx:1.27-alpine` | Very small. musl libc can break native modules and change DNS or performance behaviour. |
| Distroless / chiseled | `gcr.io/distroless/nodejs24-debian12`, `dotnet/aspnet:10.0-noble-chiseled` | No shell or package manager: minimal attack surface, non-root by default. Harder to debug (use `kubectl debug` with an ephemeral container). |

### Language runtime: .NET vs Node in containers

The sample shows both behind the same contract. Things to weigh for container workloads:

| | .NET (ASP.NET Core) | Node.js (TypeScript) |
|---|---|---|
| Concurrency model | Multi-threaded. One pod uses several cores well. | Single-threaded event loop. Usually scale out with more pods (request around 1 CPU or less each), not with bigger ones. |
| Startup time | Fast. Native AOT gives very fast startup and small images, with some library restrictions. | Fast. Good for scale-to-zero. |
| Memory | The GC adapts to the container's memory limit automatically. | The V8 heap limit is derived from the container memory. Tune with `--max-old-space-size` if needed. |
| Graceful shutdown | Built into the generic host. | Must handle SIGTERM yourself (see above). |
| Image size (sample) | Runtime image of around 230 MB (chiseled or AOT can be far smaller) | Around 180 MB on Alpine, including `node_modules` |
| Health checks | `AddHealthChecks()` built in | A library or hand-written |

Neither is "right". The point is that the orchestrator does not care. The trade-offs are in how each runtime behaves under limits, scaling and shutdown, so the probes, resources and replica counts should be tuned to match.

---

## 9. Where to go next

1. Run the sample locally: `kubectl apply -k k8s/base`, then break things. Stop Redis, delete pods, roll out the Node overlay while running a curl loop, and watch `kubectl get pods -w`.
2. Add the HPA and a PodDisruptionBudget, and load-test with a tool such as k6 or `hey` on an AKS dev cluster.
3. Replace the in-cluster Redis with Azure Cache for Redis, with the connection string held in a Secret (or in Key Vault via the CSI driver).
4. Deploy the same images to **Azure Container Apps**, then write a short comparison with AKS covering effort, cost, scaling behaviour and control. A comparison like that is good evidence for the "explain trade-offs" competency.
5. Put the manifests in an Azure Pipeline that builds, pushes to ACR, and deploys to AKS through an environment with an approval gate (Gap task G1 in [README.md](README.md)).
