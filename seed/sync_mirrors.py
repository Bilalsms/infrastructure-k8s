#!/usr/bin/env python3
"""
Repopulate the downstream Mongo mirrors of every misarch service whose data
lives on event-pubsub but whose events are NOT replayable.

CONTEXT — why this exists at all:
    Every misarch microservice that needs catalog/user/address/shipment data
    keeps a LOCAL Mongo mirror, populated by Dapr pubsub events at CREATE
    time. There is no event replay: if a downstream service's mirror is
    wiped or starts empty, the only way to repopulate it is to re-emit
    every historical CREATE event — which the source services don't expose.
    This is the "distributed-monolith" anti-pattern documented in
    projects/I_misarch_energy_DEEP_ANALYSIS_CLAUDE.md §7.

    This script bridges that gap by querying the SOURCES OF TRUTH (catalog
    GraphQL, address Postgres, shipment Postgres, Keycloak Admin API) and
    writing properly-shaped documents into every downstream Mongo, matching
    each service's Rust/Kotlin serde model exactly.

    Run after any of:
      * fresh cluster bootstrap
      * `seed.py reset` + re-seed
      * Postgres DB wipe (path-3 consolidation cutover)
      * a service being scaled to 0 and back

USAGE:
    python3 sync_mirrors.py

    Idempotent — uses replaceOne(upsert) per document so re-runs are safe.

DEPENDENCIES:
    Port-forwards from portforward.sh (gateway:8080, keycloak:8081).
    kubectl on PATH (used to read secrets and exec into Mongo pods).
"""
import base64
import json
import os
import subprocess
import sys
from typing import Any

# Same env handling as seed.py
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from seed import GW_URL, http, kc_master_token  # noqa: E402

NAMESPACE = os.environ.get("MISARCH_NAMESPACE", "misarch")
KUBECTL   = os.environ.get("KUBECTL", "kubectl")


# ── kubectl + mongo helpers ────────────────────────────────────────────────
def _k(*args: str, input_: str | None = None) -> str:
    r = subprocess.run([KUBECTL, *args], input=input_, capture_output=True, text=True, check=False)
    if r.returncode != 0:
        sys.exit(f"kubectl {' '.join(args)} failed: {r.stderr.strip()}")
    return r.stdout

def _secret(name: str, key: str) -> str:
    raw = _k("-n", NAMESPACE, "get", "secret", name, "-o", f"jsonpath={{.data.{key}}}").strip()
    return base64.b64decode(raw).decode() if raw else ""

def _mongo_pod(instance: str) -> str:
    return _k("-n", NAMESPACE, "get", "pod",
              "-l", f"app.kubernetes.io/instance={instance}",
              "-o", "jsonpath={.items[0].metadata.name}").strip()

def _mongosh(instance: str, script: str) -> str:
    pod = _mongo_pod(instance)
    return _k("-n", NAMESPACE, "exec", pod, "-c", "mongodb",
              "--", "mongosh", "--quiet", "--eval", script)

def _psql(dbname: str, sql: str) -> str:
    """Run SQL on the shared Postgres and return TSV without headers."""
    pw = _secret("misarch-pg-shared", "postgres-password")
    pod = _k("-n", NAMESPACE, "get", "pod",
             "-l", "app.kubernetes.io/instance=misarch-pg-shared",
             "-o", "jsonpath={.items[0].metadata.name}").strip()
    cmd = ["-n", NAMESPACE, "exec", pod, "-c", "postgresql", "--",
           "env", f"PGPASSWORD={pw}", "psql", "-U", "postgres", "-d", dbname,
           "-A", "-t", "-F", "|", "-c", sql]
    return _k(*cmd)


# ── sources of truth → normalised Python dicts ─────────────────────────────
def fetch_catalog() -> dict[str, Any]:
    """Return product variants + tax rates with full version data."""
    q = """{
      products(first:100){
        nodes {
          variants(first:20){
            nodes {
              id isPubliclyVisible
              currentVersion {
                id retailPrice
                taxRate { id currentVersion { id rate version } }
              }
            }
          }
        }
      }
    }"""
    data = http.post(GW_URL, json={"query": q}).json()["data"]
    variants = []
    tax_rates: dict[str, dict] = {}
    for p in data["products"]["nodes"]:
        for v in p["variants"]["nodes"]:
            cv = v["currentVersion"]
            tr = cv["taxRate"]
            trv = tr["currentVersion"]
            variants.append({
                "id": v["id"], "is_publicly_visible": v["isPubliclyVisible"],
                "version_id": cv["id"], "price": cv["retailPrice"],
                "tax_rate_id": tr["id"],
            })
            tax_rates[tr["id"]] = {
                "id": tr["id"], "version_id": trv["id"],
                "rate": trv["rate"], "version": trv["version"],
            }
    return {"variants": variants, "tax_rates": list(tax_rates.values())}

def fetch_addresses() -> list[dict]:
    rows = _psql("address_db", "SELECT id || '|' || userid FROM addressentity;").splitlines()
    return [{"id": a, "user_id": u} for line in rows if "|" in line for a, u in [line.strip().split("|")]]

def fetch_shipment_methods() -> list[dict]:
    rows = _psql("shipment_db", "SELECT id FROM shipmentmethodentity;").splitlines()
    return [{"id": r.strip()} for r in rows if r.strip()]

def fetch_keycloak_users() -> list[dict]:
    """Reach Keycloak admin API via port-forwarded localhost:8081."""
    kc_admin_pw = _secret("keycloak-bootstrap", "KEYCLOAK_ADMIN_PASSWORD")
    if not kc_admin_pw:
        sys.exit("KEYCLOAK_ADMIN_PASSWORD secret missing")
    tok_url = "http://localhost:8081/keycloak/realms/master/protocol/openid-connect/token"
    tok = http.post(tok_url, data={
        "grant_type": "password", "client_id": "admin-cli",
        "username": "admin", "password": kc_admin_pw,
    }).json()["access_token"]
    users_url = "http://localhost:8081/keycloak/admin/realms/Misarch/users"
    return http.get(users_url, headers={"Authorization": f"Bearer {tok}"}).json()


# ── per-service mirror layouts (matches each service's Rust/Kotlin model) ──
def js_uuid(s: str) -> str: return f'UUID("{s}")'

def mongo_doc(d: dict[str, Any]) -> str:
    """Render a Python dict as a mongosh literal (UUID-aware)."""
    parts = []
    for k, v in d.items():
        if isinstance(v, dict):
            parts.append(f"{k}: {mongo_doc(v)}")
        elif isinstance(v, list):
            parts.append(f"{k}: [{','.join(mongo_doc(x) if isinstance(x,dict) else json.dumps(x) for x in v)}]")
        elif isinstance(v, bool):
            parts.append(f"{k}: {str(v).lower()}")
        elif isinstance(v, int):
            parts.append(f"{k}: NumberInt({v})")
        elif isinstance(v, float):
            parts.append(f"{k}: {v}")
        elif isinstance(v, str) and v.startswith("UUID("):
            parts.append(f"{k}: {v}")
        else:
            parts.append(f"{k}: {json.dumps(v)}")
    return "{" + ",".join(parts) + "}"

def upsert_docs(instance: str, db_name: str, collection: str, docs: list[dict]) -> None:
    """Upsert each doc by _id (idempotent)."""
    if not docs:
        print(f"  {instance}.{db_name}.{collection}: nothing to upsert"); return
    ops = ",".join(
        f"{{ replaceOne: {{ filter: {{ _id: {d['_id']} }}, replacement: {mongo_doc(d)}, upsert: true }} }}"
        for d in docs
    )
    script = (
        f"const db_=db.getSiblingDB('{db_name}');"
        f"const r=db_.{collection}.bulkWrite([{ops}], {{ordered:false}});"
        f"print('  {instance}.{collection}: upserted=' + (r.upsertedCount + r.modifiedCount) + ' total=' + db_.{collection}.countDocuments());"
    )
    print(_mongosh(instance, script).strip())


def main() -> None:
    print("→ Querying sources of truth")
    catalog = fetch_catalog()
    addresses = fetch_addresses()
    shipment_methods = fetch_shipment_methods()
    users = fetch_keycloak_users()
    print(f"  catalog: {len(catalog['variants'])} variants, {len(catalog['tax_rates'])} tax_rates")
    print(f"  addresses: {len(addresses)}, shipment_methods: {len(shipment_methods)}, users: {len(users)}")

    # Pre-compute per-service docs
    # ProductVariantVersion is embedded as nested doc inside ProductVariant
    pv_full = [{
        "_id": js_uuid(v["id"]),
        "current_version": {
            "_id": js_uuid(v["version_id"]),
            "price": v["price"],
            "tax_rate_id": js_uuid(v["tax_rate_id"]),
        },
        "is_publicly_visible": v["is_publicly_visible"],
    } for v in catalog["variants"]]
    pvv = [{
        "_id": js_uuid(v["version_id"]),
        "price": v["price"],
        "tax_rate_id": js_uuid(v["tax_rate_id"]),
    } for v in catalog["variants"]]
    tr = [{
        "_id": js_uuid(t["id"]),
        "current_version": {
            "_id": js_uuid(t["version_id"]),
            "rate": t["rate"],
            "version": t["version"],
        },
    } for t in catalog["tax_rates"]]
    trv = [{
        "_id": js_uuid(t["version_id"]),
        "rate": t["rate"],
        "version": t["version"],
    } for t in catalog["tax_rates"]]

    user_docs_minimal = [{"_id": js_uuid(u["id"]), "user_address_ids": []} for u in users]
    user_addr_docs = [{"_id": js_uuid(a["id"]), "user_id": js_uuid(a["user_id"])} for a in addresses]
    ship_docs = [{"_id": js_uuid(s["id"])} for s in shipment_methods]

    # shoppingcart-db: users with cart, product_variants (flat)
    print("\n→ shoppingcart")
    sc_users = [{
        "_id": js_uuid(u["id"]),
        "shoppingcart": {"last_updated_at": "new Date()", "internal_shoppingcart_items": []},
    } for u in users]
    # Bypass datetime serialization (mongo Date literal):
    for d in sc_users:
        d["shoppingcart"]["last_updated_at"] = "DATE_NOW"
    # Inject Date() into the script via a sentinel replace
    upsert_docs("shoppingcart-db", "shoppingcart-database", "product_variants",
                [{"_id": js_uuid(v["id"]), "current_version": js_uuid(v["version_id"])} for v in catalog["variants"]])
    # users with the Date sentinel — we render then sed in mongosh
    script_sc_users = "const db_=db.getSiblingDB('shoppingcart-database');"
    for u in sc_users:
        d = mongo_doc(u).replace('"DATE_NOW"', 'new Date()')
        script_sc_users += f"db_.users.replaceOne({{_id: {u['_id']}}}, {d}, {{upsert:true}});"
    script_sc_users += "print('  shoppingcart-db.users: total=' + db_.users.countDocuments());"
    print(_mongosh("shoppingcart-db", script_sc_users).strip())

    # inventory-db: product_variants
    print("\n→ inventory")
    upsert_docs("inventory-db", "inventory-database", "product_variants",
                [{"_id": js_uuid(v["id"])} for v in catalog["variants"]])

    # order-db: full graph
    print("\n→ order")
    upsert_docs("order-db", "order-database", "users", user_docs_minimal)
    upsert_docs("order-db", "order-database", "user_addresses", user_addr_docs)
    upsert_docs("order-db", "order-database", "product_variants", pv_full)
    upsert_docs("order-db", "order-database", "product_variant_versions", pvv)
    upsert_docs("order-db", "order-database", "tax_rates", tr)
    upsert_docs("order-db", "order-database", "tax_rate_versions", trv)
    upsert_docs("order-db", "order-database", "shipment_methods", ship_docs)

    # payment-db: users + product_variants
    print("\n→ payment")
    upsert_docs("payment-db", "payment-database", "users", user_docs_minimal)
    upsert_docs("payment-db", "payment-database", "product_variants", pv_full)

    # wishlist-db: users + product_variants
    print("\n→ wishlist")
    upsert_docs("wishlist-db", "wishlist-database", "users", user_docs_minimal)
    upsert_docs("wishlist-db", "wishlist-database", "product_variants",
                [{"_id": js_uuid(v["id"])} for v in catalog["variants"]])

    print("\n✓ All downstream mirrors synced from sources of truth.")


if __name__ == "__main__":
    main()
