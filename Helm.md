# Helm

A practical guide to Helm, following on from [Kubernetes.md](Kubernetes.md). It explains what Helm is, why teams use it (and when they should not), and rewrites the sample's Kubernetes manifests as a Helm chart. The chart is in [samples/containerization/helm/visits/](samples/containerization/helm/visits/). It has been linted, then installed, tested, upgraded, rolled back and uninstalled on a local Docker Desktop cluster.

---

## 1. What is Helm?

**Helm** is the package manager for Kubernetes. It is to Kubernetes roughly what NuGet or npm is to code, combined with a templating engine and a deployment history.

| Term | Meaning | Analogy |
|---|---|---|
| **Chart** | A package: a folder of templated Kubernetes manifests plus default settings and metadata. | a NuGet / npm package |
| **Values** | The settings a chart is installed with: defaults in `values.yaml`, overridden per install with `-f file.yaml` or `--set key=value`. | configuration / parameters |
| **Release** | One installed instance of a chart in a cluster, with a name (e.g. `visits`). The same chart can be installed many times as different releases. | an installed application |
| **Revision** | Each install, upgrade or rollback of a release creates a numbered revision. Helm keeps the history in the cluster, so you can roll back. | a deployment in a pipeline's history |
| **Repository** | Where charts are published: a classic HTTP chart repository, or (now preferred) an **OCI registry** such as ACR, GHCR or Docker Hub. | NuGet.org / a private feed |

```
  values.yaml (defaults)          ┌───────────────┐
  + values-prod.yaml (overrides) ─▶│  helm upgrade │──▶ rendered Kubernetes YAML ──▶ API server
  + --set api.replicaCount=5      │   (template   │                                    │
  templates/*.yaml ──────────────▶│    engine)    │    release "visits", revision 4 ◀──┘
                                  └───────────────┘    (stored as a Secret in the namespace)
```

Helm 3 runs entirely on the client. It has no server-side component, unlike Helm 2's Tiller, and it uses your `kubectl` credentials and RBAC permissions. Helm 4 (released late 2025) keeps the same chart format (`apiVersion: v2`), so the chart in this guide works with either version.

---

## 2. Why use Helm?

The plain manifests in [Kubernetes.md](Kubernetes.md) work well for one copy of one application. These problems appear as soon as that changes:

| Problem with plain YAML | How Helm addresses it |
|---|---|
| **Environment differences.** Dev, test and production need different image tags, replica counts, resource sizes and storage classes. Copy-pasting manifests per environment drifts quickly. | One set of templates plus a small values file per environment (`values-aks.yaml` in the sample). |
| **Hard-coded names.** Two copies of the app (e.g. per-feature test environments) in one namespace collide, because every resource is called `api`, `web` and so on. | Names are generated from the release name. `helm install visits-pr-123 ...` produces `visits-pr-123-api`. |
| **No concept of "the application".** `kubectl apply` sees individual objects. Removing a resource from the folder does not delete it from the cluster, and there is no single "roll back the app" action. | A **release** groups everything. `helm upgrade` deletes objects that are no longer rendered, `helm rollback` returns the whole app to a previous revision, and `helm uninstall` removes it all. |
| **Optional features.** Turning autoscaling or persistence on or off means editing or deleting files. | `if` blocks driven by values (`api.autoscaling.enabled`, `redis.persistence.enabled`). |
| **Sharing.** Handing an application to another team or customer as a folder of YAML is fragile. | Charts are versioned packages pushed to a registry. Consumers only need to know the documented values. |
| **Installing third-party software.** Ingress controllers, cert-manager, Prometheus, KEDA, Argo CD and others are complex to install. | Nearly all of them publish an official chart. `helm install` with a few values replaces hundreds of lines of YAML. |

In practice, the biggest reason most teams meet Helm is the last one. **Even teams that write their own manifests with Kustomize install most of their cluster's infrastructure with Helm charts.**

### Helm vs Kustomize

The Kubernetes sample already uses Kustomize for the Node overlay. The two tools take different approaches:

| | Kustomize | Helm |
|---|---|---|
| Approach | **Patching.** Plain YAML base plus overlays that modify it. | **Templating.** YAML with `{{ }}` placeholders, rendered from values. |
| Base files | Valid Kubernetes YAML that can be applied directly | Not valid YAML until rendered |
| Learning curve | Low. Built into `kubectl -k`. | Moderate. Go templates, whitespace handling, chart conventions. |
| Logic (conditionals, loops) | None, by design | Full template language |
| Release tracking / rollback | No | Yes |
| Packaging and distribution | No (Git only) | Yes (versioned charts in registries) |
| Readability of the deployed YAML | High | Templates can become hard to read if overused |
| Typical use | In-house apps with a few environment variants | Reusable or distributed apps, third-party software, apps with many options |

They are not exclusive. Common combinations are:

- Helm for third-party components, with Kustomize or plain YAML for your own apps.
- A Kustomize overlay on top of a third-party chart's output (`helm template ... | kustomize` or Helm's `--post-renderer`), for patches the chart's values do not allow.
- GitOps tools (**Argo CD**, **Flux**) that can deploy both.

### When not to use Helm

- **One app, one or two environments, one team.** Plain YAML or Kustomize is simpler and easier to review.
- **When the templates would hide what is deployed.** Every value has to be threaded through by hand. A chart where *everything* is configurable can end up as hard to understand as the YAML it replaced, which is a frequent complaint.
- **On platforms that are not Kubernetes.** App Service and Azure Container Apps use Bicep or Terraform instead.

---

## 3. Chart structure

```
samples/containerization/helm/visits/
├── Chart.yaml              # name, chart version, app version, dependencies
├── values.yaml             # default values - the chart's "public API"
├── values-node.yaml        # override: use the TypeScript/Node api
├── values-aks.yaml         # override: example production settings for AKS
├── .helmignore             # files to leave out when packaging
└── templates/
    ├── _helpers.tpl        # reusable named templates (names, labels, image refs)
    ├── api.yaml            # api Deployment + Service
    ├── api-hpa.yaml        # HorizontalPodAutoscaler - only rendered if enabled
    ├── redis.yaml          # PVC (optional) + Deployment + Service
    ├── web-configmap.yaml  # nginx config
    ├── web.yaml            # web Deployment + Service
    ├── NOTES.txt           # message printed after install/upgrade
    └── tests/
        └── test-connection.yaml   # smoke test run by `helm test`
```

[Chart.yaml](samples/containerization/helm/visits/Chart.yaml) has two separate version numbers. Keeping them apart matters:

```yaml
apiVersion: v2
name: visits
description: The visits sample - nginx front end, API (.NET or Node) and Redis
type: application
# Version of the chart itself - bump when the templates change
version: 0.1.0
# Version of the application it deploys - used as the default image tag
appVersion: "1.0"
```

`helm create mychart` generates a similar skeleton, with examples, which is a good way to start a new chart.

---

## 4. The template language in five minutes

Helm templates are Go templates plus the [Sprig](https://masterminds.github.io/sprig/) function library and a few Helm additions.

### Built-in objects

| Object | Example | Contains |
|---|---|---|
| `.Values` | `.Values.api.replicaCount` | Merged values: `values.yaml`, then `-f` files in order, then `--set` |
| `.Release` | `.Release.Name`, `.Release.Namespace`, `.Release.Revision` | Information about this install |
| `.Chart` | `.Chart.Name`, `.Chart.Version`, `.Chart.AppVersion` | Contents of `Chart.yaml` |
| `.Capabilities` | `.Capabilities.KubeVersion` | What the target cluster supports |
| `.Template` | `.Template.BasePath` | Information about the current template file |

### The constructs used in the sample

```yaml
# Insert a value
replicas: {{ .Values.api.replicaCount }}

# Pipelines and functions: default, quote, upper, trunc, sha256sum...
tag: {{ .Values.api.image.tag | default .Chart.AppVersion | quote }}

# Conditionals
{{- if .Values.api.autoscaling.enabled }} ... {{- end }}

# "with" - only render if set, and make it the current scope (.)
{{- with .Values.redis.persistence.storageClass }}
storageClassName: {{ . }}
{{- end }}

# Loops over lists or maps ($ is the root scope inside a range)
{{- range $name, $value := .Values.api.env }}
- name: {{ $name }}
  value: {{ tpl $value $ | quote }}
{{- end }}

# Insert a whole block of YAML from values, indented correctly
resources:
  {{- toYaml .Values.api.resources | nindent 12 }}

# Call a named template defined in _helpers.tpl
name: {{ include "visits.fullname" . }}-api
```

Two details catch everyone out:

- **Whitespace control.** `{{-` trims whitespace (including newlines) *before* the tag, and `-}}` trims *after* it. Without them, conditionals leave blank lines or break indentation.
- **Indentation is your problem.** YAML is whitespace-sensitive and templates are plain text. `toYaml` plus `nindent N` ("newline, then indent N spaces") is the standard way to insert blocks. Always check the output with `helm template`.

---

## 5. Converting the Kubernetes files to Helm

The Helm chart produces the same objects as `k8s/base` and `k8s/node` from [Kubernetes.md](Kubernetes.md). The conversion follows a repeatable recipe:

1. **Copy each manifest into `templates/`.**
2. **Replace hard-coded names** with `{{ include "visits.fullname" . }}-<component>`, so multiple releases can coexist.
3. **Replace hard-coded labels** with shared helpers, so every resource gets the standard `app.kubernetes.io/*` labels.
4. **Move anything that varies between environments into `values.yaml`**: images, replica counts, resources, service type, probes and storage. Leave things that never vary, such as the rolling update strategy and the security context, in the template.
5. **Wrap optional resources in `if` blocks.**
6. **Render with `helm template` and compare** with the original YAML.

### Helpers: names, labels and images

[_helpers.tpl](samples/containerization/helm/visits/templates/_helpers.tpl) defines named templates once, so every file uses the same naming and labels:

```yaml
{{/*
Selector labels for one component - these must never change after install.
Usage: include "visits.selectorLabels" (dict "root" . "component" "api")
*/}}
{{- define "visits.selectorLabels" -}}
app.kubernetes.io/name: {{ include "visits.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Full image reference, adding the registry prefix and defaulting the tag to appVersion.
Usage: include "visits.image" (dict "root" . "image" .Values.api.image)
*/}}
{{- define "visits.image" -}}
{{- $tag := .image.tag | default .root.Chart.AppVersion -}}
{{- if .root.Values.imageRegistry -}}
{{ .root.Values.imageRegistry }}/{{ .image.repository }}:{{ $tag }}
{{- else -}}
{{ .image.repository }}:{{ $tag }}
{{- end -}}
{{- end }}

{{/*
In-cluster DNS name of the Redis service.
*/}}
{{- define "visits.redisHost" -}}
{{ include "visits.fullname" . }}-redis
{{- end }}
```

Named templates take a single argument. Where a helper needs both the root context and a parameter, the convention is to pass a `dict`, as above.

The `app: api` label from the plain manifests has been replaced with the standard set. `instance` (the release name) is part of the selector, which keeps two releases' pods from being mixed up.

### api.yaml: before and after

The plain manifest ([k8s/base/api.yaml](samples/containerization/k8s/base/api.yaml)) hard-codes everything:

```yaml
metadata:
  name: api
spec:
  replicas: 3
  selector:
    matchLabels:
      app: api
  ...
      containers:
        - name: api
          image: visits-api:1.0
          env:
            - name: ConnectionStrings__Redis
              value: "redis:6379,abortConnect=false"
          startupProbe: ...
          readinessProbe: ...
          livenessProbe: ...
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
```

The template ([templates/api.yaml](samples/containerization/helm/visits/templates/api.yaml)) keeps the structure and takes the variable parts from values:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "visits.fullname" . }}-api
  labels:
    {{- include "visits.labels" . | nindent 4 }}
    {{- include "visits.selectorLabels" (dict "root" . "component" "api") | nindent 4 }}
spec:
  {{- if not .Values.api.autoscaling.enabled }}
  # When autoscaling is on, the HPA owns the replica count
  replicas: {{ .Values.api.replicaCount }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "visits.selectorLabels" (dict "root" . "component" "api") | nindent 6 }}
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  template:
    metadata:
      labels:
        {{- include "visits.selectorLabels" (dict "root" . "component" "api") | nindent 8 }}
    spec:
      securityContext:
        runAsNonRoot: true
      containers:
        - name: api
          image: {{ include "visits.image" (dict "root" . "image" .Values.api.image) }}
          imagePullPolicy: {{ .Values.imagePullPolicy }}
          ports:
            - containerPort: {{ .Values.api.containerPort }}
          env:
            {{- range $name, $value := .Values.api.env }}
            - name: {{ $name }}
              value: {{ tpl $value $ | quote }}
            {{- end }}
          {{- toYaml .Values.api.probes | nindent 10 }}
          {{- with .Values.api.preStopSleepSeconds }}
          lifecycle:
            preStop:
              sleep:
                seconds: {{ . }}
          {{- end }}
          resources:
            {{- toYaml .Values.api.resources | nindent 12 }}
```

Points to notice:

- **`replicas` is omitted when autoscaling is on.** If both the Deployment and an HPA set the replica count, every `helm upgrade` resets the count the HPA chose.
- **The health checks are values, but they keep the same shape.** `toYaml .Values.api.probes` writes the `startupProbe`, `readinessProbe` and `livenessProbe` blocks straight from `values.yaml`. The probe behaviour described in [Kubernetes.md](Kubernetes.md) stays the same, but a team can tune timings per environment, for example a longer startup allowance on slower dev nodes, without touching the template.
- **`tpl` renders values as templates.** The Redis connection string needs the *generated* Redis service name, which depends on the release name. `values.yaml` cannot know that in advance, so the value is itself a template that `tpl` renders:

```yaml
# values.yaml
api:
  env:
    ConnectionStrings__Redis: '{{ include "visits.redisHost" . }}:6379,abortConnect=false'
```

For a release called `visits` this renders as `value: "visits-redis:6379,abortConnect=false"`.

### values.yaml: the chart's public interface

[values.yaml](samples/containerization/helm/visits/values.yaml) holds the defaults, and doubles as documentation of what can be configured. An excerpt:

```yaml
# Registry prefix for the web and api images, e.g. myregistry.azurecr.io.
# Empty means images built locally (Docker Desktop).
imageRegistry: ""
imagePullPolicy: IfNotPresent

api:
  replicaCount: 3
  image:
    repository: visits-api
    tag: ""                  # defaults to the chart's appVersion
  probes:
    startupProbe:
      httpGet:
        path: /health
        port: 8080
      periodSeconds: 2
      failureThreshold: 15
    readinessProbe:
      httpGet:
        path: /health/ready
        port: 8080
      ...
  autoscaling:
    enabled: false           # needs metrics-server (included on AKS)
    minReplicas: 3
    maxReplicas: 10
    targetCPUUtilizationPercentage: 70

redis:
  persistence:
    enabled: true            # false = emptyDir, data lost when the pod is replaced
    size: 1Gi
    storageClass: ""         # empty = cluster default
```

### Swapping in the TypeScript / Node API

In Kustomize this needed a JSON patch. In Helm it is a small values file, [values-node.yaml](samples/containerization/helm/visits/values-node.yaml):

```yaml
api:
  image:
    repository: visits-api-node
  env:
    ConnectionStrings__Redis: null   # null removes a key inherited from values.yaml
    REDIS_URL: 'redis://{{ include "visits.redisHost" . }}:6379'
```

Values files are **deep-merged** with the defaults. Maps merge key by key, but **lists are replaced entirely**, which is a reason to prefer maps for things like environment variables, as here. Setting a key to `null` deletes an inherited key.

### Optional resources: the HPA and Redis persistence

[api-hpa.yaml](samples/containerization/helm/visits/templates/api-hpa.yaml) is wrapped in an `if`, so it only exists when it is turned on:

```yaml
{{- if .Values.api.autoscaling.enabled }}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ include "visits.fullname" . }}-api
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ include "visits.fullname" . }}-api
  minReplicas: {{ .Values.api.autoscaling.minReplicas }}
  maxReplicas: {{ .Values.api.autoscaling.maxReplicas }}
  ...
{{- end }}
```

[redis.yaml](samples/containerization/helm/visits/templates/redis.yaml) switches between a PersistentVolumeClaim and a throwaway `emptyDir`:

```yaml
      volumes:
        - name: data
          {{- if .Values.redis.persistence.enabled }}
          persistentVolumeClaim:
            claimName: {{ include "visits.fullname" . }}-redis
          {{- else }}
          emptyDir: {}
          {{- end }}
```

The PVC also carries `helm.sh/resource-policy: keep`, so `helm uninstall` does not delete the data. This is a deliberate safety net for stateful resources.

### Rolling restarts on config change

A common gotcha with plain manifests is that changing a ConfigMap does **not** restart the pods using it, so nginx would keep its old config. The standard Helm fix is to put a hash of the config into the pod template's annotations ([web.yaml](samples/containerization/helm/visits/templates/web.yaml)):

```yaml
  template:
    metadata:
      annotations:
        # Changes whenever the nginx config changes, which triggers a rolling restart
        checksum/config: {{ include (print $.Template.BasePath "/web-configmap.yaml") . | sha256sum }}
```

The nginx config is also templated. It points at the release's API service, rather than at a hard-coded `api`:

```nginx
location /api/ {
    proxy_pass http://{{ include "visits.fullname" . }}-api:{{ .Values.api.service.port }};
}
```

### Per-environment values: AKS

[values-aks.yaml](samples/containerization/helm/visits/values-aks.yaml) shows what a production overrides file looks like. It only contains differences from the defaults:

```yaml
imageRegistry: myregistry.azurecr.io

api:
  image:
    tag: "1.4.2"
  resources:
    requests:
      cpu: 250m
      memory: 256Mi
    limits:
      memory: 512Mi
  autoscaling:
    enabled: true
    minReplicas: 3
    maxReplicas: 20

redis:
  persistence:
    storageClass: managed-csi-premium
    size: 8Gi
```

Rendering with it produces images like `myregistry.azurecr.io/visits-api:1.4.2`, an HPA, no fixed `replicas` on the API, and an AKS premium disk. Nothing in `templates/` changes. (The tags and registry name are placeholders. This file was rendered and linted, not deployed.)

### NOTES.txt and helm test

[NOTES.txt](samples/containerization/helm/visits/templates/NOTES.txt) is a template too. It prints release-specific instructions after each install or upgrade.

[tests/test-connection.yaml](samples/containerization/helm/visits/templates/tests/test-connection.yaml) is a pod with the `helm.sh/hook: test` annotation. `helm test` runs it on demand. It calls the API *through* nginx, so a pass proves all three tiers are wired together. It makes a cheap post-deployment smoke test in a pipeline:

```yaml
metadata:
  name: {{ include "visits.fullname" . }}-test-connection
  annotations:
    helm.sh/hook: test
    helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
spec:
  restartPolicy: Never
  containers:
    - name: wget
      image: busybox:1.37
      command: ["wget", "-qO-", "http://{{ include "visits.fullname" . }}-web:{{ .Values.web.service.port }}/api/visits"]
```

---

## 6. Using the chart

The images need to exist locally first (`docker build` steps in [Kubernetes.md](Kubernetes.md)). The outputs below are from the test run on Docker Desktop.

### Check before deploying

```bash
cd samples/containerization

helm lint ./helm/visits                                   # static checks
helm lint ./helm/visits -f helm/visits/values-aks.yaml    # ... with each values file
helm template visits ./helm/visits -f helm/visits/values-node.yaml   # render to stdout, no cluster needed
helm template visits ./helm/visits -s templates/api.yaml  # render one file
```

`helm template` is the most useful debugging tool. Run it whenever a template changes and read the output.

### Install, test, upgrade, roll back

```bash
kubectl config use-context docker-desktop

# install (or upgrade if it already exists) and wait for readiness
helm upgrade --install visits ./helm/visits -n visits --create-namespace --wait
curl http://localhost:8000/api/visits
# {"visits":1,"servedBy":"visits-api-6d6c7bf6cf-vvzr2"}

helm test visits -n visits
# Phase:          Succeeded

# switch to the Node api - a rolling update, like any other upgrade
helm upgrade visits ./helm/visits -n visits -f helm/visits/values-node.yaml --wait
# REVISION: 2
# API image: visits-api-node:1.0          ← from NOTES.txt

helm history visits -n visits
# REVISION  STATUS      DESCRIPTION
# 1         superseded  Install complete
# 2         superseded  Upgrade complete
# 3         deployed    Upgrade complete

helm rollback visits 1 -n visits --wait   # whole application back to revision 1 (.NET api)
helm get values visits -n visits          # the values the current revision was installed with
helm get manifest visits -n visits        # the exact YAML that was applied

helm uninstall visits -n visits
# These resources were kept due to the resource policy:
# [PersistentVolumeClaim] visits-redis
```

In the test run, revision 3 changed only `api.service.port`. This changed the rendered nginx ConfigMap, so the checksum annotation changed, and Helm rolled the web pods automatically. The rollback to revision 1 restored the .NET API image in one command.

Useful flags for pipelines:

- `--wait` waits until Deployments are ready, so the health checks gate the release.
- `--atomic` (`--rollback-on-failure` in Helm 4) rolls back automatically if the upgrade fails or times out.
- `--timeout 5m` sets how long to wait.
- `--history-max 10` limits how many revisions are stored.

---

## 7. Distributing charts with a registry

Charts are versioned artifacts, just like images, and modern Helm stores them in the **same OCI registries** as container images. That ties together all three guides:

```bash
helm package ./helm/visits                      # → visits-0.1.0.tgz

# Azure Container Registry
az acr login -n myregistry
helm push visits-0.1.0.tgz oci://myregistry.azurecr.io/helm

# GitHub Container Registry
helm push visits-0.1.0.tgz oci://ghcr.io/<org>/charts

# install straight from the registry, pinned to a version
helm upgrade --install visits oci://myregistry.azurecr.io/helm/visits --version 0.1.0 \
  -n visits --create-namespace -f values-aks.yaml
```

Third-party charts are usually installed the same way, or from a classic repository:

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx --version <pinned> -n ingress --create-namespace
```

Charts can also declare **dependencies** in `Chart.yaml`, e.g. a Redis chart, which `helm dependency update` downloads into `charts/`. That is how the hand-written Redis templates here could be replaced with a maintained chart. For production on Azure, though, a managed Azure Cache for Redis is usually the better choice.

---

## 8. Helm in a pipeline

A typical Azure Pipelines deploy stage, after the image has been pushed to ACR:

```yaml
- task: HelmDeploy@0
  inputs:
    connectionType: Azure Resource Manager
    azureSubscriptionEndpoint: 'my-azure-connection'
    azureResourceGroup: 'my-rg'
    kubernetesCluster: 'my-aks'
    namespace: visits
    command: upgrade
    chartType: FilePath
    chartPath: samples/containerization/helm/visits
    releaseName: visits
    valueFile: samples/containerization/helm/visits/values-aks.yaml
    overrideValues: api.image.tag=$(Build.BuildId),web.image.tag=$(Build.BuildId)
    install: true
    waitForExecution: true
    arguments: --atomic --timeout 5m
```

Followed by `helm test visits -n visits` as a smoke test. Equivalent plain CLI steps (`az aks get-credentials` then `helm upgrade --install ...`) work in GitHub Actions or anywhere else.

The alternative is **GitOps**. Argo CD or Flux runs inside the cluster, watches a Git repository (or OCI registry) for chart versions and values, and reconciles the cluster to match. The pipeline then only commits a new image tag and never talks to the cluster directly.

---

## 9. Good practices and pitfalls

- **Never change selector labels after the first install.** A Deployment's `spec.selector` is immutable, and the upgrade fails. Keep them minimal (name, instance, component), as in `visits.selectorLabels`.
- **Do not put secrets in values files committed to Git.** Use Key Vault with the Secrets Store CSI driver, External Secrets, or SOPS / sealed-secrets, and keep only references in values.
- **Version charts properly.** Bump `version` for every template change and `appVersion` for every app release. Pin third-party chart versions (`--version`).
- **Validate values.** A `values.schema.json` makes `helm install` reject typos and wrong types (e.g. `replicaCount: "three"`) before anything is applied.
- **Preview upgrades.** The `helm diff` plugin (`helm diff upgrade ...`) shows what will change, much like a Terraform plan.
- **Do not template everything.** Expose values for what genuinely varies between installs. A value per field makes the chart harder to read than the YAML it replaced. The sample deliberately keeps the rollout strategy and security context fixed.
- **Treat stateful resources carefully.** Use `helm.sh/resource-policy: keep` on PVCs, and be aware that `helm uninstall` deletes everything else immediately.
- **CRDs are special.** Helm installs CRDs from a chart's `crds/` folder but never upgrades or deletes them. Charts like cert-manager document their own upgrade steps.
- **Helm state lives in the cluster** (as Secrets in the release namespace). Deleting the namespace deletes the history. Changing resources by hand with `kubectl` causes drift that the next `helm upgrade` may overwrite.

---

## 10. Where to go next

1. Install the chart locally with `helm upgrade --install` and work through section 6. Then change a value, run `helm template` to see the effect, upgrade, and roll back.
2. Add a `values.schema.json` and try installing with a bad value.
3. Add an optional Ingress template (`ingress.enabled`, `ingress.host`, TLS) and switch `web.service.type` to `ClusterIP` when it is on.
4. Package the chart, push it to ACR as an OCI artifact, and deploy it to an AKS dev cluster from an Azure Pipeline with `--atomic` and `helm test`. That is end-to-end evidence across containers, registries, Kubernetes and pipelines for the promotion pack (Gap task G1 and Task idea 4 in [README.md](README.md)).
5. Write a short decision note for the team on Helm vs Kustomize for in-house services. Explaining that trade-off is good evidence of deep technical understanding.
