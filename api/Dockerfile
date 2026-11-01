# syntax=docker/dockerfile:1
FROM rust:1.93-slim-bookworm AS builder

WORKDIR /app

RUN apt-get update && apt-get install -y pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*

COPY ./ ./

# Cache the cargo registry, git deps, and the target dir across builds (persisted
# on the buildx builder). A source-only change then recompiles just the workbook
# crate instead of rebuilding every dependency from scratch. The built binary lives
# in the cached target mount, so copy it out to a real layer for the final stage.
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/app/target \
    cargo build --release && cp target/release/workbook /usr/local/bin/workbook

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y ca-certificates libssl3 && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/bin/workbook /usr/local/bin/workbook
COPY --from=builder /app/migrations /data/migrations

RUN mkdir -p /data
WORKDIR /data

CMD ["workbook", "api"]
