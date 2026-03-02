# ==============================================================================
# HeapVault 1.0 - PT Java Toolbox (Amazon Corretto 21 LTS)
#
# Purpose:
#   A platform-owned debug toolbox image to run inside Kubernetes as an
#   ephemeral container and perform JVM operations (heap dump via jcmd, etc.)
#   without relying on tools in the application image.
#
# Includes:
#   - Amazon Corretto 21 JDK (jcmd/jmap/jstack included)
#   - Minimal ops tools: bash, curl, gzip, tar, procps, coreutils, jq
#
# Notes:
#   - No runtime downloads. Everything is baked at build time.
#   - Runs as non-root by default (toolbox user). In Kubernetes debug scenarios,
#     you can still run it as root if your policies require it.
# ==============================================================================

FROM amazoncorretto:21

SHELL ["/bin/bash", "-lc"]

# OCI labels (helpful for registry/auditing)
ARG BUILD_DATE="unknown"
ARG VCS_REF="unknown"
ARG VERSION="1.0.0"

LABEL org.opencontainers.image.title="HeapVault"
LABEL org.opencontainers.image.description="PT JVM debug toolbox based on Amazon Corretto 21 (jcmd/jmap/jstack + minimal ops tools)"
LABEL org.opencontainers.image.version="${VERSION}"
LABEL org.opencontainers.image.revision="${VCS_REF}"
LABEL org.opencontainers.image.created="${BUILD_DATE}"
LABEL org.opencontainers.image.licenses="Apache-2.0"

# Install minimal tooling
RUN yum -y update && yum -y install \
      bash \
      curl \
      gzip \
      tar \
      procps-ng \
      coreutils \
      jq \
    && yum clean all \
    && rm -rf /var/cache/yum

# Optional diagnostics (enable only if you *really* need them; security may complain)
# RUN yum -y install \
#       bind-utils \
#       iputils \
#       traceroute \
#     && yum clean all \
#     && rm -rf /var/cache/yum

# Non-root user by default
RUN useradd -m -u 10001 -g 0 toolbox || true
USER 10001:0

# Quick self-test at container start (cheap, deterministic)
ENTRYPOINT ["/bin/bash", "-lc"]
CMD ["java -version && jcmd -h >/dev/null && echo 'HeapVault ready'"]