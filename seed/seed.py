#!/usr/bin/env python3
"""
MiSArch catalog seeder.

Bootstraps an admin user in the Misarch Keycloak realm, then drives the
federated Gateway (http://localhost:8080/graphql) to create:
  - 1 tax rate (Standard 19%)            (tax service, Kotlin/Spring)
  - 5 categories                         (catalog service)
  - 12 products with default variants    (catalog service)
  - 12 product images                    (media service, MinIO-backed)

Prerequisites:
  pip install requests
  ./portforward.sh                       # starts kubectl port-forwards
  export KEYCLOAK_ADMIN_PASSWORD=<pw>    # master-realm bootstrap admin password

Run:
  python3 seed.py                        # seed
  python3 seed.py reset                  # wipe all seeded data (then re-seed)
"""

import base64
import json
import os
import subprocess
import sys

import requests

# ── config ──────────────────────────────────────────────────────────────────
KC_URL        = os.environ.get("KC_URL",        "http://localhost:8081/keycloak")
GW_URL        = os.environ.get("GW_URL",        "http://localhost:8080/graphql")
# Mesh gateway does not federate the media Upload scalar; talk to the media
# service directly. Its GraphQL endpoint is mounted at "/", not "/graphql".
MEDIA_URL     = os.environ.get("MEDIA_URL",     "http://localhost:9091/")
KC_ADMIN_USER = os.environ.get("KEYCLOAK_ADMIN_USER", "admin")
KC_ADMIN_PW   = os.environ.get("KEYCLOAK_ADMIN_PASSWORD")
REALM         = os.environ.get("MISARCH_REALM", "Misarch")
SEED_USER     = os.environ.get("SEED_USER",     "seeder")
SEED_PW       = os.environ.get("SEED_PASSWORD", "Seeder!2026")
# Storefront buyer account — used for manual login, seed_checkout.py and k6.
TEST_USER     = os.environ.get("TEST_USER",     "test")
TEST_PW       = os.environ.get("TEST_PASSWORD", "test")
LOREMFLICKR_BASE = "https://loremflickr.com/800/800"  # /<tag1>,<tag2> for topical images

http = requests.Session()
http.headers["Accept"] = "application/json"


# ── Keycloak auth ───────────────────────────────────────────────────────────
def kc_master_token() -> str:
    r = http.post(
        f"{KC_URL}/realms/master/protocol/openid-connect/token",
        data={
            "grant_type": "password",
            "client_id":  "admin-cli",
            "username":   KC_ADMIN_USER,
            "password":   KC_ADMIN_PW,
        },
    )
    r.raise_for_status()
    return r.json()["access_token"]


def ensure_user(admin_tok: str, username: str, password: str,
                role: str, first: str, last: str) -> str:
    """Create (or reuse) a realm user and ensure it holds `role`. Returns its id.

    Idempotent. Also re-asserts the password on an existing user, so a account
    left over from an earlier run with a different password still works.
    """
    h = {"Authorization": f"Bearer {admin_tok}"}

    r = http.get(
        f"{KC_URL}/admin/realms/{REALM}/users",
        params={"username": username, "exact": "true"},
        headers=h,
    )
    r.raise_for_status()
    users = r.json()

    if users:
        uid = users[0]["id"]
        print(f"keycloak: reusing user {username} ({uid})")
        # Re-assert the password — the account may predate a password change.
        r = http.put(
            f"{KC_URL}/admin/realms/{REALM}/users/{uid}/reset-password",
            headers=h,
            json={"type": "password", "value": password, "temporary": False},
        )
        r.raise_for_status()
    else:
        r = http.post(
            f"{KC_URL}/admin/realms/{REALM}/users",
            headers=h,
            json={
                "username": username,
                "email":    f"{username}@example.local",
                "firstName": first,
                "lastName":  last,
                "enabled":   True,
                "emailVerified": True,
                "credentials": [
                    {"type": "password", "value": password, "temporary": False},
                ],
            },
        )
        r.raise_for_status()
        uid = r.headers["Location"].rsplit("/", 1)[-1]
        print(f"keycloak: created user {username} ({uid})")

    r = http.get(f"{KC_URL}/admin/realms/{REALM}/roles/{role}", headers=h)
    r.raise_for_status()
    role_obj = r.json()
    r = http.post(
        f"{KC_URL}/admin/realms/{REALM}/users/{uid}/role-mappings/realm",
        headers=h,
        json=[{"id": role_obj["id"], "name": role_obj["name"]}],
    )
    r.raise_for_status()
    print(f"keycloak: ensured realm role {role!r} on {username}")
    return uid


def ensure_seed_user(admin_tok: str) -> None:
    """Admin-capable account used by the seeders themselves."""
    ensure_user(admin_tok, SEED_USER, SEED_PW, "admin", "Seed", "Bot")


def ensure_test_user(admin_tok: str) -> None:
    """Storefront buyer account used for manual login, seed_checkout.py and k6.

    Created here rather than relied upon from the realm import: the Keycloak
    database is recreated whenever the namespace or its PVC is rebuilt, and the
    import does not reliably restore this account. Without it, login fails with
    `invalid_grant` and seed_checkout.py cannot authenticate.
    """
    ensure_user(admin_tok, TEST_USER, TEST_PW, "buyer", "Test", "User")


def seed_user_token() -> str:
    r = http.post(
        f"{KC_URL}/realms/{REALM}/protocol/openid-connect/token",
        data={
            "grant_type": "password",
            "client_id":  "frontend",
            "username":   SEED_USER,
            "password":   SEED_PW,
        },
    )
    r.raise_for_status()
    return r.json()["access_token"]


# ── GraphQL helpers ─────────────────────────────────────────────────────────
def gql(token: str, query: str, variables: dict | None = None) -> dict:
    r = http.post(
        GW_URL,
        headers={"Authorization": f"Bearer {token}"},
        json={"query": query, "variables": variables or {}},
    )
    r.raise_for_status()
    body = r.json()
    if body.get("errors"):
        raise RuntimeError(f"GraphQL errors:\n{json.dumps(body['errors'], indent=2)}")
    return body["data"]


def authorized_user_header(token: str) -> str:
    """Reconstruct the gateway's `Authorized-User` header from a Keycloak JWT.

    The media service expects a plain JSON object {id, roles} on the
    `Authorized-User` header — normally injected by the Mesh gateway's
    envelopPlugins.ts. When calling media directly we have to forge it
    ourselves. Roles must be lowercase ("admin" | "employee" | "buyer").
    """
    payload_b64 = token.split(".")[1]
    payload_b64 += "=" * (-len(payload_b64) % 4)
    payload = json.loads(base64.urlsafe_b64decode(payload_b64))
    valid = {"admin", "employee", "buyer"}
    realm_roles = payload.get("realm_access", {}).get("roles", [])
    return json.dumps({
        "id":    payload["sub"],
        "roles": [r for r in realm_roles if r in valid],
    })


def gql_upload(token: str, query: str, file_name: str, blob: bytes) -> dict:
    """graphql-multipart-request-spec upload — mediaFile variable carries the binary.

    Targets MEDIA_URL (the media service directly) rather than the gateway,
    because GraphQL Mesh does not federate the Upload scalar. Forges the
    `Authorized-User` header the gateway would normally inject.
    """
    operations = {"query": query, "variables": {"mediaFile": None}}
    files_map  = {"0": ["variables.mediaFile"]}
    r = http.post(
        MEDIA_URL,
        headers={
            "Authorization":   f"Bearer {token}",
            "Authorized-User": authorized_user_header(token),
        },
        data={"operations": json.dumps(operations), "map": json.dumps(files_map)},
        files=[("0", (file_name, blob, "image/jpeg"))],
    )
    r.raise_for_status()
    body = r.json()
    if body.get("errors"):
        raise RuntimeError(f"GraphQL upload errors:\n{json.dumps(body['errors'], indent=2)}")
    return body["data"]


# ── domain operations ───────────────────────────────────────────────────────
Q_TAX_LIST = "query { taxRates(first: 50) { nodes { id name } } }"

M_TAX_CREATE = """
mutation CreateTaxRate($input: CreateTaxRateInput!) {
  createTaxRate(input: $input) { id name }
}
"""

M_CATEGORY_CREATE = """
mutation CreateCategory($input: CreateCategoryInput!) {
  createCategory(input: $input) { id name }
}
"""

M_UPLOAD_MEDIA = """
mutation UploadMedia($mediaFile: Upload!) {
  uploadMedia(mediaFile: $mediaFile)
}
"""

M_PRODUCT_CREATE = """
mutation CreateProduct($input: CreateProductInput!) {
  createProduct(input: $input) {
    id internalName defaultVariant { id }
  }
}
"""


def ensure_tax_rate(tok: str) -> str:
    nodes = gql(tok, Q_TAX_LIST)["taxRates"]["nodes"]
    if nodes:
        print(f"tax: reusing {nodes[0]['name']} ({nodes[0]['id']})")
        return nodes[0]["id"]
    data = gql(tok, M_TAX_CREATE, {"input": {
        "name":        "Standard 19%",
        "description": "DE standard VAT",
        "initialVersion": {"rate": 0.19},
    }})
    tid = data["createTaxRate"]["id"]
    print(f"tax: created Standard 19% ({tid})")
    return tid


def create_category(tok: str, name: str, description: str) -> str:
    data = gql(tok, M_CATEGORY_CREATE, {"input": {
        "name":        name,
        "description": description,
        "categoricalCharacteristics": [],
        "numericalCharacteristics":   [],
    }})
    cid = data["createCategory"]["id"]
    print(f"category: {name} ({cid})")
    return cid


def upload_image(tok: str, file_name: str, blob: bytes) -> str:
    mid = gql_upload(tok, M_UPLOAD_MEDIA, file_name, blob)["uploadMedia"]
    print(f"media: {file_name} -> {mid}")
    return mid


def create_product(tok, name, description, price_cents, weight_g,
                   category_ids, tax_id, media_ids) -> str:
    data = gql(tok, M_PRODUCT_CREATE, {"input": {
        "internalName":      name,
        "isPubliclyVisible": True,
        "categoryIds":       category_ids,
        "defaultVariant": {
            "isPubliclyVisible": True,
            "initialVersion": {
                "name":                name,
                "description":         description,
                "retailPrice":         price_cents,
                "taxRateId":           tax_id,
                "weight":              weight_g / 1000.0,
                "canBeReturnedForDays": 30,
                "mediaIds":            media_ids,
                "categoricalCharacteristicValues": [],
                "numericalCharacteristicValues":   [],
            },
        },
    }})
    pid = data["createProduct"]["id"]
    print(f"product: {name} ({pid})")
    return pid


# ── sample data ─────────────────────────────────────────────────────────────
CATEGORIES = [
    ("Electronics", "Devices and gadgets"),
    ("Clothing",    "Apparel and accessories"),
    ("Books",       "Print and digital books"),
    ("Home",        "Home and kitchen goods"),
    ("Sports",      "Sports and outdoors"),
]

# (category, name, description, retailPrice in cents, weight in grams,
#  loremflickr tags — comma-separated, drive image topicality)
PRODUCTS = [
    ("Electronics", "Quartet Wireless Headphones", "Over-ear ANC headphones, 40h battery.",            12999,  280, "headphones,audio"),
    ("Electronics", "Lumen 27\" 4K Monitor",       "27-inch IPS 4K display with USB-C input.",         34900, 6200, "monitor,desk"),
    ("Electronics", "Tessa Mechanical Keyboard",   "Hot-swap 75% keyboard, tactile switches.",         11900,  920, "keyboard,mechanical"),
    ("Clothing",    "Oslo Merino Pullover",        "Lightweight merino wool, regular fit.",             8900,  410, "sweater,wool"),
    ("Clothing",    "Kyoto Linen Shirt",           "Breathable linen long-sleeve shirt.",               6500,  320, "shirt,linen"),
    ("Clothing",    "Berliner Bomber Jacket",      "Insulated bomber jacket, water repellent.",        14900,  880, "jacket,bomber"),
    ("Books",       "Cloud Native Patterns",       "Architectural patterns for cloud applications.",    3990,  540, "book,cover"),
    ("Books",       "The Pragmatic Engineer",      "A field guide to modern software engineering.",     3290,  480, "book,reading"),
    ("Home",        "Linen Throw Blanket",         "Stonewashed linen throw, 130x170 cm.",              5990,  720, "blanket,throw"),
    ("Home",        "Ceramic Pour-Over Set",       "Hand-thrown ceramic dripper with carafe.",          4500, 1100, "ceramic,coffee"),
    ("Sports",      "Trail Runner v3",             "Lightweight trail running shoes.",                 12500,  580, "runningshoes,trail"),
    ("Sports",      "Carbon Bike Bottle Cage",     "Forged carbon cage, 18g.",                          3900,   18, "bicycle,bottle"),
]


def fetch_image(tags: str) -> bytes:
    """Fetch an 800x800 CC-licensed image matching `tags` (comma-separated)
    via loremflickr — no API key required. `lock=<n>` pins the same image
    for a given tag set so re-seeds get the same picture per product."""
    # Built-in hash() is salted per-interpreter via PYTHONHASHSEED, so it
    # would give different images each re-seed — breaking the "same picture
    # per tag set" promise above. Use sha1 for cross-run stability.
    import hashlib
    seed = int(hashlib.sha1(tags.encode()).hexdigest(), 16) % 100000
    r = requests.get(f"{LOREMFLICKR_BASE}/{tags}?lock={seed}", timeout=30, allow_redirects=True)
    r.raise_for_status()
    return r.content


# ── reset (wipe seeded data) ───────────────────────────────────────────────
# MiSArch has no delete mutations for products/categories/media, so we wipe
# the catalog Postgres tables and the MinIO `media-data` bucket directly via
# `kubectl exec`. The media MongoDB has no data (the media service only
# tracks metadata in MinIO + the catalog's `mediaentity` table).

KUBECTL   = os.environ.get("KUBECTL",   "kubectl")
NAMESPACE = os.environ.get("MISARCH_NAMESPACE", "misarch")

def _kubectl(*args: str, input_: str | None = None) -> str:
    r = subprocess.run(
        [KUBECTL, "-n", NAMESPACE, *args],
        input=input_.encode() if input_ else None,
        capture_output=True, check=True,
    )
    return r.stdout.decode()


def _secret(name: str, key: str) -> str:
    raw = _kubectl("get", "secret", name, "-o", f"jsonpath={{.data.{key}}}")
    return base64.b64decode(raw).decode()


# TRUNCATE every public-schema table except flyway_schema_history (Flyway
# would otherwise re-run all migrations on next service restart).
_TRUNCATE_PUBLIC = (
    "DO $$ DECLARE r RECORD; BEGIN "
    "FOR r IN (SELECT tablename FROM pg_tables "
    "          WHERE schemaname='public' "
    "            AND tablename <> 'flyway_schema_history') "
    "LOOP EXECUTE 'TRUNCATE TABLE \"' || r.tablename "
    "             || '\" RESTART IDENTITY CASCADE'; "
    "END LOOP; END $$;"
)


# Postgres consolidation: the 8 per-service Postgres releases were replaced by a
# single `misarch-pg-shared` instance holding one logical DB per service. When
# that layout is live, the per-service secrets/pods (`tax-db`, `tax-db-0`, …)
# no longer exist, so reset must target the shared instance + `<svc>_db` DB.
PG_SHARED_POD    = os.environ.get("PG_SHARED_POD",    "misarch-pg-shared-0")
PG_SHARED_SECRET = os.environ.get("PG_SHARED_SECRET", "misarch-pg-shared")
PG_SHARED_USER   = os.environ.get("MISARCH_DB_USER",  "misarch")
_SHARED_DB = {
    "address-db": "address_db", "catalog-db": "catalog_db",
    "discount-db": "discount_db", "notification-db": "notification_db",
    "return-db": "return_db", "shipment-db": "shipment_db",
    "tax-db": "tax_db", "user-db": "user_db",
}


def _secret_exists(name: str) -> bool:
    try:
        _kubectl("get", "secret", name, "-o", "name")
        return True
    except subprocess.CalledProcessError:
        return False


def truncate_postgres(label: str, statefulset_pod: str = None) -> None:
    """Truncate all non-flyway tables for the given service DB.

    Handles both layouts:
      * per-service (vanilla): secret/pod/DB named after `label` (`tax-db`,
        `tax-db-0`, database `misarch`).
      * consolidated (path-3): shared `misarch-pg-shared-0` pod, secret
        `misarch-pg-shared`, database `<svc>_db`.
    Picks consolidated automatically when the per-service secret is gone.
    """
    if label in _SHARED_DB and not _secret_exists(label):
        pod, user = PG_SHARED_POD, PG_SHARED_USER
        pw, db    = _secret(PG_SHARED_SECRET, "password"), _SHARED_DB[label]
    else:
        pod  = statefulset_pod or f"{label}-0"
        pw, user, db = _secret(label, "password"), "misarch", "misarch"
    _kubectl(
        "exec", "-i", pod, "-c", "postgresql", "--",
        "bash", "-c",
        f"PGPASSWORD='{pw}' psql -U {user} -d {db} -v ON_ERROR_STOP=1",
        input_=_TRUNCATE_PUBLIC,
    )
    print(f"{label}: truncated all public tables (db={db}, pod={pod})")


def empty_minio_bucket() -> None:
    pod = _kubectl(
        "get", "pod", "-l", "app=minio",
        "-o", "jsonpath={.items[0].metadata.name}",
    ).strip()
    pw = _secret("minio", "rootPassword")
    script = (
        f"mc alias set local http://localhost:9000 admin '{pw}' >/dev/null && "
        "mc rm --recursive --force local/media-data/ 2>/dev/null || true"
    )
    _kubectl("exec", "-i", pod, "-c", "minio", "--", "bash", "-c", script)
    print(f"minio: emptied media-data bucket (pod {pod})")


def do_reset() -> None:
    print(f"namespace: {NAMESPACE}\n")
    # catalog cache mirrors tax rates via Dapr pubsub. Wiping catalog without
    # wiping tax leaves the tax service holding an ID the catalog has
    # forgotten — and reused tax IDs from `ensure_tax_rate` then fail with
    # "Tax rate with id ... does not exist" on createProduct. Wipe both so
    # the next seed creates a fresh rate that fans out cleanly.
    truncate_postgres("tax-db")
    truncate_postgres("catalog-db")
    empty_minio_bucket()
    print("\nDone. Run `python3 seed.py` to repopulate.")


# ── main ────────────────────────────────────────────────────────────────────
def main() -> None:
    global KC_ADMIN_PW
    if not KC_ADMIN_PW:
        # Fall back to the in-cluster bootstrap Secret, matching the behaviour
        # of seed_checkout.py. Reuses _secret() defined above.
        try:
            KC_ADMIN_PW = _secret("keycloak-bootstrap", "KEYCLOAK_ADMIN_PASSWORD")
            print("[seed] KEYCLOAK_ADMIN_PASSWORD loaded from k8s secret keycloak-bootstrap")
        except Exception:
            sys.exit(
                "KEYCLOAK_ADMIN_PASSWORD is required (master-realm admin password).\n"
                "  Could not read it from the cluster either. Set it explicitly:\n"
                "    export KEYCLOAK_ADMIN_PASSWORD=$(kubectl -n misarch get secret "
                "keycloak-bootstrap -o jsonpath='{.data.KEYCLOAK_ADMIN_PASSWORD}' | base64 -d)"
            )
    print(f"keycloak: {KC_URL}")
    print(f"gateway:  {GW_URL}")
    print(f"realm:    {REALM}")
    print()

    admin_tok = kc_master_token()
    ensure_seed_user(admin_tok)
    ensure_test_user(admin_tok)
    user_tok = seed_user_token()
    print()

    tax_id = ensure_tax_rate(user_tok)
    print()

    categories = {n: create_category(user_tok, n, d) for n, d in CATEGORIES}
    print()

    for i, (cat, name, desc, price, weight, tags) in enumerate(PRODUCTS):
        slug  = name.lower().replace(" ", "-").replace('"', '')
        blob  = fetch_image(tags)
        mid   = upload_image(user_tok, f"{i:02d}-{slug}.jpg", blob)
        create_product(user_tok, name, desc, price, weight,
                       [categories[cat]], tax_id, [mid])

    print(f"\nSeeded {len(PRODUCTS)} products across {len(categories)} categories.")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "seed"
    try:
        if cmd in ("reset", "delete", "wipe"):
            do_reset()
        elif cmd in ("seed", "create"):
            main()
        else:
            sys.exit(f"unknown command: {cmd!r} (use: seed | reset)")
    except subprocess.CalledProcessError as e:
        err = (e.stderr or b"").decode()[:500]
        sys.exit(f"\nkubectl/exec failed: {err}")
    except requests.HTTPError as e:
        body = e.response.text[:500] if e.response is not None else ""
        sys.exit(f"\nHTTP {e.response.status_code if e.response else '?'}: {body}")
    except Exception as e:
        sys.exit(f"\nError: {e}")
