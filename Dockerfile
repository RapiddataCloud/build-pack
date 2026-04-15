# Dockerfile to create a Mendix Docker image with Node.js 20 LTS and Google Chrome
# Base: RHEL/UBI (uses microdnf)
#
# Author: Mendix Digital Ecosystems, digitalecosystems@mendix.com
# Version: v6.0.3 (customized - UBI + Node.js + Google Chrome)

ARG ROOTFS_IMAGE=mendix-rootfs:app
ARG BUILDER_ROOTFS_IMAGE=mendix-rootfs:builder

# ============================================================
# Build stage
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

ARG DD_API_KEY

# ============================================================
# Step 1: Install basic utilities (guaranteed to be available)
# ============================================================
RUN microdnf update -y && \
    microdnf install -y \
        tar \
        gzip \
        xz \
        which \
        ca-certificates \
        shadow-utils \
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
    rm -rf /var/cache/yum /var/cache/dnf

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
# ============================================================
ENV CHROME_VERSION=120.0.6099.109
RUN curl -fsSL "https://storage.googleapis.com/chrome-for-testing-public/${CHROME_VERSION}/linux64/chrome-linux64.zip" \
        -o /tmp/chrome-linux64.zip && \
    microdnf install -y unzip && \
    microdnf clean all && \
    mkdir -p /opt/chrome && \
    unzip /tmp/chrome-linux64.zip -d /opt/chrome && \
    mv /opt/chrome/chrome-linux64 /opt/chrome/chrome-linux && \
    rm -f /tmp/chrome-linux64.zip && \
    chmod +x /opt/chrome/chrome-linux/chrome && \
    ln -sf /opt/chrome/chrome-linux/chrome /usr/bin/google-chrome && \
    /opt/chrome/chrome-linux/chrome --version --no-sandbox || true

# ============================================================
# Step 4: Install optional fonts (non-fatal if unavailable)
# ============================================================
RUN microdnf install -y liberation-fonts dejavu-sans-fonts 2>/dev/null || \
    echo "WARNING: Some fonts were not available, continuing..." && \
    microdnf clean all && \
    rm -rf /var/cache/yum /var/cache/dnf

# ============================================================
# Step 5: Install Node.js 20 LTS from official binary
# Target path: /usr/local/bin/node
# ============================================================
ENV NODE_VERSION=20.18.0
RUN ARCH=$(uname -m) && \
    case "$ARCH" in \
        x86_64)  NODE_ARCH=x64 ;; \
        aarch64) NODE_ARCH=arm64 ;; \
        *) echo "Unsupported arch: $ARCH" && exit 1 ;; \
    esac && \
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" -o /tmp/node.tar.xz && \
    tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 --no-same-owner && \
    rm -f /tmp/node.tar.xz && \
    node --version && \
    npm --version && \
    chmod -R a+rx /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx

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

ENTRYPOINT ["/opt/mendix/build/startup.py"]
