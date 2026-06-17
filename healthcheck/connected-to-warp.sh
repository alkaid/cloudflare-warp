#!/bin/bash

# Check WARP connection directly through WARP's internal proxy.
# This bypasses GOST authentication for healthcheck purposes.
#
# In multi-instance mode, /tmp/healthy-warp-ports lists the planned direct
# instance ports. Check every listed port by default so partial instance loss is
# visible instead of hidden by one surviving instance.
# Falls back to port 40000 for single-instance mode.

set -e

PORTS_FILE="${WARP_HEALTHCHECK_PORTS_FILE:-/tmp/healthy-warp-ports}"
HEALTH_URL="${WARP_HEALTH_URL:-https://cloudflare.com/cdn-cgi/trace}"
MIN_HEALTHY="${WARP_HEALTHCHECK_MIN_HEALTHY:-}"
PORTS=()

if [ -f "$PORTS_FILE" ] && [ -s "$PORTS_FILE" ]; then
    while IFS= read -r port; do
        [ -n "$port" ] && PORTS+=("$port")
    done < "$PORTS_FILE"
else
    PORTS=(40000)
fi

TOTAL=${#PORTS[@]}

if [ -z "$MIN_HEALTHY" ]; then
    MIN_HEALTHY=$TOTAL
fi

if ! [[ "$MIN_HEALTHY" =~ ^[0-9]+$ ]] || [ "$MIN_HEALTHY" -lt 1 ]; then
    echo "Invalid WARP_HEALTHCHECK_MIN_HEALTHY: ${MIN_HEALTHY}"
    exit 1
fi

RESULT_DIR=$(mktemp -d)
cleanup() {
    rm -rf "$RESULT_DIR"
}
trap cleanup EXIT

PIDS=()

for port in "${PORTS[@]}"; do
    (
        if curl -fsS --connect-timeout 3 --max-time 10 --socks5-hostname "127.0.0.1:${port}" \
            "$HEALTH_URL" 2>/dev/null | grep -qE "warp=(plus|on)"; then
            : > "${RESULT_DIR}/${port}.ok"
        else
            : > "${RESULT_DIR}/${port}.failed"
        fi
    ) &
    PIDS+=($!)
done

for pid in "${PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
done

HEALTHY=0
FAILED=()
for port in "${PORTS[@]}"; do
    if [ -f "${RESULT_DIR}/${port}.ok" ]; then
        HEALTHY=$((HEALTHY + 1))
    else
        FAILED+=("$port")
    fi
done

if [ "$HEALTHY" -ge "$MIN_HEALTHY" ]; then
    exit 0
fi

echo "WARP healthcheck failed: ${HEALTHY}/${TOTAL} healthy; required ${MIN_HEALTHY}; failed ports: ${FAILED[*]}"
exit 1
