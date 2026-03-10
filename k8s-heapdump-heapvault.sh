#!/usr/bin/env bash
# ==============================================================================
# kheap
#
# Purpose:
#   Collect a JVM heap dump from a Kubernetes pod.
#
# Operating modes:
#   1) DIRECT mode
#      Try to execute the heap dump directly inside the target container
#      using tools already present there (jcmd or jattach).
#
#   2) DEBUG mode
#      If DIRECT mode is unavailable or fails, fall back to a reusable
#      ephemeral toolbox container named "kheap", using jattach from that
#      container.
#
# Behavior:
#   - Validates namespace, pod, target container and required local commands
#   - Auto-detects Java PID if not explicitly provided
#   - Creates heap dump inside the target container filesystem
#   - Copies the heap dump locally
#   - Verifies local/remote size match
#   - Compresses locally with gzip
#   - Removes the remote heap dump after successful copy
#
# Notes:
#   - DIRECT mode is best-effort only, because application containers may not
#     contain the required Java diagnostic tools
#   - DEBUG mode is the supported fallback for tool-poor images
#
# Requirements:
#   - kubectl configured and authorized
#   - local commands: kubectl awk grep date gzip
#   - DEBUG mode toolbox image must contain jattach
#
# Usage:
#   ./kheap -n <namespace> -p <pod> [-c <container>] \
#       [-P <java_pid>] [-i <toolbox_image>] [-r <remote_dir>] \
#       [-o <output_dir>] [--no-gzip] [--keep-remote] [--direct-only] [--debug-only]
#
# Examples:
#   ./kheap -n pt-healthcheck -p fanny-547bb857d8-jq59m
#
#   ./kheap -n pt-healthcheck -p fanny-547bb857d8-jq59m -c app
#
#   ./kheap -n pt-healthcheck -p fanny-547bb857d8-jq59m --direct-only
#
#   ./kheap -n pt-healthcheck -p fanny-547bb857d8-jq59m --debug-only
#
# Default toolbox image:
#   registry.dasrn.generali.it/gbs/spring-boot-demo:kheap
# ==============================================================================

set -euo pipefail

NS=""
POD=""
CONTAINER=""
JAVA_PID=""
REMOTE_DIR="/tmp"
OUTPUT_DIR="."
NO_GZIP=false
KEEP_REMOTE=false
DIRECT_ONLY=false
DEBUG_ONLY=false

DEFAULT_IMAGE="registry.dasrn.generali.it/gbs/spring-boot-demo:kheap"
TOOL_IMAGE="${KHEAP_IMAGE:-$DEFAULT_IMAGE}"

DEBUG_CONTAINER="kheap"

TS="$(date +%Y%m%d%H%M%S)"
REMOTE_HPROF=""
LOCAL_HPROF=""
LOCAL_GZ=""
FINAL_FILE=""
MODE_USED=""

usage() {
  cat <<EOF
Usage: $0 -n <namespace> -p <pod> [-c <container>] [-P <pid>] [-i <image>] [-r <remote_dir>] [-o <output_dir>] [--no-gzip] [--keep-remote] [--direct-only] [--debug-only]

Options:
  -n <namespace>     Kubernetes namespace
  -p <pod>           Pod name
  -c <container>     Target container name (default: auto-detect first container)
  -P <pid>           Java PID (default: auto-detect)
  -i <image>         Toolbox image for DEBUG mode ephemeral container
  -r <remote_dir>    Remote directory inside target container (default: /tmp)
  -o <output_dir>    Local output directory (default: current directory)
  --no-gzip          Do not compress the local heap dump
  --keep-remote      Keep the remote heap dump file after successful copy
  --direct-only      Use DIRECT mode only, do not fall back to DEBUG mode
  --debug-only       Use DEBUG mode only, skip DIRECT mode
  -h, --help         Show this help

Environment:
  KHEAP_IMAGE        Override default toolbox image
EOF
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }

require_cmd() {
  local missing=0
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "ERROR: Required command not found: $cmd" >&2
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]] || exit 1
}

cleanup_on_error() {
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    log "Script failed (rc=$rc)."
    if [[ -n "${LOCAL_HPROF:-}" && -f "$LOCAL_HPROF" ]]; then
      log "Removing partial local file: $LOCAL_HPROF"
      rm -f "$LOCAL_HPROF" || true
    fi
    if [[ -n "${LOCAL_GZ:-}" && -f "$LOCAL_GZ" ]]; then
      log "Removing partial local file: $LOCAL_GZ"
      rm -f "$LOCAL_GZ" || true
    fi
  fi
  exit $rc
}

trap cleanup_on_error EXIT

# -----------------------------
# Parse args
# -----------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) NS="$2"; shift 2 ;;
    -p) POD="$2"; shift 2 ;;
    -c) CONTAINER="$2"; shift 2 ;;
    -P) JAVA_PID="$2"; shift 2 ;;
    -i) TOOL_IMAGE="$2"; shift 2 ;;
    -r) REMOTE_DIR="$2"; shift 2 ;;
    -o) OUTPUT_DIR="$2"; shift 2 ;;
    --no-gzip) NO_GZIP=true; shift 1 ;;
    --keep-remote) KEEP_REMOTE=true; shift 1 ;;
    --direct-only) DIRECT_ONLY=true; shift 1 ;;
    --debug-only) DEBUG_ONLY=true; shift 1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "Unknown argument: $1" ;;
  esac
done

[[ -z "$NS" || -z "$POD" ]] && { usage; die "Namespace and pod are required."; }
[[ "$DIRECT_ONLY" = true && "$DEBUG_ONLY" = true ]] && die "--direct-only and --debug-only are mutually exclusive."

require_cmd kubectl awk grep date gzip

log "Using kheap image: $TOOL_IMAGE"

# -----------------------------
# Validate local output dir
# -----------------------------
mkdir -p "$OUTPUT_DIR" || die "Cannot create output directory: $OUTPUT_DIR"
[[ -d "$OUTPUT_DIR" ]] || die "Output path is not a directory: $OUTPUT_DIR"
[[ -w "$OUTPUT_DIR" ]] || die "Output directory is not writable: $OUTPUT_DIR"

# -----------------------------
# Validate pod
# -----------------------------
kubectl -n "$NS" get pod "$POD" >/dev/null || die "Pod not found."

PHASE="$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}')"
[[ "$PHASE" != "Running" ]] && die "Pod is not Running (phase=$PHASE)."
log "Pod phase: $PHASE"

if [[ -z "$CONTAINER" ]]; then
  CONTAINER="$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.spec.containers[0].name}')"
  [[ -z "$CONTAINER" ]] && die "Could not auto-detect target container name."
  log "Auto-detected target container: $CONTAINER"
else
  log "Target container: $CONTAINER"
fi

kubectl -n "$NS" get pod "$POD" -o jsonpath="{.spec.containers[?(@.name=='$CONTAINER')].name}" | grep -qx "$CONTAINER" \
  || die "Target container '$CONTAINER' not found in pod '$POD'."

REMOTE_HPROF="${REMOTE_DIR%/}/heap_${NS}_${POD}_${TS}.hprof"
LOCAL_HPROF="${OUTPUT_DIR%/}/${NS}_${POD}_${TS}.hprof"
LOCAL_GZ="${LOCAL_HPROF}.gz"
FINAL_FILE="$LOCAL_HPROF"

# -----------------------------
# Common helpers
# -----------------------------
validate_remote_dir() {
  log "Validating remote directory on target container: $REMOTE_DIR"
  kubectl -n "$NS" exec "$POD" -c "$CONTAINER" -- sh -lc "
    mkdir -p '$REMOTE_DIR' &&
    test -d '$REMOTE_DIR' &&
    test -w '$REMOTE_DIR'
  " >/dev/null || return 1
}

detect_java_pid_in_container() {
  kubectl -n "$NS" exec "$POD" -c "$CONTAINER" -- sh -lc \
    "ps -eo pid,args 2>/dev/null | awk '/[j]ava/ {print \$1; exit}'" 2>/dev/null || true
}

verify_remote_file_exists() {
  kubectl -n "$NS" exec "$POD" -c "$CONTAINER" -- sh -lc "ls -lh '$REMOTE_HPROF'" >/dev/null 2>&1
}

copy_heap_dump() {
  if kubectl -n "$NS" cp "$POD:$REMOTE_HPROF" "$LOCAL_HPROF" -c "$CONTAINER" >/dev/null 2>&1; then
    return 0
  fi

  log "kubectl cp failed, trying fallback via cat..."
  kubectl -n "$NS" exec "$POD" -c "$CONTAINER" -- sh -lc "cat '$REMOTE_HPROF'" > "$LOCAL_HPROF"
}

verify_size() {
  local remote_size local_size

  log "Verifying remote/local file size..."
  remote_size="$(kubectl -n "$NS" exec "$POD" -c "$CONTAINER" -- sh -lc "wc -c < '$REMOTE_HPROF'" 2>/dev/null | tr -d '[:space:]')"
  [[ -n "$remote_size" ]] || die "Could not determine remote heap dump size."

  local_size="$(wc -c < "$LOCAL_HPROF" | tr -d '[:space:]')"
  [[ -n "$local_size" ]] || die "Could not determine local heap dump size."

  [[ "$remote_size" = "$local_size" ]] || die "Size mismatch after copy: remote=$remote_size local=$local_size"
  log "Size verification OK: $local_size bytes"
}

compress_local_file() {
  if [[ "$NO_GZIP" = false ]]; then
    log "Compressing locally..."
    gzip -9 -f "$LOCAL_HPROF"
    FINAL_FILE="$LOCAL_GZ"
    ls -lh "$FINAL_FILE"
  else
    FINAL_FILE="$LOCAL_HPROF"
  fi
}

cleanup_remote_file() {
  if [[ "$KEEP_REMOTE" = false ]]; then
    log "Removing remote heap dump: $REMOTE_HPROF"
    kubectl -n "$NS" exec "$POD" -c "$CONTAINER" -- sh -lc "rm -f '$REMOTE_HPROF'" \
      || warn "Remote file cleanup failed."
  else
    log "Keeping remote heap dump as requested."
  fi
}

copy_with_retries() {
  log "Copying heap dump locally to: $LOCAL_HPROF"
  for i in {1..12}; do
    if copy_heap_dump; then
      break
    fi
    [[ $i -eq 12 ]] && die "Copy failed after 12 retries."
    log "Copy failed. Retrying ($i/12) in 5s..."
    rm -f "$LOCAL_HPROF" || true
    sleep 5
  done

  [[ -f "$LOCAL_HPROF" ]] || die "Local heap dump file not found after copy."
  ls -lh "$LOCAL_HPROF"
}

# -----------------------------
# DIRECT mode helpers
# -----------------------------
direct_detect_tool() {
  kubectl -n "$NS" exec "$POD" -c "$CONTAINER" -- sh -lc '
    if command -v jcmd >/dev/null 2>&1; then
      echo jcmd
    elif command -v jattach >/dev/null 2>&1; then
      echo jattach
    else
      echo none
    fi
  ' 2>/dev/null || true
}

run_direct_mode() {
  local tool=""
  local pid=""

  log "Trying DIRECT mode on target container..."

  validate_remote_dir || {
    warn "DIRECT mode: remote directory validation failed."
    return 1
  }

  tool="$(direct_detect_tool)"
  [[ -n "$tool" ]] || tool="none"

  if [[ "$tool" = "none" ]]; then
    warn "DIRECT mode: neither jcmd nor jattach found in target container."
    return 1
  fi

  log "DIRECT mode: detected tool: $tool"

  if [[ -n "$JAVA_PID" ]]; then
    pid="$JAVA_PID"
  else
    log "DIRECT mode: detecting Java PID in target container..."
    pid="$(detect_java_pid_in_container)"
    [[ -n "$pid" ]] || {
      warn "DIRECT mode: could not auto-detect Java PID."
      return 1
    }
  fi

  log "DIRECT mode: using Java PID: $pid"

  if [[ "$tool" = "jcmd" ]]; then
    log "DIRECT mode: creating heap dump with jcmd at: $REMOTE_HPROF"
    kubectl -n "$NS" exec "$POD" -c "$CONTAINER" -- sh -lc \
      "jcmd '$pid' GC.heap_dump '$REMOTE_HPROF'" >/dev/null || {
        warn "DIRECT mode: jcmd heap dump failed."
        return 1
      }
  else
    log "DIRECT mode: creating heap dump with jattach at: $REMOTE_HPROF"
    kubectl -n "$NS" exec "$POD" -c "$CONTAINER" -- sh -lc \
      "jattach '$pid' dumpheap '$REMOTE_HPROF'" >/dev/null || {
        warn "DIRECT mode: jattach heap dump failed."
        return 1
      }
  fi

  verify_remote_file_exists || {
    warn "DIRECT mode: heap dump file not found after dump."
    return 1
  }

  JAVA_PID="$pid"
  MODE_USED="DIRECT"
  return 0
}

# -----------------------------
# DEBUG mode helpers
# -----------------------------
ensure_debug_container_running() {
  local exists_in_spec=""
  local running_state=""
  local running=""
  local eph_status=""
  local debug_output=""

  log "DEBUG mode: ensuring reusable debug container exists..."

  exists_in_spec="$(kubectl -n "$NS" get pod "$POD" -o jsonpath="{range .spec.ephemeralContainers[*]}{.name}{'\n'}{end}" 2>/dev/null | grep -x "${DEBUG_CONTAINER}" || true)"
  running_state="$(kubectl -n "$NS" get pod "$POD" -o jsonpath="{range .status.ephemeralContainerStatuses[*]}{.name}:{.state.running.startedAt}{'\n'}{end}" 2>/dev/null | grep "^${DEBUG_CONTAINER}:" || true)"

  if [[ -n "$running_state" && "$running_state" != "${DEBUG_CONTAINER}:" ]]; then
    log "DEBUG mode: reusing running debug container: $DEBUG_CONTAINER"
    return 0
  fi

  if [[ -n "$exists_in_spec" ]]; then
    log "DEBUG mode: ephemeral container '$DEBUG_CONTAINER' already exists in spec."
    eph_status="$(kubectl -n "$NS" get pod "$POD" -o jsonpath="{range .status.ephemeralContainerStatuses[*]}{.name} state={.state} lastState={.lastState}{'\n'}{end}" 2>/dev/null || true)"
    [[ -n "$eph_status" ]] && echo "$eph_status" >&2
    die "Ephemeral container '$DEBUG_CONTAINER' exists but is NOT running. Recreate the pod (kubectl -n $NS delete pod $POD) and retry."
  fi

  log "DEBUG mode: creating debug container '$DEBUG_CONTAINER'..."
  if ! debug_output="$(
    kubectl -n "$NS" debug "pod/$POD" \
      --profile=general \
      --image="$TOOL_IMAGE" \
      --target="$CONTAINER" \
      --container="$DEBUG_CONTAINER" \
      --quiet \
      -- sh -lc "sleep infinity" 2>&1
  )"; then
    echo "$debug_output" >&2
    die "kubectl debug failed."
  fi

  [[ -n "$debug_output" ]] && echo "$debug_output"

  log "DEBUG mode: waiting for debug container '$DEBUG_CONTAINER' to be Running..."
  for i in {1..60}; do
    eph_status="$(kubectl -n "$NS" get pod "$POD" -o jsonpath="{range .status.ephemeralContainerStatuses[*]}{.name} running={.state.running.startedAt} waiting={.state.waiting.reason} terminated={.state.terminated.reason}{'\n'}{end}" 2>/dev/null || true)"
    [[ -n "$eph_status" ]] && log "DEBUG mode status check $i/60: $(echo "$eph_status" | tr '\n' '; ')"

    running="$(kubectl -n "$NS" get pod "$POD" -o jsonpath="{range .status.ephemeralContainerStatuses[*]}{.name}:{.state.running.startedAt}{'\n'}{end}" 2>/dev/null | awk -F: -v c="$DEBUG_CONTAINER" '$1==c && $2!="" {print $2}')"
    [[ -n "$running" ]] && break
    sleep 2
  done

  running="$(kubectl -n "$NS" get pod "$POD" -o jsonpath="{range .status.ephemeralContainerStatuses[*]}{.name}:{.state.running.startedAt}{'\n'}{end}" 2>/dev/null | awk -F: -v c="$DEBUG_CONTAINER" '$1==c && $2!="" {print $2}')"
  if [[ -z "$running" ]]; then
    kubectl -n "$NS" describe pod "$POD" >&2 || true
    die "Debug container '$DEBUG_CONTAINER' is not running."
  fi
}

debug_detect_java_pid() {
  local pid=""

  pid="$(kubectl -n "$NS" exec "$POD" -c "$DEBUG_CONTAINER" -- sh -lc \
    "ps -eo pid,args 2>/dev/null | awk '/[j]ava/ {print \$1; exit}'" 2>/dev/null || true)"

  if [[ -z "$pid" ]]; then
    log "DEBUG mode: Java PID not visible from debug container, trying target container..."
    pid="$(detect_java_pid_in_container)"
  fi

  echo "$pid"
}

run_debug_mode() {
  local debug_id=""
  local jattach_path=""
  local pid=""

  log "Trying DEBUG mode with toolbox container..."

  validate_remote_dir || die "Remote directory '$REMOTE_DIR' does not exist or is not writable."

  ensure_debug_container_running

  debug_id="$(kubectl -n "$NS" exec "$POD" -c "$DEBUG_CONTAINER" -- sh -lc 'id' 2>/dev/null)" \
    || die "Cannot exec into debug container '$DEBUG_CONTAINER'."
  log "DEBUG mode: debug container identity: $debug_id"

  jattach_path="$(kubectl -n "$NS" exec "$POD" -c "$DEBUG_CONTAINER" -- sh -lc 'command -v jattach 2>/dev/null || true' 2>/dev/null || true)"
  [[ -n "$jattach_path" ]] || die "jattach not found in kheap container. Bake it into the image."
  log "DEBUG mode: jattach: $jattach_path"

  if [[ -n "$JAVA_PID" ]]; then
    pid="$JAVA_PID"
  else
    log "DEBUG mode: detecting Java PID..."
    pid="$(debug_detect_java_pid)"
    [[ -n "$pid" ]] || die "Could not auto-detect Java PID. Provide it with -P <pid>."
  fi

  log "DEBUG mode: using Java PID: $pid"
  log "DEBUG mode: creating heap dump with jattach at: $REMOTE_HPROF"
  kubectl -n "$NS" exec "$POD" -c "$DEBUG_CONTAINER" -- sh -lc \
    "$jattach_path '$pid' dumpheap '$REMOTE_HPROF'" \
    || die "Heap dump failed. Cluster policy may block attach/ptrace even for root."

  verify_remote_file_exists || die "Heap dump file not found in target container at '$REMOTE_HPROF'."

  JAVA_PID="$pid"
  MODE_USED="DEBUG"
  return 0
}

# -----------------------------
# Mode selection
# -----------------------------
if [[ "$DEBUG_ONLY" = true ]]; then
  run_debug_mode
elif [[ "$DIRECT_ONLY" = true ]]; then
  run_direct_mode || die "DIRECT mode failed and fallback is disabled by --direct-only."
else
  if run_direct_mode; then
    log "DIRECT mode succeeded."
  else
    warn "DIRECT mode failed or unavailable. Falling back to DEBUG mode."
    run_debug_mode
  fi
fi

# -----------------------------
# Copy / verify / compress / cleanup
# -----------------------------
copy_with_retries
verify_size
compress_local_file
cleanup_remote_file

# -----------------------------
# Summary
# -----------------------------
echo
echo "================== KHEAP SUMMARY =================="
echo "Mode used        : $MODE_USED"
echo "Namespace        : $NS"
echo "Pod              : $POD"
echo "Target container : $CONTAINER"
echo "Java PID         : $JAVA_PID"
echo "Remote file      : $REMOTE_HPROF"
echo "Local file       : $FINAL_FILE"
if [[ "$MODE_USED" = "DEBUG" ]]; then
  echo "Debug container  : $DEBUG_CONTAINER (REUSE, kept running)"
  echo "Tool image       : $TOOL_IMAGE"
else
  echo "Debug container  : not used"
  echo "Tool image       : not used"
fi
echo "Gzip             : $([[ "$NO_GZIP" = false ]] && echo "enabled" || echo "disabled")"
echo "Keep remote      : $([[ "$KEEP_REMOTE" = true ]] && echo "yes" || echo "no")"
echo "==================================================="
echo

trap - EXIT
log "Done."