# all need run on aarch host
VERSION = $(shell cat Dockerfile.version | grep "^FROM " | sed -e "s/FROM.*:v\{0,\}//g" )
HUB ?= docker.io/querycapistio
TEMP_ROOT = ${PWD}/.tmp

# version tag or branch
# examples: make xxx TAG=1.11.0
TAG = $(VERSION)
RELEASE_BRANCH = master

GIT_CLONE = git clone
GIT_CLONE_TOOLS = git clone

ifneq ($(TAG),master)
	RELEASE_BRANCH = release-$(word 1,$(subst ., ,$(VERSION))).$(word 2,$(subst ., ,$(VERSION)))
	GIT_CLONE = git clone -b $(TAG)
	GIT_CLONE_TOOLS = git clone -b $(RELEASE_BRANCH)
endif

BUILD_TOOLS_VERSION = $(RELEASE_BRANCH)-latest
BUILD_TOOLS_IMAGE = $(HUB)/build-tools:$(BUILD_TOOLS_VERSION)
BUILD_TOOLS_PROXY_IMAGE = $(HUB)/build-tools-proxy:$(BUILD_TOOLS_VERSION)

echo:
	@echo "TAG: $(TAG)"
	@echo "RELEASE_BRANCH: $(RELEASE_BRANCH)"

clean.build-tools:
	rm -rf $(TEMP_ROOT)/tools

clone.build-tools:
	$(GIT_CLONE_TOOLS) --depth=1 https://github.com/istio/tools.git $(TEMP_ROOT)/tools

# Build build-tools && build-tools-proxy for arm64
dockerx.build-tools: clean.build-tools clone.build-tools
	cd $(TEMP_ROOT)/tools/docker/build-tools \
		&& DRY_RUN=1 HUB=$(HUB) CONTAINER_BUILDER="buildx build --push --platform=linux/arm64" ./build-and-push.sh

cleanup.envoy:
	rm -rf $(TEMP_ROOT)/proxy

# Clone istio/proxy
# To checkout last stable sha from istio/istio
clone.envoy: cleanup.istio clone.istio
	git clone https://github.com/istio/proxy.git $(TEMP_ROOT)/proxy
	cd $(TEMP_ROOT)/proxy && git checkout $(shell cat $(TEMP_ROOT)/istio/istio.deps | grep lastStableSHA | sed 's/.*"lastStableSHA": "\([a-zA-Z0-9]*\)"/\1/g')

# Build envoy
# /tmp/bazel here should must be link here, cause, bazel-out is symlink to TEST_TMPDIR
build.envoy: cleanup.envoy clone.envoy
	docker pull $(HUB)/build-tools-proxy:$(BUILD_TOOLS_VERSION)
	docker run \
		-e=ENVOY_ORG=istio \
		-e=TEST_TMPDIR=/tmp/bazel \
		-v=/tmp/bazel:/tmp/bazel \
		-v=$(TEMP_ROOT)/proxy:/go/src/istio/proxy \
		-w=/go/src/istio/proxy \
		$(BUILD_TOOLS_PROXY_IMAGE) make build_envoy
	mkdir -p $(TEMP_ROOT)/envoy-linux-arm64 && cp $(TEMP_ROOT)/proxy/bazel-bin/src/envoy/envoy $(TEMP_ROOT)/envoy-linux-arm64/envoy

cleanup.istio:
	rm -rf $(TEMP_ROOT)/istio

clone.istio:
	$(GIT_CLONE) --depth=1 https://github.com/istio/istio.git $(TEMP_ROOT)/istio


ISTIO_ENVOY_LINUX_ARM64_RELEASE_DIR = $(TEMP_ROOT)/istio/out/linux_arm64/release

AGENT_BINARIES := ./pilot/cmd/pilot-agent
STANDARD_BINARIES := ./pilot/cmd/pilot-discovery ./operator/cmd/operator

ISTIO_MAKE = cd $(TEMP_ROOT)/istio && IMG=$(BUILD_TOOLS_IMAGE) HUB=$(HUB) BASE_VERSION=$(TAG) TAG=$(TAG) make

# Build istio binaries and copy envoy binary for arm64
# in github actions it will download from artifacts
build.istio:
	cd $(TEMP_ROOT)/istio \
    	&& $(ISTIO_MAKE) build-linux TARGET_ARCH=amd64 STANDARD_BINARIES="$(STANDARD_BINARIES)" AGENT_BINARIES="$(AGENT_BINARIES)"
	cd $(TEMP_ROOT)/istio \
		&& $(ISTIO_MAKE) build-linux TARGET_ARCH=arm64 STANDARD_BINARIES="$(STANDARD_BINARIES)" AGENT_BINARIES="$(AGENT_BINARIES)" \
		&& cp $(TEMP_ROOT)/envoy-linux-arm64/envoy $(ISTIO_ENVOY_LINUX_ARM64_RELEASE_DIR)/envoy

ESCAPED_HUB := $(shell echo $(HUB) | sed "s/\//\\\\\//g")

# Replace istio base images and pull latest BUILD_TOOLS_IMAGE
# sed must be gnu sed
dockerx.istio.prepare:
	sed -i -e 's/gcr.io\/istio-release\/\(base\|distroless\)/$(ESCAPED_HUB)\/\1/g' $(TEMP_ROOT)/istio/pilot/docker/Dockerfile.pilot
	sed -i -e 's/gcr.io\/istio-release\/\(base\|distroless\)/$(ESCAPED_HUB)\/\1/g' $(TEMP_ROOT)/istio/pilot/docker/Dockerfile.proxyv2
	sed -i -e 's/gcr.io\/istio-release\/\(base\|distroless\)/$(ESCAPED_HUB)\/\1/g' $(TEMP_ROOT)/istio/operator/docker/Dockerfile.operator
	docker pull $(BUILD_TOOLS_IMAGE)

# Build istio base images as multi-arch
dockerx.istio-base:
	$(ISTIO_MAKE) dockerx.base DOCKERX_PUSH=true DOCKER_ARCHITECTURES=linux/amd64,linux/arm64
	$(ISTIO_MAKE) dockerx.distroless DOCKERX_PUSH=true DOCKER_ARCHITECTURES=linux/amd64,linux/arm64

COMPONENTS = proxyv2 pilot operator
dockerx.istio-components: dockerx.istio.prepare dockerx.istio-base
	$(foreach component,$(COMPONENTS),cd $(TEMP_ROOT)/istio && $(ISTIO_MAKE) dockerx.$(component) DOCKERX_PUSH=true DOCKER_BUILD_VARIANTS="default distroless" DOCKER_ARCHITECTURES=linux/amd64,linux/arm64;)

# Build istio images as multi-arch
dockerx.istio: cleanup.istio clone.istio build.istio dockerx.istio-components
