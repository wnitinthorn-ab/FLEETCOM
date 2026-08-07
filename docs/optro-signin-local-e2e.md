# Local E2E: Midship ↔ Optro "Sign in with Optro" (`private_key_jwt` / certificate)

How to set up the local FLEETCOM stack so the Midship "Sign in with Optro" flow works end-to-end with the new **`private_key_jwt`** client authentication (a JWT assertion signed by Midship's private key, verified by AuditBoard against a configured public certificate — RFC 7523). Replaces the old dynamic client registration + shared `client_secret`.

**TL;DR:** run `./fleetcom start`, make sure AB is on a current branch, wire a keypair + client id on both sides so they're *consistent*, then run **`./fleetcom-verify-optro.sh`** — it does a live probe and tells you exactly what's misconfigured.

## The flow (what has to line up)
```
Midship FE (:5173) ──"Sign in with Optro" (localhost:9002)──▶ Midship BE (:8000) /auth/optrooauth/login
   ▶ redirect to AB authorize  https://localhost:9002/midship/v1/oauth2/authorize?client_id=<X>&redirect_uri=<R>&PKCE
   ▶ (browser must have an AB session) AB issues ?code=… ▶ Midship callback (:5173) ▶ Midship BE
   ▶ token exchange: Midship signs a private_key_jwt assertion (aud = <base>/midship/v1/oauth2/token) with its
     PRIVATE key ▶ AB verifies it against MIDSHIP_OAUTH_CERTIFICATE (public) ▶ 200 ▶ Midship session minted.
```
Three things must be consistent across the two repos:
1. **client id** — Midship `OPTRO_CLIENT_ID` == AB `MIDSHIP_OAUTH_CLIENT_ID`.
2. **keypair** — AB `MIDSHIP_OAUTH_CERTIFICATE` is the base64-PEM **public** half of Midship `OPTRO_CLIENT_PRIVATE_KEY`.
3. **audience** — AB's `v1.soxhub.url` (← env `BASE_URL`) must equal the instance origin the Midship client posts to (locally `https://localhost:9002`, the caddy entrypoint). This is the #1 footgun (see gotcha 3).

## One-time setup

### 1. Generate a keypair (throwaway for local; real one provisioned per-deploy)
```bash
python3 - <<'PY'
import base64
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import serialization as s
k = ec.generate_private_key(ec.SECP256R1())   # ES256 (AB also accepts RS256)
print("OPTRO_CLIENT_PRIVATE_KEY =",
      base64.b64encode(k.private_bytes(s.Encoding.PEM, s.PrivateFormat.PKCS8, s.NoEncryption())).decode())  # -> Midship
print("MIDSHIP_OAUTH_CERTIFICATE =",
      base64.b64encode(k.public_key().public_bytes(s.Encoding.PEM, s.PublicFormat.SubjectPublicKeyInfo)).decode())  # -> AB
PY
```

### 2. Midship — `midship/config.ini` under `[app.local_db]` (uncommitted; holds local secrets)
```ini
optro_client_id        = midship-local
optro_client_private_key = <base64 PEM private key from step 1>
optro_client_signing_alg = ES256
optro_redirect_uri     = http://localhost:5173/auth/optrooauth/callback
; so aiohttp trusts caddy's mkcert cert on the server-to-server token POST:
ssl_cert_file          = <path to a certifi cacert.pem + $(mkcert -CAROOT)/rootCA.pem bundle>
```
(Or export `SSL_CERT_FILE` in the Midship API's environment — same effect.)

### 3. AuditBoard — `auditboard-backend/.envrc` (git-ignored), then `direnv allow .`
```bash
export MIDSHIP_OAUTH_CLIENT_ID=midship-local
export MIDSHIP_OAUTH_CERTIFICATE=<base64 PEM public key from step 1>
export MIDSHIP_OAUTH_REDIRECT_URIS='["http://localhost:5173/auth/optrooauth/callback"]'
```

## Gotchas (symptom → cause → fix)

1. **AB branch silently stale.** `git checkout <branch>` uses the *local* branch, which can be far behind origin — and then AB has neither the verifier (#37314) nor the env mapping (#37319). *Symptom:* AB returns `invalid_client` "Invalid client_id" (config client never resolves) even though your env vars are set. *Fix:* `git -C auditboard-backend status -sb` — if it says "behind N", `git pull`, then `pnpm install`, then rebuild.

2. **Stale/orphaned `dist/` after a branch switch.** `dist/` is git-ignored, so switching branches leaves compiled files whose source no longer exists; v1 crashes on boot with `SyntaxError: does not provide an export named X`. *Fix:* wipe workspace `dist/` dirs and rebuild: `find common contexts data-access-layer integrations -type d -name dist -not -path '*/node_modules/*' -prune -exec rm -rf {} +` then **`pnpm -w ab build`** (NOT bare `ab build` — the `@soxhub/ope` tool needs pnpm's context; and after any `.envrc` edit run `direnv allow`).

3. **`aud` mismatch — the big one.** AB verifies the assertion `aud` against `${v1.soxhub.url}/midship/v1/oauth2/token`, and `v1.soxhub.url` ← env `BASE_URL`. **The AB v1 process HARDCODES `BASE_URL='http://localhost:9001'` inline in `package.json` script `_:start:api:v1`** — so v1 expects `aud = http://localhost:9001/...`, but the Midship client (via the FE `buildOptroBaseUrl`) uses the caddy entrypoint `https://localhost:9002`. `@soxhub/config` lets that inline `BASE_URL` win over any `NODE_CONFIG` override. *Symptom:* `invalid_client` "Invalid client assertion" while the assertion self-verifies fine in isolation. *Two fixes:* (a) point v1's inline `BASE_URL` at `https://localhost:9002` (quick, but it also changes the access-token issuer AB mints and self-calls now go over caddy TLS — Node needs `NODE_EXTRA_CA_CERTS` for mkcert); **(b) preferred:** drive the Midship client at `http://localhost:9001` (bypass caddy — no AB change, matches how AB's own `playwright:start:api` runs and how CI will).

4. **aiohttp can't trust caddy's cert.** caddy on :9002 is https-only with an mkcert cert; **Node/Python do NOT read the macOS keychain.** *Fix (Python):* `SSL_CERT_FILE` = a bundle of `certifi` + `$(mkcert -CAROOT)/rootCA.pem`. *(Node self-calls:* `NODE_EXTRA_CA_CERTS=$(mkcert -CAROOT)/rootCA.pem`.)

5. **"Signing you in" spinner on the authorize page.** The Optro authorize returns 200 but needs an authenticated AB session. In a fresh browser there is none, so it spins. *Fix:* log into AB first — open `https://localhost:9002`, sign in as `ops@soxhub.com` / `password`; then run Sign in with Optro in the same browser. (The AB login SPA loads fine on a clean navigation; a stuck tab can make Playwright's snapshot time out — reset to `about:blank` first.)

6. **AWS SSO expired blocks AB start.** `./fleetcom start auditboard` parks on `aws sso login --profile Testing`. *Fix:* complete the SSO login in a browser (or launch Chrome to the printed authorize URL) before AB will boot.

## Verify + run
```bash
./fleetcom start                 # bring the stack up (AWS SSO must be valid)
./fleetcom-verify-optro.sh       # checks branch/code/config/keypair/aud + a LIVE assertion probe
```
Green = ready. Then the browser E2E: log into AB at `https://localhost:9002` once, go to Midship `http://localhost:5173/signin` → **Sign in with Optro** → `localhost:9002` → Continue → you land in Midship signed in. Confirm on the AB side: `POST /midship/v1/oauth2/token 200` in the AB v1 log.

**Playwright driving:** the Playwright MCP connects to Chrome over CDP on `:9222`; launch it headed with `--remote-debugging-port=9222 --user-data-dir=<tmp> --ignore-certificate-errors`.
