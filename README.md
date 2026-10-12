# Senior Engineer Pack

This document is intended to help a software engineer identify practical, hands-on opportunities to demonstrate senior-level capability in:

- containerization and orchestration
- platform-as-a-service (PaaS) design and delivery
- cloud architecture and resiliency patterns
- infrastructure as code, scaling and high availability (the main gap identified in section 2)
- practical evidence that can later be used for promotion discussions

---

## 1. What a senior software engineer needs to show

The competency focus in the following evidence areas:

### A. Containerization and orchestration
A software engineer should be able to show they can:
- build container images consistently and safely
- run applications locally with Docker Compose
- deploy into Kubernetes or a managed Kubernetes-like environment
- configure health checks, ingress, scaling, secrets, and environment config
- explain trade-offs between container orchestration approaches and runtime choices

### B. PaaS experience
A software engineer should be able to show they can:
- design and deliver solutions using a modern managed platform
- use managed services instead of operating infrastructure directly
- choose between Azure App Service, Azure Container Apps, Azure Functions, Azure Kubernetes Service, managed databases, caches, messaging, etc.
- design end-to-end solution architecture with platform constraints in mind

### C. Cloud design patterns
A software engineer should be able to show they can apply patterns such as:
- strangler fig
- circuit breaker
- cache-aside
- retry and timeout
- throttling and rate limiting
- sidecar
- sharding
- event sourcing

They should also be able to explain when not to use certain patterns and what risks they introduce.

Each pattern is explained, with examples based on the containerization sample, in [patterns/](patterns/README.md).

---

## 2. Identified gap: infrastructure, scaling and high availability

Reviewing an engineer's pull request history against these areas often shows a clear split between what is already evidenced and what is missing. A typical example:

### Already evidenced
- repeatable, rollback-safe database deployments
- repeatable, rollback-safe application deployments
- zero-downtime rollout strategies

### Not yet evidenced
- authoring Azure Pipelines YAML (build, release, environments, approvals)
- infrastructure as code (Bicep, Terraform or ARM)
- Docker images and container build pipelines
- App Service configuration: deployment slots, autoscaling, health checks
- high availability: redundancy, failover, recovery objectives
- scaling behaviour under load

The existing deployment work is a good base. The gap is mostly that it stops at the application layer and does not reach the platform underneath it. The tasks below are chosen to extend that existing work, not start from nothing.

### Gap task G1: Own the next pipeline change
Objective:
Become the author, not just a consumer, of the pipeline YAML.

Steps:
1. Read commits retrospectively and write down how the pipeline is structured, what each stage does, and anything that could be improved.
2. Ask to pair with another software engineer on the next pipeline change, then take the lead on the one after that.
3. Good candidate changes: extract reusable stage/job templates, add an `environment` with approval checks, add a deploy-to-slot stage, publish test and coverage results, add a PR validation run for infrastructure changes.

Evidence:
- PRs authored in the pipeline repository
- review comments on other people's pipeline PRs (start reviewing them from now on)
- a short note on the pipeline design and why it is structured that way

### Gap task G2: Define the App Service estate as Bicep
Objective:
Move one service's hosting from portal or manual setup to infrastructure as code.

Scope:
- App Service plan and web app
- `staging` deployment slot with slot-specific settings
- health check path configured on the app
- autoscale settings (CPU/HTTP queue rules, minimum instance count of 2 or more)
- app settings sourced from Key Vault references
- the pipeline runs `what-if` on PRs and `deploy` on merge

Example skeleton:

```bicep
resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: 'asp-${appName}-${env}'
  location: location
  sku: { name: 'P1v3', capacity: 2 }
  properties: { zoneRedundant: true }
}

resource app 'Microsoft.Web/sites@2023-12-01' = {
  name: 'app-${appName}-${env}'
  location: location
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      healthCheckPath: '/health'
      alwaysOn: true
    }
  }
}

resource staging 'Microsoft.Web/sites/slots@2023-12-01' = {
  parent: app
  name: 'staging'
  location: location
  properties: { serverFarmId: plan.id }
}

resource autoscale 'Microsoft.Insights/autoscalesettings@2022-10-01' = {
  name: 'autoscale-${appName}-${env}'
  location: location
  properties: {
    enabled: true
    targetResourceUri: plan.id
    profiles: [
      {
        name: 'default'
        capacity: { minimum: '2', maximum: '6', default: '2' }
        rules: [
          {
            metricTrigger: {
              metricName: 'CpuPercentage'
              metricResourceUri: plan.id
              timeGrain: 'PT1M'
              statistic: 'Average'
              timeWindow: 'PT5M'
              timeAggregation: 'Average'
              operator: 'GreaterThan'
              threshold: 70
            }
            scaleAction: { direction: 'Increase', type: 'ChangeCount', value: '1', cooldown: 'PT5M' }
          }
          {
            metricTrigger: {
              metricName: 'CpuPercentage'
              metricResourceUri: plan.id
              timeGrain: 'PT1M'
              statistic: 'Average'
              timeWindow: 'PT10M'
              timeAggregation: 'Average'
              operator: 'LessThan'
              threshold: 30
            }
            scaleAction: { direction: 'Decrease', type: 'ChangeCount', value: '1', cooldown: 'PT10M' }
          }
        ]
      }
    ]
  }
}
```

Evidence:
- Bicep PR plus the pipeline PR that deploys it
- `what-if` output from a PR run
- ADR: why Bicep (or Terraform), how environments are parameterised, how drift is handled

### Gap task G3: Health-gated slot swap with automatic rollback
Objective:
Extend the existing zero-downtime work down to the platform layer.

Steps:
1. Deploy to the `staging` slot.
2. Warm up and smoke-test the slot (health endpoint plus a few key requests).
3. Swap only if the checks pass.
4. Monitor errors and latency after the swap, and swap back automatically if thresholds are breached.

Evidence:
- pipeline YAML for the deploy/swap/verify stages
- a recorded run showing a failed deployment being caught before swap, or rolled back after it
- runbook for manual rollback

### Gap task G4: Prove the autoscaling works under load
Objective:
Show scaling behaviour with data, not just configuration.

Steps:
1. Write a load test (Azure Load Testing, k6 or JMeter) for a realistic endpoint mix.
2. Run it against a non-production environment with the G2 autoscale rules.
3. Record when instances scale out and back in, and how latency and error rate behave while that happens.
4. Tune thresholds, cooldowns and minimum instances, and write up the results.

Evidence:
- load test script in source control
- before/after charts of instance count, p95 latency and errors
- a short scaling report with recommendations

### Gap task G5: High availability review and failure drill
Objective:
Demonstrate HA thinking for one production service end to end.

Steps:
1. Agree RTO and RPO targets for the service with the team.
2. Assess the current single points of failure: single instance, single zone, single region, database, cache, secrets, DNS.
3. Propose changes with cost and risk trade-offs, e.g. zone-redundant plan, minimum 2 instances, SQL auto-failover group, Front Door or Traffic Manager for regional failover.
4. Implement at least one change via the G2 Bicep.
5. Run a controlled failure drill in non-production (stop an instance, fail over the database, use Azure Chaos Studio if available) and measure actual recovery against the targets.

Evidence:
- HA assessment document / ADR
- drill results compared with RTO/RPO
- updated runbook

### Gap task G6: Release and incident duty
Objective:
Get operational evidence that does not come from writing code.

Ideas:
- act as release owner for a number of production deployments
- join the on-call or incident rota, or shadow it
- lead or write the post-incident review for a deployment-related issue

Evidence:
- release notes and checklists a software engineer owned
- post-incident reviews authored

### Evidence from outside ADO
Not all relevant work shows up in pull requests. Before the promotion review, a software engineer should list from memory any of the following, with date, system and outcome:
- release-pipeline or classic release changes made in the ADO UI rather than in YAML
- environments, app services, databases or Key Vaults set up or reconfigured by hand
- scaling or performance changes made in response to load
- incidents handled during or after a deployment, including rollbacks
- any failover, restore or disaster-recovery exercise

Even small items are useful because they show the work already started and the gap tasks continue it.

### Suggested order
1. G1 (start reviewing pipeline PRs immediately, it costs nothing)
2. G2, then G3 (Bicep for the App Service, then health-gated slot swaps on top of it)
3. G4 (load test the autoscale rules from G2)
4. G5 (HA review and drill)
5. G6 alongside the others, as opportunities come up

Taken together, G1 to G5 cover all six gap items and link directly to the existing deployment evidence.

---

## 3. Good task ideas that create evidence

The best evidence is not just learning theory; it is shipping small but meaningful cloud-focused tasks with real-world constraints.

### Task idea 1: Containerize an existing application

Objective:
Create a production-ready Docker build and local runtime setup for an application that is currently running directly on a host or using a manual startup script.

Example outcome:
- Dockerfile created
- multi-stage build used where appropriate
- non-root user configuration
- health checks added
- environment variables externalized
- Docker Compose file for local dependencies

Evidence to collect:
- Git diff showing container setup
- screenshot or notes of app running in Docker
- architecture notes explaining why the container approach was chosen

Sample steps:
1. Identify application entry point and build requirements.
2. Create a Dockerfile.
3. Add .dockerignore.
4. Add health check endpoint or a simple startup verification.
5. Run locally with Docker Compose.
6. Document startup, configuration, and troubleshooting steps.

Example Dockerfile pattern:

```dockerfile
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src
COPY . .
RUN dotnet restore
RUN dotnet publish -c Release -o /app/publish

FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS final
WORKDIR /app
COPY --from=build /app/publish .
EXPOSE 8080
ENV ASPNETCORE_URLS=http://+:8080
ENTRYPOINT ["dotnet", "MyApp.dll"]
```

Example Compose setup:

```yaml
services:
  api:
    build: .
    ports:
      - "8080:8080"
    environment:
      ASPNETCORE_ENVIRONMENT: Development
      ConnectionStrings__Default: "Server=db;Database=app;User Id=sa;Password=YourStrong!Passw0rd;"
    depends_on:
      - db

  db:
    image: mcr.microsoft.com/mssql/server:2022-latest
    environment:
      ACCEPT_EULA: "Y"
      MSSQL_SA_PASSWORD: "YourStrong!Passw0rd"
```

Why this helps:
This demonstrates real expertise in dependency isolation, reproducible builds, and operational readiness.

---

### Task idea 2: Deploy to a managed PaaS platform

Objective:
Take the containerized app and deploy it to a managed cloud runtime such as Azure App Service, Azure Container Apps, or Azure Functions depending on the needs of the app.

Good choices:
- App Service for web apps or API services
- Azure Container Apps for container-based workloads with scaling and sidecars
- Azure Functions for event-driven or serverless workloads
- AKS where orchestration complexity is intentionally needed

Evidence to collect:
- deployment architecture diagram
- infrastructure definition or scripts
- environment variable configuration
- scaling configuration and observability setup

Sample Azure deployment flow:

```bash
az group create --name rg-demo-app --location westeurope
az containerapp env create --name caenv-demo --resource-group rg-demo-app --location westeurope
az containerapp create \
  --name demo-api \
  --resource-group rg-demo-app \
  --environment caenv-demo \
  --image myregistry.azurecr.io/demo-api:latest \
  --target-port 8080 \
  --ingress external
```

This shows:
- working knowledge of cloud resource provisioning
- understanding of deployment topology
- ability to move from local containers to managed services

---

### Task idea 3: Build a resilient cloud application with design patterns

Objective:
Create a small system that intentionally applies multiple cloud patterns and makes the trade-offs visible.

Example architecture:
- API front end
- Redis cache
- database
- queue or event bus
- background worker

Patterns to include:
- cache-aside for read-heavy endpoints
- retry and circuit breaker for dependency access
- rate limiting or throttling at the API edge
- sidecar for logging or telemetry proxying
- event-driven processing for asynchronous jobs
- strangler fig for gradual migration of legacy functionality

Example exercise:
Build an application where:
- the API checks Redis before the database
- outbound calls use retry with exponential backoff
- a failing downstream dependency marks the circuit open temporarily
- a background worker consumes a queue and writes records

Example pseudocode:

```csharp
var retryPolicy = Policy
    .Handle<HttpRequestException>()
    .WaitAndRetryAsync(3, retryAttempt => TimeSpan.FromSeconds(Math.Pow(2, retryAttempt)));

var circuitBreakerPolicy = Policy
    .Handle<HttpRequestException>()
    .CircuitBreakerAsync(2, TimeSpan.FromSeconds(30));

var pipeline = Policy.WrapAsync(retryPolicy, circuitBreakerPolicy);

await pipeline.ExecuteAsync(async () =>
{
    var response = await httpClient.GetAsync("https://downstream-service/api");
    response.EnsureSuccessStatusCode();
});
```

Why this helps:
It turns abstract cloud patterns into a real implementation that can be discussed in an interview or promotion review.

---

### Task idea 4: Add Kubernetes deployment and orchestration evidence

Objective:
Create deployment manifests for an application and demonstrate orchestration concepts.

Focus areas:
- Deployment and ReplicaSet
- Service and Ingress
- ConfigMaps and Secrets
- readiness and liveness probes
- autoscaling
- rolling updates

Example Kubernetes manifest:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-api
spec:
  replicas: 3
  selector:
    matchLabels:
      app: demo-api
  template:
    metadata:
      labels:
        app: demo-api
    spec:
      containers:
        - name: api
          image: myregistry.azurecr.io/demo-api:latest
          ports:
            - containerPort: 8080
          readinessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 10
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 20
          env:
            - name: ASPNETCORE_ENVIRONMENT
              value: Production
```

Suggested deliverables:
- deployment manifest
- service manifest
- ingress or load balancer configuration
- notes on scaling and failure handling

This is especially useful if a software engineer can later say:
> I designed and deployed containerized workloads using Kubernetes primitives, managed runtime constraints, and service resiliency patterns.

---

### Task idea 5: Run a migration or refactor using a strangler fig approach

Objective:
Migrate or replace a legacy component incrementally without a risky big-bang rewrite.

Good scenarios:
- old API service replaced by new service behind the same route
- existing database access moved behind a new abstraction layer
- legacy monolith gradually exposes new endpoints and features via a new service

Evidence:
- architecture decision note
- traffic-routing plan
- dashboard or logs showing cutover steps
- comparison between old and new system behavior

This demonstrates senior thinking because it shows:
- risk management
- incremental delivery
- observability
- operational awareness

---

## 4. Suggested portfolio of evidence a software engineer can build

As a software engineer starts taking on small projects, they can build a reusable evidence set for promotion.

### Evidence pack should include:
- architecture diagram
- short design summary
- screenshots or logs from deployment
- a description of key trade-offs and why a certain cloud pattern was chosen
- notes on security, observability, and operational resilience
- examples of scale and failure scenarios considered

### Good examples of artifacts:
- ADR (Architecture Decision Record)
- deployment notes
- runbook for startup, scaling, rollback, and troubleshooting
- sample GitHub PR with explanation of the design decisions
- diagram showing traffic flow, dependencies, caches, and failure boundaries

---

## 5. Suggested near-future opportunities to pursue

These are the types of tasks that map cleanly to the promotion criteria.

### Option A: Build a cloud-native reference app
A small but realistic system with:
- API service
- database
- cache
- queue or event consumer
- containerized deployment
- managed cloud hosting
- scaling and observability

This is probably the strongest single option because it gives broad coverage.

### Option B: Contribute to platform modernization work
Look for work such as:
- containerizing an existing application
- moving an app from VM or direct hosting to a managed platform
- introducing health checks, secrets, and environment variables
- implementing logging and telemetry pipelines
- creating a deployment workflow for staging and production

### Option C: Lead a resilience improvement initiative
Look for tasks involving:
- adding retries and timeouts
- using caching to reduce load
- reducing dependency failures through circuit breakers
- protecting systems with rate limiting or throttling
- improving observability and alerting

### Option D: Design a phased migration
Take a monolith or legacy application and propose a strangler fig migration into new services or a managed platform. This shows architectural maturity and decision quality.

---

## 6. Example "evidence" tasks with outcome statements

These are examples a software engineer could later use in a promotion conversation.

### Example 1
"Containerized an internal service using Docker and deployed it to Azure Container Apps, adding health checks, secrets, and autoscale configuration."

Evidence:
- Dockerfile
- Compose or Kubernetes manifests
- deployment screenshots
- configuration notes

### Example 2
"Designed and implemented a fault-tolerant API pattern using retries, circuit breakers, and cache-aside to reduce dependency failure impact."

Evidence:
- code changes
- resilience configuration
- explanation of failure modes and mitigation

### Example 3
"Led a phased migration approach for a legacy service using a strangler fig pattern, enabling incremental deployment and a lower-risk rollback strategy."

Evidence:
- architecture write-up
- route migration plan
- monitoring and rollout notes

### Example 4
"Built Kubernetes deployment artifacts covering rollout strategy, probe configuration, service exposure, and scaling behavior for a production-like workload."

Evidence:
- manifests
- deployment steps
- operational notes

---

## 7. Suggested step-by-step plan a software engineer can follow

### Step 1: Pick one small application to work on
Choose a project that is realistic but not too large.

Good candidates:
- a REST API
- a small background worker
- a web app with dependencies
- a service that currently runs locally or in a VM

### Step 2: Containerize it
Add Docker support and prove it runs locally.

Deliverables:
- Dockerfile
- Compose file
- local startup documentation

### Step 3: Deploy to a managed platform
Use a PaaS platform, not a VM-first approach.

Suggested targets:
- Azure Container Apps
- Azure App Service
- Azure Functions
- AKS if orchestration complexity is required

### Step 4: Add resilience patterns
Apply at least 3-5 patterns relevant to the application.

Examples:
- cache-aside for database-heavy reads
- retry/backoff for downstream calls
- circuit breaker around unstable dependencies
- throttling at the API boundary
- asynchronous messaging for decoupling

### Step 5: Add operational evidence
Capture:
- health checks
- logs and traces
- runbook
- deployment notes
- rollback approach

### Step 6: Package it as evidence
Prepare a concise summary for review:
- what problem it solved
- what architecture decisions were made
- what patterns were used and why
- what the outcome was
- what was learned and what could be improved later

---

## 8. What a strong promotion narrative might sound like

A senior-level narrative could be:

> I have hands-on experience designing and delivering containerized applications in managed cloud environments, using PaaS services to reduce operational overhead while improving deployment consistency and resilience. I have applied cloud design patterns such as cache-aside, retries, circuit breakers, throttling, and event-driven processing to improve reliability and scalability. I can take an application from local containerization to production deployment, ensure it is observable and resilient, and make architecture decisions with risk and operational impact in mind.

This is exactly the kind of statement a software engineer can support with real work and artifacts.

---

## 9. Recommended next actions

If a software engineer wants a practical path forward, the best sequence is:

0. Close the infrastructure gap first: start reviewing pipeline PRs now and pick up G1–G3 from section 2.
1. Select one small application or service to modernize.
2. Containerize it and run it locally with Docker.
3. Deploy it to a managed cloud platform such as Azure Container Apps or App Service.
4. Add at least 3 cloud patterns that clearly improve resilience or performance.
5. Capture the results in a simple architecture walkthrough and evidence folder.
6. Use this as the foundation for a promotion discussion.

---

## 10. Final recommendation

The strongest path is not to learn every pattern in the abstract, but to do a small number of concrete, well-documented implementations that show senior-level judgment.

The most valuable combinations are:
- Docker + Kubernetes or managed containers
- PaaS deployment + short architecture decision notes
- cloud design patterns + real failure handling and observability
- incremental migration strategy + risk-aware rollout

That combination will create convincing, reusable evidence for promotion.
