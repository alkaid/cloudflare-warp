#!/bin/bash

set -e

cd "$(dirname "$0")/.."

IMAGE_NAME=${IMAGE_NAME:-cloudflare-warp-test}
CONTAINER_NAME=${CONTAINER_NAME:-warp-gost-toggle-test}
START_GOST=${START_GOST:-false}
INIT_WAIT=${INIT_WAIT:-20}
TRACE_WAIT=${TRACE_WAIT:-90}
INSTANCE_PORT=${INSTANCE_PORT:-40000}
GOST_SOCKS_PORT=${GOST_SOCKS_PORT:-1080}
GOST_HTTP_PORT=${GOST_HTTP_PORT:-8080}

test_healthcheck_aggregation() {
    local tmp_dir fake_bin ports_file output_file
    tmp_dir=$(mktemp -d)
    fake_bin="${tmp_dir}/bin"
    ports_file="${tmp_dir}/healthy-warp-ports"
    output_file="${tmp_dir}/healthcheck.out"
    mkdir -p "$fake_bin"

    cat > "${fake_bin}/curl" <<'EOF'
#!/bin/bash

for arg in "$@"; do
    case "$arg" in
        127.0.0.1:40000|127.0.0.1:40001)
            echo "warp=on"
            exit 0
            ;;
        127.0.0.1:40002)
            echo "warp=off"
            exit 0
            ;;
    esac
done

exit 1
EOF
    chmod +x "${fake_bin}/curl"

    printf "%s\n" 40000 40001 40002 > "$ports_file"

    if PATH="${fake_bin}:$PATH" WARP_HEALTHCHECK_PORTS_FILE="$ports_file" \
        bash ./healthcheck/connected-to-warp.sh >"$output_file" 2>&1; then
        echo "Expected healthcheck to fail when one configured port is unhealthy"
        cat "$output_file"
        rm -rf "$tmp_dir"
        exit 1
    fi

    if ! grep -q "2/3 healthy; required 3; failed ports: 40002" "$output_file"; then
        echo "Unexpected healthcheck failure output"
        cat "$output_file"
        rm -rf "$tmp_dir"
        exit 1
    fi

    PATH="${fake_bin}:$PATH" WARP_HEALTHCHECK_PORTS_FILE="$ports_file" \
        WARP_HEALTHCHECK_MIN_HEALTHY=2 bash ./healthcheck/connected-to-warp.sh

    rm -rf "$tmp_dir"
    echo "Healthcheck aggregation test passed"
}

test_active_health_restart() {
    local tmp_dir fake_bin output_file curl_log
    tmp_dir=$(mktemp -d)
    fake_bin="${tmp_dir}/bin"
    output_file="${tmp_dir}/active-health.out"
    curl_log="${tmp_dir}/curl.log"
    mkdir -p "$fake_bin"

    cat > "${fake_bin}/sudo" <<'EOF'
#!/bin/bash

case "${1:-}" in
    mkdir)
        exit 0
        ;;
    kill)
        shift
        /bin/kill "$@" 2>/dev/null || true
        exit 0
        ;;
esac

exec "$@"
EOF

    cat > "${fake_bin}/dbus-daemon" <<'EOF'
#!/bin/bash
trap 'exit 0' TERM INT
while true; do /bin/sleep 60 & wait "$!"; done
EOF

    cat > "${fake_bin}/warp-svc" <<'EOF'
#!/bin/bash
trap 'exit 0' TERM INT
while true; do /bin/sleep 60 & wait "$!"; done
EOF

    cat > "${fake_bin}/warp-cli" <<'EOF'
#!/bin/bash
if [[ "$*" == *status* ]]; then
    echo "Status: Connected"
fi
exit 0
EOF

    cat > "${fake_bin}/curl" <<EOF
#!/bin/bash
echo "\$*" >> "$curl_log"
echo "warp=off"
exit 0
EOF

    cat > "${fake_bin}/sleep" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "7" ]; then
    exit 42
fi
exit 0
EOF

    chmod +x "${fake_bin}"/*

    set +e
    PATH="${fake_bin}:$PATH" WARP_HEALTH_INTERVAL=1 WARP_HEALTH_FAILURES=2 \
        WARP_RESTART_DELAY=7 bash ./start-warp-instance.sh 0 40000 "" 2 \
        >"$output_file" 2>&1
    local status=$?
    set -e

    if [ "$status" -ne 42 ]; then
        echo "Expected active health restart path to reach restart delay"
        cat "$output_file"
        rm -rf "$tmp_dir"
        exit 1
    fi

    if ! grep -q "Health probe failed (2/2)" "$output_file"; then
        echo "Expected consecutive health failures before restart"
        cat "$output_file"
        rm -rf "$tmp_dir"
        exit 1
    fi

    if ! grep -q -- "--socks5-hostname 127.0.0.1:40000" "$curl_log"; then
        echo "Expected active health probe to use --socks5-hostname"
        cat "$curl_log"
        rm -rf "$tmp_dir"
        exit 1
    fi

    rm -rf "$tmp_dir"
    echo "Active health restart test passed"
}

test_active_health_disabled() {
    local tmp_dir fake_bin output_file curl_log
    tmp_dir=$(mktemp -d)
    fake_bin="${tmp_dir}/bin"
    output_file="${tmp_dir}/active-health-disabled.out"
    curl_log="${tmp_dir}/curl.log"
    mkdir -p "$fake_bin"

    cat > "${fake_bin}/sudo" <<'EOF'
#!/bin/bash

case "${1:-}" in
    mkdir)
        exit 0
        ;;
    kill)
        shift
        /bin/kill "$@" 2>/dev/null || true
        exit 0
        ;;
esac

exec "$@"
EOF

    cat > "${fake_bin}/dbus-daemon" <<'EOF'
#!/bin/bash
trap 'exit 0' TERM INT
while true; do /bin/sleep 60 & wait "$!"; done
EOF

    cat > "${fake_bin}/warp-svc" <<'EOF'
#!/bin/bash
trap 'exit 0' TERM INT
while true; do /bin/sleep 60 & wait "$!"; done
EOF

    cat > "${fake_bin}/warp-cli" <<'EOF'
#!/bin/bash
if [[ "$*" == *status* ]]; then
    echo "Status: Connected"
fi
exit 0
EOF

    cat > "${fake_bin}/curl" <<EOF
#!/bin/bash
echo "\$*" >> "$curl_log"
echo "warp=off"
exit 0
EOF

    cat > "${fake_bin}/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF

    chmod +x "${fake_bin}"/*

    set +e
    PATH="${fake_bin}:$PATH" WARP_HEALTH_INTERVAL=0 timeout 2s \
        bash ./start-warp-instance.sh 0 40000 "" 2 >"$output_file" 2>&1
    local status=$?
    set -e

    if [ "$status" -ne 124 ]; then
        echo "Expected disabled active health run to wait for warp-svc until timeout"
        cat "$output_file"
        rm -rf "$tmp_dir"
        exit 1
    fi

    if [ -s "$curl_log" ]; then
        echo "Expected WARP_HEALTH_INTERVAL=0 to skip content health probes"
        cat "$curl_log"
        rm -rf "$tmp_dir"
        exit 1
    fi

    rm -rf "$tmp_dir"
    echo "Active health disabled test passed"
}

is_true() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

cleanup() {
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
}

trap cleanup EXIT

echo "Testing healthcheck aggregation"
test_healthcheck_aggregation
echo "Testing active health restart"
test_active_health_restart
echo "Testing active health disabled mode"
test_active_health_disabled

if is_true "${HEALTHCHECK_ONLY:-false}"; then
    echo "HEALTHCHECK_ONLY=true; skipping Docker integration test"
    exit 0
fi

echo "Building test image: ${IMAGE_NAME}:latest"
if [ "${SKIP_BUILD:-false}" = "true" ]; then
    docker image inspect "${IMAGE_NAME}:latest" >/dev/null
else
    docker build --build-arg COMMIT_SHA="local-test" -t "${IMAGE_NAME}:latest" .
fi

cleanup

RUN_ARGS=(
    -d
    --name "$CONTAINER_NAME"
    -e "START_GOST=${START_GOST}"
    -p "${INSTANCE_PORT}:40000"
)

if is_true "$START_GOST"; then
    RUN_ARGS+=(
        -p "${GOST_SOCKS_PORT}:1080"
        -p "${GOST_HTTP_PORT}:8080"
    )
fi

echo "Starting container with START_GOST=${START_GOST}"
docker run "${RUN_ARGS[@]}" "${IMAGE_NAME}:latest" >/dev/null

echo "Waiting ${INIT_WAIT}s for WARP to initialize"
sleep "$INIT_WAIT"

if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" != "true" ]; then
    echo "Container is not running"
    docker logs "$CONTAINER_NAME"
    exit 1
fi

echo "Checking direct WARP instance port ${INSTANCE_PORT}"
if ! nc -z localhost "$INSTANCE_PORT"; then
    echo "WARP instance port ${INSTANCE_PORT} is not listening"
    docker logs "$CONTAINER_NAME"
    exit 1
fi

TRACE=""
for elapsed in $(seq 0 5 "$TRACE_WAIT"); do
    TRACE=$(curl -x "socks5h://localhost:${INSTANCE_PORT}" -s --max-time 15 https://cloudflare.com/cdn-cgi/trace || true)
    if echo "$TRACE" | grep -qE "warp=(plus|on)"; then
        break
    fi
    if [ "$elapsed" -lt "$TRACE_WAIT" ]; then
        sleep 5
    fi
done
echo "$TRACE"
if ! echo "$TRACE" | grep -qE "warp=(plus|on)"; then
    echo "Direct WARP instance port did not route through WARP"
    docker logs "$CONTAINER_NAME"
    exit 1
fi

if is_true "$START_GOST"; then
    echo "Checking GOST SOCKS5 proxy ${GOST_SOCKS_PORT}"
    if ! nc -z localhost "$GOST_SOCKS_PORT"; then
        echo "GOST SOCKS5 proxy is not listening"
        docker logs "$CONTAINER_NAME"
        exit 1
    fi

    GOST_TRACE=$(curl -x "socks5h://localhost:${GOST_SOCKS_PORT}" -s --max-time 30 https://cloudflare.com/cdn-cgi/trace || true)
    echo "$GOST_TRACE"
    if ! echo "$GOST_TRACE" | grep -qE "warp=(plus|on)"; then
        echo "GOST SOCKS5 proxy did not route through WARP"
        docker logs "$CONTAINER_NAME"
        exit 1
    fi

    echo "Checking GOST HTTP proxy ${GOST_HTTP_PORT}"
    if ! nc -z localhost "$GOST_HTTP_PORT"; then
        echo "GOST HTTP proxy is not listening"
        docker logs "$CONTAINER_NAME"
        exit 1
    fi
else
    echo "Checking that GOST was not started"
    if docker logs "$CONTAINER_NAME" 2>&1 | grep -q "Starting WARP proxies on :1080"; then
        echo "GOST startup log found while START_GOST=false"
        docker logs "$CONTAINER_NAME"
        exit 1
    fi
fi

echo "START_GOST=${START_GOST} test passed"
