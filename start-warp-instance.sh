#!/bin/bash

# Copyright (c) 2025 Ercin Dedeoglu
# Licensed under CC BY-NC 4.0 (Attribution-NonCommercial)
# https://github.com/ErcinDedeoglu/cloudflare-warp
#
# Helper script: starts a single WARP instance with isolated data/IPC paths.
# Called by entrypoint.sh as: /start-warp-instance.sh <instance> <port> <license_keys_csv> <timeout>
#
# Uses STATE_DIRECTORY and RUNTIME_DIRECTORY env vars (systemd convention)
# to give each warp-svc its own data dir and IPC socket — no extra
# capabilities required (no SYS_ADMIN, no mount namespaces).

set -e

INSTANCE=${1:?"Instance number required"}
PORT=${2:?"Port number required"}
LICENSE_KEYS_CSV=${3:-}
CONNECT_TIMEOUT=${4:-30}
WARP_HEALTH_INTERVAL=${WARP_HEALTH_INTERVAL:-0}
WARP_HEALTH_FAILURES=${WARP_HEALTH_FAILURES:-3}
WARP_RESTART_DELAY=${WARP_RESTART_DELAY:-5}
WARP_HEALTH_URL=${WARP_HEALTH_URL:-https://cloudflare.com/cdn-cgi/trace}
WARP_PID=""
DBUS_PID=""

# Parse license keys
ALL_KEYS=()
if [ -n "$LICENSE_KEYS_CSV" ]; then
    IFS=',' read -ra ALL_KEYS <<< "$LICENSE_KEYS_CSV"
fi
NUM_KEYS=${#ALL_KEYS[@]}

# Detect Zero Trust mode from environment (WARP_ORG is set by entrypoint.sh)
ZT_MODE=false
if [ -n "${WARP_ORG:-}" ]; then
    ZT_MODE=true
fi

DATA_DIR="/var/lib/cloudflare-warp/instance-${INSTANCE}"
RUN_DIR="/run/warp-${INSTANCE}"
DBUS_DIR="/run/dbus-${INSTANCE}"
DBUS_SOCK="${DBUS_DIR}/system_bus_socket"

echo "[Instance ${INSTANCE}] Starting (proxy port: ${PORT})..."
echo "[Instance ${INSTANCE}]   DATA_DIR=${DATA_DIR}"
echo "[Instance ${INSTANCE}]   RUN_DIR=${RUN_DIR}"
echo "[Instance ${INSTANCE}]   DBUS_DIR=${DBUS_DIR}"

is_non_negative_int() {
    [[ "${1:-}" =~ ^[0-9]+$ ]]
}

is_positive_int() {
    [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ]
}

if ! is_non_negative_int "$WARP_HEALTH_INTERVAL"; then
    echo "[Instance ${INSTANCE}] Error: WARP_HEALTH_INTERVAL must be a non-negative integer"
    exit 1
fi

if ! is_positive_int "$WARP_HEALTH_FAILURES"; then
    echo "[Instance ${INSTANCE}] Error: WARP_HEALTH_FAILURES must be a positive integer"
    exit 1
fi

if ! is_positive_int "$WARP_RESTART_DELAY"; then
    echo "[Instance ${INSTANCE}] Error: WARP_RESTART_DELAY must be a positive integer"
    exit 1
fi

cleanup_instance() {
    if [ -n "${WARP_PID:-}" ] && kill -0 "$WARP_PID" 2>/dev/null; then
        sudo kill "$WARP_PID" 2>/dev/null || true
        wait "$WARP_PID" 2>/dev/null || true
    fi

    if [ -n "${DBUS_PID:-}" ] && kill -0 "$DBUS_PID" 2>/dev/null; then
        sudo kill "$DBUS_PID" 2>/dev/null || true
        wait "$DBUS_PID" 2>/dev/null || true
    fi
}

shutdown_instance() {
    echo "[Instance ${INSTANCE}] Shutting down..."
    cleanup_instance
    exit 0
}

probe_warp_proxy() {
    curl -fsS --connect-timeout 5 --max-time 20 --socks5 "127.0.0.1:${PORT}" \
        "$WARP_HEALTH_URL" 2>/dev/null | grep -qE 'warp=(on|plus)'
}

restart_instance_script() {
    echo "[Instance ${INSTANCE}] Restarting in ${WARP_RESTART_DELAY}s..."
    cleanup_instance
    sleep "$WARP_RESTART_DELAY"
    exec "$0" "$INSTANCE" "$PORT" "$LICENSE_KEYS_CSV" "$CONNECT_TIMEOUT"
}

trap shutdown_instance SIGTERM SIGINT

# Create instance-specific directories
sudo mkdir -p "$DATA_DIR" "$RUN_DIR" "$DBUS_DIR"

# Start a per-instance D-Bus daemon (used for power-state notifications;
# non-critical in containers but reduces warp-svc log noise)
sudo dbus-daemon \
    --address="unix:path=${DBUS_SOCK}" \
    --config-file=/usr/share/dbus-1/system.conf \
    --nopidfile --nofork >/dev/null 2>&1 &
DBUS_PID=$!
sleep 1

# Write MDM config for Zero Trust (must happen before warp-svc reads data dir)
if [ "$ZT_MODE" = true ]; then
    sudo tee "${DATA_DIR}/mdm.xml" > /dev/null <<MDMEOF
<dict>
  <key>organization</key>
  <string>${WARP_ORG}</string>
  <key>auth_client_id</key>
  <string>${WARP_AUTH_CLIENT_ID}</string>
  <key>auth_client_secret</key>
  <string>${WARP_AUTH_CLIENT_SECRET}</string>
  <key>service_mode</key>
  <string>proxy</string>
  <key>proxy_port</key>
  <integer>${PORT}</integer>
  <key>auto_connect</key>
  <integer>1</integer>
  <key>switch_locked</key>
  <true/>
  <key>onboarding</key>
  <false/>
</dict>
MDMEOF
    echo "[Instance ${INSTANCE}] MDM config written (org: ${WARP_ORG}, port: ${PORT})"
fi

# Start warp-svc with custom paths via env vars
sudo env \
    STATE_DIRECTORY="$DATA_DIR" \
    RUNTIME_DIRECTORY="$RUN_DIR" \
    DBUS_SYSTEM_BUS_ADDRESS="unix:path=${DBUS_SOCK}" \
    warp-svc --accept-tos &
WARP_PID=$!

# Wait for the daemon to be ready
ELAPSED=0
while [ "$ELAPSED" -lt "$CONNECT_TIMEOUT" ]; do
    if sudo env RUNTIME_DIRECTORY="$RUN_DIR" DBUS_SYSTEM_BUS_ADDRESS="unix:path=${DBUS_SOCK}" \
        warp-cli --accept-tos status 2>/dev/null | grep -qE '(Status|Connected)'; then
        echo "[Instance ${INSTANCE}] WARP daemon ready after ${ELAPSED}s"
        break
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

if [ "$ELAPSED" -ge "$CONNECT_TIMEOUT" ]; then
    echo "[Instance ${INSTANCE}] Warning: daemon may not be fully ready after ${CONNECT_TIMEOUT}s, continuing anyway..."
fi

# Helper: run warp-cli for this instance
wcli() {
    sudo env RUNTIME_DIRECTORY="$RUN_DIR" DBUS_SYSTEM_BUS_ADDRESS="unix:path=${DBUS_SOCK}" \
        warp-cli --accept-tos "$@"
}

if [ "$ZT_MODE" = true ]; then
    # Zero Trust: warp-svc handles enrollment automatically via MDM config.
    # MDM sets service_mode=proxy and proxy_port; connect as safety net.
    echo "[Instance ${INSTANCE}] Zero Trust mode: waiting for automatic enrollment..."
    wcli connect 2>/dev/null || true
    wcli debug qlog disable || true
    echo "[Instance ${INSTANCE}] WARP Zero Trust proxy active on localhost:${PORT}"
else
    # Register and apply license (tries preferred key first, falls back to others)
    STORED_KEY_FILE="${DATA_DIR}/.license_key"

    try_license_keys() {
        local label=$1
        # Round-robin: instance N starts at key N so devices spread evenly across keys
        local start_idx=$((INSTANCE % NUM_KEYS))
        for offset in $(seq 0 $((NUM_KEYS - 1))); do
            local idx=$(( (start_idx + offset) % NUM_KEYS ))
            local key="${ALL_KEYS[$idx]}"
            echo "[Instance ${INSTANCE}] Trying license key $((idx + 1))/${NUM_KEYS}..."
            local out
            out=$(wcli registration license "$key" 2>&1) && {
                echo "[Instance ${INSTANCE}] License ${label} (key $((idx + 1)))!"
                echo -n "$LICENSE_KEYS_CSV" | sudo tee "$STORED_KEY_FILE" > /dev/null
                return 0
            } || {
                echo "[Instance ${INSTANCE}] Key $((idx + 1)) failed: ${out}"
            }
        done
        echo "[Instance ${INSTANCE}] All ${NUM_KEYS} license keys failed, running as free WARP"
        return 1
    }

    if [ ! -f "${DATA_DIR}/reg.json" ]; then
        REG_OK=false
        MAX_REG_ATTEMPTS=15
        for attempt in $(seq 1 $MAX_REG_ATTEMPTS); do
            REG_OUT=$(wcli registration new 2>&1) && {
                echo "[Instance ${INSTANCE}] Registered!"
                REG_OK=true
                break
            } || {
                # Exponential backoff with jitter: 2^attempt + random jitter, capped at 120s
                BACKOFF=$(( (1 << attempt) + RANDOM % (1 << attempt) ))
                [ "$BACKOFF" -gt 120 ] && BACKOFF=120
                echo "[Instance ${INSTANCE}] Registration attempt ${attempt}/${MAX_REG_ATTEMPTS} failed: ${REG_OUT} (retrying in ${BACKOFF}s)"
                sleep "$BACKOFF"
            }
        done
        if [ "$REG_OK" = false ]; then
            echo "[Instance ${INSTANCE}] Warning: registration failed after ${MAX_REG_ATTEMPTS} attempts, continuing without license..."
        fi
        if [ "$REG_OK" = true ] && [ "$NUM_KEYS" -gt 0 ]; then
            try_license_keys "applied" || true
        fi
    else
        # Re-apply license if keys have changed since last registration
        STORED_KEYS=""
        [ -f "$STORED_KEY_FILE" ] && STORED_KEYS=$(sudo cat "$STORED_KEY_FILE" 2>/dev/null)
        if [ "$NUM_KEYS" -gt 0 ] && [ "$LICENSE_KEYS_CSV" != "$STORED_KEYS" ]; then
            echo "[Instance ${INSTANCE}] License key(s) changed, re-applying..."
            try_license_keys "updated" || true
        fi
    fi

    # Set proxy mode, custom port, and connect
    wcli mode proxy
    wcli proxy port "$PORT"
    wcli connect
    wcli debug qlog disable || true

    echo "[Instance ${INSTANCE}] WARP proxy active on localhost:${PORT}"
fi

if [ "$WARP_HEALTH_INTERVAL" -eq 0 ]; then
    wait "$WARP_PID" || restart_instance_script
    restart_instance_script
fi

FAILURES=0
while true; do
    if ! kill -0 "$WARP_PID" 2>/dev/null; then
        wait "$WARP_PID" 2>/dev/null || true
        echo "[Instance ${INSTANCE}] warp-svc exited"
        restart_instance_script
    fi

    sleep "$WARP_HEALTH_INTERVAL"

    if probe_warp_proxy; then
        if [ "$FAILURES" -gt 0 ]; then
            echo "[Instance ${INSTANCE}] Health recovered"
        fi
        FAILURES=0
        continue
    fi

    FAILURES=$((FAILURES + 1))
    echo "[Instance ${INSTANCE}] Health probe failed (${FAILURES}/${WARP_HEALTH_FAILURES})"

    if [ "$FAILURES" -lt "$WARP_HEALTH_FAILURES" ]; then
        wcli connect >/dev/null 2>&1 || true
        continue
    fi

    echo "[Instance ${INSTANCE}] Unhealthy after ${FAILURES} consecutive probes"
    restart_instance_script
done
