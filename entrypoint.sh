#!/bin/bash

# Copyright (c) 2025 Ercin Dedeoglu
# Licensed under CC BY-NC 4.0 (Attribution-NonCommercial)
# https://github.com/ErcinDedeoglu/cloudflare-warp
#
# Commercial use is prohibited. For personal/educational use,
# you must provide public attribution to this project.

set -e

WARP_INSTANCES=${WARP_INSTANCES:-1}
START_GOST=${START_GOST:-false}
WARP_INSTANCE_PORT_BASE=${WARP_INSTANCE_PORT_BASE:-40000}
WARP_INTERNAL_PORT_BASE=${WARP_INTERNAL_PORT_BASE:-41000}
WARP_HEALTH_INTERVAL=${WARP_HEALTH_INTERVAL:-60}
WARP_HEALTH_FAILURES=${WARP_HEALTH_FAILURES:-3}
WARP_HEALTH_URL=${WARP_HEALTH_URL:-https://cloudflare.com/cdn-cgi/trace}
WARP_SUPERVISOR_INTERVAL=${WARP_SUPERVISOR_INTERVAL:-30}
WARP_SUPERVISOR_PID_DIR=${WARP_SUPERVISOR_PID_DIR:-/tmp/warp-supervisor}
SUPERVISOR_PID=""
GOST_PID=""
SOCAT_PIDS=()
SOCAT_EXTERNAL_PORTS=()
SOCAT_INTERNAL_PORTS=()
INSTANCE_PIDS=()
INSTANCE_INTERNAL_PORTS=()

is_true() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

start_instance_port_forward() {
    local external_port="$1"
    local internal_port="$2"
    local index=${3:-${#SOCAT_PIDS[@]}}

    mkdir -p "$WARP_SUPERVISOR_PID_DIR"
    echo "Exposing WARP instance port on 0.0.0.0:${external_port} -> 127.0.0.1:${internal_port}"
    socat "TCP-LISTEN:${external_port},fork,reuseaddr,bind=0.0.0.0" "TCP:127.0.0.1:${internal_port}" &
    SOCAT_PIDS[$index]=$!
    SOCAT_EXTERNAL_PORTS[$index]=$external_port
    SOCAT_INTERNAL_PORTS[$index]=$internal_port
    printf "%s\n" "$!" > "${WARP_SUPERVISOR_PID_DIR}/socat-${index}.pid"
}

start_warp_instance_process() {
    local instance="$1"
    local internal_port="$2"

    mkdir -p "$WARP_SUPERVISOR_PID_DIR"
    /start-warp-instance.sh \
        "$instance" "$internal_port" "$LICENSE_KEYS_CSV" "${WARP_CONNECT_TIMEOUT:-30}" &
    INSTANCE_PIDS[$instance]=$!
    INSTANCE_INTERNAL_PORTS[$instance]=$internal_port
    printf "%s\n" "$!" > "${WARP_SUPERVISOR_PID_DIR}/instance-${instance}.pid"
}

supervise_multi_instance_children() {
    while true; do
        sleep "$WARP_SUPERVISOR_INTERVAL"

        for i in $(seq 0 $((WARP_INSTANCES - 1))); do
            local pid="${INSTANCE_PIDS[$i]:-}"
            local pid_file="${WARP_SUPERVISOR_PID_DIR}/instance-${i}.pid"
            local internal_port="${INSTANCE_INTERNAL_PORTS[$i]:-$((WARP_INTERNAL_PORT_BASE + i))}"

            if [ -f "$pid_file" ]; then
                pid=$(cat "$pid_file" 2>/dev/null || true)
            fi

            if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
                if [ -n "$pid" ]; then
                    wait "$pid" 2>/dev/null || true
                fi
                echo "[Supervisor] Instance ${i} process exited; restarting"
                start_warp_instance_process "$i" "$internal_port"
            fi
        done

        for i in "${!SOCAT_PIDS[@]}"; do
            local pid="${SOCAT_PIDS[$i]:-}"
            local pid_file="${WARP_SUPERVISOR_PID_DIR}/socat-${i}.pid"
            local external_port="${SOCAT_EXTERNAL_PORTS[$i]:-}"
            local internal_port="${SOCAT_INTERNAL_PORTS[$i]:-}"

            if [ -f "$pid_file" ]; then
                pid=$(cat "$pid_file" 2>/dev/null || true)
            fi

            if [ -z "$external_port" ] || [ -z "$internal_port" ]; then
                continue
            fi

            if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
                if [ -n "$pid" ]; then
                    wait "$pid" 2>/dev/null || true
                fi
                echo "[Supervisor] Port forward ${external_port}->${internal_port} exited; restarting"
                start_instance_port_forward "$external_port" "$internal_port" "$i"
            fi
        done
    done
}

supervise_single_instance() {
    local warp_pid="$1"
    local external_port="$2"
    local failures=0

    while true; do
        if [ "$WARP_HEALTH_INTERVAL" -eq 0 ]; then
            sleep 5
        else
            sleep "$WARP_HEALTH_INTERVAL"
        fi

        if ! kill -0 "$warp_pid" 2>/dev/null; then
            wait "$warp_pid" 2>/dev/null || true
            echo "[Supervisor] Single WARP daemon exited; stopping container for restart"
            kill -TERM "$$" 2>/dev/null || true
            exit 1
        fi

        if [ "$WARP_HEALTH_INTERVAL" -eq 0 ]; then
            continue
        fi

        if curl -fsS --connect-timeout 5 --max-time 20 --socks5-hostname "127.0.0.1:${external_port}" \
            "$WARP_HEALTH_URL" 2>/dev/null | grep -qE 'warp=(on|plus)'; then
            if [ "$failures" -gt 0 ]; then
                echo "[Supervisor] Single WARP health recovered"
            fi
            failures=0
            continue
        fi

        failures=$((failures + 1))
        echo "[Supervisor] Single WARP health probe failed (${failures}/${WARP_HEALTH_FAILURES})"
        warp-cli --accept-tos connect >/dev/null 2>&1 || true

        if [ "$failures" -ge "$WARP_HEALTH_FAILURES" ]; then
            echo "[Supervisor] Single WARP unhealthy; stopping container for restart"
            kill -TERM "$$" 2>/dev/null || true
            exit 1
        fi
    done
}

cleanup_multi_instance() {
    echo "Shutting down ${WARP_INSTANCES} WARP instances..."
    kill "${SUPERVISOR_PID:-}" 2>/dev/null || true

    # Deregister devices so they don't count against the WARP+ per-key limit
    # (or Zero Trust's 50-device limit). Without this, each container recreation
    # would leave orphaned device registrations on Cloudflare's side.
    for i in $(seq 0 $((WARP_INSTANCES - 1))); do
        local run="/run/warp-${i}"
        local dbus="/run/dbus-${i}/system_bus_socket"
        sudo env RUNTIME_DIRECTORY="$run" DBUS_SYSTEM_BUS_ADDRESS="unix:path=${dbus}" \
            warp-cli --accept-tos registration delete 2>/dev/null || true
    done

    for pid in "${INSTANCE_PIDS[@]}"; do
        sudo kill "$pid" 2>/dev/null || true
    done
    for pid_file in "${WARP_SUPERVISOR_PID_DIR}"/instance-*.pid; do
        [ -f "$pid_file" ] || continue
        local pid
        pid=$(cat "$pid_file" 2>/dev/null || true)
        [ -n "$pid" ] && sudo kill "$pid" 2>/dev/null || true
    done

    for pid in "${SOCAT_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    for pid_file in "${WARP_SUPERVISOR_PID_DIR}"/socat-*.pid; do
        [ -f "$pid_file" ] || continue
        local pid
        pid=$(cat "$pid_file" 2>/dev/null || true)
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    done

    kill "${GOST_PID:-}" 2>/dev/null || true
    wait
}

# Validate WARP_INSTANCES
if ! [[ "$WARP_INSTANCES" =~ ^[0-9]+$ ]] || [ "$WARP_INSTANCES" -lt 1 ]; then
    echo "Error: WARP_INSTANCES must be a positive integer"
    exit 1
fi

if ! [[ "$WARP_INSTANCE_PORT_BASE" =~ ^[0-9]+$ ]] || [ "$WARP_INSTANCE_PORT_BASE" -lt 1024 ]; then
    echo "Error: WARP_INSTANCE_PORT_BASE must be an integer >= 1024"
    exit 1
fi

if ! [[ "$WARP_INTERNAL_PORT_BASE" =~ ^[0-9]+$ ]] || [ "$WARP_INTERNAL_PORT_BASE" -lt 1024 ]; then
    echo "Error: WARP_INTERNAL_PORT_BASE must be an integer >= 1024"
    exit 1
fi

if ! [[ "$WARP_HEALTH_INTERVAL" =~ ^[0-9]+$ ]]; then
    echo "Error: WARP_HEALTH_INTERVAL must be a non-negative integer"
    exit 1
fi

if ! [[ "$WARP_HEALTH_FAILURES" =~ ^[0-9]+$ ]] || [ "$WARP_HEALTH_FAILURES" -lt 1 ]; then
    echo "Error: WARP_HEALTH_FAILURES must be a positive integer"
    exit 1
fi

if ! [[ "$WARP_SUPERVISOR_INTERVAL" =~ ^[0-9]+$ ]] || [ "$WARP_SUPERVISOR_INTERVAL" -lt 1 ]; then
    echo "Error: WARP_SUPERVISOR_INTERVAL must be a positive integer"
    exit 1
fi

# ---- Parse license key(s) — WARP_LICENSE_KEY accepts comma-separated values ----
LICENSE_KEYS=()
if [ -n "${WARP_LICENSE_KEY:-}" ]; then
    IFS=',' read -ra _RAW_KEYS <<< "$WARP_LICENSE_KEY"
    for _k in "${_RAW_KEYS[@]}"; do
        _k=$(echo "$_k" | xargs)
        [ -n "$_k" ] && LICENSE_KEYS+=("$_k")
    done
fi
NUM_KEYS=${#LICENSE_KEYS[@]}

# Reconstruct cleaned CSV for passing to instance scripts and change detection
LICENSE_KEYS_CSV=""
if [ "$NUM_KEYS" -gt 0 ]; then
    LICENSE_KEYS_CSV=$(IFS=','; echo "${LICENSE_KEYS[*]}")
fi

# ---- Zero Trust enrollment mode (service token auth) ----
ZT_MODE=false
if [ -n "${WARP_ORG:-}" ]; then
    if [ -z "${WARP_AUTH_CLIENT_ID:-}" ] || [ -z "${WARP_AUTH_CLIENT_SECRET:-}" ]; then
        echo "Error: WARP_ORG is set but WARP_AUTH_CLIENT_ID and/or WARP_AUTH_CLIENT_SECRET are missing."
        echo "All three variables are required for Zero Trust enrollment."
        exit 1
    fi
    if [ "$NUM_KEYS" -gt 0 ]; then
        echo "Error: WARP_ORG and WARP_LICENSE_KEY are mutually exclusive."
        echo "Use WARP_ORG for Zero Trust enrollment OR WARP_LICENSE_KEY for WARP+ — not both."
        exit 1
    fi
    ZT_MODE=true
fi

# ---- helper: write MDM XML for Zero Trust enrollment ----
# warp-svc reads mdm.xml from its data directory on startup and auto-enrolls
# into the Zero Trust org using the service token — no browser required.
# $1 = data directory, $2 = proxy port
write_mdm_xml() {
    local data_dir="$1"
    local port="$2"
    local mdm_file="${data_dir}/mdm.xml"
    sudo tee "$mdm_file" > /dev/null <<MDMEOF
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
  <integer>${port}</integer>
  <key>auto_connect</key>
  <integer>1</integer>
  <key>switch_locked</key>
  <true/>
  <key>onboarding</key>
  <false/>
</dict>
MDMEOF
    echo "MDM config written to ${mdm_file} (org: ${WARP_ORG}, port: ${port})"
}

# ==============================================================================
# SINGLE INSTANCE MODE
# ==============================================================================
if [ "$WARP_INSTANCES" -eq 1 ]; then
    EXTERNAL_PORT=${WARP_INSTANCE_PORT_BASE}
    INTERNAL_PORT=${WARP_INTERNAL_PORT_BASE}

    # start dbus
    sudo mkdir -p /run/dbus
    if [ -f /run/dbus/pid ]; then
        sudo rm /run/dbus/pid
    fi
    sudo dbus-daemon --config-file=/usr/share/dbus-1/system.conf

    # Write MDM config for Zero Trust (must happen before warp-svc reads data dir)
    if [ "$ZT_MODE" = true ]; then
        write_mdm_xml "/var/lib/cloudflare-warp" "$INTERNAL_PORT"
    fi

    # start the daemon
    sudo warp-svc --accept-tos &
    WARP_PID=$!

    # wait for the daemon to be ready
    MAX_WAIT=${WARP_CONNECT_TIMEOUT:-30}
    INTERVAL=2
    ELAPSED=0

    echo "Waiting for WARP daemon to be ready (max ${MAX_WAIT}s)..."
    while [ $ELAPSED -lt $MAX_WAIT ]; do
        if warp-cli status 2>/dev/null | grep -qE "(Status|Connected)"; then
            echo "WARP daemon is ready after ${ELAPSED}s"
            break
        fi
        sleep $INTERVAL
        ELAPSED=$((ELAPSED + INTERVAL))
    done

    if [ $ELAPSED -ge $MAX_WAIT ]; then
        echo "Warning: WARP daemon may not be fully ready after ${MAX_WAIT}s, continuing anyway..."
    fi

    if [ "$ZT_MODE" = true ]; then
        # Zero Trust: warp-svc handles enrollment automatically via MDM config.
        # MDM sets service_mode=proxy and proxy_port; connect as safety net.
        echo "Zero Trust mode: waiting for automatic enrollment via service token..."
        warp-cli --accept-tos connect 2>/dev/null || true
        echo "WARP Zero Trust proxy active on localhost:${INTERNAL_PORT} (org: ${WARP_ORG})"
    else
        # register and apply license (tries all keys in order, stops on first success)
        STORED_KEY_FILE="/var/lib/cloudflare-warp/.license_key"

        apply_license_keys() {
            local label=$1
            for i in $(seq 0 $((NUM_KEYS - 1))); do
                local key="${LICENSE_KEYS[$i]}"
                echo "Trying license key $((i + 1))/${NUM_KEYS}..."
                local out
                out=$(warp-cli registration license "$key" 2>&1) && {
                    echo "Warp license ${label} (key $((i + 1)))!"
                    echo -n "$LICENSE_KEYS_CSV" | sudo tee "$STORED_KEY_FILE" > /dev/null
                    return 0
                } || {
                    echo "Key $((i + 1)) failed: ${out}"
                }
            done
            echo "All ${NUM_KEYS} license keys failed, running as free WARP"
            return 1
        }

        if [ ! -f /var/lib/cloudflare-warp/reg.json ]; then
            REG_OK=false
            MAX_REG_ATTEMPTS=10
            for attempt in $(seq 1 $MAX_REG_ATTEMPTS); do
                REG_OUT=$(warp-cli registration new 2>&1) && {
                    echo "Warp client registered!"
                    REG_OK=true
                    break
                } || {
                    # Exponential backoff with jitter: 2^attempt + random jitter, capped at 120s
                    BACKOFF=$(( (1 << attempt) + RANDOM % (1 << attempt) ))
                    [ "$BACKOFF" -gt 120 ] && BACKOFF=120
                    echo "Registration attempt ${attempt}/${MAX_REG_ATTEMPTS} failed: ${REG_OUT} (retrying in ${BACKOFF}s)"
                    sleep "$BACKOFF"
                }
            done
            if [ "$REG_OK" = false ]; then
                echo "Warning: registration failed after ${MAX_REG_ATTEMPTS} attempts, continuing without license..."
            fi
            if [ "$REG_OK" = true ] && [ "$NUM_KEYS" -gt 0 ]; then
                apply_license_keys "registered" || true
            fi
        else
            # Re-apply license if keys have changed since last registration
            STORED_KEYS=""
            [ -f "$STORED_KEY_FILE" ] && STORED_KEYS=$(sudo cat "$STORED_KEY_FILE" 2>/dev/null)
            if [ "$NUM_KEYS" -gt 0 ] && [ "$LICENSE_KEYS_CSV" != "$STORED_KEYS" ]; then
                echo "License key(s) changed, re-applying..."
                apply_license_keys "updated" || true
            fi
        fi

        # set proxy mode and connect
        warp-cli --accept-tos mode proxy
        warp-cli --accept-tos proxy port "$INTERNAL_PORT"
        warp-cli --accept-tos connect
        echo "WARP proxy mode active on localhost:${INTERNAL_PORT}"
    fi

    # disable qlog
    warp-cli --accept-tos debug qlog disable || true

    start_instance_port_forward "$EXTERNAL_PORT" "$INTERNAL_PORT"
    printf "%s\n" "$EXTERNAL_PORT" > /tmp/healthy-warp-ports
    supervise_single_instance "$WARP_PID" "$EXTERNAL_PORT" &
    SUPERVISOR_PID=$!

    if ! is_true "$START_GOST"; then
        echo "START_GOST is disabled; WARP instance is available on :${EXTERNAL_PORT}"
        wait "$WARP_PID"
        kill "$SUPERVISOR_PID" 2>/dev/null || true
        exit 0
    fi

    # Build GOST arguments
    GOST_LISTEN=":1080"
    GOST_OPTS=""

    if [ -n "$PROXY_USER" ] && [ -n "$PROXY_PASS" ]; then
        GOST_LISTEN="${PROXY_USER}:${PROXY_PASS}@:1080"
        echo "Proxy authentication enabled for user: ${PROXY_USER}"
    fi

    CLIMITER=${PROXY_MAX_CONN:-10}
    RLIMITER=${PROXY_MAX_RPS:-10}
    GOST_OPTS="climiter=${CLIMITER}&rlimiter=${RLIMITER}"

    if [ -n "$PROXY_ALLOWED_IPS" ]; then
        GOST_OPTS="${GOST_OPTS}&admission=~${PROXY_ALLOWED_IPS}"
        echo "IP whitelist enabled: ${PROXY_ALLOWED_IPS}"
    fi

    # Build HTTP proxy listen addresses
    HTTP_WARP_LISTEN=":8080"
    HTTP_DIRECT_LISTEN=":8081"
    if [ -n "$PROXY_USER" ] && [ -n "$PROXY_PASS" ]; then
        HTTP_WARP_LISTEN="${PROXY_USER}:${PROXY_PASS}@:8080"
        HTTP_DIRECT_LISTEN="${PROXY_USER}:${PROXY_PASS}@:8081"
    fi

    # Build direct proxy listen address
    DIRECT_LISTEN=":1081"
    if [ -n "$PROXY_USER" ] && [ -n "$PROXY_PASS" ]; then
        DIRECT_LISTEN="${PROXY_USER}:${PROXY_PASS}@:1081"
    fi

    # Start direct proxies (SOCKS5 on 1081, HTTP on 8081) - bypass WARP
    echo "Starting direct proxies on :1081 (SOCKS5) and :8081 (HTTP) -> Internet (no WARP)"
    gost -L "socks5://${DIRECT_LISTEN}?${GOST_OPTS}" -L "http://${HTTP_DIRECT_LISTEN}?${GOST_OPTS}" &

    # Start Shadowsocks servers (for mobile VPN clients)
    # Use PROXY_PASS if set, otherwise default to 'cloudflare-warp'
    SS_PASS=${PROXY_PASS:-cloudflare-warp}
    SS_METHOD=${SS_METHOD:-chacha20-ietf-poly1305}

    echo "Starting Shadowsocks servers:"
    echo "  - WARP exit on :8388 (method: ${SS_METHOD})"
    echo "  - Direct exit on :8389 (method: ${SS_METHOD})"

    # Shadowsocks through WARP
    gost -L "ss://${SS_METHOD}:${SS_PASS}@:8388?${GOST_OPTS}" -F socks5://127.0.0.1:${EXTERNAL_PORT} &

    # Shadowsocks direct (bypass WARP)
    gost -L "ss://${SS_METHOD}:${SS_PASS}@:8389?${GOST_OPTS}" &

    # Generate connection info for mobile apps
    echo ""
    echo "=== Shadowsocks Connection Info ==="
    echo "For mobile apps (Shadowsocks, Shadowrocket, v2rayNG):"
    echo "  Server: <YOUR_SERVER_IP>"
    echo "  Port (WARP): 8388"
    echo "  Port (Direct): 8389"
    if [ -n "$PROXY_PASS" ]; then
        echo "  Password: <your PROXY_PASS>"
    else
        echo "  Password: cloudflare-warp"
    fi
    echo "  Method: ${SS_METHOD}"
    echo "==================================="
    echo ""

    # Start WARP proxies (SOCKS5 on 1080, HTTP on 8080) - chain to WARP
    echo "Starting WARP proxies on :1080 (SOCKS5) and :8080 (HTTP) -> WARP proxy"
    gost -L "socks5://${GOST_LISTEN}?${GOST_OPTS}" -L "http://${HTTP_WARP_LISTEN}?${GOST_OPTS}" -F socks5://127.0.0.1:${EXTERNAL_PORT}

    # Unreachable — gost above runs in the foreground
    exit 0
fi

# ==============================================================================
# MULTI-INSTANCE MODE (WARP_INSTANCES > 1)
#
# Each warp-svc uses STATE_DIRECTORY and RUNTIME_DIRECTORY env vars
# (systemd convention) to see its own data dir and IPC socket.
# Each instance gets a unique Cloudflare IP for round-robin rotation.
#
# No extra Docker capabilities required (no SYS_ADMIN).
# ==============================================================================

echo "========================================"
echo " Multi-Instance WARP Mode"
echo " Instances : ${WARP_INSTANCES}"
if [ "$ZT_MODE" = true ]; then
echo " Enrollment : Zero Trust (${WARP_ORG})"
elif [ "$NUM_KEYS" -gt 0 ]; then
echo " License keys : ${NUM_KEYS} (auto-fallback)"
fi
echo " Strategy  : round-robin"
echo "========================================"
echo ""

# ---- helper: generate GOST YAML config for round-robin ----
generate_gost_config() {
    local config_file="/tmp/gost-config.yaml"
    local ss_pass="${PROXY_PASS:-cloudflare-warp}"
    local ss_method="${SS_METHOD:-chacha20-ietf-poly1305}"
    local climiter_val="${PROXY_MAX_CONN:-10}"
    local rlimiter_val="${PROXY_MAX_RPS:-10}"

    # --- chain node list (all planned instance ports) ---
    local nodes=""
    local planned_ports=""
    for i in $(seq 0 $((WARP_INSTANCES - 1))); do
        local port=$((WARP_INSTANCE_PORT_BASE + i))
        nodes="${nodes}
    - name: warp-${i}
      addr: 127.0.0.1:${port}
      connector:
        type: socks5
      dialer:
        type: tcp"
        planned_ports="${planned_ports}${port}\n"
    done

    # Persist planned ports for the healthcheck script. GOST will skip failed
    # nodes and retry them; the healthcheck reports how many planned ports work.
    printf "%b" "$planned_ports" > /tmp/healthy-warp-ports

    # --- proxy auth block (SOCKS5 / HTTP handlers) ---
    local proxy_auth=""
    if [ -n "$PROXY_USER" ] && [ -n "$PROXY_PASS" ]; then
        proxy_auth="
    auth:
      username: ${PROXY_USER}
      password: ${PROXY_PASS}"
    fi

    # --- admission (IP whitelist) ---
    local admission_ref=""
    local admission_section=""
    if [ -n "$PROXY_ALLOWED_IPS" ]; then
        admission_ref="
  admission: admission-0"
        local matchers=""
        IFS=',' read -ra IPS <<< "$PROXY_ALLOWED_IPS"
        for ip in "${IPS[@]}"; do
            ip=$(echo "$ip" | xargs)  # trim whitespace
            matchers="${matchers}
  - ${ip}"
        done
        admission_section="
admissions:
- name: admission-0
  whitelist: true
  matchers:${matchers}"
    fi

    # --- write YAML ---
    cat > "$config_file" <<EOF
services:
# ---- WARP proxies (round-robin) ----
- name: socks5-warp
  addr: ":1080"
  handler:
    type: socks5
    chain: warp-chain${proxy_auth}
  listener:
    type: tcp
  climiter: climiter-0
  rlimiter: rlimiter-0${admission_ref}

- name: http-warp
  addr: ":8080"
  handler:
    type: http
    chain: warp-chain${proxy_auth}
  listener:
    type: tcp
  climiter: climiter-0
  rlimiter: rlimiter-0${admission_ref}

- name: ss-warp
  addr: ":8388"
  handler:
    type: ss
    chain: warp-chain
    auth:
      username: ${ss_method}
      password: ${ss_pass}
  listener:
    type: tcp
  climiter: climiter-0
  rlimiter: rlimiter-0${admission_ref}

# ---- Direct proxies (bypass WARP) ----
- name: socks5-direct
  addr: ":1081"
  handler:
    type: socks5${proxy_auth}
  listener:
    type: tcp
  climiter: climiter-0
  rlimiter: rlimiter-0${admission_ref}

- name: http-direct
  addr: ":8081"
  handler:
    type: http${proxy_auth}
  listener:
    type: tcp
  climiter: climiter-0
  rlimiter: rlimiter-0${admission_ref}

- name: ss-direct
  addr: ":8389"
  handler:
    type: ss
    auth:
      username: ${ss_method}
      password: ${ss_pass}
  listener:
    type: tcp
  climiter: climiter-0
  rlimiter: rlimiter-0${admission_ref}

# ---- Round-robin chain ----
chains:
- name: warp-chain
  hops:
  - name: warp-hop
    selector:
      strategy: round
      maxFails: 3
      failTimeout: 30s
    nodes:${nodes}

# ---- Limiters ----
climiters:
- name: climiter-0
  limits:
  - '\$ ${climiter_val}'

rlimiters:
- name: rlimiter-0
  limits:
  - '\$ ${rlimiter_val}'
${admission_section}
EOF

    echo "GOST config written to ${config_file}"
}

# ---- start each WARP instance with isolated paths ----
for i in $(seq 0 $((WARP_INSTANCES - 1))); do
    INTERNAL_PORT=$((WARP_INTERNAL_PORT_BASE + i))
    EXTERNAL_PORT=$((WARP_INSTANCE_PORT_BASE + i))
    start_warp_instance_process "$i" "$INTERNAL_PORT"
    start_instance_port_forward "$EXTERNAL_PORT" "$INTERNAL_PORT" "$i"
    sleep $((5 + RANDOM % 5))  # stagger with jitter (5-9s) to avoid Cloudflare API rate-limiting
done

# ---- verify each instance is connected to WARP (parallel) ----
echo ""
echo "Verifying WARP instances (parallel)..."
READY_COUNT=0
MAX_VERIFY_WAIT=90
VERIFY_DIR=$(mktemp -d)
VERIFY_PIDS=()

for i in $(seq 0 $((WARP_INSTANCES - 1))); do
    (
        PORT=$((WARP_INTERNAL_PORT_BASE + i))
        WAIT=0
        while [ "$WAIT" -lt "$MAX_VERIFY_WAIT" ]; do
            if curl -s --connect-timeout 3 --socks5-hostname "127.0.0.1:${PORT}" \
                "https://cloudflare.com/cdn-cgi/trace" 2>/dev/null | grep -qE 'warp=(on|plus)'; then
                echo "OK" > "${VERIFY_DIR}/${i}"
                exit 0
            fi
            sleep 3
            WAIT=$((WAIT + 3))
        done
        exit 1
    ) &
    VERIFY_PIDS+=($!)
done

for pid in "${VERIFY_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
done

for i in $(seq 0 $((WARP_INSTANCES - 1))); do
    EXTERNAL_PORT=$((WARP_INSTANCE_PORT_BASE + i))
    INTERNAL_PORT=$((WARP_INTERNAL_PORT_BASE + i))
    if [ -f "${VERIFY_DIR}/${i}" ]; then
        echo "  Instance ${i}: OK (port ${EXTERNAL_PORT})"
        READY_COUNT=$((READY_COUNT + 1))
    else
        echo "  Instance ${i}: FAILED (internal port ${INTERNAL_PORT} not responding after ${MAX_VERIFY_WAIT}s)"
    fi
done

echo ""
echo "${READY_COUNT}/${WARP_INSTANCES} WARP instances ready"

if [ "$READY_COUNT" -eq 0 ]; then
    rm -rf "$VERIFY_DIR"
    echo "Error: no WARP instances started successfully. Exiting."
    exit 1
fi

if ! is_true "$START_GOST"; then
    : > /tmp/healthy-warp-ports
    for i in $(seq 0 $((WARP_INSTANCES - 1))); do
        echo "$((WARP_INSTANCE_PORT_BASE + i))" >> /tmp/healthy-warp-ports
    done
    rm -rf "$VERIFY_DIR"
    echo "START_GOST is disabled; WARP instances are available on :${WARP_INSTANCE_PORT_BASE}-$((WARP_INSTANCE_PORT_BASE + WARP_INSTANCES - 1))"
    trap cleanup_multi_instance SIGTERM SIGINT
    supervise_multi_instance_children &
    SUPERVISOR_PID=$!
    wait
    exit 0
fi

# ---- generate GOST config (include all planned instances) ----
generate_gost_config
rm -rf "$VERIFY_DIR"

# ---- summary ----
echo ""
echo "=== Proxy Endpoints (round-robin across ${READY_COUNT} IPs) ==="
echo "  SOCKS5 (WARP)  : :1080"
echo "  HTTP   (WARP)  : :8080"
echo "  SS     (WARP)  : :8388"
echo "  SOCKS5 (Direct): :1081"
echo "  HTTP   (Direct): :8081"
echo "  SS     (Direct): :8389"
if [ -n "$PROXY_USER" ]; then
    echo "  Auth: ${PROXY_USER}:***"
fi
echo "========================================================="
echo ""

trap cleanup_multi_instance SIGTERM SIGINT

supervise_multi_instance_children &
SUPERVISOR_PID=$!

# ---- start GOST (foreground keeps container alive) ----
echo "Starting GOST proxy (round-robin across ${WARP_INSTANCES} planned instances; ${READY_COUNT} verified at startup)..."
gost -C /tmp/gost-config.yaml &
GOST_PID=$!

wait $GOST_PID
