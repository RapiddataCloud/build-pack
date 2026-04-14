# Dockerfile to create a Mendix Docker image with Node.js 20 LTS and Chromium
# Base: RHEL/UBI (uses microdnf)
#
# Author: Mendix Digital Ecosystems, digitalecosystems@mendix.com
# Version: v6.0.2 (customized - UBI + Node.js + Chromium)

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
# Install Ruby (if Datadog), Chromium, and dependencies via microdnf
# ============================================================
RUN microdnf update -y && \
    microdnf install -y \
        # Basic utilities
        tar \
        gzip \
        xz \
        which \
        ca-certificates \
    && \
    # Install Ruby if Datadog is detected
    if [ ! -z "$DD_API_KEY" ] ; then \
        microdnf install -y ruby ; \
    fi && \
    # Enable CodeReady Builder / EPEL-like repos for Chromium (UBI 8/9)
    # Chromium is not in the default UBI repos, so we need to add one
    microdnf install -y \
        # Chromium dependencies (available in UBI)
        nss \
        nss-tools \
        nspr \
        alsa-lib \
        atk \
        at-spi2-atk \
        at-spi2-core \
        cups-libs \
        dbus-libs \
        gtk3 \
        libdrm \
        libxkbcommon \
        libXcomposite \
        libXdamage \
        libXext \
        libXfixes \
        libXrandr \
        libX11 \
        libXcb \
        mesa-libgbm \
        pango \
        cairo \
        # Fonts
        liberation-fonts \
        google-noto-sans-fonts \
        google-noto-sans-cjk-ttc-fonts \
        google-noto-emoji-fonts \
    && \
    microdnf clean all && \
    rm -rf /var/cache/yum /var/cache/dnf

# ============================================================
# Install Chromium from a prebuilt binary (since UBI doesn't ship Chromium)
# Using Chromium from Linux Foundation / official archives
# ============================================================
# Option: Use Google Chrome instead (has a stable RPM for RHEL)
RUN curl -fsSL https://dl.google.com/linux/direct/google-chrome-stable_current_x86_64.rpm -o /tmp/chrome.rpm && \
    microdnf install -y /tmp/chrome.rpm && \
    rm -f /tmp/chrome.rpm && \
    microdnf clean all && \
    rm -rf /var/cache/yum /var/cache/dnf && \
    google-chrome --version

# ============================================================
# Install Node.js 20 LTS from official binary
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
# Environment variables for Chrome/Puppeteer
# ============================================================
ENV PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true
ENV PUPPETEER_EXECUTABLE_PATH=/usr/bin/google-chrome
ENV CHROME_PATH=/usr/bin/google-chrome
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
    chmod -R g=u /home/mendix

ENV NPM_CONFIG_PREFIX=/home/mendix/.npm-global
ENV PATH=/home/mendix/.npm-global/bin:$PATH

# Switch back to non-root user
USER ${USER_UID}

ENV NGINX_CUSTOM_BIN_PATH=/usr/sbin/nginx
WORKDIR /opt/mendix/build

ENV PORT=8080
EXPOSE $PORT

ENTRYPOINT ["/opt/mendix/build/startup.py"]
