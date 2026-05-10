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
