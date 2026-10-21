ARG BASE_IMAGE=docker.arvancloud.ir/library/alpine:3.24
FROM ${BASE_IMAGE}

ARG SINGBOX_VERSION=1.14.2
ARG TARGETARCH=amd64

RUN apk add --no-cache bash curl jq tini ca-certificates iproute2 nginx openssl

RUN set -eux; \
    curl -fsSL -o /tmp/sing-box.tar.gz \
        "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-${TARGETARCH}-musl.tar.gz"; \
    tar -xzf /tmp/sing-box.tar.gz -C /tmp \
        "sing-box-${SINGBOX_VERSION}-linux-${TARGETARCH}-musl/sing-box"; \
    mv "/tmp/sing-box-${SINGBOX_VERSION}-linux-${TARGETARCH}-musl/sing-box" /usr/local/bin/sing-box; \
    chmod +x /usr/local/bin/sing-box; \
    rm -rf /tmp/sing-box.tar.gz "/tmp/sing-box-${SINGBOX_VERSION}-linux-${TARGETARCH}-musl"; \
    sing-box version

COPY www /var/www/html
COPY --chmod=755 scripts /usr/local/bin

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
