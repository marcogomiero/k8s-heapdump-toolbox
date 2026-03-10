FROM alpine:3.23.3 AS builder

ARG JATTACH_VERSION=v2.2
RUN apk add --no-cache curl
RUN curl -fsSL -o /jattach \
    https://github.com/jattach/jattach/releases/download/${JATTACH_VERSION}/jattach \
 && chmod +x /jattach

FROM alpine:3.23.3

RUN apk add --no-cache \
    bash \
    gzip \
    tar \
    procps \
    coreutils \
    jq

COPY --from=builder /jattach /usr/local/bin/jattach

ENTRYPOINT ["/bin/bash","-lc"]
CMD ["echo 'kheap toolbox ready'"]