# MiSArch seed scripts

Two Python scripts seed the cluster with reproducible test data. Both talk to
the GraphQL gateway (`api.misarch.<reserved-ip>.nip.io`) and Keycloak
(`auth.misarch.<reserved-ip>.nip.io`), using `portforward.sh` for local runs
or the public ingress in CI.

## Setup (run first)

Create a virtualenv and install the pinned dependencies from
[`requirements.txt`](./requirements.txt) before running any script below (the
scripts' only third-party dependency is `requests`; the file pins its
transitive closure so a reproduction resolves identical versions):

```
cd seed
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

Then start the port-forwards in a separate terminal (`./portforward.sh`) so the
scripts can reach the gateway and Keycloak locally.

## `seed.py` — catalog + tax (upstream)

Vendor seeder. Wipes and re-creates the product catalog, tax rates and MinIO
media bucket.

```
python3 seed.py            # seed
python3 seed.py reset      # wipe (catalog + tax + MinIO only)
```

**Reset is incomplete by design.** Other services (inventory, shoppingcart,
order, payment, wishlist, review) hold local mirrors of catalog data populated
by the *initial* Dapr pubsub stream — `reset` does not clear them, leaving
dangling UUIDs that surface as cascading "X not found" errors on the next
seed. See `memory/cnae_misarch_reset_semantics.md` for the full recovery
sequence (drop downstream Mongo DBs, rollout-restart gateway, etc.).

## `seed_checkout.py` — checkout prerequisites (CNAE)

Project-specific. Adds the data the saga needs but `seed.py` does not provide:

* one shipment method (`dhl-standard`)
* one billing/shipping address for the `test` user
* one credit-card payment-info record for the `test` user
* 100 inventory units per product variant

```
python3 seed_checkout.py seed              # full seed (idempotent)
python3 seed_checkout.py discover          # print discoverable mutation names
python3 seed_checkout.py discover-types K  # describe input types matching K
```

Reuses `seed.py` primitives (`KC_URL`, `GW_URL`, `kc_master_token`, `gql`,
`ensure_seed_user`), so a successful `python3 seed.py` is the precondition.

After running both, `../../scripts/debug/checkout-debug.sh` validates the full
saga end-to-end in one curl chain.

## `sync_mirrors.py` — repopulate downstream Mongo mirrors

Every misarch microservice that needs catalog / user / address / shipment
data keeps a local Mongo mirror, populated by Dapr pubsub events at CREATE
time. There is no event replay: if a downstream mirror is wiped or starts
empty, the only way to repopulate it is to re-emit historical CREATE events,
which the source services don't expose. This is the "distributed-monolith"
anti-pattern documented in `projects/I_misarch_energy_DEEP_ANALYSIS_CLAUDE.md`
§7.

`sync_mirrors.py` bridges that gap. It queries the SOURCES OF TRUTH (catalog
GraphQL, address Postgres, shipment Postgres, Keycloak Admin API) and writes
properly-shaped documents into every downstream Mongo (`shoppingcart-db`,
`inventory-db`, `order-db`, `payment-db`, `wishlist-db`), matching each
service's Rust/Kotlin serde model exactly.

```
python3 sync_mirrors.py
```

Idempotent — uses `replaceOne(upsert)` per document so re-runs are safe.

**Run it whenever:**

* a fresh cluster boot or `seed.py reset` + re-seed
* a Postgres DB wipe (e.g. the path-3 consolidation cutover)
* a service has been scaled to 0 and back, or pubsub events were lost
* a new Keycloak user was created (so their `users` mirror exists everywhere)

The typical post-bootstrap sequence is:

```
python3 seed.py             # catalog + tax + media (source of truth)
python3 seed_checkout.py    # shipment method + address + payment-info + stock
python3 sync_mirrors.py     # repopulate every downstream Mongo from source
```

## Troubleshooting (seen these — don't re-debug them)

- **`seed.py` gets `Query.taxRates requires authentication`** even with a valid token, right after a `terraform apply` / mass restart → **Keycloak lost its `daprd` sidecar.** The gateway verifies JWTs by fetching JWKS through Dapr invoke to keycloak; no daprd → all tokens rejected. Fix: `kubectl -n misarch rollout restart deploy/keycloak`, wait until its pod shows a `daprd` container, retry. It is **not** a TLS/cert issue. Full detail + the "which pod lost daprd" one-liner: `SERVICES.md` §8.1.

- **`uploadMedia: "error sending request"`** during `seed.py` → **misarch-media lost its `daprd` sidecar.** Same fix: restart `deploy/misarch-media`, restart `./portforward.sh` (recreated pod drops the forward), retry.

- **`seed.py reset` → `secrets "tax-db" not found`** → you're on the consolidated Postgres (`misarch-pg-shared`), which deleted the per-service DB secrets. `truncate_postgres()` is now consolidation-aware (routes to `misarch-pg-shared-0` / DB `<svc>_db`), so this is fixed — if you still see it, the shared instance isn't up yet.
