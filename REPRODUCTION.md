# Reproduction Guide — MiSArch Energy Sustainability

**Course:** Cloud Native Architecture and Engineering (40103) — TU Berlin, SoSe 2026
**Project:** I — Energy Efficiency & Sustainability on MiSArch (Group 10)
**Author:** Syed Muhammad Bilal (520101)
**Last validated:** 2026-07-26, GKE 1.35.5-gke.1241004 — full path re-run end to end
(0 nodes → `terraform apply` → seed → order placed → invoice confirmed).

> **All shell commands below run from the root of this repository**
> (`infrastructure-k8s`) unless the snippet says otherwise. Sibling repos are
> assumed cloned alongside it, e.g. `../inventory`, `../gateway`, `../load-tests`.

## Repositories

| Repo | URL | Contains |
|---|---|---|
| `infrastructure-k8s` | https://github.com/Bilalsms/infrastructure-k8s | Terraform for all in-cluster resources, seed scripts, dashboards. **Start here.** |
| `gateway` | https://github.com/Bilalsms/gateway | Gateway-Optimized source: JWT-verification cache, HTTP-only OTel, playground off |
| `inventory` | https://github.com/Bilalsms/inventory | `pubSubName` Dapr subscription fix |

Each repo carries a `vanilla` branch (baseline) and `main` (refactored).

## Branches

| Branch | Contents |
|---|---|
| `vanilla` | Baseline MiSArch on stock upstream `:main` images + the measurement stack (Kepler, kube-prometheus, OTel) and the inventory-db replica-set change. No energy refactors. Pins the **stock** inventory image, so it does *not* carry the `pubSubName` fix (§3). |
| `main` | Refactored: `vanilla` + KEDA scale-to-zero, HPA, cluster autoscaler, per-pod right-sizing, patched inventory image, Gateway-Optimized image. |

> **Naming:** the container tag is `cnae-gateway-slim`; the report calls this
> refactor **Gateway-Optimized**. Same artifact, older tag.
>
> **Baseline caveat:** since the `pubSubName` fix is pinned only on `main`, the
> branches differ by that correctness patch in addition to the energy refactors.
> On `vanilla` the checkout saga cannot complete, so S1/S2 there exercise
> browse/cart traffic only.

Switching baseline ↔ refactored is just `git checkout <branch> && terraform apply`:
the image tags and refactor `.tf` files (`keda.tf`, `keda-scaledobjects.tf`,
`hpa.tf`, right-sized `requests`/`limits`) are tracked per branch.

---

## 0. Prerequisites

### Local tools

| Tool | Tested version | Used for |
|---|---|---|
| `terraform` | 1.9+ | Provisioning all K8s resources |
| `kubectl` | matching GKE minor | Live cluster operations |
| `gcloud` (with `gke-gcloud-auth-plugin`) | latest | Cluster creation + IAM |
| `helm` | 3.14+ | Some chart inspection (TF wraps it) |
| `docker` (with `buildx`) | latest | Cross-arch image builds (Apple Silicon → amd64) |
| `k6` | 0.50+ | Load testing |
| `python` 3.10+ | system | Seed scripts |
| `jq` | latest | Metric post-processing |

Install on macOS:

```bash
brew install terraform kubectl google-cloud-sdk helm docker k6 jq
brew install --cask docker            # for the Docker daemon, not just the CLI
gcloud components install gke-gcloud-auth-plugin
```

### GCP project

```bash
gcloud auth login
gcloud config set project <your-project-id>
gcloud services enable container.googleapis.com
gcloud services enable compute.googleapis.com
gcloud services enable artifactregistry.googleapis.com
```

---

## 1. Create the GKE cluster

The cluster is **not** managed by Terraform in this repo (the TF here manages
in-cluster resources only). Create it with `gcloud`:

```bash
gcloud container clusters create misarch \
  --zone=europe-west1-b \
  --num-nodes=2 \
  --machine-type=e2-standard-8 \
  --release-channel=stable

# Pull credentials into kubeconfig
gcloud container clusters get-credentials misarch --zone=europe-west1-b
```

**Why europe-west1-b**: lowest grid-carbon-intensity region in GCP Europe
(see Google's per-region intensity report).

### Reserve a static external IP

```bash
gcloud compute addresses create misarch-ingress \
  --region=europe-west1
gcloud compute addresses describe misarch-ingress \
  --region=europe-west1 --format='value(address)'
```

Take note of the IP — you'll reference it as `<IP>.nip.io` for ingress
hostnames. Our deployment used `35.210.206.80`.

### Note the node-pool name

Every later command that resizes or autoscales the cluster needs the **node-pool
name**, which is *not* `default-pool` in our deployment:

```bash
gcloud container node-pools list --cluster=misarch --zone=europe-west1-b
# our deployment: e2-pool
export POOL=e2-pool
```

**Why:** `gcloud container clusters create --num-nodes` names the pool
`default-pool`, but this cluster's pool is `e2-pool`. Passing the wrong name
fails with `node pool "default-pool" not found` — substitute your own name
throughout §7.

### Enable cluster autoscaler (part of the A2 refactor)

```bash
gcloud container clusters update misarch \
  --zone=europe-west1-b \
  --enable-autoscaling \
  --min-nodes=1 --max-nodes=2 \
  --node-pool=$POOL
```

---

## 2. Bootstrap Terraform

```bash
# Copy or create your tfvars from the latest-deployment.tfvars template
cp latest-deployment.tfvars.example latest-deployment.tfvars   # if present
# Edit: GCP_PROJECT, KUBERNETES_CONFIG_PATH, MISARCH_INGRESS_BASE_HOST, image tags

terraform init
terraform apply -auto-approve -var-file=latest-deployment.tfvars
```

This will provision (in order):

1. `misarch` namespace
2. Ingress-nginx + cert-manager + **self-signed** ClusterIssuer (`selfsigned-cluster`)
3. Dapr operator + control plane
4. All databases (8 Postgres + 8 Mongo + InfluxDB + Redis + RabbitMQ + MinIO)
5. Keycloak + bootstrap admin secret
6. 22 MiSArch microservices + their Dapr sidecars
7. KEDA operator + the experiment-config ScaledObject
8. kube-prometheus-stack (Prometheus + Grafana + Alertmanager) + Kepler exporter
9. Two Grafana dashboards (Kepler default + our custom CNAE energy dashboard)
10. 5 HPAs on hot-path services (catalog, inventory, order, payment, shoppingcart)

**Expected time:** ~12 minutes from clean cluster. Subsequent applies: ~2 min.

### Re-deploying over an existing cluster (namespace was deleted)

If you are rebuilding after `kubectl delete namespace misarch` (rather than on a
brand-new cluster), four **cluster-scoped** resources survive the namespace
deletion and make the next `terraform apply` fail with `already exists`. Delete
them first:

```bash
kubectl delete clusterrole misarch-chaostoolkit-executor otel-collector-prometheus-sd --ignore-not-found
kubectl delete clusterrolebinding misarch-chaostoolkit-executor-binding otel-collector-prometheus-sd --ignore-not-found
```

**Why:** ClusterRoles/Bindings are not namespaced, so `delete namespace` leaves
them behind while Terraform's state still expects to create them. `redeploy.sh`
performs this cleanup automatically — this manual step is the equivalent when
running a plain `terraform apply`.

Dapr's 5 CRDs and the `dapr-sidecar-injector` webhook also survive. Both are
harmless: Helm adopts existing CRDs, and the webhook is `failurePolicy: Ignore`,
so a missing injector backend never blocks pod admission.

> **This `Ignore` policy is exactly why sidecars go missing silently** (issue 4):
> when the injector is unavailable, pods are admitted **without** `daprd` instead
> of being rejected. Always run the audit in issue 4 after a mass restart.

### Known issue 1 — apply hangs on Dapr CRDs

The first apply sometimes fails because Dapr's CRDs are not yet registered
when a `kubectl_manifest` resource depending on them runs. The `kubectl`
provider has `apply_retry_count = 15` set in `main.tf`, which usually masks
this — if it doesn't, just re-run `terraform apply`.

### Known issue 2 — `cnae-energy-dashboard` "already exists"

If you tested the dashboard ConfigMap with `kubectl apply -f -` before
`terraform apply`, TF doesn't know about it and fails with
`configmaps "cnae-energy-dashboard" already exists`. Fix:

```bash
terraform import -var-file=latest-deployment.tfvars \
  kubernetes_config_map.cnae_energy_dashboard misarch/cnae-energy-dashboard
terraform apply -auto-approve -var-file=latest-deployment.tfvars
```

The same pattern applies to `kubernetes_service.inventory_db_shim`:

```bash
terraform import -var-file=latest-deployment.tfvars \
  kubernetes_service.inventory_db_shim misarch/inventory-db
```

### Known issue 3 — experiment-executor PVC ReadWriteOnce + RollingUpdate

`misarch-experiment-executor` mounts a single ReadWriteOnce PVC. Default
`RollingUpdate` strategy spawns a second pod that fails Multi-Attach. The
deployment therefore sets `strategy.type = "Recreate"` in
`misarch-experiment-exectuor.tf`, so a clean `terraform apply` already
produces the correct strategy — no manual patch is needed.

**MinIO hits the same failure and is *not* covered by that fix.** After any
mass restart, `minio` can sit in `ContainerCreating` for 10+ minutes with:

```
Multi-Attach error for volume "pvc-..." Volume is already used by pod(s) minio-<old>
```

The old pod still holds the ReadWriteOnce volume, so the new one can never
attach — it will not resolve on its own. Delete the **old** pod to release it:

```bash
kubectl -n misarch get pods | grep minio      # identify old (Running) vs new (ContainerCreating)
kubectl -n misarch delete pod <old-minio-pod>
```

**Why:** if you ever see the executor stuck `Pending` on a Multi-Attach
volume error after a manual `kubectl edit`, re-assert the committed state
with `terraform apply` (or the one-off patch below) to restore `Recreate`:

```bash
kubectl -n misarch patch deploy misarch-experiment-executor \
  -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}'
```

---

## 2b. Trust the self-signed certificates (do this before anything else)

cert-manager issues **self-signed** certificates (`CERT_ISSUER =
"selfsigned-cluster"`; Let's Encrypt was dropped because `nip.io` hosts hit LE
rate limits). Browsers reject every HTTPS origin until each is accepted
**individually**. Visit all five and click through the warning (Chrome:
*Advanced → Proceed*; Firefox: *Advanced → Accept the Risk*):

| # | URL | Why it must be accepted separately |
|---|---|---|
| 1 | `https://misarch.<IP>.nip.io/` | Storefront SPA |
| 2 | `https://api.misarch.<IP>.nip.io/graphql` | GraphQL gateway — the SPA calls this |
| 3 | `https://auth.misarch.<IP>.nip.io/` | Keycloak — login redirects here |
| 4 | `https://grafana.misarch.<IP>.nip.io/` | Energy dashboards |
| 5 | `https://prometheus.misarch.<IP>.nip.io/` | Raw metric queries |

**Why separately:** a trust exception is scoped to one **origin**. Accepting
only the storefront leaves the SPA's calls to `api.` and `auth.` blocked, and
the browser shows **no second warning** — they just fail. Symptoms: storefront
loads but lists no products, infinite spinner, or login bouncing back. This
looks exactly like a broken deployment and is the most common false alarm here.
If the UI misbehaves, check devtools → Network for failed `api.`/`auth.`
requests before debugging the cluster.

CLI: use `curl -k`. Seed scripts are unaffected — they use plain HTTP via
`portforward.sh` (§4).

---

## 2c. Dashboard credentials

The Grafana and Prometheus UIs are both password-protected. Neither password is
printed by `terraform apply`, so retrieve them as follows.

**Grafana** (`https://grafana.<IP>.nip.io`) — user `admin`. The password comes
from the kube-prometheus-stack chart default and is also referenced in
`configmaps.tf` as `GRAFANA_ADMIN_PASSWORD`:

```bash
kubectl -n misarch get secret prometheus-stack-grafana \
  -o jsonpath='{.data.admin-user}' | base64 -d; echo
kubectl -n misarch get secret prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
# default: admin / prom-operator
```

**Prometheus** (`https://prometheus.<IP>.nip.io`) — user `admin`, protected by
an nginx basic-auth Secret whose password is a Terraform-generated
`random_password`. The Secret stores only the bcrypt hash, so read the
plaintext from the Terraform output:

```bash
terraform output -raw prometheus_basic_auth_password; echo
```

**Why the output and not the Secret:** `kubernetes_secret.prometheus_basic_auth`
holds `admin:<bcrypt>` for nginx, which is one-way — the plaintext exists only in
Terraform state. The value is stable across applies (`ignore_changes` pins the
hash, because `bcrypt()` is non-deterministic and would otherwise rewrite the
Secret on every run).

> The Grafana password is the chart default. Fine for a short-lived measurement
> cluster behind a self-signed cert, but set `grafana.adminPassword` in
> `prometheus.tf` before exposing this deployment anywhere real.

---

## 2d. Fix Keycloak CORS (required — login is dead without it)

**Symptom:** the storefront loads, but clicking **Login does nothing at all** —
no redirect, no error, no Keycloak page. The browser console shows a blocked
cross-origin request to `auth.misarch.<IP>.nip.io`.

**Cause:** the realm template ships the `frontend` client with an **empty
`webOrigins`** list. This deployment is *split-origin* — the SPA is served from
`misarch.<IP>.nip.io` while Keycloak lives on `auth.misarch.<IP>.nip.io` — so
every keycloak-js call is cross-origin. With no allowed web origin the browser
blocks the CORS preflight and the SPA's login handler fails silently. A
permissive `redirectUris` does **not** help: redirect URIs and web origins are
enforced independently.

**Fix** — run the helper script. It resolves the ingress IP, reads the admin
credentials from the cluster, patches the client, and verifies the result:

```bash
./fix-keycloak-cors.sh                 # auto-detects the ingress IP
./fix-keycloak-cors.sh 35.210.206.80   # or pass it explicitly
```

Expected tail of the output:

```
==> Verifying CORS preflight from https://misarch.<IP>.nip.io ...
    OK  access-control-allow-origin: https://misarch.<IP>.nip.io
CORS fixed. The Login button will now reach Keycloak.
```

The script is idempotent (safe to re-run), exits non-zero if the preflight does
not come back correct, and honours `NAMESPACE`, `REALM` and `CLIENT_ID` env
overrides. Run it **after every fresh `terraform apply`** — the realm is
re-imported with empty `webOrigins` each time.

<details>
<summary>Manual equivalent, if you prefer not to run the script</summary>

```bash
IP=<your-ingress-ip>
U=$(kubectl -n misarch get secret keycloak-bootstrap -o jsonpath='{.data.KEYCLOAK_ADMIN}' | base64 -d)
P=$(kubectl -n misarch get secret keycloak-bootstrap -o jsonpath='{.data.KEYCLOAK_ADMIN_PASSWORD}' | base64 -d)
K=/opt/keycloak/bin/kcadm.sh
L="$K config credentials --server http://localhost:8080/keycloak --realm master --user '$U' --password '$P' >/dev/null"

CID=$(kubectl -n misarch exec deploy/keycloak -c keycloak -- sh -c \
  "$L; $K get clients -r Misarch -q clientId=frontend --fields id --format csv --noquotes")

kubectl -n misarch exec deploy/keycloak -c keycloak -- sh -c \
  "$L; $K update clients/$CID -r Misarch \
     -s 'webOrigins=[\"https://misarch.$IP.nip.io\",\"https://api.misarch.$IP.nip.io\"]' \
     -s 'redirectUris=[\"https://misarch.$IP.nip.io/*\"]'"

# verify — must echo the shop origin back
curl -sk -X OPTIONS "https://auth.misarch.$IP.nip.io/keycloak/realms/Misarch/protocol/openid-connect/token" \
  -H "Origin: https://misarch.$IP.nip.io" -H "Access-Control-Request-Method: POST" -D- -o /dev/null \
  | grep -i access-control-allow-origin
```

</details>

> **Note the Keycloak base path.** Keycloak is served under **`/keycloak`**, not
> the bare host: use `https://auth.misarch.<IP>.nip.io/keycloak/realms/Misarch`.
> Requests to `/realms/...` return 404 and look like a broken realm import.

> **Login still fails after this fix until §4 has run.** The `test` user is
> created by `seed.py`, not by Terraform. Between §2 and §4 the login page
> appears but every credential is rejected with `invalid_grant` — expected, not
> a fault.

---

## 3. Build the patched inventory image

The upstream inventory image (`ghcr.io/misarch/inventory:*`) ships with a
Dapr pubsub key typo (`pubsubname` lowercase) that silently drops every
event. Without the fix, `createProductItemBatch` returns "ProductVariant
not found" and checkout never works.

Authenticate to Artifact Registry once:

```bash
gcloud artifacts repositories create misarch \
  --location=europe-west1 --repository-format=docker
gcloud auth configure-docker europe-west1-docker.pkg.dev
```

Build + push (must be `--platform linux/amd64` if building on Apple Silicon):

```bash
cd ../inventory       # the patched inventory repo, cloned alongside this one
docker buildx build \
  --platform linux/amd64 \
  -t europe-west1-docker.pkg.dev/<gcp-project>/misarch/inventory:cnae-pubsubname-fix \
  --push .
```

The image tag is already pinned in `misarch-inventory.tf` (search for
`cnae-pubsubname-fix`; it sits under the `// Upstream image ... ships with a Dapr
pubsub key typo` comment). **Don't revert it until the upstream PR lands.**

---

## 4. Seed catalog + checkout prerequisites

Two-script seed in two terminals. **Terminal A** runs port-forwards:

```bash
cd seed
./portforward.sh
```

**Terminal B** runs the seeders. Create the venv from the pinned
`requirements.txt` (the scripts' only third-party dependency is `requests`;
the file pins its transitive closure so a reproduction resolves identical
versions):

```bash
cd seed
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

Then run **all three scripts, in this order**:

```bash
# 1. Catalog + tax + media (~5 min)
python3 seed.py

# 2. Replicate catalog IDs into the downstream service mirrors (~30 s)
python3 sync_mirrors.py

# 3. Checkout prerequisites: shipment method + test-user address +
#    credit-card payment-info + 100 stock units per variant (~30 s)
python3 seed_checkout.py seed
```

> **All three are mandatory — `seed.py` alone leaves a broken storefront.**
> `seed.py` only populates catalog/tax/MinIO. Skipping the other two produces
> symptoms that look like bugs but are missing data:
>
> | Skipped | Symptom |
> |---|---|
> | `sync_mirrors.py` | Add-to-wishlist and add-to-cart fail; services hold catalog mirrors that do not contain the new product IDs, so they report the products as non-existent. |
> | `seed_checkout.py` | Every product shows **out of stock** (`inventory.productItems` is empty) and checkout cannot start. |
>
> **Verify before moving on** — both must be non-zero:
>
> ```bash
> kubectl -n misarch exec inventory-db-0 -c mongodb -- mongosh --quiet --eval \
>   'print(db.getSiblingDB("inventory").productItems.countDocuments({}))'   # expect 100 x variants
> ```

`seed_checkout.py` auto-pulls `KEYCLOAK_ADMIN_PASSWORD` from the
`keycloak-bootstrap` Secret via `kubectl`. Override with
`KEYCLOAK_ADMIN_PASSWORD=<pw>` if you want to.

### Known issue 4 — Dapr sidecar admission flakiness

> **Worst case is scale-from-zero, not a normal apply.** Restarting a node pool
> from 0 nodes restarts the `dapr-sidecar-injector` at the same time as every
> workload, so it is unavailable while pods are being admitted. On our
> 2026-07-26 cold start this cost **16 of 20** Dapr-enabled pods their sidecar
> at once. **Always run the audit below after any scale-from-zero, before
> seeding or measuring** — do not assume a green `kubectl get pods` means the
> mesh is healthy, because a pod missing `daprd` still reports `Running`.

The GKE Dapr webhook occasionally misses sidecar injection on a few pods
after cluster restart or churn. Affected pods show `READY 2/2` (app +
ECS) instead of `3/3` (app + ECS + daprd). Federated GraphQL queries
then fail with `Unexpected empty "data" and "errors" fields`. Detect:

```bash
kubectl -n misarch get pods -o json | python3 -c "
import json, sys
for p in json.load(sys.stdin)['items']:
  n = p['metadata']['name']
  if not n.startswith('misarch-'): continue
  cs = [c['name'] for c in p['spec']['containers']]
  enabled = p['metadata'].get('annotations',{}).get('dapr.io/enabled','') == 'true'
  if enabled and 'daprd' not in cs:
    print(f'  MISSING daprd: {n}')
"
```

Fix by rollout-restarting each missing service:

```bash
kubectl -n misarch rollout restart deploy/<name>
```

### Known issue 5 — `seed.py reset` is incomplete

`seed.py reset` only wipes catalog, tax, and MinIO. Every other service
(inventory, shoppingcart, order, payment, wishlist, review) keeps its
local Dapr-replicated mirror, which becomes stale after a re-seed. Full
reset sequence:

```bash
# 1. catalog + tax + MinIO
python3 seed.py reset
# 2. wipe all downstream mirrors
kubectl -n misarch exec shoppingcart-db-... -c mongodb -- mongosh --quiet \
  --eval 'db.getSiblingDB("shoppingcart-database").dropDatabase()'
# (repeat for inventory, order, payment, wishlist, review)
# 3. re-seed catalog
python3 seed.py
# 4. bounce gateway so Mesh re-introspects subgraphs
kubectl -n misarch rollout restart deploy/misarch-gateway
# 5. clear frontend localStorage in browser (use incognito window)
# 6. re-seed checkout
python3 seed_checkout.py seed
# 7. backfill user mirror in shoppingcart-db (test user predates current Dapr)
# (see memory/cnae_misarch_reset_semantics.md for the exact insert)
```

Worth one paragraph in the report's Discussion — this is the
distributed-monolith anti-pattern in action.

---

## 5. Validate end-to-end

In a third terminal:

```bash
cd ../load-tests
./mint-token.sh       # writes .auth-token, valid ~1 h

# Single-iteration saga: addToCart → createOrder → placeOrder
../scripts/debug/checkout-debug.sh
```

Expected output: three JSON responses, the last with
`"orderStatus": "PLACED"`. If you see any errors, follow the
"Known issue" sections above before re-running.

### Storefront UI smoke test

Open `https://misarch.<IP>.nip.io/` in an **incognito window** (browser
cache pinning old product IDs is the #1 source of false alarms).
Confirm: product list with images, sign-in with `test`/`test`, add-to-
cart, checkout.

---

## 6. Run the energy baseline

### Vanilla baseline (before refactor)

```bash
cd ../load-tests
caffeinate -i ./run-baseline.sh vanilla
# OR background:
nohup ./run-baseline.sh vanilla > /tmp/baseline-vanilla.log 2>&1 &
```

Duration: ~80 min (S0 idle 20 min + 5 min stabilize + S1 normal 30 min
+ 5 min stabilize + S2 peak 20 min + metric pulls). Run dir lands in
`runs/<UTC-timestamp>-vanilla/`.

### Refactored baseline (after A2 + right-size + HPA)

```bash
nohup ./run-baseline.sh refactored > /tmp/baseline-refactored.log 2>&1 &
```

Same shape, `-refactored` suffix.

### Reading the results

```bash
cat runs/<timestamp>-refactored/SUMMARY.txt
```

Three rows for S0/S1/S2, each showing iterations, http_reqs, error
percentage, p95 latency, check-pass percentage. The companion
`kepler-power-per-pod-*.json` files contain the per-pod Watt data — see
`projects/data/rightsize.py` for the comparison script.

### Known issue 6 — measurement timezone

Early runs recorded `SUMMARY.txt` and the run-directory name in local
wall-clock time, which silently broke direct Prometheus queries (we lost
2 h analysing the wrong windows). `run-baseline.sh` now logs UTC
throughout, and run directories are named with a trailing `Z` (e.g.
`2026-06-30_20-55-07Z-gateway-slim-r1`) to make this explicit. If you
inherit an older run without the `Z` suffix, treat its directory name as
local time; the per-run JSON metric files carry absolute epoch
timestamps and are always correct regardless.

---

## 6a. Reproduction video — recording checklist

The submitted video must be **≤ 5 minutes, uncut** (speed up long waits, do
not edit out steps) and must show *deploy → a basic working scenario → the
refactoring change*. No narration is required. Record the following linear
sequence; the bracketed items are the ones a grader must actually see happen.

1. **Deploy** *(speed up ~10×)*
   - `terraform apply` against a clean cluster (§2). Let the terminal scroll;
     the point is to show it is IaC-driven and hands-off.
   - `kubectl -n misarch get pods` settling to all-Running. **[all pods Ready]**
2. **System works — basic scenario** *(real time)*
   - `./scripts/debug/checkout-debug.sh` → three JSON responses ending in
     `"orderStatus": "PLACED"`. **[PLACED]**
   - Storefront in an incognito window: product list with images → sign in
     `test`/`test` → add to cart → checkout. **[order confirmed in UI]**
3. **The change is live** *(real time)*
   - `kubectl -n misarch get scaledobject,hpa` — show KEDA + HPA present.
   - `kubectl -n misarch get deploy misarch-experiment-config` at `0/0`
     replicas (KEDA scale-to-zero). **[0 replicas]**
   - `kubectl -n misarch get deploy misarch-gateway -o jsonpath=…` showing the
     Gateway-Optimized image (tag `cnae-gateway-slim`) and
     `NODE_OPTIONS=--max-old-space-size=512`. **[refactored image]**
   - Optional 5-second proof the playground is gone:
     `curl -sk https://api.misarch.<IP>.nip.io/graphql` → returns JSON
     `"Must provide query string."`, not the GraphiQL UI. **[playground off]**
4. **The change measured** *(speed up the run, show the result live)*
   - Kick off `./run-baseline.sh` (or open the pre-recorded run dir) and show
     the Grafana **CNAE energy dashboard** with per-pod Watts / CO₂e panel.
     **[gateway pod power lower under load vs. the vanilla panel]**

**Why this order:** it mirrors the three things the email asks the video to
prove — that the system deploys, that it runs, and that the refactor is real
and has the claimed effect — in the shortest path that shows each without
cuts. Do a dry run first; a full deploy exceeds 5 min, so pre-stage the
cluster and screen-record only the `apply` + verification, then splice in a
sped-up capture of the settling wait.

**Before you hit record:** accept all five self-signed certificates (§2b) in the
browser profile you are recording with. Otherwise the storefront will load
empty on camera and the take is wasted. Also run the Dapr audit (issue 4)
so the mesh is healthy before the first shot.

---

## 7. Cluster shutdown / restart (cost saving)

To stop GCP billing without losing state:

```bash
# Scale node pool to 0 (use your real pool name from §1 — ours is e2-pool)
gcloud container clusters update misarch \
  --zone=europe-west1-b --node-pool=$POOL \
  --no-enable-autoscaling
gcloud container clusters resize misarch \
  --zone=europe-west1-b --node-pool=$POOL --num-nodes=0 --quiet
# (Autoscaler must be off first: min-nodes=1 forbids scaling to zero.)
```

To restart — **this is a 4-step procedure, not a one-liner.** Persistent
volumes survive and pods are recreated automatically, but they do **not** come
back healthy on their own (measured 2026-07-26: ~17 min to green):

```bash
# 1. Bring the nodes back (~2-3 min). Use your real pool name (§1).
gcloud container clusters resize misarch \
  --zone=europe-west1-b --node-pool=$POOL --num-nodes=2 --quiet

gcloud container clusters get-credentials misarch --zone=europe-west1-b

# 2. Wait for pods to reconcile (~5 min)
kubectl -n misarch get pods -w      # ctrl-C when churn stops

# 3. MANDATORY — audit for pods that lost their Dapr sidecar (see issue 4).
#    Expect many after a scale-from-zero.
kubectl -n misarch get pods -o json | python3 -c 'import sys,json;d=json.load(sys.stdin);print("\n".join(p["metadata"]["name"] for p in d["items"] if p["metadata"].get("annotations",{}).get("dapr.io/app-id") and "daprd" not in [c["name"] for c in p["spec"]["containers"]]) or "none missing")'

#    For every name printed:
kubectl -n misarch rollout restart deploy/<name>
#    Re-run the audit until it prints "none missing".

# 4. If minio sticks in ContainerCreating, clear the RWO volume (see issue 3):
kubectl -n misarch delete pod <old-minio-pod>
```

Finally, confirm the app really works — a green pod list is not proof:

```bash
curl -sk -X POST https://api.misarch.<IP>.nip.io/graphql \
  -H 'Content-Type: application/json' \
  -d '{"query":"{ products(first:3){ totalCount nodes{ id } } }"}'
# expect a non-zero totalCount and real product IDs
```

**Prometheus retention warning**: the kube-prometheus-stack TSDB is
ephemeral (no PV by default). All historical metrics are lost on
node-pool scale-to-zero. Run a fresh baseline after every restart if
you need pre-restart-comparable numbers. The per-run JSON files are
persistent and unaffected.

---

## 8. Cost reference

Actual spend measured for one 30-day billing period on this project
(europe-west1, 2× e2-standard-8, GKE Standard, June 2026):

| Component | Actual (€) | % | Notes |
|---|---|---|---|
| **Compute Engine** (2× e2-standard-8 nodes) | **188.40** | 66 % | Sustained-use discount applied automatically |
| **Kubernetes Engine** (control-plane fee) | **62.26** | 22 % | $0.10/hr = ~€60/month per cluster. Fixed overhead independent of workload. |
| **Networking** (regional L4 LB + egress + IPs) | 23.60 | 8 % | Nginx-ingress LB dominates; egress from metric pulls is small |
| **Cloud Monitoring** (metrics ingest above free tier) | 12.53 | 4 % | Kepler + Prom + cAdvisor push a lot of custom series |
| **Cloud Logging** | 0 | 0 % | 50 GB/month free tier held for this workload |
| **Artifact Registry storage** (custom images) | ~1 | <1 % | 3-4 gateway/inventory image versions × ~200 MB |
| **Total** | **€286.79** | 100 % | ≈ US$ 310 |

Node cost alone (~US$ 180) under-estimates by ~1.7×: the control-plane fee,
Monitoring ingest and LB lines are invisible in a "cost per VM-hour" model.

- **Always-on:** ≈ €9.60/day. **Nodes at 0** (§7): ≈ €2.50/day, almost all
  control-plane fee — that fee stops only if the cluster is deleted.
- Student credits last ~30 days here. Set a Budget alert at 90 % with
  "Disable billing" to protect the card once credits run out.
