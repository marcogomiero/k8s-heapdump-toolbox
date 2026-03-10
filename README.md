# k8s-heapdump-toolbox

A lightweight Bash toolbox for collecting JVM heap dumps from Kubernetes pods — even when the target container has no Java diagnostic tools installed.

---

## Overview

`kheap` is a single-script solution that automates the full heap dump lifecycle:

1. Validates the target namespace, pod, and container
2. Auto-detects the Java PID (or accepts one explicitly)
3. Triggers the heap dump inside the container
4. Copies the `.hprof` file locally
5. Verifies size integrity (remote vs. local)
6. Compresses the file with gzip
7. Removes the remote copy (unless `--keep-remote` is set)

It supports two operating modes and falls back automatically from one to the other.

---

## Operating Modes

### DIRECT mode
Executes the heap dump directly inside the target container using tools already present there (`jcmd` or `jattach`). This is the preferred mode when the application image ships with JDK tooling.

### DEBUG mode
Injects a reusable ephemeral container (`kheap`) into the pod using `kubectl debug`. The ephemeral container carries `jattach` and attaches to the JVM process in the target container. This is the fallback for minimal/distroless images that have no diagnostic tools.

By default, DIRECT mode is attempted first; if it fails, the script falls back to DEBUG mode. This behaviour can be overridden with `--direct-only` or `--debug-only`.

---

## Requirements

**Local machine:**
- `kubectl` configured and authorised against the target cluster
- Standard POSIX utilities: `awk`, `grep`, `date`, `gzip`

**Cluster:**
- The pod must be in `Running` phase
- DEBUG mode requires the cluster to allow ephemeral containers (`kubectl debug`) and `ptrace`/attach syscalls (check your PodSecurityPolicy / SecurityContext constraints)

---

## Toolbox Image

The DEBUG mode ephemeral container is built from the included `Dockerfile`. It is based on [Chainguard Wolfi](https://github.com/chainguard-images/wolfi-base) (minimal, distroless-style) and bundles:

- [`jattach`](https://github.com/jattach/jattach) — a lightweight JVM attach tool (default version: `v2.2`)
- `procps` — for Java PID detection via `ps`

### Build

```bash
docker build \
  --build-arg JATTACH_VERSION=v2.2 \
  -t <your-registry>/k8s-heapdump-toolbox:kheap .
```

### Override the toolbox image

Set the `KHEAP_IMAGE` environment variable or use the `-i` flag:

```bash
export KHEAP_IMAGE=<your-registry>/k8s-heapdump-toolbox:kheap
# or
./kheap -n my-ns -p my-pod -i <your-registry>/k8s-heapdump-toolbox:kheap
```

---

## Usage

```
./kheap -n <namespace> -p <pod> [-c <container>] [-P <java_pid>] \
        [-i <toolbox_image>] [-r <remote_dir>] [-o <output_dir>] \
        [--no-gzip] [--keep-remote] [--direct-only] [--debug-only]
```

### Options

| Flag | Description | Default |
|---|---|---|
| `-n <namespace>` | Kubernetes namespace | *(required)* |
| `-p <pod>` | Pod name | *(required)* |
| `-c <container>` | Target container name | auto-detect (first container) |
| `-P <pid>` | Java PID | auto-detect |
| `-i <image>` | Toolbox image for DEBUG mode | `$KHEAP_IMAGE` or built-in default |
| `-r <remote_dir>` | Directory inside target container where the dump is written | `/tmp` |
| `-o <output_dir>` | Local directory where the dump is saved | current directory |
| `--no-gzip` | Skip local gzip compression | — |
| `--keep-remote` | Do not delete the `.hprof` from the pod after copying | — |
| `--direct-only` | Use DIRECT mode only, no fallback | — |
| `--debug-only` | Use DEBUG mode only, skip DIRECT | — |
| `-h`, `--help` | Show help | — |

### Environment variables

| Variable | Description |
|---|---|
| `KHEAP_IMAGE` | Override the default toolbox image used in DEBUG mode |

---

## Examples

```bash
# Minimal usage — auto-detect container and Java PID
./kheap -n pt-healthcheck -p fanny-547bb857d8-jq59m

# Specify the target container explicitly
./kheap -n pt-healthcheck -p fanny-547bb857d8-jq59m -c app

# Force DIRECT mode only (fails if the container has no jcmd/jattach)
./kheap -n pt-healthcheck -p fanny-547bb857d8-jq59m --direct-only

# Force DEBUG mode only (always uses the ephemeral toolbox container)
./kheap -n pt-healthcheck -p fanny-547bb857d8-jq59m --debug-only

# Save dump to a specific directory, skip compression
./kheap -n pt-healthcheck -p fanny-547bb857d8-jq59m -o /dumps --no-gzip

# Use a custom registry image
./kheap -n pt-healthcheck -p fanny-547bb857d8-jq59m \
  -i myregistry.example.com/toolbox:kheap
```

---

## Output

On success, `kheap` prints a summary:

```
================== KHEAP SUMMARY ====================
Mode used        : DEBUG
Namespace        : pt-healthcheck
Pod              : fanny-547bb857d8-jq59m
Target container : app
Java PID         : 1
Remote file      : /tmp/heap_pt-healthcheck_fanny-547bb857d8-jq59m_20240315120000.hprof
Local file       : ./pt-healthcheck_fanny-547bb857d8-jq59m_20240315120000.hprof.gz
Debug container  : kheap (REUSE, kept running)
Tool image       : myregistry.example.com/toolbox:kheap
Gzip             : enabled
Keep remote      : no
=====================================================
```

The ephemeral debug container (`kheap`) is kept running after the first invocation so it can be **reused** for subsequent dumps on the same pod without re-injection overhead.

---

## Notes

- `--direct-only` and `--debug-only` are mutually exclusive.
- If the ephemeral container was previously injected but is no longer running (e.g. crashed), the script will error out with instructions to delete and recreate the pod.
- On copy failure, `kubectl cp` is retried up to 3 times; if all attempts fail, the script falls back to streaming via `kubectl exec … cat`.
- Partial local files are cleaned up automatically on error via a `trap`.

---

## License

See [LICENSE](LICENSE) if present, or refer to the repository root.
