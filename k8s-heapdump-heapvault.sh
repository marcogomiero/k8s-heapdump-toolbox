#!/usr/bin/env bash
# ==============================================================================
# k8s-heapdump-heapvault.sh
#
# HeapVault - Kubernetes JVM Heap Dump Tool (Corretto 21 based toolbox)
#
# Creates a Java heap dump from a running pod using a PT-owned toolbox image.
# Does NOT require tools inside the application container.
#
# What it does:
#   1) Verifies pod is Running
#   2) Creates ephemeral debug container (HeapVault image)
#   3) Detects JVM PID (or uses provided one)
#   4) Executes jcmd GC.heap_dump
#   5) Copies dump locally with retries
#   6) Optionally compresses locally
#
# REQUIREMENTS
#   - kubectl debug enabled
#   - Target pod must allow ephemeral containers
#
# USAGE
#   ./k8s-heapdump-heapvault.sh -n <namespace> -p <pod> [-c <container>] \
#       [-P <java_pid>] [-i <toolbox_image>] [-r <remote_dir>] [--no-gzip]
#
# DEFAULT TOOL IMAGE
#   registry.dasrn.generali.it/gbs/spring-boot-demo:heapvault
#
# SECURITY NOTE
#   Heap dumps may contain secrets and PII. Handle securely.
# ==============================================================================

set -euo pipefail

NS=""
POD=""
CONTAINER=""
JAVA_PID=""
REMOTE_DIR="/tmp"
NO_GZIP=false

# Default image (override via env HEAPVAULT_IMAGE or -i)
DEFAULT_IMAGE="registry.dasrn.generali.it/gbs/spring-boot-demo:heapvault"
TOOL_IMAGE="${HEAPVAULT_IMAGE:-$DEFAULT_IMAGE}"

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

# -----------------------------
# Validate pod
# -----------------------------
kubectl -n "$NS" get pod "$POD" >/dev/null || die "Pod not found."

PHASE="$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}')"
[[ "$PHASE" != "Running" ]] && die "Pod is not Running (phase=$PHASE)."

log "Pod phase: $PHASE"

if [[ -z "$CONTAINER" ]]; then
  CONTAINER="$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.spec.containers[0].name}')"
  log "Auto-detected container: $CONTAINER"
else
  log "Target container: $CONTAINER"
fi

TS="$(date +%Y%m%d_%H%M%S)"
DEBUG_CONTAINER="heapvault-${TS}"
REMOTE_HPROF="${REMOTE_DIR%/}/heap_${POD}_${TS}.hprof"
LOCAL_HPROF="./${POD}_${TS}.hprof"
LOCAL_GZ="${LOCAL_HPROF}.gz"

# -----------------------------
# Create ephemeral container
# -----------------------------
log "Creating ephemeral debug container: $DEBUG_CONTAINER"

kubectl -n "$NS" debug "pod/$POD" \
  --image="$TOOL_IMAGE" \
  --target="$CONTAINER" \
  --container="$DEBUG_CONTAINER" \
  --quiet \
  -- bash -c "echo ready" >/dev/null

# Wait until jcmd available
for i in {1..30}; do
  if kubectl -n "$NS" exec "$POD" -c "$DEBUG_CONTAINER" -- bash -c "command -v jcmd" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

kubectl -n "$NS" exec "$POD" -c "$DEBUG_CONTAINER" -- bash -c "command -v jcmd" >/dev/null 2>&1 \
  || die "jcmd not found inside HeapVault container."

log "HeapVault container ready."

# -----------------------------
# Detect PID
# -----------------------------
if [[ -z "$JAVA_PID" ]]; then
  log "Detecting JVM via jcmd -l"
  JVM_LIST="$(kubectl -n "$NS" exec "$POD" -c "$DEBUG_CONTAINER" -- bash -c "jcmd -l 2>/dev/null || true")"
  COUNT="$(echo "$JVM_LIST" | awk '/^[0-9]+/ {print $1}' | wc -l | tr -d ' ')"

  if [[ "$COUNT" -eq 0 ]]; then
    die "No JVM detected."
  elif [[ "$COUNT" -gt 1 ]]; then
    echo "$JVM_LIST"
    die "Multiple JVMs detected. Use -P <pid>."
  fi

  JAVA_PID="$(echo "$JVM_LIST" | awk '/^[0-9]+/ {print $1}' | head -n1)"
fi

log "Using Java PID: $JAVA_PID"

# -----------------------------
# Create heap dump
# -----------------------------
log "Creating heap dump at $REMOTE_HPROF"

kubectl -n "$NS" exec "$POD" -c "$DEBUG_CONTAINER" -- bash -c \
  "jcmd $JAVA_PID GC.heap_dump $REMOTE_HPROF" \
  || die "Heap dump failed."

kubectl -n "$NS" exec "$POD" -c "$CONTAINER" -- bash -c \
  "ls -lh $REMOTE_HPROF" \
  || die "Heap dump file not found."

# -----------------------------
# Copy locally with retries
# -----------------------------
log "Copying heap dump locally..."

while true; do
  if kubectl -n "$NS" cp "$POD:$REMOTE_HPROF" "$LOCAL_HPROF" -c "$CONTAINER" >/dev/null 2>&1; then
    break
  fi
  log "kubectl cp failed. Retrying in 5s..."
  sleep 5
done

log "Heap dump copied locally."
ls -lh "$LOCAL_HPROF"

# -----------------------------
# Compress locally
# -----------------------------
if [[ "$NO_GZIP" = false ]] && command -v gzip >/dev/null 2>&1; then
  log "Compressing locally..."
  gzip -9 -f "$LOCAL_HPROF"
  ls -lh "$LOCAL_GZ"
  FINAL_FILE="$LOCAL_GZ"
else
  FINAL_FILE="$LOCAL_HPROF"
fi

# -----------------------------
# Final summary
# -----------------------------
echo
echo "================ HEAPVAULT SUMMARY ================"
echo "Namespace        : $NS"
echo "Pod              : $POD"
echo "Container        : $CONTAINER"
echo "Java PID         : $JAVA_PID"
echo "Remote file      : $REMOTE_HPROF"
echo "Local file       : $FINAL_FILE"
echo "Debug container  : $DEBUG_CONTAINER"
echo "==================================================="
echo

log "HeapVault completed successfully."