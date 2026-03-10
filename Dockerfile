FROM cgr.dev/chainguard/wolfi-base:latest AS builder

ARG JATTACH_VERSION=v2.2

USER root

RUN apk add --no-cache curl \
 && curl -fsSL -o /tmp/jattach \
      "https://github.com/jattach/jattach/releases/download/${JATTACH_VERSION}/jattach" \
 && chmod +x /tmp/jattach \
 && mkdir -p /usr/local/bin \
 && mv /tmp/jattach /usr/local/bin/jattach

FROM cgr.dev/chainguard/wolfi-base:latest

USER root

RUN apk add --no-cache procps \
 && mkdir -p /usr/local/bin

COPY --from=builder /usr/local/bin/jattach /usr/local/bin/jattach