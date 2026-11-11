# Dockerfile to create a Mendix Docker image with Node.js 26 LTS and Google Chrome
# Base: RHEL/UBI (uses microdnf)
#
# Author: Mendix Digital Ecosystems, digitalecosystems@mendix.com
# Version: v6.1.0 (customized - UBI + Node.js 26 + Google Chrome + Python 3.11 fix)
#

ARG ROOTFS_IMAGE=mendix-rootfs:app
ARG BUILDER_ROOTFS_IMAGE=mendix-rootfs:builder

# ============================================================
# Build stage (unchanged)
# ============================================================
FROM ${BUILDER_ROOTFS_IMAGE} AS builder

ARG BUILD_PATH=project
ARG DD_API_KEY
ARG EXCLUDE_LOGFILTER=true
ARG BLOBSTORE
ARG BUILDPACK_XTRACE

COPY $BUILD_PATH /opt/mendix/build

ENV NGINX_CUSTOM_BIN_PATH=/usr/sbin/nginx
ARG USER_UID=1001

COPY scripts/startup.py scripts/vcap_application.json /opt/mendix/build/

RUN mkdir -p /tmp/buildcache/bust /tmp/cf-deps /var/mendix/build /var/mendix/build/.local && \
    chmod +rx /opt/mendix/buildpack/compilation.py /opt/mendix/buildpack/buildpack/stage.py /opt/mendix/build/startup.py && \
    cd /opt/mendix/buildpack && \
    ./compilation.py /opt/mendix/build /tmp/buildcache /tmp/cf-deps 0 && \
    rm -fr /tmp/buildcache /tmp/javasdk /tmp/opt /tmp/downloads /opt/mendix/buildpack/compilation.py /var/mendix && \
    ln -s /opt/mendix/.java /opt/mendix/build && \
    chown -R ${USER_UID}:0 /opt/mendix && \
    chmod -R g=u /opt/mendix

# ============================================================
# Final stage
# ============================================================
FROM ${ROOTFS_IMAGE}

LABEL Author="Mendix Digital Ecosystems"
LABEL maintainer="digitalecosystems@mendix.com"

# Switch to root for package installation
USER root

# Only used to decide whether Ruby is installed (Step 2). Never pass a real
# Datadog key as a build arg - give it to the container at runtime instead.
ARG DD_API_KEY

# Make sure /usr/local/bin (where Node.js is installed) is always on PATH
ENV PATH=/usr/local/bin:$PATH

# ============================================================
# Step 1: Install basic utilities
# NOTE: no bare `microdnf update -y` here - on UBI9 it drags in
# the python3 (3.9) package as a dependency and repoints
# /usr/bin/python3 away from the buildpack's 3.11. Install only
# the explicitly listed packages.
# NOTE: do NOT add "curl" - UBI9-minimal already ships
# curl-minimal (provides /usr/bin/curl) and the full curl
# package conflicts with it.
# ============================================================
RUN microdnf install -y \
        tar \
        gzip \
        xz \
        unzip \
        which \
        ca-certificates \
        shadow-utils \
        libstdc++ \
        libX11 \
        libXcomposite \
        libXdamage \
        libXext \
        libXfixes \
        libXrandr \
        libgbm \
        libxcb \
        alsa-lib \
        atk \
        cups-libs \
        gtk3 \
        nss \
        pango \
    && microdnf clean all && \
    rm -rf /var/cache/yum /var/cache/dnf && \
    command -v curl || { echo "ERROR: curl not found in base image"; exit 1; }

# ============================================================
# Step 2: Install Ruby conditionally for Datadog
# ============================================================
RUN if [ ! -z "$DD_API_KEY" ] ; then \
        microdnf install -y ruby && \
        microdnf clean all && \
        rm -rf /var/cache/yum /var/cache/dnf ; \
    fi

# ============================================================
# Step 3: Install Google Chrome at /opt/chrome/chrome-linux/
# Target path: /opt/chrome/chrome-linux/chrome
# Download/unzip failures stop the build; only the final
# version check is allowed to fail.
# (unzip is installed in Step 1)
# ============================================================
ENV CHROME_VERSION=120.0.6099.109
RUN set -e; \
    curl -fsSL "https://storage.googleapis.com/chrome-for-testing-public/${CHROME_VERSION}/linux64/chrome-linux64.zip" \
        -o /tmp/chrome-linux64.zip; \
    mkdir -p /opt/chrome; \
    unzip -q /tmp/chrome-linux64.zip -d /opt/chrome; \
    mv /opt/chrome/chrome-linux64 /opt/chrome/chrome-linux; \
    rm -f /tmp/chrome-linux64.zip; \
    chmod +x /opt/chrome/chrome-linux/chrome; \
    ln -sf /opt/chrome/chrome-linux/chrome /usr/bin/google-chrome; \
    /opt/chrome/chrome-linux/chrome --version --no-sandbox || echo "WARNING: chrome --version failed (non-fatal)"

# ============================================================
# Step 4: Install optional fonts (non-fatal if unavailable)
# ============================================================
RUN (microdnf install -y liberation-fonts dejavu-sans-fonts 2>/dev/null || \
     echo "WARNING: Some fonts were not available, continuing...") && \
    microdnf clean all && \
    rm -rf /var/cache/yum /var/cache/dnf

# ============================================================
# Step 5: Install Node.js 26 LTS from official binary
# Target path: /usr/local/bin/node
# ============================================================
ENV NODE_VERSION=26.13.1
RUN set -e; \
    case "$(uname -m)" in \
        x86_64)  NODE_ARCH=x64 ;; \
        aarch64) NODE_ARCH=arm64 ;; \
        *) echo "Unsupported arch: $(uname -m)"; exit 1 ;; \
    esac; \
    NODE_FILE="node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz"; \
    NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}"; \
    echo "Downloading ${NODE_URL}/${NODE_FILE}"; \
    curl -fsSL "${NODE_URL}/${NODE_FILE}" -o "/tmp/${NODE_FILE}"; \
    curl -fsSL "${NODE_URL}/SHASUMS256.txt" | grep " ${NODE_FILE}\$" > /tmp/node.sha256; \
    (cd /tmp && sha256sum -c node.sha256); \
    tar -xJf "/tmp/${NODE_FILE}" -C /usr/local --strip-components=1 --no-same-owner; \
    rm -f "/tmp/${NODE_FILE}" /tmp/node.sha256; \
    if ! /usr/local/bin/node --version; then \
        echo "ERROR: node failed to start. Missing libraries:"; \
        (ldd /usr/local/bin/node 2>&1 | grep -i "not found") || true; \
        exit 1; \
    fi; \
    /usr/local/bin/npm --version; \
    chmod -R a+rx /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx

# ============================================================
# Step 6: Ensure Python 3.11 is the container's python3
# The buildpack vendors its dependencies as cp311 wheels under
# /opt/mendix/buildpack/lib/python3.11/site-packages - the
# runtime interpreter MUST be 3.11. Any earlier microdnf
# transaction that installed python3 (3.9) is overridden here.
# ============================================================
RUN microdnf install -y python3.11 && \
    microdnf clean all && \
    rm -rf /var/cache/yum /var/cache/dnf && \
    ln -sf /usr/bin/python3.11 /usr/bin/python3 && \
    /usr/bin/python3.11 --version && \
    python3 --version

# ============================================================
# Environment variables for Chrome / Puppeteer
# ============================================================
ENV PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true
ENV PUPPETEER_EXECUTABLE_PATH=/opt/chrome/chrome-linux/chrome
ENV CHROME_PATH=/opt/chrome/chrome-linux/chrome
ENV CHROMIUM_FLAGS="--no-sandbox --disable-dev-shm-usage --disable-gpu --headless"

# ============================================================
# Mendix environment setup
# ============================================================
ENV HOME=/opt/mendix/build
ENV PYTHONPATH="/opt/mendix/buildpack/lib/:/opt/mendix/buildpack/:/opt/mendix/buildpack/lib/python3.11/site-packages/"

ARG USER_UID=1001

# Copy build artifacts from build container
COPY --from=builder /opt/mendix /opt/mendix

# npm global dir for non-root user
RUN mkdir -p /home/mendix/.npm-global && \
    chown -R ${USER_UID}:0 /home/mendix && \
    chmod -R g=u /home/mendix && \
    chown -R ${USER_UID}:0 /opt/chrome && \
    chmod -R g=u /opt/chrome

ENV NPM_CONFIG_PREFIX=/home/mendix/.npm-global
ENV PATH=/home/mendix/.npm-global/bin:$PATH

# Switch back to non-root user
USER ${USER_UID}

ENV NGINX_CUSTOM_BIN_PATH=/usr/sbin/nginx
WORKDIR /opt/mendix/build

ENV PORT=8080
EXPOSE $PORT

# Interpreter-explicit: immune to any future /usr/bin/python3 symlink change
ENTRYPOINT ["/usr/bin/python3.11", "/opt/mendix/build/startup.py"]