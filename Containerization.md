# Containerization

A practical guide to containers, Docker, Docker Compose and container registries. It goes with Task idea 1 in the [Senior Pack](README.md), and the working example is in [samples/containerization/](samples/containerization/).

---

## 1. What is a container?

A **container** is a running process (or group of processes) that is packaged with everything it needs: the application, its runtime, its libraries, its configuration and a minimal filesystem. It is isolated from the other processes on the machine. It runs the same way on a developer laptop, a build agent, a test server and in the cloud.

The problem it solves is "it works on my machine". A container does not rely on whatever happens to be installed on the host, because it brings its own dependencies with it.

### Containers vs virtual machines

```
        Virtual machines                          Containers
 ┌──────────┐ ┌──────────┐ ┌──────────┐   ┌──────────┐ ┌──────────┐ ┌──────────┐
 │  App A   │ │  App B   │ │  App C   │   │  App A   │ │  App B   │ │  App C   │
 │ Libs/Bins│ │ Libs/Bins│ │ Libs/Bins│   │ Libs/Bins│ │ Libs/Bins│ │ Libs/Bins│
 │ Guest OS │ │ Guest OS │ │ Guest OS │   └──────────┘ └──────────┘ └──────────┘
 └──────────┘ └──────────┘ └──────────┘   ┌────────────────────────────────────┐
 ┌────────────────────────────────────┐   │ Container runtime (e.g. Docker)    │
 │ Hypervisor                         │   ├────────────────────────────────────┤
 ├────────────────────────────────────┤   │ Host OS (shared kernel)            │
 │ Host OS / hardware                 │   ├────────────────────────────────────┤
 └────────────────────────────────────┘   │ Hardware                           │
                                          └────────────────────────────────────┘
```

| | Virtual machine | Container |
|---|---|---|
| What is virtualised | Hardware: each VM runs a full guest OS | The OS: containers share the host kernel |
| Size | Gigabytes | Megabytes to a few hundred MB |
| Startup time | Minutes | Milliseconds to seconds |
| Isolation | Strong (hypervisor boundary) | Good, but weaker (shared kernel) |
| Density | Tens per host | Hundreds per host |
| Typical use | Different OSs, strong tenant isolation, legacy workloads | Microservices, APIs, build agents, scale-out workloads |

### How it works underneath

Containers are not a single technology. They combine Linux kernel features:

- **Namespaces** control what a process can *see*. Each container gets its own process tree, network interfaces, hostname, mount points and users.
- **Control groups (cgroups)** control what a process can *use*: CPU, memory and I/O limits.
- **Union / overlay filesystems** stack read-only image layers and add a thin writable layer on top for each container.

Windows has equivalents (Windows containers), but most server workloads, including ASP.NET Core, run in Linux containers. On Windows and macOS, Docker Desktop runs Linux containers inside a lightweight Linux VM (WSL 2 on Windows).

### Key terms

| Term | Meaning |
|---|---|
| **Image** | A read-only, versioned template: the filesystem plus metadata (entry point, environment, ports). Like a class. |
| **Container** | A running (or stopped) instance of an image, with its own writable layer. Like an object. |
| **Layer** | One filesystem change in an image (usually one Dockerfile instruction). Layers are cached and shared between images. |
| **Dockerfile** | The text file of instructions used to build an image. |
| **Tag** | A human-friendly, *mutable* label for an image version, e.g. `redis:7-alpine`. |
| **Digest** | An immutable content hash identifying an exact image, e.g. `redis@sha256:4f3c...`. |
| **Registry** | A server that stores and distributes images (Docker Hub, ACR, GHCR, ...). |
| **Volume** | Storage managed outside the container's writable layer, so data survives when the container is removed. |

Containers are meant to be **ephemeral**. Anything written inside a container is lost when it is removed. State belongs in volumes, databases or external services.

---

## 2. What is Docker?

**Docker** is the platform that made containers mainstream (2013). The name refers to several things:

- **Docker Engine (`dockerd`)**: the background daemon that builds images and runs containers. Under the hood it uses `containerd` and `runc`.
- **Docker CLI (`docker`)**: the command-line client that talks to the engine.
- **BuildKit**: the modern build engine behind `docker build`. It adds parallel stages, better caching, build secrets and multi-platform builds.
- **Docker Compose (`docker compose`)**: a tool for defining and running multi-container applications from a YAML file.
- **Docker Desktop**: the Windows/macOS application that bundles all of the above with a Linux VM and a UI. Large organisations need a paid licence for it.
- **Docker Hub**: Docker's public registry (see section 6).

### Open standards (OCI)

Docker's image and runtime formats were donated to the **Open Container Initiative (OCI)**. As a result, an image built with Docker also runs on Podman, containerd, Kubernetes, Azure Container Apps, App Service and AWS ECS, and it can be stored in any OCI-compliant registry. Docker is the most common tool, but not the only one.

```
  Dockerfile ──docker build──▶ Image ──docker push──▶ Registry
                                 │                        │
                            docker run               docker pull
                                 ▼                        ▼
                             Container             (any machine / cloud)
```

---

## 3. The image format and the Dockerfile

### What is inside an image

An OCI image is not one big file. It consists of:

1. a **manifest**, which lists the config and the layers by digest
2. a **config** JSON object containing the entry point, environment variables, exposed ports, working directory, user and the history of how the image was built
3. **layers**, which are compressed tarballs of filesystem changes and are applied in order

Images can also be published as a **multi-platform index**, for example `linux/amd64` and `linux/arm64` under one tag. Docker then pulls the right variant for the machine automatically.

You can inspect these yourself:

```bash
docker image inspect redis:7-alpine       # config: Env, Cmd, ExposedPorts, layers...
docker history redis:7-alpine             # one row per layer and the instruction that created it
docker buildx imagetools inspect redis:7-alpine   # manifest / platforms in the registry
```

### Dockerfile instructions

| Instruction | Purpose |
|---|---|
| `FROM image[:tag] [AS name]` | Base image to build on. Multiple `FROM`s create a **multi-stage** build. |
| `WORKDIR /path` | Sets (and creates) the working directory for the following instructions. |
| `COPY src dest` | Copies files from the build context (or `--from=stage`) into the image. |
| `ADD src dest` | Like `COPY`, but can also unpack archives and fetch URLs. Prefer `COPY` unless you need these features. |
| `RUN command` | Runs a command at **build** time and saves the result as a new layer. |
| `ENV KEY=value` | Sets an environment variable at build and run time. |
| `ARG NAME[=default]` | A build-time-only variable (`docker build --build-arg`). |
| `EXPOSE port` | Documents the port the app listens on. It does not publish the port. |
| `USER name/uid` | The user that later instructions and the container itself run as. |
| `ENTRYPOINT ["exe", "arg"]` | The executable that runs when the container starts. |
| `CMD ["arg"]` | Default arguments to the entry point, or the default command. Can be overridden by `docker run image <cmd>`. |
| `HEALTHCHECK CMD ...` | A command Docker runs periodically to decide whether the container is healthy. |
| `LABEL key=value` | Metadata such as source repository, version or maintainer. |

### Example: a multi-stage .NET Dockerfile

This is [samples/containerization/api/Dockerfile](samples/containerization/api/Dockerfile):

```dockerfile
# ---- Stage 1: build ----
# The SDK image contains the compilers and tooling - large, only used to build
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

# Copy the project file first and restore, so this layer is cached
# until the package references change
COPY Api.csproj .
RUN dotnet restore

# Now copy the source and publish
COPY . .
RUN dotnet publish -c Release -o /app/publish --no-restore

# ---- Stage 2: runtime ----
# The ASP.NET runtime image is much smaller and contains no build tools
FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS final
WORKDIR /app
COPY --from=build /app/publish .

# Run as the built-in non-root user rather than root
USER $APP_UID

# .NET 8+ images listen on 8080 by default
EXPOSE 8080
ENTRYPOINT ["dotnet", "Api.dll"]
```

The example shows these practices:

- **Multi-stage build.** The final image contains only the runtime and the published output, not the SDK or the source code. This cuts the size substantially and removes tools an attacker could use.
- **Layer ordering for caching.** The `.csproj` is copied and restored *before* the rest of the source. When only `.cs` files change, Docker reuses the cached `dotnet restore` layer, so builds are much faster. As a rule, put the things that change least often first.
- **Non-root user.** Microsoft's .NET images include an `app` user, and `$APP_UID` refers to it.
- **Pinned base image tags.** Use `10.0` rather than `latest`. In production, consider pinning to a digest for fully reproducible builds.
- **`.dockerignore`.** This keeps `bin/`, `obj/`, `.git` and secrets out of the build context. Builds are faster and secrets do not end up in an image by accident:

```
bin/
obj/
Dockerfile
.dockerignore
```

### Example: a multi-stage TypeScript / Node.js Dockerfile

The same API is also written in TypeScript with Express, in [samples/containerization/api-node/](samples/containerization/api-node/). This is its [Dockerfile](samples/containerization/api-node/Dockerfile):

```dockerfile
# ---- Stage 1: build ----
# Full dependency install (including TypeScript) to compile src/ to dist/
FROM node:24-alpine AS build
WORKDIR /app

# Copy the manifests first and install, so this layer is cached
# until the dependencies change
COPY package.json package-lock.json ./
RUN npm ci

COPY tsconfig.json ./
COPY src ./src
RUN npm run build

# ---- Stage 2: production dependencies only ----
FROM node:24-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

# ---- Stage 3: runtime ----
# No TypeScript compiler, no dev dependencies, no source - just JavaScript and runtime packages
FROM node:24-alpine AS final
ENV NODE_ENV=production
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY package.json ./

# The official image's built-in non-root "node" user. Numeric so that
# Kubernetes' runAsNonRoot can verify it is not root.
USER 1000

EXPOSE 8080
# Exec form, so node is PID 1 and receives SIGTERM directly
CMD ["node", "dist/server.js"]
```

The same principles apply as for .NET, with some Node-specific points:

- **`npm ci`, not `npm install`.** `npm ci` installs exactly what is in `package-lock.json`, so builds are reproducible. Always commit the lock file.
- **Three stages.** TypeScript and the `@types/*` packages are only needed to compile. The `deps` stage installs production dependencies only (`--omit=dev`), and the final image copies just those plus the compiled `dist/` folder.
- **Run `node` directly, in exec form.** Avoid `CMD npm start` and the shell form `CMD node dist/server.js`. In both cases npm or a shell becomes PID 1 and may not pass SIGTERM on to Node. Docker would then wait 10 seconds and force-kill the container, dropping in-flight requests.
- **Handle SIGTERM in code.** As PID 1, Node gets no default signal handling, so the app closes its server explicitly (see the end of [server.ts](samples/containerization/api-node/src/server.ts)). An alternative is `docker run --init` or `tini` as the entry point.
- **Alpine vs Debian base images.** `node:24-alpine` is small, but it uses musl rather than glibc, which occasionally breaks native npm modules. `node:24-slim` (Debian) is the safer choice when that happens.
- **`.dockerignore`** must exclude `node_modules/` and `dist/`. Otherwise the local, possibly Windows-built, `node_modules` is sent to the build and can overwrite the Linux one:

```
node_modules/
dist/
Dockerfile
.dockerignore
```

---

## 4. Running containers with Docker

### Build an image

```bash
cd samples/containerization/api
docker build -t visits-api:1.0 .
#             │               └─ build context (files available to COPY)
#             └─ name:tag for the resulting image

docker images                   # list local images

# the TypeScript / Node version is built the same way
docker build -t visits-api-node:1.0 ../api-node
```

### Run a container

```bash
docker run -d --name visits-api -p 8080:8080 -e ASPNETCORE_ENVIRONMENT=Development visits-api:1.0
```

| Flag | Meaning |
|---|---|
| `-d` | Detached: runs in the background. |
| `--name` | A friendly container name. Otherwise Docker generates one. |
| `-p host:container` | Publishes a container port on the host, e.g. `-p 8080:8080`. |
| `-e KEY=value` | Sets an environment variable. ASP.NET Core maps `Section__Key` to configuration `Section:Key`. |
| `-v name:/path` | Mounts a named volume (or `-v C:\host\path:/path` for a bind mount). |
| `--rm` | Removes the container automatically when it stops. |
| `-it` | Interactive with a terminal, e.g. `docker run -it --rm alpine sh`. |
| `--network name` | Attaches the container to a user-defined network. |
| `--memory 512m --cpus 1` | Resource limits (enforced by cgroups). |

Once it is running, `curl http://localhost:8080/health` should return `"healthy"`. (`/api/visits` needs Redis, which is covered next.)

The Node image runs the same way. Configuration also comes from environment variables, read in code with `process.env`:

```bash
docker run -d --name visits-api-node -p 8081:8080 -e REDIS_URL=redis://host.docker.internal:6379 visits-api-node:1.0
```

### Run an off-the-shelf image

You do not need a Dockerfile to use existing software. Docker pulls the image from Docker Hub automatically:

```bash
docker run -d --name redis -p 6379:6379 redis:7-alpine
docker exec -it redis redis-cli ping      # → PONG
```

### Everyday commands

```bash
docker ps                      # running containers (-a to include stopped)
docker logs -f visits-api      # follow a container's stdout/stderr
docker exec -it visits-api sh  # open a shell inside a running container (if it has one)
docker inspect visits-api      # full JSON: IP address, mounts, env, state
docker stats                   # live CPU / memory per container
docker stop visits-api         # graceful stop (SIGTERM, then SIGKILL after 10s)
docker start visits-api        # start a stopped container again
docker rm visits-api           # remove a stopped container (-f to force)
docker rmi visits-api:1.0      # remove an image
docker system prune            # clean up stopped containers, dangling images, unused networks
```

### Connecting containers by hand

Containers on the same **user-defined network** can reach each other by container name, through Docker's built-in DNS:

```bash
docker network create demo
docker run -d --name redis --network demo redis:7-alpine
docker run -d --name visits-api --network demo -p 8080:8080 \
  -e ConnectionStrings__Redis="redis:6379,abortConnect=false" visits-api:1.0

curl http://localhost:8080/api/visits     # → {"visits":1,"servedBy":"<container id>"}
```

This works, but keeping several `docker run` commands, networks and volumes in sync by hand is error prone. Docker Compose solves that.

---

## 5. Multi-container apps with Docker Compose

**Docker Compose** describes a whole application (services, networks, volumes and configuration) in one declarative YAML file. One command then brings the whole application up or down. It is ideal for local development, integration tests and demos. For production orchestration across many machines, see Kubernetes, Azure Container Apps and the other options in [README.md](README.md).

### The sample application

[samples/containerization/](samples/containerization/) contains three services. Two are built from our own Dockerfiles, and one is an off-the-shelf image:

```
                 host:8000
                     │
            ┌────────▼────────┐        ┌──────────────────┐        ┌──────────────────┐
 browser ──▶│ web  (nginx)    │ /api/* │ api  (.NET 10)   │        │ redis            │
            │ static page +   ├───────▶│ minimal API      ├───────▶│ redis:7-alpine   │
            │ reverse proxy   │        │ GET /api/visits  │        │ visit counter    │
            └─────────────────┘        └──────────────────┘        └────────┬─────────┘
                    built from              built from                      │
                    web/Dockerfile          api/Dockerfile           volume: redis-data
```

```
samples/containerization/
├── docker-compose.yml
├── docker-compose.node.yml   # override: swap in the TypeScript/Node api
├── api/                      # .NET 10 version of the api
│   ├── Api.csproj
│   ├── Program.cs            # GET /api/visits, GET /health, GET /health/ready
│   ├── Dockerfile            # multi-stage .NET build (section 3)
│   └── .dockerignore
├── api-node/                 # TypeScript / Express version - same endpoints
│   ├── package.json, package-lock.json, tsconfig.json
│   ├── src/server.ts
│   ├── Dockerfile            # multi-stage Node build (section 3)
│   └── .dockerignore
├── web/
│   ├── Dockerfile            # FROM nginx, copies config + page
│   ├── nginx.conf            # serves index.html, proxies /api/ to http://api:8080
│   └── index.html
└── k8s/                      # Kubernetes manifests - see Kubernetes.md
```

The API increments a counter in Redis and reports which container handled the request. In C#:

```csharp
app.MapGet("/api/visits", async (IConnectionMultiplexer redis) =>
{
    var visits = await redis.GetDatabase().StringIncrementAsync("visits");
    return Results.Ok(new { visits, servedBy = Environment.MachineName });
});
```

And in TypeScript ([server.ts](samples/containerization/api-node/src/server.ts)):

```typescript
const redisUrl = process.env.REDIS_URL ?? "redis://localhost:6379";
const redis = new Redis(redisUrl, { enableOfflineQueue: false, maxRetriesPerRequest: 1 });

app.get("/api/visits", async (_req, res) => {
  const visits = await redis.incr("visits");
  res.json({ visits, servedBy: os.hostname() });
});
```

Both versions expose the same endpoints on port 8080, so either image can sit behind the same nginx front end and use the same Redis. That is the point of the container contract: consumers care about the port, the endpoints and the configuration, not about the language inside.

The web image is deliberately small:

```dockerfile
FROM nginx:1.27-alpine

# Replace the default site config with one that also proxies /api to the api service
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html/index.html

EXPOSE 80
```

### docker-compose.yml

```yaml
services:

  # nginx serving a static page and acting as a reverse proxy to the api
  web:
    build: ./web
    ports:
      - "8000:80"            # host:container - browse to http://localhost:8000
    depends_on:
      - api

  # ASP.NET Core minimal API, built from api/Dockerfile
  api:
    build: ./api
    environment:
      ASPNETCORE_ENVIRONMENT: Development
      ConnectionStrings__Redis: "redis:6379,abortConnect=false"
    depends_on:
      redis:
        condition: service_healthy   # wait until redis passes its health check
    # No "ports" - the api is only reachable from other containers on this network

  # Off-the-shelf image pulled from Docker Hub - nothing to build
  redis:
    image: redis:7-alpine
    volumes:
      - redis-data:/data     # named volume so the counter survives "docker compose down"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 5

volumes:
  redis-data:
```

Things to notice:

- **`build:` vs `image:`.** `web` and `api` are built from local Dockerfiles. `redis` is pulled from a registry.
- **Service names are hostnames.** Compose creates a private network for the project, so `api` reaches Redis at `redis:6379` and nginx proxies to `http://api:8080`. No IP addresses are needed.
- **Only `web` publishes a port.** The API and Redis are not reachable from the host, only from inside the network. This mirrors a production layout where only the front door is public.
- **`depends_on` with `condition: service_healthy`.** The API does not start until Redis answers `ping`. A plain `depends_on` only controls start *order*, not *readiness*.
- **Configuration through environment variables.** The same image runs in every environment. Only the configuration differs.
- **Named volume.** Redis data survives `docker compose down`. It is deleted only with `docker compose down -v`.

### Running it

```bash
cd samples/containerization

docker compose up -d --build     # build images, create network + volume, start everything
docker compose ps                # status of each service (redis shows "healthy")

curl http://localhost:8000/api/visits
# {"visits":1,"servedBy":"a4c592937ade"}
# or open http://localhost:8000 in a browser and click the button

docker compose logs -f api       # follow logs for one service
docker compose exec redis redis-cli get visits   # run a command in a service container
```

### Swapping in the TypeScript / Node API

[docker-compose.node.yml](samples/containerization/docker-compose.node.yml) is an **override file**. Compose merges it over the main file, so it only has to describe what changes:

```yaml
services:
  api:
    build: ./api-node
    environment:
      REDIS_URL: "redis://redis:6379"
```

```bash
docker compose -f docker-compose.yml -f docker-compose.node.yml up -d --build
curl http://localhost:8000/api/visits
# {"visits":1,"servedBy":"db2980a1a3b3"}   ← now served by Node
docker compose -f docker-compose.yml -f docker-compose.node.yml down
```

The same technique is commonly used for per-environment differences, such as a `compose.override.yaml` with debug settings for local development.

### Scaling a service

Because the API is stateless (the state lives in Redis) and does not publish a host port, it can be scaled out:

```bash
docker compose up -d --scale api=3
for i in 1 2 3 4 5 6; do curl -s http://localhost:8000/api/visits; echo; done
# {"visits":1,"servedBy":"1d9278413d34"}
# {"visits":2,"servedBy":"1d9278413d34"}
# {"visits":3,"servedBy":"a51423d3bf6a"}
# {"visits":4,"servedBy":"1d9278413d34"}
# {"visits":5,"servedBy":"0aa9d35f99d4"}
# ...
```

The `servedBy` value shows requests landing on different replicas, while the counter stays consistent because it is shared through Redis.

This only works because `nginx.conf` uses `resolver 127.0.0.11` (Docker's DNS) and a variable in `proxy_pass`. That makes nginx re-resolve `api` rather than caching a single IP at startup. The distribution comes from DNS, so it is spread, not strict round-robin. In production, a real load balancer or orchestrator takes care of this.

### Stopping and cleaning up

```bash
docker compose stop          # stop containers, keep them
docker compose down          # remove containers and network (volume kept - counter survives)
docker compose down -v       # also remove volumes
docker compose down --rmi local   # also remove the images built by this project
```

### Useful Compose features to explore next

- `env_file:` loads environment variables from a `.env` file. Keep that file out of source control if it holds secrets.
- `profiles:` defines optional services, e.g. `docker compose --profile tools up` to start a DB admin UI.
- `compose.override.yaml` holds local developer overrides that are merged automatically.
- `docker compose watch` rebuilds or syncs files on change during development.
- `deploy.resources.limits` sets CPU and memory limits per service.

---

## 6. Container registries

A **container registry** is a server that stores and distributes container images, much as NuGet.org distributes packages. A build pipeline builds an image and **pushes** it to a registry. Every environment (test, staging, production, a colleague's laptop) then **pulls** that exact image. That is how the same artifact gets promoted through environments.

### Image naming

```
  myregistry.azurecr.io / teamname/visits-api : 1.4.2
  └──── registry ─────┘   └─── repository ──┘   └ tag ┘

  Shorthands:
    redis:7-alpine          →  docker.io/library/redis:7-alpine   (Docker Hub "official" image)
    ghcr.io/org/api:latest  →  GitHub Container Registry
```

- When no registry is given, Docker assumes Docker Hub (`docker.io`).
- When no tag is given, Docker assumes `:latest`. That is just a tag name, not "the newest". Avoid relying on it.
- Tags are **mutable**: `1.4` can be moved to point at a new image. Digests (`@sha256:...`) are **immutable**. Deploy by a unique tag (e.g. build number or Git SHA) or by digest, so you know exactly what is running.

### The generic workflow

The same steps apply to every registry. Only the login step and the hostname differ:

```bash
docker login <registry>
docker tag visits-api:1.0 <registry>/<repository>:1.0
docker push <registry>/<repository>:1.0
docker pull <registry>/<repository>:1.0     # on any other machine
```

### Docker Hub

[hub.docker.com](https://hub.docker.com) is the default public registry and the largest source of base images.

- **Official images** (`redis`, `nginx`, `postgres`, `node`) are curated and have no namespace prefix. **Verified Publisher** images come from vendors.
- A free account gets unlimited public repositories, with limited private repositories on paid plans.
- **Pull rate limits** apply to anonymous and free-tier pulls. Shared CI agents can hit them and fail builds unpredictably. Log in during pipelines, or mirror or cache the base images you depend on in your own registry.
- Images on Docker Hub can be published by anyone. Prefer official or verified images and scan what you pull.

```bash
docker login                                 # prompts for Docker ID + access token
docker tag visits-api:1.0 mydockerid/visits-api:1.0
docker push mydockerid/visits-api:1.0
```

> Microsoft publishes its images (.NET, SQL Server, etc.) to its own registry, **MCR** (`mcr.microsoft.com`), not to Docker Hub. That is why the Dockerfile above uses `mcr.microsoft.com/dotnet/...`.

### Azure Container Registry (ACR)

ACR is Azure's managed, **private** registry. It is the natural choice when deploying to Azure services.

- **Tiers:** Basic, Standard and Premium. They differ in storage and throughput. Only **Premium** adds geo-replication (a registry replica in each region you deploy to), private endpoints / private link, and more advanced network rules.
- **Microsoft Entra ID authentication.** Pipelines, App Service, Container Apps and AKS pull using **managed identities** and the `AcrPull` role, so no passwords are stored anywhere. Push from pipelines with an Azure DevOps service connection or the `AcrPush` role. Keep the admin user disabled.
- **ACR Tasks:** `az acr build` builds the image *in Azure*, without needing Docker on the build agent. Tasks can also rebuild automatically when a base image is patched.
- Also includes Microsoft Defender for Cloud vulnerability scanning, retention policies for untagged manifests, and soft delete.
- Integrates with Azure App Service (Web App for Containers), Azure Container Apps, AKS, Azure Functions and Azure Container Instances.

```bash
az acr create -g my-rg -n myregistry --sku Standard
az acr login -n myregistry                   # uses your az login; no separate password

docker tag visits-api:1.0 myregistry.azurecr.io/visits-api:1.0
docker push myregistry.azurecr.io/visits-api:1.0

# or build and push in the cloud in one step
az acr build -r myregistry -t visits-api:{{.Run.ID}} ./samples/containerization/api

# let AKS pull without credentials
az aks update -g my-rg -n my-aks --attach-acr myregistry
```

In an Azure Pipeline, the `Docker@2` task builds and pushes using a Docker registry service connection:

```yaml
- task: Docker@2
  inputs:
    command: buildAndPush
    containerRegistry: 'acr-service-connection'
    repository: 'visits-api'
    dockerfile: 'samples/containerization/api/Dockerfile'
    tags: |
      $(Build.BuildId)
```

> **Azure DevOps has no built-in container registry.** Azure Artifacts handles NuGet, npm, Maven, Python and Universal Packages, but not container images. ADO-based teams normally pair their pipelines with ACR.

### GitHub Container Registry (GHCR)

GHCR (`ghcr.io`) is part of GitHub Packages and sits next to the source code.

- Images belong to a user or organisation, can be linked to a repository, and inherit that repository's permissions.
- Public images are free. Private images use the GitHub Packages storage and transfer allowance of your plan.
- In **GitHub Actions**, the built-in `GITHUB_TOKEN` can push (with `packages: write` permission), so no extra secrets are needed. Outside Actions, use a personal access token with `write:packages`.

```bash
echo $GITHUB_PAT | docker login ghcr.io -u <github-username> --password-stdin
docker tag visits-api:1.0 ghcr.io/<org>/visits-api:1.0
docker push ghcr.io/<org>/visits-api:1.0
```

```yaml
# .github/workflows/build.yml (excerpt)
permissions:
  contents: read
  packages: write
steps:
  - uses: actions/checkout@v4
  - uses: docker/login-action@v3
    with:
      registry: ghcr.io
      username: ${{ github.actor }}
      password: ${{ secrets.GITHUB_TOKEN }}
  - uses: docker/build-push-action@v6
    with:
      context: samples/containerization/api
      push: true
      tags: ghcr.io/${{ github.repository_owner }}/visits-api:${{ github.sha }}
```

### Other registries worth knowing

| Registry | Notes |
|---|---|
| **Amazon ECR** | AWS's private registry, with IAM-based auth. Pairs with ECS, EKS and App Runner. Also offers ECR Public. |
| **Google Artifact Registry** | GCP's registry. It replaced Google Container Registry and also hosts language packages. |
| **Microsoft Container Registry (MCR)** | Read-only source of Microsoft's own images. You pull from it but do not push to it. |
| **Quay.io** | Red Hat's registry, common in the OpenShift ecosystem. |
| **Harbor** | Open-source (CNCF) registry you host yourself, with scanning, signing and replication. Used on-premises or in air-gapped environments. |
| **GitLab Container Registry** | Built into GitLab projects, the equivalent of GHCR. |

### Comparison

| | Docker Hub | Azure Container Registry | GitHub Container Registry |
|---|---|---|---|
| Hostname | `docker.io` | `<name>.azurecr.io` | `ghcr.io` |
| Main use | Public images, base images | Private images for Azure workloads | Images built alongside GitHub code |
| Authentication | Docker ID + access token | Entra ID, managed identity, service principal | GitHub token / PAT |
| Best CI pairing | Any | Azure Pipelines, `az acr build` | GitHub Actions |
| Network isolation | No | Yes (Premium: private endpoints) | No |
| Geo-replication | Global CDN (managed by Docker) | Yes (Premium) | Global CDN (managed by GitHub) |
| Scanning | Docker Scout | Defender for Cloud | Dependabot / third-party actions |

### Registry good practices

- **Build once, promote everywhere.** Deploy the same image (by digest) to test, staging and production. Do not rebuild for each environment.
- **Use unique, meaningful tags** such as build ID, Git SHA or semantic version. Do not deploy `latest` to production.
- **Use identity, not passwords.** Prefer managed identities, OIDC or workload identity federation over admin users and long-lived tokens.
- **Scan images** for vulnerabilities in the pipeline and in the registry. Rebuild regularly to pick up patched base images.
- **Sign images** (Notation or Cosign) and generate an SBOM if supply-chain assurance is required.
- **Set retention policies** so untagged and old images do not pile up storage costs.
- **Keep the registry close to the workload.** Same region, or geo-replicated, to reduce pull time and egress cost and to improve availability.

---

## 7. Where to go next

1. Run the sample: `cd samples/containerization && docker compose up -d --build`, then open http://localhost:8000.
2. Containerize a real team application by following Task idea 1 in [README.md](README.md). Add a health check endpoint, a non-root user and a Compose file for its dependencies.
3. Push its image to ACR from an Azure Pipeline using a service connection. This also covers Gap task G1.
4. Deploy that image to Azure Container Apps or App Service for Containers, pulling from ACR with a managed identity.
5. Take the same image to Kubernetes (Task idea 4, and [Kubernetes.md](Kubernetes.md)).

Each step produces something concrete (a PR, a pipeline run, a deployed endpoint) that can go into the evidence pack.
