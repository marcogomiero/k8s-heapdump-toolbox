#!/usr/bin/env bash
# ==============================================================================
# k8s-heapdump-heapvault.sh
#
# HeapVault - Kubernetes JVM Heap Dump Tool (toolbox image)
#
# Default behavior:
#   - REUSE ephemeral container named "heapvault" and keep it running.
#   - If "heapvault" exists but is NOT running -> FAIL and require pod recreate.
#   - Heap dump is performed with jattach (more reliable cross-container).
#
# USAGE
#   ./k8s-heapdump-heapvault.sh -n <namespace> -p <pod> [-c <container>] \
#       [-P <java_pid>] [-i <toolbox_image>] [-r <remote_dir>] [--no-gzip]
#
# DEFAULT TOOL IMAGE
#   registry.dasrn.generali.it/gbs/spring-boot-demo:heapvault
# ==============================================================================

set -euo pipefail

NS=""
POD=""
CONTAINER=""
JAVA_PID=""
REMOTE_DIR="/tmp"
NO_GZIP=false

DEFAULT_IMAGE="registry.dasrn.generali.it/gbs/spring-boot-demo:heapvault"
TOOL_IMAGE="${HEAPVAULT_IMAGE:-$DEFAULT_IMAGE}"

DEBUG_CONTAINER="heapvault"

usage() {
  echo "Usage: $0 -n <namespace> -p <pod> [-c <container>] [-P <pid>] [-i <image>] [-r <remote_dir>] [--no-gzip]"
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

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
    --no-gzip) NO_GZIP=true; shift 1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "Unknown argument: $1" ;;
  esac
done

[[ -z "$NS" || -z "$POD" ]] && { usage; die "Namespace and pod are required."; }

log "Using HeapVault image: $TOOL_IMAGE"
log "Mode: REUSE (debug container name: $DEBUG_CONTAINER)"

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

TS="$(date +%Y%m%d%H%M%S)"
REMOTE_HPROF="${REMOTE_DIR%/}/heap_${POD}_${TS}.hprof"
LOCAL_HPROF="./${POD}_${TS}.hprof"
LOCAL_GZ="${LOCAL_HPROF}.gz"

# -----------------------------
# Ensure reusable debug container exists and is Running
# -----------------------------
exists_in_spec="$(kubectl -n "$NS" get pod "$POD" -o jsonpath="{range .spec.ephemeralContainers[*]}{.name}{'\n'}{end}" 2>/dev/null | grep -x "${DEBUG_CONTAINER}" || true)"
running_state="$(kubectl -n "$NS" get pod "$POD" -o jsonpath="{range .status.ephemeralContainerStatuses[?(@.name=='${DEBUG_CONTAINER}')]}{.state.running.startedAt}{end}" 2>/dev/null || true)"

if [[ -n "$running_state" ]]; then
  log "Reusing running debug container: $DEBUG_CONTAINER"
else
  if [[ -n "$exists_in_spec" ]]; then
    die "Ephemeral container '$DEBUG_CONTAINER' exists but is NOT running. Recreate the pod (kubectl -n $NS delete pod $POD) and retry."
  fi
  log "No existing debug container '$DEBUG_CONTAINER'. Creating it..."
  kubectl -n "$NS" debug "pod/$POD" \
    --profile=general \
    --image="$TOOL_IMAGE" \
    --target="$CONTAINER" \
    --container="$DEBUG_CONTAINER" \
    --quiet \
    -- sh -lc "sleep infinity" >/dev/null || die "kubectl debug failed."
fi

log "Waiting for debug container '$DEBUG_CONTAINER' to be Running..."
for _ in {1..60}; do
  running="$(kubectl -n "$NS" get pod "$POD" -o jsonpath="{range .status.ephemeralContainerStatuses[?(@.name=='$DEBUG_CONTAINER')]}{.state.running.startedAt}{end}" 2>/dev/null || true)"
  [[ -n "$running" ]] && break
  sleep 2
done
running="$(kubectl -n "$NS" get pod "$POD" -o jsonpath="{range .status.ephemeralContainerStatuses[?(@.name=='$DEBUG_CONTAINER')]}{.state.running.startedAt}{end}" 2>/dev/null || true)"
[[ -z "$running" ]] && die "Debug container '$DEBUG_CONTAINER' is not running."

# -----------------------------
# Preflight: ensure root + tools in debug container
# -----------------------------
log "Preflight in debug container..."
kubectl -n "$NS" exec "$POD" -c "$DEBUG_CONTAINER" -- sh -lc 'id' || true

JATTACH_PATH="$(kubectl -n "$NS" exec "$POD" -c "$DEBUG_CONTAINER" -- sh -lc 'command -v jattach 2>/dev/null || true' 2>/dev/null || true)"
[[ -z "$JATTACH_PATH" ]] && die "jattach not found in HeapVault container. Bake it into the image (recommended)."
log "jattach: $JATTACH_PATH"

# -----------------------------
# Detect Java PID if not provided
# -----------------------------
if [[ -z "$JAVA_PID" ]]; then
  log "Detecting Java PID from process list (debug container)..."
  # In pods where kubectl debug --target works, PID namespace is shared, so we can find java PID.
  JAVA_PID="$(kubectl -n "$NS" exec "$POD" -c "$DEBUG_CONTAINER" -- sh -lc \
    "ps -eo pid,args | awk '/[j]ava/ {print \$1; exit}'" 2>/dev/null || true)"
  [[ -z "$JAVA_PID" ]] && die "Could not auto-detect Java PID. Provide it with -P <pid>."
fi
log "Using Java PID: $JAVA_PID"

# -----------------------------
# Create heap dump with jattach
# -----------------------------
log "Creating heap dump with jattach at: $REMOTE_HPROF"
kubectl -n "$NS" exec "$POD" -c "$DEBUG_CONTAINER" -- sh -lc \
  "$JATTACH_PATH '$JAVA_PID' dumpheap '$REMOTE_HPROF'" \
  || die "Heap dump failed. If this still fails, cluster policy may block attach/ptrace even for root."

# Verify file exists in target container (file should be created in target mount namespace)
kubectl -n "$NS" exec "$POD" -c "$CONTAINER" -- sh -lc "ls -lh '$REMOTE_HPROF'" \
  || die "Heap dump file not found in target container at '$REMOTE_HPROF'."

# -----------------------------
# Copy locally with retries
# -----------------------------
log "Copying heap dump locally to: $LOCAL_HPROF"
for i in {1..12}; do
  if kubectl -n "$NS" cp "$POD:$REMOTE_HPROF" "$LOCAL_HPROF" -c "$CONTAINER" >/dev/null 2>&1; then
    break
  fi
  [[ $i -eq 12 ]] && die "Copy failed after 12 retries."
  log "Copy failed. Retrying ($i/12) in 5s..."
  sleep 5
done
ls -lh "$LOCAL_HPROF"

# -----------------------------
# Compress locally
# -----------------------------
FINAL_FILE="$LOCAL_HPROF"
if [[ "$NO_GZIP" = false ]] && command -v gzip >/dev/null 2>&1; then
  log "Compressing locally..."
  gzip -9 -f "$LOCAL_HPROF"
  FINAL_FILE="$LOCAL_GZ"
  ls -lh "$FINAL_FILE"
fi

# -----------------------------
# Summary
# -----------------------------
echo
echo "================ HEAPVAULT SUMMARY ================"
echo "Namespace        : $NS"
echo "Pod              : $POD"
echo "Target container : $CONTAINER"
echo "Java PID         : $JAVA_PID"
echo "Remote file      : $REMOTE_HPROF"
echo "Local file       : $FINAL_FILE"
echo "Debug container  : $DEBUG_CONTAINER (REUSE, kept running)"
echo "Tool image       : $TOOL_IMAGE"
echo "==================================================="
echo
log "Done."