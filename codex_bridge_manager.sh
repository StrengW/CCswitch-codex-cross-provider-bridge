#!/usr/bin/env bash
set -Eeuo pipefail

# Codex Cross-Provider Bridge manager for Linux/macOS/WSL Bash.
# The script manages only the bridge process and Codex's user-level config.
# It deliberately does not restart or modify CC Switch.

CPB_COMMAND="auto"
CPB_SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CPB_BRIDGE_SCRIPT="${CPB_BRIDGE_SCRIPT:-$CPB_SCRIPT_DIR/codex_provider_bridge.py}"
CPB_CODEX_CONFIG="${CPB_CODEX_CONFIG:-${CODEX_HOME:-$HOME/.codex}/config.toml}"
CPB_LISTEN_ADDRESS="127.0.0.1"
CPB_BRIDGE_PORT=15722
CPB_UPSTREAM_URL="http://127.0.0.1:15721"
CPB_PROVIDER_ID="custom"
CPB_PROVIDER_NAME="CC Switch Bridge"
CPB_OFFICIAL_PROVIDER_ID="cc-switch-official"
CPB_MODEL=""
CPB_FOREGROUND=1
CPB_FIXED_PORT=0

usage() {
    cat <<'EOF'
Usage:
  codex_bridge_manager.sh [auto|start|repair|status|doctor|stop] [options]

Commands:
  auto      Start only for the official/bridge Codex config (default)
  start     Start or reuse the bridge and apply bridge config
  repair    Apply bridge config without selecting a CC Switch provider
  status    Show bridge, upstream, config, and process status
  doctor    Check prerequisites and machine-specific paths without changing them
  stop      Stop only the bridge process managed by this script

Options:
  --bridge-script PATH       Path to codex_provider_bridge.py
  --codex-config PATH        Path to Codex config.toml
  --bridge-port PORT         Preferred local bridge port (default: 15722)
  --upstream-url URL         Local CC Switch URL (default: http://127.0.0.1:15721)
  --provider-id ID           Codex provider table ID (default: custom)
  --provider-name NAME       Display name written to the provider table
  --official-provider-id ID  Provider ID that activates auto mode
  --model MODEL              Official model to write and force for bridged
                              /responses replays (for example gpt-5.6-sol)
  --foreground               Compatibility alias; foreground is already the default
  --background               Detach the bridge; later use stop to close it
  --fixed-port               Fail if the preferred bridge port is occupied
  -h, --help                 Show this help
EOF
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

is_uint() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

validate_port() {
    local port="$1"
    is_uint "$port" || die "Invalid port: $port"
    (( port >= 1 && port <= 65535 )) || die "Port must be between 1 and 65535: $port"
}

validate_config() {
    [[ "$CPB_LISTEN_ADDRESS" == "127.0.0.1" || "$CPB_LISTEN_ADDRESS" == "localhost" ]] ||
        die 'For safety, the listen address must be 127.0.0.1 or localhost.'
    [[ "$CPB_PROVIDER_ID" =~ ^[A-Za-z0-9_-]+$ ]] ||
        die 'Provider ID may contain only letters, digits, underscores, and hyphens.'
    [[ "$CPB_OFFICIAL_PROVIDER_ID" =~ ^[A-Za-z0-9_-]+$ ]] ||
        die 'Official provider ID may contain only letters, digits, underscores, and hyphens.'
    [[ "$CPB_UPSTREAM_URL" =~ ^http://(127\.0\.0\.1|localhost)(:[0-9]+)?(/.*)?$ ]] ||
        die 'For safety, upstream URL must be a local http:// URL.'
    validate_port "$CPB_BRIDGE_PORT"
}

CPB_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/CodexProviderBridge"
CPB_STATE_FILE="$CPB_STATE_DIR/bridge-state.env"
CPB_STDOUT_LOG="$CPB_STATE_DIR/bridge-stdout.log"
CPB_STDERR_LOG="$CPB_STATE_DIR/bridge-stderr.log"

parse_args() {
    if (($# > 0)) && [[ "$1" != -* ]]; then
        CPB_COMMAND="$1"
        shift
    fi

    while (($# > 0)); do
        case "$1" in
            --bridge-script)
                (($# >= 2)) || die 'Missing value for --bridge-script.'
                CPB_BRIDGE_SCRIPT="$2"; shift 2 ;;
            --codex-config)
                (($# >= 2)) || die 'Missing value for --codex-config.'
                CPB_CODEX_CONFIG="$2"; shift 2 ;;
            --bridge-port)
                (($# >= 2)) || die 'Missing value for --bridge-port.'
                CPB_BRIDGE_PORT="$2"; shift 2 ;;
            --upstream-url)
                (($# >= 2)) || die 'Missing value for --upstream-url.'
                CPB_UPSTREAM_URL="$2"; shift 2 ;;
            --provider-id)
                (($# >= 2)) || die 'Missing value for --provider-id.'
                CPB_PROVIDER_ID="$2"; shift 2 ;;
            --provider-name)
                (($# >= 2)) || die 'Missing value for --provider-name.'
                CPB_PROVIDER_NAME="$2"; shift 2 ;;
            --official-provider-id)
                (($# >= 2)) || die 'Missing value for --official-provider-id.'
                CPB_OFFICIAL_PROVIDER_ID="$2"; shift 2 ;;
            --model)
                (($# >= 2)) || die 'Missing value for --model.'
                CPB_MODEL="$2"; shift 2 ;;
            --foreground)
                CPB_FOREGROUND=1; shift ;;
            --background)
                CPB_FOREGROUND=0; shift ;;
            --fixed-port)
                CPB_FIXED_PORT=1; shift ;;
            -h|--help)
                usage; exit 0 ;;
            *)
                die "Unknown argument: $1" ;;
        esac
    done

    case "$CPB_COMMAND" in
        auto|start|repair|status|doctor|stop) ;;
        *) die "Unknown command: $CPB_COMMAND" ;;
    esac
    validate_config
}

resolve_python() {
    if command -v python3 >/dev/null 2>&1; then
        CPB_PYTHON="$(command -v python3)"
    elif command -v python >/dev/null 2>&1; then
        CPB_PYTHON="$(command -v python)"
    else
        die 'Python 3.10 or newer was not found on PATH.'
    fi
    local version_ok
    version_ok="$($CPB_PYTHON -c 'import sys; print(int(sys.version_info >= (3, 10)))' 2>/dev/null || true)"
    [[ "$version_ok" == "1" ]] || die 'Python 3.10 or newer is required.'
}

configured_model() {
    [[ -f "$CPB_CODEX_CONFIG" ]] || return 0
    sed -n '
/^[[:space:]]*\[/q
s/^[[:space:]]*model[[:space:]]*=[[:space:]]*"\([^"]*\)".*$/\1/p
' "$CPB_CODEX_CONFIG" | head -n 1
}

state_value() {
    local key="$1"
    [[ -f "$CPB_STATE_FILE" ]] || return 0
    awk -F= -v wanted="$key" '$1 == wanted {sub(/^[^=]*=/, ""); print; exit}' "$CPB_STATE_FILE"
}

managed_pid() {
    local pid command_line expected
    pid="$(state_value pid || true)"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    # The state stores the canonical absolute path used to launch Python.
    # Comparing against a caller-supplied relative path breaks status/stop as
    # soon as the manager is invoked from another working directory.
    expected="$(state_value bridge_script || true)"
    [[ -n "$expected" ]] || expected="$CPB_BRIDGE_SCRIPT"
    command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    [[ "$command_line" == *"$expected"* ]] || return 1
    printf '%s\n' "$pid"
}

port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -ltnH 2>/dev/null | awk -v needle=":$port" '$4 ~ needle "$" { found=1 } END { exit(found ? 0 : 1) }'
        return $?
    fi
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
        return $?
    fi
    resolve_python
    "$CPB_PYTHON" - "$port" <<'PY' >/dev/null 2>&1
import socket
import sys

sock = socket.socket()
sock.settimeout(0.5)
try:
    sys.exit(0 if sock.connect_ex(("127.0.0.1", int(sys.argv[1]))) == 0 else 1)
finally:
    sock.close()
PY
}

find_available_port() {
    local candidate="$1" attempt
    for ((attempt = 0; attempt < 200; attempt++)); do
        ((candidate <= 65535)) || break
        if ! port_in_use "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
        ((candidate++))
    done
    die "No free local TCP port found near $1."
}

rewrite_codex_config() {
    local port="$1"
    mkdir -p "$(dirname -- "$CPB_CODEX_CONFIG")"
    CPB_CONFIG="$CPB_CODEX_CONFIG" \
    CPB_PORT="$port" \
    CPB_LISTEN="$CPB_LISTEN_ADDRESS" \
    CPB_PROVIDER="$CPB_PROVIDER_ID" \
    CPB_PROVIDER_NAME="$CPB_PROVIDER_NAME" \
    CPB_MODEL="$CPB_MODEL" \
    "$CPB_PYTHON" - <<'PY'
from __future__ import annotations

import datetime as dt
import json
import os
import re
import shutil
import tempfile
from pathlib import Path

path = Path(os.environ["CPB_CONFIG"])
port = int(os.environ["CPB_PORT"])
listen = os.environ["CPB_LISTEN"]
provider = os.environ["CPB_PROVIDER"]
provider_name = os.environ["CPB_PROVIDER_NAME"]
model = os.environ.get("CPB_MODEL", "")
exists = path.exists()
original = path.read_text(encoding="utf-8") if exists else ""
newline = "\r\n" if "\r\n" in original else "\n"
had_final_newline = original.endswith(("\n", "\r"))
lines = original.splitlines()

def quote(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)

def first_section_index(items: list[str]) -> int:
    for index, line in enumerate(items):
        if re.match(r"^\s*\[", line):
            return index
    return len(items)

def set_top_level(items: list[str], key: str, value: str) -> None:
    end = first_section_index(items)
    pattern = re.compile(r"^\s*" + re.escape(key) + r"\s*=")
    for index in range(end):
        if pattern.search(items[index]):
            items[index] = f"{key} = {value}"
            return
    items.insert(end, f"{key} = {value}")

def section_bounds(items: list[str], header: re.Pattern[str]):
    start = None
    for index, line in enumerate(items):
        if header.match(line):
            start = index
            break
    if start is None:
        return None
    end = len(items)
    for index in range(start + 1, len(items)):
        if re.match(r"^\s*\[", items[index]):
            end = index
            break
    return start, end

def set_section_key(items: list[str], header_pattern: re.Pattern[str], new_header: str,
                    key: str, value: str) -> None:
    bounds = section_bounds(items, header_pattern)
    if bounds is None:
        if items and items[-1].strip():
            items.append("")
        items.extend([new_header, f"{key} = {value}"])
        return
    start, end = bounds
    pattern = re.compile(r"^\s*" + re.escape(key) + r"\s*=")
    for index in range(start + 1, end):
        if pattern.search(items[index]):
            items[index] = f"{key} = {value}"
            return
    items.insert(end, f"{key} = {value}")

escaped = re.escape(provider)
provider_header = re.compile(
    r"^\s*\[model_providers\.(?:" + escaped + r'|"' + escaped + r'")\]\s*$'
)
features_header = re.compile(r"^\s*\[features\]\s*$")

set_top_level(lines, "model_provider", quote(provider))
set_top_level(lines, "disable_response_storage", "true")
if model.strip():
    set_top_level(lines, "model", quote(model))
set_section_key(lines, provider_header, f"[model_providers.{provider}]", "name", quote(provider_name))
set_section_key(lines, provider_header, f"[model_providers.{provider}]", "base_url", quote(f"http://{listen}:{port}/v1"))
set_section_key(lines, provider_header, f"[model_providers.{provider}]", "wire_api", quote("responses"))
set_section_key(lines, provider_header, f"[model_providers.{provider}]", "requires_openai_auth", "true")
set_section_key(lines, provider_header, f"[model_providers.{provider}]", "supports_websockets", "false")
set_section_key(lines, features_header, "[features]", "enable_request_compression", "false")

updated = newline.join(lines)
if had_final_newline:
    updated += newline
if updated == original:
    print(f"Codex config is already correct: {path}")
    raise SystemExit(0)

backup = None
if exists:
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S-%f")[:-3]
    backup = path.with_name(path.name + ".bridge-backup-" + stamp)
    shutil.copy2(path, backup)

path.parent.mkdir(parents=True, exist_ok=True)
fd, temporary_name = tempfile.mkstemp(prefix="." + path.name + ".bridge-tmp-", dir=path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8", newline="") as handle:
        handle.write(updated)
    os.replace(temporary_name, path)
except Exception:
    try:
        os.unlink(temporary_name)
    except FileNotFoundError:
        pass
    raise

print(f"Updated Codex config: {path}")
if backup:
    print(f"Backup created: {backup}")
PY
}

detect_config_mode() {
    [[ -f "$CPB_CODEX_CONFIG" ]] || { printf 'third_party\n'; return; }
    CPB_CONFIG="$CPB_CODEX_CONFIG" \
    CPB_PROVIDER="$CPB_PROVIDER_ID" \
    CPB_PROVIDER_NAME="$CPB_PROVIDER_NAME" \
    CPB_OFFICIAL_PROVIDER="$CPB_OFFICIAL_PROVIDER_ID" \
    CPB_DEFAULT_PORT="$CPB_BRIDGE_PORT" \
    CPB_UPSTREAM_URL="$CPB_UPSTREAM_URL" \
    CPB_STATE_PORT="$(state_value port || true)" \
    "$CPB_PYTHON" - <<'PY'
from __future__ import annotations

import os
import re
from urllib.parse import urlsplit

path = os.environ["CPB_CONFIG"]
provider_id = os.environ["CPB_PROVIDER"]
provider_name = os.environ["CPB_PROVIDER_NAME"]
official_id = os.environ["CPB_OFFICIAL_PROVIDER"]
ports = {int(os.environ["CPB_DEFAULT_PORT"])}
upstream_url = os.environ["CPB_UPSTREAM_URL"]
state_port = os.environ.get("CPB_STATE_PORT", "")
if state_port.isdigit():
    ports.add(int(state_port))
try:
    upstream_port = urlsplit(upstream_url).port or 80
except ValueError:
    upstream_port = 15721
lines = open(path, encoding="utf-8").read().splitlines()

active = None
for line in lines:
    if re.match(r"^\s*\[", line):
        break
    match = re.match(r'^\s*model_provider\s*=\s*"((?:\\.|[^"\\])*)"', line)
    if match:
        active = match.group(1).replace('\\"', '"').replace('\\\\', '\\')
        break

if active == official_id:
    print("official")
    raise SystemExit(0)
if active != provider_id:
    print("third_party")
    raise SystemExit(0)

escaped = re.escape(provider_id)
header = re.compile(r'^\s*\[model_providers\.(?:' + escaped + r'|"' + escaped + r'")\]\s*$')
inside = False
base_url = None
provider_name_value = None
supports_websockets = None
for line in lines:
    if re.match(r"^\s*\[", line):
        inside = bool(header.match(line))
        continue
    if inside:
        match = re.match(r'^\s*base_url\s*=\s*"((?:\\.|[^"\\])*)"', line)
        if match:
            base_url = match.group(1).replace('\\"', '"').replace('\\\\', '\\')
        match = re.match(r'^\s*name\s*=\s*"((?:\\.|[^"\\])*)"', line)
        if match:
            provider_name_value = match.group(1).replace('\\"', '"').replace('\\\\', '\\')
        match = re.match(r'^\s*supports_websockets\s*=\s*(true|false)\b', line)
        if match:
            supports_websockets = match.group(1)

if base_url:
    try:
        uri = urlsplit(base_url)
        port = uri.port or 80
        bridge_marker = (
            provider_name_value == provider_name
            or (provider_name_value and "bridge" in provider_name_value.lower())
            or supports_websockets == "false"
        )
        if uri.scheme == "http" and uri.hostname in {"127.0.0.1", "localhost"} \
                and uri.path.rstrip("/") == "/v1" \
                and (port in ports or (bridge_marker and port != upstream_port)):
            print("bridge")
            raise SystemExit(0)
    except ValueError:
        pass
print("third_party")
PY
}

write_state() {
    local pid="$1" port="$2" resolved_script="$3"
    mkdir -p "$CPB_STATE_DIR"
    local temporary="$CPB_STATE_FILE.tmp.$$"
    {
        printf 'pid=%s\n' "$pid"
        printf 'port=%s\n' "$port"
        printf 'listen_address=%s\n' "$CPB_LISTEN_ADDRESS"
        printf 'upstream_url=%s\n' "$CPB_UPSTREAM_URL"
        printf 'bridge_script=%s\n' "$resolved_script"
        printf 'model_override=%s\n' "$CPB_MODEL"
        printf 'started_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >"$temporary"
    mv -f -- "$temporary" "$CPB_STATE_FILE"
}

stop_bridge() {
    local pid
    pid="$(managed_pid || true)"
    if [[ -z "$pid" ]]; then
        printf 'No bridge process managed by this script is running.\n'
        rm -f -- "$CPB_STATE_FILE"
        return 0
    fi
    kill "$pid" 2>/dev/null || true
    for _ in {1..20}; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
    fi
    rm -f -- "$CPB_STATE_FILE"
    printf 'Stopped bridge process %s.\n' "$pid"
}

start_bridge() {
    [[ -f "$CPB_BRIDGE_SCRIPT" ]] || die "Bridge script not found: $CPB_BRIDGE_SCRIPT"
    resolve_python
    mkdir -p "$CPB_STATE_DIR"

    local existing_pid existing_port existing_model requested_model selected_port resolved_script automatic_model
    if [[ "$CPB_COMMAND" == "auto" && -z "$CPB_MODEL" ]]; then
        automatic_model="$(configured_model || true)"
        if [[ "$automatic_model" =~ ^(gpt-|o[0-9]|codex) ]]; then
            CPB_MODEL="$automatic_model"
            printf 'Using configured official model for replay: %s\n' "$CPB_MODEL"
        fi
    fi
    existing_pid="$(managed_pid || true)"
    existing_port="$(state_value port || true)"
    existing_model="$(state_value model_override || true)"
    requested_model="$CPB_MODEL"
    if [[ -z "$requested_model" && -n "$existing_model" ]]; then
        requested_model="$existing_model"
        CPB_MODEL="$existing_model"
    fi
    if [[ -n "$existing_pid" && "$existing_port" =~ ^[0-9]+$ ]] && port_in_use "$existing_port"; then
        if ((CPB_FOREGROUND)); then
            printf 'Restarting the existing managed bridge in foreground mode.\n'
            stop_bridge
            existing_pid=''
            existing_port=''
        elif [[ "$existing_model" != "$requested_model" ]]; then
            printf 'Bridge model override changed (%s -> %s); restarting it.\n' "${existing_model:--}" "${requested_model:--}"
            stop_bridge
            existing_pid=''
            existing_port=''
        else
            printf 'Bridge is already running on http://%s:%s\n' "$CPB_LISTEN_ADDRESS" "$existing_port"
            rewrite_codex_config "$existing_port"
            return 0
        fi
    fi
    if [[ -f "$CPB_STATE_FILE" && -z "$existing_pid" ]]; then
        rm -f -- "$CPB_STATE_FILE"
    fi

    selected_port="$CPB_BRIDGE_PORT"
    if port_in_use "$selected_port"; then
        if ((CPB_FIXED_PORT)); then
            die "Port $selected_port is already in use. Stop that process or choose another --bridge-port."
        fi
        selected_port="$(find_available_port "$((CPB_BRIDGE_PORT + 1))")"
        printf 'Warning: port %s is occupied; using %s instead.\n' "$CPB_BRIDGE_PORT" "$selected_port" >&2
    fi
    resolved_script="$(CDPATH= cd -- "$(dirname -- "$CPB_BRIDGE_SCRIPT")" && pwd -P)/$(basename -- "$CPB_BRIDGE_SCRIPT")"
    local bridge_args=(
        --listen "$CPB_LISTEN_ADDRESS:$selected_port"
        --upstream "$CPB_UPSTREAM_URL"
    )
    if [[ -n "$CPB_MODEL" ]]; then
        bridge_args+=(--model-override "$CPB_MODEL")
    fi
    if ((CPB_FOREGROUND)); then
        "$CPB_PYTHON" -u "$resolved_script" "${bridge_args[@]}" &
    else
        nohup "$CPB_PYTHON" -u "$resolved_script" "${bridge_args[@]}" \
            >"$CPB_STDOUT_LOG" 2>"$CPB_STDERR_LOG" < /dev/null &
    fi
    local pid=$!
    write_state "$pid" "$selected_port" "$resolved_script"

    for _ in {1..50}; do
        if ! kill -0 "$pid" 2>/dev/null; then
            break
        fi
        if port_in_use "$selected_port"; then
            rewrite_codex_config "$selected_port"
            printf 'Bridge started: http://%s:%s\n' "$CPB_LISTEN_ADDRESS" "$selected_port"
            printf 'Forwarding to: %s\n' "$CPB_UPSTREAM_URL"
            if ((CPB_FOREGROUND)); then
                printf 'Foreground mode is active. Press Ctrl+C, close this terminal, or terminate the VS Code task to stop the bridge.\n'
                trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; if [[ "$(state_value pid || true)" == "$pid" ]]; then rm -f -- "$CPB_STATE_FILE"; fi; exit 130' INT TERM
                local exit_code=0
                wait "$pid" || exit_code=$?
                trap - INT TERM
                if [[ "$(state_value pid || true)" == "$pid" ]]; then
                    rm -f -- "$CPB_STATE_FILE"
                fi
                return "$exit_code"
            fi
            return 0
        fi
        sleep 0.1
    done
    local error_tail=''
    [[ -f "$CPB_STDERR_LOG" ]] && error_tail="$(tail -n 8 "$CPB_STDERR_LOG" || true)"
    kill "$pid" 2>/dev/null || true
    rm -f -- "$CPB_STATE_FILE"
    die "Bridge failed to start.${error_tail:+\n$error_tail}"
}

repair_config() {
    resolve_python
    local port="$CPB_BRIDGE_PORT" state_port
    state_port="$(state_value port || true)"
    if [[ -z "$CPB_MODEL" ]]; then
        local state_model
        state_model="$(state_value model_override || true)"
        if [[ -n "$state_model" ]]; then
            CPB_MODEL="$state_model"
        fi
    fi
    if [[ "$state_port" =~ ^[0-9]+$ ]] && port_in_use "$state_port"; then
        port="$state_port"
    elif ! port_in_use "$port"; then
        printf 'Warning: no managed bridge is listening on port %s; config will be repaired but requests will fail until it starts.\n' "$port" >&2
    fi
    rewrite_codex_config "$port"
    printf 'Repair complete. Codex provider %s points to http://%s:%s/v1\n' "$CPB_PROVIDER_ID" "$CPB_LISTEN_ADDRESS" "$port"
}

show_status() {
    local pid port=''
    pid="$(managed_pid || true)"
    port="$(state_value port || true)"
    [[ "$port" =~ ^[0-9]+$ ]] || port="$CPB_BRIDGE_PORT"
    printf 'ManagedProcess: %s\n' "$([[ -n "$pid" ]] && echo true || echo false)"
    printf 'ProcessId: %s\n' "${pid:-none}"
    printf 'BridgeUrl: http://%s:%s\n' "$CPB_LISTEN_ADDRESS" "$port"
    printf 'BridgeListening: %s\n' "$(port_in_use "$port" && echo true || echo false)"
    printf 'UpstreamUrl: %s\n' "$CPB_UPSTREAM_URL"
    printf 'ModelOverride: %s\n' "$(state_value model_override || true)"
    local upstream_host upstream_port
    if [[ "$CPB_UPSTREAM_URL" =~ ^http://(127\.0\.0\.1|localhost):([0-9]+) ]]; then
        upstream_host="${BASH_REMATCH[1]}"
        upstream_port="${BASH_REMATCH[2]}"
        printf 'UpstreamListening: %s\n' "$(port_in_use "$upstream_port" && echo true || echo false)"
    else
        printf 'UpstreamListening: unknown\n'
    fi
    printf 'CodexConfig: %s\n' "$CPB_CODEX_CONFIG"
    printf 'StateFile: %s\n' "$CPB_STATE_FILE"
}

show_doctor() {
    printf 'Codex Cross-Provider Bridge portability check\n'
    printf 'ManagerScript: %s\n' "$CPB_SCRIPT_DIR/$(basename -- "${BASH_SOURCE[0]}")"
    printf 'BridgeScript: %s\n' "$CPB_BRIDGE_SCRIPT"
    printf 'BridgeScriptExists: %s\n' "$([[ -f "$CPB_BRIDGE_SCRIPT" ]] && echo true || echo false)"
    if resolve_python 2>/dev/null; then
        printf 'Python: %s\n' "$CPB_PYTHON"
        printf 'PythonVersion: %s\n' "$($CPB_PYTHON -c 'import platform; print(platform.python_version())')"
    else
        printf 'Python: ERROR - Python 3.10 or newer was not found\n'
    fi
    printf 'CodexConfig: %s\n' "$CPB_CODEX_CONFIG"
    printf 'CodexConfigExists: %s\n' "$([[ -f "$CPB_CODEX_CONFIG" ]] && echo true || echo false)"
    printf 'DetectedConfigMode: %s\n' "$(detect_config_mode)"
    printf 'PreferredBridgePortAvailable: %s\n' "$(! port_in_use "$CPB_BRIDGE_PORT" && echo true || echo false)"
    show_status
}

automatic_bridge() {
    resolve_python
    local mode
    mode="$(detect_config_mode)"
    case "$mode" in
        official|bridge)
            printf 'Official/bridge Codex configuration detected; ensuring the bridge is running.\n'
            start_bridge ;;
        *)
            printf 'Third-party or non-bridge Codex configuration detected; the bridge will stay stopped.\n'
            stop_bridge ;;
    esac
}

main() {
    parse_args "$@"
    case "$CPB_COMMAND" in
        auto) automatic_bridge ;;
        start) start_bridge ;;
        repair) repair_config ;;
        status) show_status ;;
        doctor) show_doctor ;;
        stop) stop_bridge ;;
    esac
}

main "$@"
