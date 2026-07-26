#!/usr/bin/env python3
"""
MiSArch checkout-prerequisites seeder.

Unblocks the `placeOrder` saga for the `test` user by seeding the three
things a checkout requires:
  1. at least one shipment method      (admin-level mutation)
  2. an address for the `test` user    (test-user-scoped mutation)
  3. a payment-information record      (test-user-scoped mutation)

The exact GraphQL mutation/input names vary across MiSArch service versions,
so this script supports a discovery pass:

  python3 seed_checkout.py discover    # prints candidate mutations + input fields
  python3 seed_checkout.py seed        # runs the seeding using the constants below

Re-uses seed.py's auth helpers — sources Keycloak admin password from
KEYCLOAK_ADMIN_PASSWORD and the same KC_URL / GW_URL env defaults.
"""

import json
import os
import sys

import requests

# Re-use seed.py's primitives. Same dir.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import seed as seed_module  # noqa: E402
from seed import (  # noqa: E402
    KC_URL, GW_URL, REALM, KC_ADMIN_USER, KC_ADMIN_PW,
    http, kc_master_token, gql, ensure_seed_user,
)

TEST_USER     = os.environ.get("TEST_USER",     "test")
TEST_PW       = os.environ.get("TEST_PASSWORD", "test")


# ── auth as the test user ───────────────────────────────────────────────────
def test_user_token() -> str:
    r = http.post(
        f"{KC_URL}/realms/{REALM}/protocol/openid-connect/token",
        data={
            "grant_type": "password",
            "client_id":  "frontend",
            "username":   TEST_USER,
            "password":   TEST_PW,
        },
    )
    r.raise_for_status()
    return r.json()["access_token"]


# ── discovery: introspect the federated schema ──────────────────────────────
INTROSPECT = """
query Discover {
  __schema {
    mutationType {
      fields {
        name
        args { name type { name kind ofType { name kind } } }
      }
    }
    types {
      name
      kind
      inputFields { name type { name kind ofType { name kind } } }
    }
  }
}
"""


def _fmt_type(t: dict) -> str:
    if t is None:
        return "?"
    if t.get("name"):
        return t["name"]
    return f"{t.get('kind','?')}<{_fmt_type(t.get('ofType'))}>"


def discover(token: str, keywords: list[str]) -> None:
    data = gql(token, INTROSPECT)
    mutations = data["__schema"]["mutationType"]["fields"]
    types     = data["__schema"]["types"]

    def matches(name: str) -> bool:
        n = name.lower()
        return any(k in n for k in keywords)

    print("=== candidate mutations ===")
    for f in mutations:
        if not matches(f["name"]):
            continue
        args = ", ".join(f"{a['name']}: {_fmt_type(a['type'])}" for a in f["args"])
        print(f"  {f['name']}({args})")

    print("\n=== candidate input types ===")
    for t in types:
        if t["kind"] != "INPUT_OBJECT" or not matches(t["name"]):
            continue
        print(f"  input {t['name']} {{")
        for fld in (t.get("inputFields") or []):
            print(f"    {fld['name']}: {_fmt_type(fld['type'])}")
        print("  }")


# ── seed: edit the strings below once `discover` reveals real names ─────────
# Best-guess mutation names + payloads based on conventional MiSArch naming.
# Run `discover` first to confirm. If a name differs, edit here and re-run `seed`.

# Test user's Keycloak UUID.
#
# This MUST be looked up at runtime, not hardcoded: Keycloak mints a fresh UUID
# for `test` every time its database is recreated (new cluster, or a
# `kubectl delete namespace misarch`). A stale value makes the address mutation
# fail with "User with id <uuid> does not exist" even though the user exists —
# the address service correctly rejects an id it has never mirrored.
#
# Set TEST_USER_ID to override (e.g. to seed for a different user).
def resolve_test_user_id() -> str:
    override = os.environ.get("TEST_USER_ID")
    if override:
        print(f"[seed_checkout] TEST_USER_ID from env: {override}")
        return override

    admin_tok = kc_master_token()
    r = http.get(
        f"{KC_URL}/admin/realms/{REALM}/users",
        params={"username": TEST_USER, "exact": "true"},
        headers={"Authorization": f"Bearer {admin_tok}"},
        timeout=30,
    )
    r.raise_for_status()
    users = r.json()
    if not users:
        sys.exit(
            f"Keycloak user {TEST_USER!r} not found in realm {REALM!r}.\n"
            "  Run `python3 seed.py` first — it creates the test user."
        )
    uid = users[0]["id"]
    print(f"[seed_checkout] resolved {TEST_USER!r} -> {uid}")
    return uid

M_SHIPMENT_METHOD_CREATE = """
mutation CreateShipmentMethod($input: CreateShipmentMethodInput!) {
  createShipmentMethod(input: $input) { id name }
}
"""
SHIPMENT_METHOD_INPUT = {
    "name":              "Standard Shipping",
    "description":       "DHL ground, 3-5 business days",
    "externalReference": "dhl-standard",
    "baseFees":          499,   # cents
    "feesPerItem":       0,
    "feesPerKg":         0,
}

M_ADDRESS_CREATE = """
mutation CreateUserAddress($input: CreateUserAddressInput!) {
  createUserAddress(input: $input) { id }
}
"""
# NameInput shape needs to be confirmed via:
#   python3 seed_checkout.py discover-types NameInput
# Common shapes: {firstName, lastName} or {firstName, lastName, middleName}
ADDRESS_INPUT = {
    # "userId" is injected in seed() from resolve_test_user_id()
    # `name` (NameInput) is declared on the address subgraph but the federated
    # gateway schema doesn't expose it — Mesh skew. Skip; name lives on the user.
    "street1":    "Straße des 17. Juni 135",
    "street2":    "",            # NON_NULL in schema — pass empty string
    "city":       "Berlin",
    "postalCode": "10623",
    "country":    "DE",
}

# Only createCreditCardPaymentInformation exists — there is no INVOICE path.
M_PAYMENT_INFO_CREATE = """
mutation CreateCreditCardPaymentInformation($input: CreateCreditCardInformationInput!) {
  createCreditCardPaymentInformation(input: $input) { id }
}
"""
PAYMENT_INFO_INPUT = {
    "cardHolder":     "Test User",
    "cardNumber":     "4242424242424242",  # Stripe test PAN — won't actually be charged
    "expirationDate": "12/30",
}

STOCK_PER_VARIANT = int(os.environ.get("STOCK_PER_VARIANT", "100"))

Q_LIST_VARIANTS = """
query ListVariants {
  products(first: 200) {
    nodes {
      id
      internalName
      defaultVariant { id }
    }
  }
}
"""

M_PRODUCT_ITEM_BATCH = """
mutation CreateProductItemBatch($input: CreateProductItemBatchInput!) {
  createProductItemBatch(input: $input) { id }
}
"""


def seed_inventory(admin_tok: str) -> None:
    data = gql(admin_tok, Q_LIST_VARIANTS)
    nodes = data["products"]["nodes"]
    print(f"inventory: seeding {STOCK_PER_VARIANT} units × {len(nodes)} variants")
    for n in nodes:
        vid = n["defaultVariant"]["id"]
        gql(admin_tok, M_PRODUCT_ITEM_BATCH, {
            "input": {"productVariantId": vid, "number": STOCK_PER_VARIANT},
        })
        print(f"  + {n['internalName']} ({vid}) → +{STOCK_PER_VARIANT}")


def seed() -> None:
    print(f"keycloak: {KC_URL}\ngateway:  {GW_URL}\nrealm:    {REALM}\n")

    test_tok = test_user_token()
    print(f"keycloak: signed in as {TEST_USER}")

    # Resolve the test user's *current* Keycloak UUID (see resolve_test_user_id).
    test_user_id = resolve_test_user_id()
    ADDRESS_INPUT["userId"] = test_user_id
    if "userId" in PAYMENT_INFO_INPUT:
        PAYMENT_INFO_INPUT["userId"] = test_user_id

    # 1. shipment method — admin token required (test user is buyer-only)
    admin_tok = _admin_user_token()
    data = gql(admin_tok, M_SHIPMENT_METHOD_CREATE, {"input": SHIPMENT_METHOD_INPUT})
    print(f"shipment-method: {data}")

    # 1b. inventory: seed N units per product variant so things aren't out-of-stock
    seed_inventory(admin_tok)

    # 2. address (under the test user's account)
    data = gql(test_tok, M_ADDRESS_CREATE, {"input": ADDRESS_INPUT})
    print(f"address: {data}")

    # 3. payment information (under the test user's account)
    data = gql(test_tok, M_PAYMENT_INFO_CREATE, {"input": PAYMENT_INFO_INPUT})
    print(f"payment-info: {data}")

    print("\nDone. Verify by placing an order through the frontend or k6 cart scenario.")


def _admin_user_token() -> str:
    """Bootstrap (or re-use) the SEED_USER from seed.py — it carries the realm
    'admin' role, which is required to create a shipment method. If the user
    doesn't exist or the password has drifted, ensure_seed_user resets it.
    """
    admin_tok = kc_master_token()
    ensure_seed_user(admin_tok)   # creates if missing; idempotent

    seed_user = os.environ.get("SEED_USER", "seeder")
    seed_pw   = os.environ.get("SEED_PASSWORD", "Seeder!2026")
    r = http.post(
        f"{KC_URL}/realms/{REALM}/protocol/openid-connect/token",
        data={
            "grant_type": "password",
            "client_id":  "frontend",
            "username":   seed_user,
            "password":   seed_pw,
        },
    )
    if r.status_code == 401:
        # Password drifted (user exists with a different password). Reset it
        # via the admin API and retry.
        h = {"Authorization": f"Bearer {admin_tok}"}
        users = http.get(
            f"{KC_URL}/admin/realms/{REALM}/users",
            params={"username": seed_user, "exact": "true"}, headers=h,
        ).json()
        uid = users[0]["id"]
        http.put(
            f"{KC_URL}/admin/realms/{REALM}/users/{uid}/reset-password",
            headers=h,
            json={"type": "password", "value": seed_pw, "temporary": False},
        ).raise_for_status()
        r = http.post(
            f"{KC_URL}/realms/{REALM}/protocol/openid-connect/token",
            data={
                "grant_type": "password",
                "client_id":  "frontend",
                "username":   seed_user,
                "password":   seed_pw,
            },
        )
    r.raise_for_status()
    return r.json()["access_token"]


# ── main ────────────────────────────────────────────────────────────────────
def _fetch_kc_admin_pw_from_k8s() -> str | None:
    """Pull KEYCLOAK_ADMIN_PASSWORD from the in-cluster bootstrap secret."""
    import base64, subprocess
    try:
        ns = os.environ.get("MISARCH_NAMESPACE", "misarch")
        raw = subprocess.check_output(
            ["kubectl", "-n", ns, "get", "secret", "keycloak-bootstrap",
             "-o", "jsonpath={.data.KEYCLOAK_ADMIN_PASSWORD}"],
            stderr=subprocess.DEVNULL, text=True,
        ).strip()
        return base64.b64decode(raw).decode() if raw else None
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None


if __name__ == "__main__":
    if not KC_ADMIN_PW:
        KC_ADMIN_PW = _fetch_kc_admin_pw_from_k8s()
        if KC_ADMIN_PW:
            seed_module.KC_ADMIN_PW = KC_ADMIN_PW
            print("[seed_checkout] KEYCLOAK_ADMIN_PASSWORD loaded from k8s secret keycloak-bootstrap")
    if not KC_ADMIN_PW:
        sys.exit("KEYCLOAK_ADMIN_PASSWORD is required (env var not set and could not read k8s secret keycloak-bootstrap)")

    cmd = sys.argv[1] if len(sys.argv) > 1 else "seed"
    try:
        if cmd == "discover":
            tok = test_user_token()
            discover(tok, keywords=["shipment", "shipping", "address", "payment"])
        elif cmd == "discover-types":
            # python3 seed_checkout.py discover-types NameInput CreateCreditCardInformationInput
            wanted = [a.lower() for a in sys.argv[2:]] or ["name", "creditcard"]
            tok = test_user_token()
            discover(tok, keywords=wanted)
        elif cmd == "seed":
            seed()
        else:
            sys.exit(f"unknown command: {cmd!r} (use: discover | discover-types <names> | seed)")
    except requests.HTTPError as e:
        body = e.response.text[:500] if e.response is not None else ""
        sys.exit(f"\nHTTP {e.response.status_code if e.response else '?'}: {body}")
    except Exception as e:
        sys.exit(f"\nError: {e}")
