#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat >&2 <<EOF
Usage: $0 [options] [PROJECT_DIR]

Options:
  --proxy HOST:PORT   Address of the host-side proxy (default: 127.0.0.1:8085)
  --network           Give the sandbox the host network directly, no proxy
  --bluetooth         Expose the system D-Bus so BlueZ (bluetoothctl etc.) works
  -h, --help          Show this help
EOF
    exit 1
}

BLUETOOTH=0
NETWORK=0
PROXY_ADDR="127.0.0.1:8085"
PROXY_SET=0
PROJECT_ARG="."

while [ $# -gt 0 ]; do
    case "$1" in
        --bluetooth) BLUETOOTH=1 ;;
        --network)   NETWORK=1 ;;
        --proxy)
            [ $# -ge 2 ] || { echo "--proxy needs HOST:PORT" >&2; usage; }
            PROXY_ADDR="$2"; PROXY_SET=1; shift ;;
        --proxy=*)   PROXY_ADDR="${1#--proxy=}"; PROXY_SET=1 ;;
        -h|--help)   usage ;;
        -*)          echo "Unknown option: $1" >&2; usage ;;
        *)           PROJECT_ARG="$1" ;;
    esac
    shift
done

if [ "$NETWORK" -eq 1 ] && [ "$PROXY_SET" -eq 1 ]; then
    echo "--network and --proxy are mutually exclusive" >&2
    exit 1
fi

if [[ "$PROXY_ADDR" != *:* ]] || ! [[ "${PROXY_ADDR##*:}" =~ ^[0-9]+$ ]]; then
    echo "Invalid proxy address '$PROXY_ADDR', expected HOST:PORT" >&2
    exit 1
fi
PROXY_PORT="${PROXY_ADDR##*:}"

PROJECT="$(realpath "$PROJECT_ARG")"
SANDBOX_HOME="/home/smith/Work/opencode-leash"
mkdir -p "$SANDBOX_HOME"

SOCAT_SOCKET="$XDG_RUNTIME_DIR/oc-proxy.sock"

# Optional bwrap arguments, filled in by the features below
NET_ARGS=()
EXTRA_ARGS=()
INNER_CMD='/opt/opencode/bin/opencode' #'exec /bin/bash'


if [ "$NETWORK" -eq 1 ]; then
    # Host network, no proxy. DNS often goes through a symlink into
    # /run/systemd/resolve, so make that reachable too.
    if [ -d /run/systemd/resolve ]; then
        EXTRA_ARGS+=(--ro-bind /run/systemd/resolve /run/systemd/resolve)
    fi
else
    # Isolated network, everything goes through the proxy
    PROXY_URL="http://127.0.0.1:${PROXY_PORT}"
    CA_CERT="/var/lib/mitmproxy-ca/mitmproxy-ca-cert.pem"
    NET_ARGS+=(--unshare-net)
    EXTRA_ARGS+=(
        --ro-bind "$HOME/.mitmproxy" /var/lib/mitmproxy-ca
        --setenv http_proxy "$PROXY_URL"
        --setenv https_proxy "$PROXY_URL"
        --setenv HTTP_PROXY "$PROXY_URL"
        --setenv HTTPS_PROXY "$PROXY_URL"
        --setenv no_proxy "localhost,127.0.0.1,::1"
        --setenv NO_PROXY "localhost,127.0.0.1,::1"
        --setenv NODE_TLS_REJECT_UNAUTHORIZED "0"
        --setenv SSL_CERT_FILE "$CA_CERT"
        --setenv NODE_EXTRA_CA_CERTS "$CA_CERT"
        --setenv CURL_CA_BUNDLE "$CA_CERT"
    )
    # Sandbox-side socat forwards the local port to the host socket
    INNER_CMD="socat TCP-LISTEN:${PROXY_PORT},fork UNIX-CONNECT:\"\$XDG_RUNTIME_DIR/oc-proxy.sock\" &
exec /bin/bash"
fi

if [ "$BLUETOOTH" -eq 1 ]; then
    BT_SOCKET="/run/dbus/system_bus_socket"
    if [ ! -S "$BT_SOCKET" ]; then
        echo "System D-Bus socket not found at $BT_SOCKET" >&2
        exit 1
    fi
    EXTRA_ARGS+=(
        --ro-bind "$BT_SOCKET" /run/dbus/system_bus_socket
        --setenv DBUS_SYSTEM_BUS_ADDRESS "unix:path=/run/dbus/system_bus_socket"
    )
fi

cleanup() {
    [ -n "${SOCAT_HOST_PID:-}" ] && kill "$SOCAT_HOST_PID" 2>/dev/null || true
    [ "$NETWORK" -eq 0 ] && rm -f "$SOCAT_SOCKET"
}
trap cleanup EXIT

# 1. Start host-side socat (proxy mode only)
if [ "$NETWORK" -eq 0 ]; then
    rm -f "$SOCAT_SOCKET"
    socat UNIX-LISTEN:"$SOCAT_SOCKET",fork,mode=600 TCP:"$PROXY_ADDR" &
    SOCAT_HOST_PID=$!
    sleep 0.1
fi

# 2. Launch bwrap unprivileged
exec bwrap \
  --die-with-parent \
  --new-session \
  --unshare-user \
  --unshare-pid \
  --unshare-ipc \
  --unshare-uts \
  ${NET_ARGS[@]+"${NET_ARGS[@]}"} \
  \
  --ro-bind /usr /usr \
  --ro-bind /bin /bin \
  --ro-bind /lib /lib \
  --ro-bind /lib64 /lib64 \
  --ro-bind /etc /etc \
  --ro-bind /usr/local /usr/local \
  --ro-bind /var/lib/opencode /opt/opencode \
  \
  --proc /proc \
  --dev /dev \
  --tmpfs /tmp \
  \
  --dir /home \
  --dir /home/sandbox \
  --bind "$SANDBOX_HOME" /home/sandbox \
  --bind "$PROJECT" /workspace \
  --bind "$XDG_RUNTIME_DIR" /run/user/1000 \
  --chdir /workspace \
  \
  --clearenv \
  --setenv HOME /home/sandbox \
  --setenv USER sandbox \
  --setenv PATH /usr/local/bin:/usr/bin:/bin \
  --setenv TERM "${TERM:-xterm-256color}" \
  --setenv XDG_RUNTIME_DIR "/run/user/1000" \
  \
  ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} \
  \
  bash -c "$INNER_CMD"
