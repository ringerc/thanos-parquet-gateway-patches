# syntax=docker/dockerfile:1

# Multi-platform build image with cross compilation. See
# https://docs.docker.com/build/building/multi-platform/
# and https://hub.docker.com/_/golang/#cross-compile-your-app-inside-the-docker-container

# Image to use for go builds
ARG GOIMAGE=golang:1.25-trixie

# Image to use as base for released result. Typically the base images are injected
# by the Makefile using pinned digests for this image from the .busybox_images
# file.
ARG BASEIMAGE=quay.io/prometheus/busybox:latest

# Compile on the local build arch
FROM --platform=$BUILDPLATFORM $GOIMAGE AS builder
ARG GOOS
ARG GOARCH

WORKDIR /build

# Cache modules to make rebuilds faster
# https://go.dev/ref/mod#module-cache
COPY go.* ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download

COPY . .

# Build the binary, possibly cross-compiling
ARG TARGETARCH
ARG TARGETOS
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    mkdir bin && \
    GOARCH=${TARGETARCH} GOOS=${TARGETOS} go build -o bin/thanos-parquet-gateway ./cmd/...

# Prepare result image on the target arch
FROM $BASEIMAGE

LABEL maintainer="The Thanos Authors"
COPY --from=builder /build/bin/thanos-parquet-gateway /bin/thanos-parquet-gateway

RUN adduser \
    -D `#Dont assign a password` \
    -H `#Dont create home directory` \
    -u 1001 `#User id`\
    thanos && \
    chown thanos /bin/thanos-parquet-gateway
USER 1001
ENTRYPOINT [ "/bin/thanos-parquet-gateway" ]
