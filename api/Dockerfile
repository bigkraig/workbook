# syntax=docker/dockerfile:1
# Base images pinned by digest (reproducible, immune to tag re-pushes). Bump version +
# digest to pick up security patches: docker buildx imagetools inspect <image:tag>.
FROM rust:1.100.0-slim-bookworm@sha256:7c7d4eb4d05b7781187a327809466cfddf29753f6defdc3d19a0e291951b7a37 AS builder

WORKDIR /app

COPY ./ ./

# Cache the cargo registry, git deps, and the target dir across builds (persisted
# on the buildx builder). A source-only change then recompiles just the workbook
# crate instead of rebuilding every dependency from scratch. The built binary lives
# in the cached target mount, so copy it out to a real layer for the final stage.
# --no-default-features drops the SQLite backend (local-dev only): production is
# Postgres, so the bundled C SQLite never ships in the image.
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/app/target \
    cargo build --release --no-default-features && cp target/release/workbook /usr/local/bin/workbook

FROM debian:bookworm-20261104-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc

# All TLS is rustls (no OpenSSL); only the CA bundle is needed. upgrade picks up Debian
# security fixes published after the pinned snapshot.
RUN apt-get update && apt-get upgrade -y && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/bin/workbook /usr/local/bin/workbook
COPY --from=builder /app/migrations /data/migrations

RUN mkdir -p /data
WORKDIR /data

CMD ["workbook", "api"]
