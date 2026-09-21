#!/bin/bash
# FLEETCOM doctor: verify every expected port is held by the expected
# process (or free), and run basic health checks. Safe to run any time.
set -uo pipefail

GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; NC=$'\033[0m'
FAIL=0

# Sourced for the checkout report below. Doctor previously read no paths at all,
# which meant a green report could describe a fleet booted from a different
# checkout than the one being edited — the failure a worktree override makes
# easy to hit and hard to see.
_doctor_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_doctor_here/paths.sh"

check_port() { # port, expected pattern (in lsof COMMAND or name), label
	local port=$1 pattern=$2 label=$3
	local holder
	holder=$(lsof -iTCP:"$port" -sTCP:LISTEN -P -n 2>/dev/null | awk 'NR==2 {print $1}')
	if [ -z "$holder" ]; then
		printf "%s✗ %-5s %-40s NOT LISTENING%s\n" "$RED" "$port" "$label" "$NC"
		FAIL=1
	elif [[ "$holder" == *"$pattern"* ]] || [ "$pattern" = "any" ]; then
		printf "%s✓ %-5s %-40s %s%s\n" "$GREEN" "$port" "$label" "$holder" "$NC"
	else
		printf "%s? %-5s %-40s held by %s (expected %s)%s\n" "$YELLOW" "$port" "$label" "$holder" "$pattern" "$NC"
	fi
}

check_http() { # url, expected code, label
	local url=$1 want=$2 label=$3 code
	code=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 "$url")
	if [ "$code" = "$want" ]; then
		printf "%s✓ %s -> %s%s\n" "$GREEN" "$label" "$code" "$NC"
	else
		printf "%s✗ %s -> %s (want %s)%s\n" "$RED" "$label" "$code" "$want" "$NC"
		FAIL=1
	fi
}

check_process() { # pgrep pattern, label
	local pattern=$1 label=$2
	if pgrep -f "$pattern" >/dev/null 2>&1; then
		printf "%s✓ %-5s %-40s running%s\n" "$GREEN" "" "$label" "$NC"
	else
		printf "%s✗ %-5s %-40s NOT RUNNING%s\n" "$RED" "" "$label" "$NC"
		FAIL=1
	fi
}

# Printed first, because every port and health line below describes whatever
# was booted from these paths. A worktree override that is stale, or one a
# previous task left recorded, is otherwise invisible in a green report.
echo "== Checkouts =="
fleetcom_print_checkouts

echo "== Midship (fixed ports) =="
check_port 5173 node   "Vite frontend"
check_port 8000 Python "FastAPI API"
check_port 8080 docke  "WOPI (docker)"
check_port 9980 docke  "Collabora/Onyx (docker)"
check_port 5432 docke  "Postgres (docker)"
check_port 6379 docke  "Redis (docker)"
check_port 1337 docke  "Hatchet server (docker)"
check_port 7077 docke  "Hatchet gRPC (docker)"
check_process "midship.heretic.hatchet.worker" "Hatchet workers (document/procedure/screenshot)"

echo "== AuditBoard =="
check_port 5433  postgres "native Postgres (moved)"
check_port 6382  redis    "native Redis (moved)"
check_port 9001  node     "API v1 (Hapi)"
check_port 9003  node     "API v2 (Hono)"
check_port 9002  any      "Caddy HTTPS entrypoint"
check_port 9006  any      "client Vite"
check_port 18080 docke    "Conductor API (moved)"
check_port 3000  docke    "Conductor UI"
check_port 8004  docke    "ML local service (moved)"
check_port 8001  docke    "ML global service"
check_port 3008  docke    "Poxa websockets"
check_port 9000  docke    "MinIO"

echo "== Cascade =="
check_port 8010  docke "Django API"
check_port 8011  docke "Daphne WS"
check_port 33060 docke "Postgres"
check_port 63790 docke "Redis (moved host publish)"
check_port 6010  docke "MinIO API"
check_port 8088  any   "Parcel client"

echo "== Health checks =="
check_http http://localhost:8000/health/db     200 "Midship API (+DB)"
check_http http://localhost:9001/api/v1/health 200 "AB API v1"
check_http https://localhost:9002/login        200 "AB Caddy/login"
check_http http://localhost:8010/api/          401 "Cascade API (401 = auth wall, healthy)"
check_http http://localhost:8088/              200 "Cascade client"

exit $FAIL
