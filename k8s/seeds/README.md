# Gateway authorization seeds

The `gateway-service` enforces DB-driven, JWT-gated authorization. Two seeds wire it up.
Both mirror the Dev EC2 reference environment and are required after a fresh `ccedb` /
fresh Keycloak.

## 1. `api_permissions.sql` — permission catalog (Postgres / `ccedb`)

The gateway loads `SELECT * FROM api_permissions` on startup
(`LOAD_PERMISSIONS_FROM_DATABASE_ON_STARTUP=true`). Without it the gateway falls back to its
bundled YAML and authorizes nothing from the DB.

```bash
docker exec -i postgres-uat psql -U admin -d ccedb < api_permissions.sql
```

Idempotent. Verify: gateway logs `Successfully loaded 5 permissions from database`.

## 2. `cce-realm.json` — Keycloak `cce` realm (clients, roles, scopes)

Partial export of the Dev EC2 `cce` realm (client secrets stripped — Keycloak regenerates
them on import). Contains:

- **`gateway-service`** client (confidential, JWT resource server) with client roles
  `COLLECTOR_EVENTS_WRITE`, `HTTPBIN_READ`, `HTTPBIN_WRITE` — these match
  `api_permissions.permission_name`.
- **`gateway-audience`** client scope — an audience mapper that stamps `aud=gateway-service`
  into access tokens (the gateway requires `JWT_AUDIENCE=gateway-service`).
- **`openhim-emitter-adaptor`** client (service-account / client-credentials flow) whose
  service account is granted the gateway-service roles, so its tokens carry
  `resource_access.gateway-service.roles`. This is the token-minting identity.

Import into a running Keycloak (creates the realm):

```bash
# admin token from the master realm (KEYCLOAK_ADMIN_PASSWORD)
TOKEN=$(curl -s "$KC/realms/master/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=admin-cli \
  -d username=admin -d password="$ADMIN_PW" | jq -r .access_token)

curl -s -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -X POST "$KC/admin/realms" --data-binary @cce-realm.json     # -> 201
```

`$KC` is the Keycloak base URL incl. relative path, e.g. `http://keycloak:8080/auth`.
The partial export already includes the emitter service-account role mappings, so no manual
role assignment is needed.

### Verify end-to-end

```bash
# client-credentials token as the emitter (Host header makes iss match in-cluster issuer)
TOK=$(curl -s -H "Host: keycloak:8080" \
  "$KC/realms/cce/protocol/openid-connect/token" \
  -d grant_type=client_credentials -d client_id=openhim-emitter-adaptor \
  -d client_secret="$EMITTER_SECRET" | jq -r .access_token)

# POST /v1/events -> reaches the collector (400 CloudEvent validation = authz passed)
curl -X POST http://gateway-service:8090/v1/events -H "Authorization: Bearer $TOK" \
  -H 'Content-Type: application/json' -d '{}'

# GET /v1/events -> 403 (token has POST permission only) — proves per-method enforcement
```

> **Note:** the gateway's `ALLOWED_ORIGINS` must be a concrete origin, never `*` — it sets
> `allowCredentials=true` and Spring 500s every request on the wildcard+credentials combo.
> Set per-environment in the overlay's `cce-config` (`ALLOWED_ORIGINS`).
