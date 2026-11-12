#!/usr/bin/env python3
"""
openhim_non2xx_primary.py

Fetches transactions for a given channel from OpenHIM-core's API
and reports those where the PRIMARY route's response status
is outside the 2xx range.

-------------------------------------------------------------------
DEPENDENCIES
-------------------------------------------------------------------
None beyond the Python standard library (urllib, json, ssl, base64).

-------------------------------------------------------------------
USAGE (environment variables)
-------------------------------------------------------------------
  OPENHIM_URL   e.g. https://openhim.example.org:8080   (required)
  OPENHIM_USER  e.g. root@openhim.org                    (required)
  OPENHIM_PASS  password                                 (required)
  CHANNEL_ID    the channel's Mongo ObjectId string       (required)
  AUTH_TYPE     "basic" (default) or "token" (OpenHIM's custom salted
                challenge-response scheme; matches OPENHIM_CORE_AUTH_TYPE)
  FROM          ISO timestamp, e.g. 2026-07-01T00:00:00.000Z  (optional)
  TO            ISO timestamp                                (optional)
  PAGE_SIZE     default 100                                  (optional)
  INSECURE      "true" to skip TLS cert verification          (optional)

Example:
  OPENHIM_URL=https://openhim.example.org:8080 \
  OPENHIM_USER=root@openhim.org \
  OPENHIM_PASS=yourpassword \
  CHANNEL_ID=5b9c1234abcd0000000000ab \
  python3 openhim_non2xx_primary.py

NOTES ON SERVER VARIATIONS (verify against your actual OpenHIM instance):
  1. Auth: AUTH_TYPE=basic (default) assumes HTTP Basic Auth is enabled
     server-side (api.authenticationTypes includes 'basic' in core config).
     AUTH_TYPE=token uses OpenHIM's custom salted challenge-response scheme
     instead: GET /authenticate/<user> returns {salt, ts} (the SERVER's
     stored salt); passwordHash = SHA512(serverSalt + password); a fresh
     random CLIENT salt is generated per request; authToken =
     SHA512(passwordHash + clientSalt + ts); headers sent are auth-username,
     auth-ts (server's ts), auth-salt (the CLIENT salt, not the server's),
     auth-token. Verified against the RW OpenHIM instance 2026-07-13 (see
     org.openphc.cce.emitter.openhim.OpenHimAuthInterceptor in
     openhim-cce-emitter-adaptor for the reference Java implementation).
  2. Date filtering is done CLIENT-SIDE, not server-side. Verified against the
     RW OpenHIM instance 2026-07-13: neither `startDate`/`endDate` nor `from`/`to`
     query params bound the /transactions results on this OpenHIM-core version —
     the server silently ignores them and returns the full history, newest-first
     (confirmed: page 30 of a "last 10 minutes" query returned a transaction from
     2 days earlier). Transactions ARE reliably returned newest-first, so this
     script pages through them and skips any before FROM/after TO, and STOPS as
     soon as a page's oldest transaction is older than FROM (safe because of the
     newest-first ordering) rather than trying to fetch and rely on a filtered
     count. This makes runtime proportional to the requested window, not to the
     channel's total lifetime history.
  3. filterRepresentation=full is required so routes[].response is
     actually populated in the payload.
"""

import base64
import datetime
import hashlib
import json
import os
import secrets
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter

# ---------------------------------------------------------------------
# Config (populated from environment variables in main())
# ---------------------------------------------------------------------
base_url = None
user = None
password = None
channel_id = None
from_date = None
to_date = None
page_size = 100
insecure = False
auth_type = "basic"
_password_hash = None  # token auth only: SHA512(serverSalt + password), computed once


def require_env(name):
    v = os.environ.get(name)
    if not v:
        print(f"Missing required env var: {name}", file=sys.stderr)
        sys.exit(1)
    return v


def env_or(name, default):
    v = os.environ.get(name)
    return v if v else default


def build_url(page):
    qs = {
        "channelID": channel_id,
        "filterPage": page,
        "filterLimit": page_size,
        "filterRepresentation": "full",
    }
    if from_date:
        qs["startDate"] = from_date  # swap to 'from' if your version needs it
    if to_date:
        qs["endDate"] = to_date  # swap to 'to' if your version needs it
    return f"{base_url}/transactions?{urllib.parse.urlencode(qs)}"


def ssl_context():
    if not insecure:
        return None
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def sha512_hex(s):
    return hashlib.sha512(s.encode("utf-8")).hexdigest()


def fetch_password_hash():
    """Token auth, once at startup: GET /authenticate/<user> -> {salt, ts} (server's
    stored salt); passwordHash = SHA512(serverSalt + password). Cached for the run —
    each request below mints its own fresh client salt + token from this hash."""
    req = urllib.request.Request(
        f"{base_url}/authenticate/{urllib.parse.quote(user)}", method="GET")
    req.add_header("Accept", "application/json")
    with urllib.request.urlopen(req, timeout=30, context=ssl_context()) as resp:
        challenge = json.loads(resp.read().decode("utf-8"))
    return sha512_hex(challenge["salt"] + password)


def token_auth_headers():
    global _password_hash
    if _password_hash is None:
        _password_hash = fetch_password_hash()
    client_salt = secrets.token_hex(16)
    now = datetime.datetime.now(datetime.timezone.utc)
    ts = now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}Z"
    token = sha512_hex(_password_hash + client_salt + ts)
    return {"auth-username": user, "auth-ts": ts, "auth-salt": client_salt, "auth-token": token}


def http_get(url):
    req = urllib.request.Request(url, method="GET")
    req.add_header("Accept", "application/json")

    if auth_type == "token":
        for k, v in token_auth_headers().items():
            req.add_header(k, v)
    else:
        basic_auth = base64.b64encode(f"{user}:{password}".encode("utf-8")).decode("ascii")
        req.add_header("Authorization", f"Basic {basic_auth}")

    try:
        with urllib.request.urlopen(req, timeout=30, context=ssl_context()) as resp:
            return resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        raise IOError(f"HTTP {e.code} - {body}") from e
    except urllib.error.URLError as e:
        raise IOError(str(e.reason)) from e


def find_primary_route(tx):
    routes = tx.get("routes")
    if not isinstance(routes, list):
        return None
    for route in routes:
        if route.get("primary") is True:
            return route
    return None


def is_non_2xx(status):
    return status is not None and (status < 200 or status >= 300)


def parse_ts(s):
    """ISO8601 (e.g. 2026-07-13T08:42:12.000Z) -> aware UTC datetime, or None."""
    if not s:
        return None
    try:
        return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None


def extract_resource_type(request):
    """Best-effort FHIR resourceType for a transaction: parse request.body as JSON
    (top-level resourceType, or the first Bundle entry's resource), falling back to
    the last non-numeric path segment (e.g. /fhir/Patient/123 -> Patient)."""
    body = request.get("body")
    if isinstance(body, str) and body.strip():
        try:
            payload = json.loads(body)
        except (ValueError, TypeError):
            payload = None
        if isinstance(payload, dict):
            rtype = payload.get("resourceType")
            if rtype and rtype != "Bundle":
                return rtype
            entries = payload.get("entry")
            if isinstance(entries, list) and entries:
                first_resource = entries[0].get("resource") if isinstance(entries[0], dict) else None
                if isinstance(first_resource, dict) and first_resource.get("resourceType"):
                    return first_resource.get("resourceType")
            if rtype:
                return rtype  # Bundle with no readable entry resourceType

    path = request.get("path") or ""
    for seg in reversed([s for s in path.split("/") if s]):
        if not seg.isdigit() and seg.lower() not in ("fhir", "_history"):
            return seg
    return "UNKNOWN"


def main():
    global base_url, user, password, channel_id, from_date, to_date, page_size, insecure, auth_type

    base_url = require_env("OPENHIM_URL").rstrip("/")
    user = require_env("OPENHIM_USER")
    password = require_env("OPENHIM_PASS")
    channel_id = require_env("CHANNEL_ID")
    from_date = os.environ.get("FROM")
    to_date = os.environ.get("TO")
    page_size = int(env_or("PAGE_SIZE", "100"))
    insecure = env_or("INSECURE", "false").lower() == "true"
    auth_type = env_or("AUTH_TYPE", "basic").lower()

    from_dt = parse_ts(from_date)
    to_dt = parse_ts(to_date)

    offenders = []
    total_checked = 0      # transactions actually within [from_dt, to_dt]
    total_seen = 0         # all transactions fetched, incl. out-of-window ones
    page = 1
    stop = False

    while not stop:
        # Server-side startDate/endDate/from/to are sent for forward-compat but are NOT
        # trusted (verified 2026-07-13 this OpenHIM-core version ignores them and returns
        # full unfiltered history, newest-first) — see the module docstring. Filtering and
        # the early-exit below are what actually bound this to the requested window.
        url = build_url(page)
        body = None
        last_err = None
        for attempt in range(1, 4):
            try:
                body = http_get(url)
                break
            except IOError as e:
                last_err = e
                print(f"  page {page} attempt {attempt} failed: {e}", file=sys.stderr)
        if body is None:
            print(f"Failed fetching page {page} after 3 attempts: {last_err}", file=sys.stderr)
            sys.exit(1)

        batch = json.loads(body)
        if not isinstance(batch, list) or len(batch) == 0:
            break

        if page % 10 == 0 or page == 1:
            print(f"  ...page {page}, {total_checked} in-window / {total_seen} scanned, "
                  f"{len(offenders)} offenders so far", file=sys.stderr)

        for tx in batch:
            total_seen += 1
            request = tx.get("request") or {}
            tx_ts = parse_ts(request.get("timestamp"))

            if from_dt is not None and tx_ts is not None and tx_ts < from_dt:
                # Newest-first ordering (verified): once we're below FROM, everything
                # remaining (this page and all later pages) is even older. Stop here.
                stop = True
                break
            if to_dt is not None and tx_ts is not None and tx_ts > to_dt:
                continue  # newer than TO — skip, keep scanning (shouldn't normally occur)

            total_checked += 1
            primary = find_primary_route(tx)
            status = None
            route_name = None

            if primary is not None:
                route_name = primary.get("name")
                response = primary.get("response")
                if response and response.get("status") is not None:
                    status = response.get("status")

            if is_non_2xx(status):
                offenders.append({
                    "transactionId": tx.get("_id"),
                    "clientID": tx.get("clientID"),
                    "requestPath": request.get("path"),
                    "resourceType": extract_resource_type(request),
                    "timestamp": request.get("timestamp"),
                    "primaryRouteName": route_name,
                    "primaryStatus": status,
                    "overallStatus": tx.get("status"),
                })

        if stop or len(batch) < page_size:
            break  # crossed below FROM, or last page
        page += 1

    total_pages = page
    print(f"Checked {total_checked} transactions for channel {channel_id} "
          f"(scanned {total_seen} across {total_pages} page(s) to find them).")
    print(f"Found {len(offenders)} with non-2xx primary route response:\n")

    by_resource_type = Counter(o["resourceType"] for o in offenders)
    if by_resource_type:
        print("By resourceType:")
        for rtype, count in by_resource_type.most_common():
            print(f"  {rtype:<20} {count}")
        print()

    print(json.dumps(offenders, indent=2))


if __name__ == "__main__":
    main()
