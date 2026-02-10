.PHONY: all ci build proto lint test-norace test deps docker-build docker-test docker-push docker-manifest crossbuild tarballs-release version clean busybox-versions

# Version variables
VERSION ?= $(shell git describe --tags --abbrev=0 2>/dev/null || (test -f VERSION && cat VERSION) || echo "v0.0.0-dev")
REVISION ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BRANCH ?= $(shell git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
BUILD_USER ?= $(shell whoami)@$(shell hostname)
BUILD_DATE ?= $(shell date -u +'%Y-%m-%dT%H:%M:%SZ')

# For local testing of build/release processes, create a buildx builder if you don't have one, and
# start a local registry if you don't have one:
#
#     docker buildx create --name container-builder --driver docker-container --bootstrap \
#            --platform linux/amd64,linux/arm64,linux/ppc64le
#
#     docker run -d -p 5000:5000 --restart always --name registry --init --network host registry:3
#
# and run a multi-arch build with:
#
#     make DOCKER_IMAGE_REPO=localhost:5000/thanos/thanos-parquet-gateway \
#          DOCKER_BUILD="docker buildx build --builder container-builder --load" \
#          DOCKER_MANIFEST_CREATE_FLAGS=--insecure \
#          docker-build docker-push docker-manifest
#
# The Makefile's build flow doesn't currently support bypassing local dockerd to directly push, so
# images are stored into the local dockerd before being pushed to the registry.
#

# Docker variables

# Override docker to allow direct use of podman or other tools
DOCKER ?= docker
DOCKER_BUILD ?= $(DOCKER) buildx build --load
# Pass --insecure here if manifest create fails with "no such manifest" on a local registry
DOCKER_MANIFEST_CREATE_FLAGS ?=

# Tag and image pushed to the remote repo by docker-push and docker-manifest targets
DOCKER_IMAGE_REPO ?= quay.io/thanos/thanos-parquet-gateway
DOCKER_IMAGE_TAG  ?= $(subst /,-,$(shell git rev-parse --abbrev-ref HEAD))-$(shell date +%Y-%m-%d)-$(shell git rev-parse --short HEAD)
DOCKER_CI_TAG ?= $(shell git rev-parse --short HEAD)
DOCKER_PLATFORM ?= linux/amd64,linux/arm64
DOCKER_BUILDX_BUILDER ?= multi-arch-builder

DOCKER_ARCHS       ?= amd64 arm64 ppc64le
# Generate three targets: docker-xxx-amd64, docker-xxx-arm64, docker-xxx-ppc64le.
# Run make docker-xxx -n to see the result with dry run.
BUILD_DOCKER_ARCHS = $(addprefix docker-build-,$(DOCKER_ARCHS))
TEST_DOCKER_ARCHS  = $(addprefix docker-test-,$(DOCKER_ARCHS))
PUSH_DOCKER_ARCHS  = $(addprefix docker-push-,$(DOCKER_ARCHS))

# Base images to use are resolved from .busybox-versions
BASE_DOCKER_IMAGE ?= quay.io/prometheus/busybox@sha256:
arch = $(shell uname -m)

include .busybox-versions
# The include .busybox-versions includes the SHA's of all the platforms, which can be used as var.
ifeq ($(arch), x86_64)
	# amd64
	BASE_DOCKER_SHA=${amd64}
else ifeq ($(arch), armv8)
	# arm64
	BASE_DOCKER_SHA=${arm64}
else ifeq ($(arch), arm64)
	# arm64
	BASE_DOCKER_SHA=${arm64}
else ifeq ($(arch), aarch64)
        # arm64
        BASE_DOCKER_SHA=${arm64}
else ifeq ($(arch), ppc64le)
	# ppc64le
	BASE_DOCKER_SHA=${ppc64le}
else
	echo >&2 "only support amd64, arm64 or ppc64le arch" && exit 1
endif

# Build flags
PKG = github.com/thanos-io/thanos-parquet-gateway/pkg/version
LDFLAGS = -s -w \
	-X '$(PKG).Version=$(VERSION)' \
	-X '$(PKG).Revision=$(REVISION)' \
	-X '$(PKG).Branch=$(BRANCH)' \
	-X '$(PKG).BuildUser=$(BUILD_USER)' \
	-X '$(PKG).BuildDate=$(BUILD_DATE)'

GO_BUILD_ARGS = -tags stringlabels -ldflags="$(LDFLAGS)"

all: build
.DEFAULT_GOAL=all

ci: test-norace build lint

build: protos parquet-gateway

GO = go
GOTOOL = $(GO) tool -modfile=go.tools.mod
GOIMPORTS = $(GOTOOL) golang.org/x/tools/cmd/goimports
REVIVE = $(GOTOOL) github.com/mgechev/revive
MODERNIZE = $(GOTOOL) golang.org/x/tools/gopls/internal/analysis/modernize/cmd/modernize
PROTOC = protoc

# Pinned busybox base image versions are currently manually updated here; "make busybox-versions".
# It should be under a GH workflow.
busybox-versions: scripts/busybox-updater.sh
	./scripts/busybox-updater.sh

lint: $(wildcard **/*.go)
	@echo ">> running lint..."
	$(REVIVE) -config revive.toml ./...
	$(MODERNIZE) -test ./...
	find . -name '*.go' ! -path './proto/*' | xargs $(GOIMPORTS) -l -w -local $(head -n 1 go.mod | cut -d ' ' -f 2)
	@golangci-lint run ./...

test-norace: $(wildcard **/*.go)
	@echo ">> running tests without checking for races..."
	@mkdir -p .cover
	$(GO) test -v -tags stringlabels -short -count=1 ./... -coverprofile .cover/cover.out

test: $(wildcard **/*.go)
	@echo ">> running tests..."
	@mkdir -p .cover
	$(GO) test -v -tags stringlabels -race -short -count=1 ./... -coverprofile .cover/cover.out

parquet-gateway: $(shell find . -type f -name '*.go')
	@echo ">> building binaries..."
	@$(GO) build $(GO_BUILD_ARGS) -o parquet-gateway github.com/thanos-io/thanos-parquet-gateway/cmd

protos: proto/metapb/meta.pb.go proto/streampb/stream.pb.go

proto/streampb/stream.pb.go: proto/streampb/stream.proto
	@echo ">> compiling protos..."
	@$(PROTOC) -I=proto/streampb/ --go_out=paths=source_relative:./proto/streampb/ proto/streampb/stream.proto

proto/metapb/meta.pb.go: proto/metapb/meta.proto
	@echo ">> compiling protos..."
	@$(PROTOC) -I=proto/metapb/ --go_out=paths=source_relative:./proto/metapb/ proto/metapb/meta.proto

.PHONY: docker-test $(TEST_DOCKER_ARCHS)
docker-test: $(TEST_DOCKER_ARCHS)
$(TEST_DOCKER_ARCHS): docker-test-%:
	@echo ">> testing image"
	@$(DOCKER) run "thanos-linux-$*" --help

.PHONY: docker-build $(BUILD_DOCKER_ARCHS)
docker-build: $(BUILD_DOCKER_ARCHS)
$(BUILD_DOCKER_ARCHS): docker-build-%:
	@$(DOCKER_BUILD) -t "thanos-linux-$*" \
  --build-arg BASEIMAGE="$(BASE_DOCKER_IMAGE)$($*)" \
  --platform=linux/$* \
  .

.PHONY: docker-push $(PUSH_DOCKER_ARCHS)
docker-push: ## Pushes Thanos docker image build to "$(DOCKER_IMAGE_REPO):$(DOCKER_IMAGE_TAG)".
docker-push: $(PUSH_DOCKER_ARCHS)
$(PUSH_DOCKER_ARCHS): docker-push-%:
	@echo ">> pushing image"
	@docker tag "thanos-linux-$*" "$(DOCKER_IMAGE_REPO)-linux-$*:$(DOCKER_IMAGE_TAG)"
	@docker push "$(DOCKER_IMAGE_REPO)-linux-$*:$(DOCKER_IMAGE_TAG)"

	# docker-manifest push docker manifest to support multiple architectures.
.PHONY: docker-manifest
docker-manifest:
	@echo ">> creating and pushing manifest"
	DOCKER_CLI_EXPERIMENTAL=enabled $(DOCKER) manifest create $(DOCKER_MANIFEST_CREATE_FLAGS) -a "$(DOCKER_IMAGE_REPO):$(DOCKER_IMAGE_TAG)" $(foreach ARCH,$(DOCKER_ARCHS),$(DOCKER_IMAGE_REPO)-linux-$(ARCH):$(DOCKER_IMAGE_TAG))
	DOCKER_CLI_EXPERIMENTAL=enabled $(DOCKER) manifest push "$(DOCKER_IMAGE_REPO):$(DOCKER_IMAGE_TAG)"

# Cross-compilation targets. These are NOT used to produce the Docker images.
crossbuild:
	@echo ">> cross-building binaries"
	@mkdir -p .build
	@for os in linux; do \
		for arch in amd64 arm64 ppc64le; do \
			echo "Building for $$os/$$arch"; \
			CGO_ENABLED=0 GOOS=$$os GOARCH=$$arch $(GO) build $(GO_BUILD_ARGS) -o .build/$$os-$$arch/thanos-parquet-gateway github.com/thanos-io/thanos-parquet-gateway/cmd; \
		done; \
	done

# Release tarballs
tarballs-release: crossbuild
	@echo ">> creating release tarballs"
	@mkdir -p .tarballs
	@for os in linux darwin windows; do \
		for arch in amd64 arm64; do \
			binary=thanos-parquet-gateway-$$os-$$arch; \
			tarball=thanos-parquet-gateway-$(VERSION).$$os-$$arch.tar.gz; \
			echo "Creating $$tarball"; \
			tar -czf .tarballs/$$tarball -C .build $$binary; \
		done; \
	done
	@echo ">> calculating checksums"
	@cd .tarballs && sha256sum *.tar.gz > sha256sums.txt

# Version information
version:
	@echo "VERSION: $(VERSION)"
	@echo "REVISION: $(REVISION)"
	@echo "BRANCH: $(BRANCH)"
	@echo "BUILD_USER: $(BUILD_USER)"
	@echo "BUILD_DATE: $(BUILD_DATE)"

# Clean build artifacts
clean:
	@echo ">> cleaning build artifacts"
	@rm -rf .build .tarballs parquet-gateway .cover

# Dependencies
deps:
	@echo ">> ensuring dependencies"
	@$(GO) mod tidy
	@$(GO) mod verify
