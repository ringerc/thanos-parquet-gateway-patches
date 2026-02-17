# syntax=docker/dockerfile:1

# Multi-platform build image with cross compilation. See
# https://docs.docker.com/build/building/multi-platform/
# and https://hub.docker.com/_/golang/#cross-compile-your-app-inside-the-docker-container

# Image to use for go builds
ARG GORELEASER_IMAGE=goreleaser/goreleaser-cross:v1.25

# Image to use as base for released result. Typically the base images are injected
# by the Makefile using pinned digests for this image from the .busybox_images
# file.
ARG BASEIMAGE=quay.io/prometheus/busybox:latest

# Compile on the local build arch
FROM --platform=$BUILDPLATFORM ${GORELEASER_IMAGE} AS builder
ARG GOOS
ARG GOARCH

WORKDIR /build

# Cache modules to make rebuilds faster
# https://go.dev/ref/mod#module-cache
COPY go.* ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download

COPY . .

# Build the binary, possibly cross-compiling.
#
# Goreleaser really prefers to build the binaries outside the container and
# release the same binaries as build artifacts + container binaries. But this
# isn't particularly practical with CGO cross-compilation as is presently
# required for FIPS-mode Go binaries, and I prefer to build binaries within a
# containerised build env for reproducibility & isolation anyway.
#
# Arguably the "goreleaser release" step could be run directly from within the
# container build if we want to upload bare binaries in future. Or this could
# be done only for the FIPS build, and the non-FIPS build could use a regular
# goreleaser invocation. But for now, in-container it is.
#
ARG TARGETARCH
ARG TARGETOS
ARG GORELEASER_TARGET_NAME=parquet-gateway
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    mkdir bin && \
    GOARCH=${TARGETARCH} GOOS=${TARGETOS} goreleaser build -f .goreleaser.yml --skip=validate --clean --verbose --single-target --id=${GORELEASER_TARGET_NAME}

# Prepare result image on the target arch
FROM $BASEIMAGE

LABEL maintainer="The Thanos Authors"

ARG GORELEASER_BINARY_NAME=parquet-gateway
COPY --from=builder /build/dist/${GORELEASER_BINARY_NAME} /usr/local/bin/${GORELEASER_BINARY_NAME}

RUN adduser \
    -D `#Dont assign a password` \
    -H `#Dont create home directory` \
    -u 1001 `#User id`\
    thanos && \
    chown thanos /usr/local/bin/${GORELEASER_BINARY_NAME}
USER 1001
ENTRYPOINT [ "/usr/local/bin/${GORELEASER_BINARY_NAME}" ]
