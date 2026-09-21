#!/bin/bash
# FLEETCOM verify-optro: does the local stack support the Midship <-> Optro
# "Sign in with Optro" private_key_jwt (certificate) flow?
#
# Read-only. Run AFTER `./fleetcom start` (and after logging into AB once).
# The master check is a LIVE probe: it builds a client assertion with Midship's
# real code and posts it to AB's token endpoint. If AB replies invalid_grant
# (rejecting only the dummy auth code) the certificate path is wired correctly;
# if it replies invalid_client the assertion/cert/aud is misconfigured.
#
# See docs/optro-signin-local-e2e.md for the gotchas each check maps to.
set -uo pipefail
# Standalone: does not source or read FLEETCOM's paths.sh/local.conf, and
# ignores AB_BACKEND_DIR/MIDSHIP_TURBO_BROCCOLI_DIR even if set in the
# environment — always assumes the sibling-repo layout under ~/Development.
AB="$HOME/Development/auditboard-backend"
MID="$HOME/Development/midship-turbo-broccoli"
# The instance URL the Midship FE produces locally (buildOptroBaseUrl default = caddy https entrypoint).
OPTRO_LOCAL_BASE="${OPTRO_LOCAL_BASE:-http://localhost:9001}"

G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; N=$'\033[0m'
FAIL=0
ok()  { printf "  ${G}✓${N} %s\n" "$1"; }
no()  { printf "  ${R}✗${N} %s\n     ${Y}↳ %s${N}\n" "$1" "$2"; FAIL=1; }
warn(){ printf "  ${Y}!${N} %s\n     ↳ %s\n" "$1" "$2"; }

echo "== services =="
for spec in "8000:Midship API" "5173:Midship FE" "9001:AB v1 (Hapi)"; do
	p=${spec%%:*}; l=${spec#*:}
	if nc -z localhost "$p" 2>/dev/null; then ok "$l listening ($p)"
	else no "$l NOT listening ($p)" "run ./fleetcom start (AB v1 needs AWS SSO valid)"; fi
done
# caddy only matters when the client base points at the https entrypoint; the default
# flow talks to AB's own origin (:9001), which needs no proxy.
if nc -z localhost 9002 2>/dev/null; then ok "AB caddy listening (9002)"
elif [ "${OPTRO_LOCAL_BASE#https://localhost:9002}" != "$OPTRO_LOCAL_BASE" ]; then
	no "AB caddy NOT listening (9002)" "OPTRO_LOCAL_BASE points at caddy; start it or use http://localhost:9001"
else warn "AB caddy not listening (9002)" "not required — client base is $OPTRO_LOCAL_BASE"; fi

echo "== AuditBoard branch + code =="
if git -C "$AB" status -sb 2>/dev/null | head -1 | grep -q "behind"; then
	no "AB branch is BEHIND origin" "git -C $AB pull  (a stale branch lacks the verifier/env-mapping); then pnpm install + clean rebuild (wipe dist/, pnpm -w ab build)"
else ok "AB branch not behind origin"; fi
grep -q "MIDSHIP_OAUTH_CLIENT_ID" "$AB/config/custom-environment-variables.mjs" 2>/dev/null \
	&& ok "AB env mapping present (MIDSHIP_OAUTH_* -> v1.midship.*, #37319)" \
	|| no "AB missing MIDSHIP_OAUTH env mapping" "AB branch too old (needs SOX-101255 #37319); pull + rebuild"
grep -qE "client_assertion|private_key_jwt" "$AB/contexts/auth/src/lib/midship-oauth2/index.ts" 2>/dev/null \
	&& ok "AB private_key_jwt verifier present (#37314)" \
	|| no "AB missing private_key_jwt verifier" "AB branch too old (needs SOX-101255 #37314); pull + rebuild"

echo "== AuditBoard resolved config =="
# Resolved from contexts/api, not the repo root: @soxhub/config is a workspace
# package and the ROOT package.json does not depend on it, so a root-cwd import
# dies with ERR_MODULE_NOT_FOUND. NODE_CONFIG_DIR is then required because the
# `config` package looks for ./config relative to cwd, and the config dir lives
# at the repo root. Without both, every check below reads an empty config and
# reports a false negative (missing clientId/cert/redirectUris).
AB_JSON=$(cd "$AB/contexts/api" && NODE_CONFIG_DIR="$AB/config" direnv exec . node --input-type=module -e \
	"import {getConfigValue as g} from '@soxhub/config'; console.log(JSON.stringify({cid:g('v1.midship.clientId'),cert:(g('v1.midship.certificate')||''),uris:(g('v1.midship.redirectUris')||[]),url:g('v1.soxhub.url')}))" \
	2>/dev/null | tail -1)
if [ -z "$AB_JSON" ]; then
	no "could not resolve AB config (direnv/node)" "cd $AB && direnv allow .  (edited .envrc must be re-approved)"
	AB_JSON='{"cid":"","cert":"","uris":[],"url":""}'
else
	# The running v1 process is the source of truth: package.json's `_:start:api:v1` sets an
	# inline BASE_URL that wins over .envrc, so a fresh config eval can disagree with reality.
	AB_URL=$(for pid in $(pgrep -f "contexts/api/app.ts"); do ps eww "$pid" 2>/dev/null | tr ' ' '\n' | grep '^BASE_URL=' | head -1 | cut -d= -f2-; done | head -1)
	[ -z "$AB_URL" ] && AB_URL=$(printf '%s' "$AB_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['url'])" 2>/dev/null)
	ok "AB v1.soxhub.url = $AB_URL (from the running process)"
	if [ "$AB_URL" != "$OPTRO_LOCAL_BASE" ]; then
		no "AB soxhub.url ($AB_URL) != client base ($OPTRO_LOCAL_BASE)" \
		   "aud will mismatch. The AB v1 process hardcodes BASE_URL in package.json _:start:api:v1 (default http://localhost:9001). Either point it at $OPTRO_LOCAL_BASE, or drive the Midship client at AB's origin ($AB_URL)."
	fi
fi

echo "== Midship config + consistency + LIVE assertion probe =="
# Build a certifi+mkcert CA bundle so aiohttp trusts caddy's https cert during the probe.
CA_BUNDLE=""
CERTIFI=$(cd "$MID" && ENV=local_db poetry run python -c "import certifi;print(certifi.where())" 2>/dev/null | tail -1)
MKCERT_ROOT="$(mkcert -CAROOT 2>/dev/null)/rootCA.pem"
if [ -f "$CERTIFI" ] && [ -f "$MKCERT_ROOT" ]; then
	CA_BUNDLE="$(mktemp -t fleetcom-optro-ca).pem"
	cat "$CERTIFI" "$MKCERT_ROOT" > "$CA_BUNDLE" 2>/dev/null
fi

cd "$MID" && AB_JSON="$AB_JSON" OPTRO_LOCAL_BASE="$OPTRO_LOCAL_BASE" \
	ENV=local_db PYTHONWARNINGS=ignore SSL_CERT_FILE="${CA_BUNDLE:-}" poetry run python - <<'PY'
import os, json, base64, asyncio, aiohttp
from midship.config import config
from midship.app.api.auth.optro_oauth import build_client_assertion, _CLIENT_ASSERTION_ALG, _client_auth_params, _TOKEN_PATH

G="\033[32m"; R="\033[31m"; Y="\033[33m"; N="\033[0m"
ab = json.loads(os.environ.get("AB_JSON") or '{}')
base = os.environ.get("OPTRO_LOCAL_BASE", "https://localhost:9002")
rc = {"fail": 0}
def ok(m): print(f"  {G}✓{N} {m}")
def no(m, h): print(f"  {R}✗{N} {m}\n     {Y}↳ {h}{N}"); rc.__setitem__("fail", 1)

# client_id consistency
cid = config.OPTRO_CLIENT_ID
if cid and cid == ab.get("cid"): ok(f"client_id matches on both sides ({cid})")
else: no(f"client_id mismatch: midship={cid!r} vs AB={ab.get('cid')!r}",
         "set Midship OPTRO_CLIENT_ID == AB MIDSHIP_OAUTH_CLIENT_ID")

# signing key present + keypair pairing
if not config.OPTRO_CLIENT_PRIVATE_KEY:
    no("Midship OPTRO_CLIENT_PRIVATE_KEY not set", "generate an EC(ES256)/RSA(RS256) keypair; set base64-PEM private key")
else:
    ok(f"Midship signing key present (alg={_CLIENT_ASSERTION_ALG}, signed via Authlib RFC 7523)")
    try:
        from cryptography.hazmat.primitives import serialization as s
        k = s.load_pem_private_key(config.OPTRO_CLIENT_PRIVATE_KEY.encode(), password=None)
        pub = base64.b64encode(k.public_key().public_bytes(
            s.Encoding.PEM, s.PublicFormat.SubjectPublicKeyInfo)).decode()
        if pub.strip() == (ab.get("cert") or "").strip():
            ok("keypair PAIRED (Midship private ↔ AB MIDSHIP_OAUTH_CERTIFICATE)")
        else:
            no("keypair NOT paired with AB certificate",
               "AB MIDSHIP_OAUTH_CERTIFICATE must be the base64-PEM PUBLIC half of Midship's OPTRO_CLIENT_PRIVATE_KEY")
    except Exception as e:
        no(f"could not derive public key: {e}", "check OPTRO_CLIENT_PRIVATE_KEY is base64-encoded PEM")

# Midship renamed Config.OPTRO_REDIRECT_URI to MIDSHIP_REDIRECT_URI (config.py:221).
# Read the new name and fall back to the old one, so this script works against a
# checkout from either side of that rename instead of raising AttributeError.
_redirect_uri = getattr(config, "MIDSHIP_REDIRECT_URI", "") or getattr(config, "OPTRO_REDIRECT_URI", "")

# redirect_uri allowlisted
if _redirect_uri in (ab.get("uris") or []):
    ok("redirect_uri allowlisted on AB")
else:
    no(f"redirect_uri {_redirect_uri} not in AB MIDSHIP_OAUTH_REDIRECT_URIS {ab.get('uris')}",
       "add Midship's OPTRO_REDIRECT_URI to AB MIDSHIP_OAUTH_REDIRECT_URIS (JSON array)")

# LIVE probe: build assertion via Midship's real code, POST to AB, inspect the error kind
async def probe():
    params = _client_auth_params(base, config.OPTRO_CLIENT_ID)
    if "client_assertion" not in params:
        no("no client_assertion produced", "set OPTRO_CLIENT_PRIVATE_KEY")
        return
    body = {"grant_type": "authorization_code", "code": "verify-dummy", "code_verifier": "a"*43,
            "client_id": config.OPTRO_CLIENT_ID, "redirect_uri": _redirect_uri, **params}
    try:
        async with aiohttp.ClientSession() as ss:
            async with ss.post(f"{base}{_TOKEN_PATH}", data=body, allow_redirects=False) as r:
                t = (await r.text()).lower()
    except aiohttp.ClientConnectorCertificateError:
        no("aiohttp can't trust caddy's cert", "run with SSL_CERT_FILE=<certifi + $(mkcert -CAROOT)/rootCA.pem bundle>")
        return
    except Exception as e:
        no(f"probe request failed: {type(e).__name__}: {e}", f"is AB reachable at {base}?")
        return
    if "invalid_client" in t:
        no("AB REJECTED the assertion (invalid_client)",
           "aud/cert/alg/client_id mismatch — see the AB-config check above (usually the soxhub.url/aud mismatch)")
    elif "invalid_grant" in t or "authorization code" in t or r.status == 200:
        ok("✅ AB ACCEPTED the private_key_jwt assertion (only the dummy code rejected) — certificate path READY")
    else:
        no("inconclusive AB response", f"body: {t[:160]}")

asyncio.run(probe())
raise SystemExit(rc["fail"])
PY
PROBE_RC=$?
[ "$PROBE_RC" -ne 0 ] && FAIL=1
[ -n "$CA_BUNDLE" ] && rm -f "$CA_BUNDLE" 2>/dev/null

echo
if [ "$FAIL" -eq 0 ]; then
	printf "${G}Optro private_key_jwt flow: READY${N}  (browser E2E: log into AB at %s first, then Sign in with Optro)\n" "$OPTRO_LOCAL_BASE"
else
	printf "${R}Optro private_key_jwt flow: NOT ready${N}  — fix the ✗ items above (details: docs/optro-signin-local-e2e.md)\n"
fi
exit "$FAIL"
