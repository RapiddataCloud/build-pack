# Dockerfile to create a Mendix Docker image based on either the source code or
# Mendix Deployment Archive (aka mda file)
# Ubuntu-based with Node.js 20 LTS and Chromium
#
# Author: Mendix Digital Ecosystems, digitalecosystems@mendix.com
# Version: v6.0.2 (customized - Ubuntu + Node.js + Chromium)

ARG ROOTFS_IMAGE=mendix-rootfs:app
ARG BUILDER_ROOTFS_IMAGE=mendix-rootfs:builder

# ============================================================
# Build stage
# ============================================================
FROM ${BUILDER_ROOTFS_IMAGE} AS builder

# Build-time variables
ARG BUILD_PATH=project
ARG DD_API_KEY
ARG EXCLUDE_LOGFILTER=true
ARG BLOBSTORE
ARG BUILDPACK_XTRACE

# Copy project model/sources
COPY $BUILD_PATH /opt/mendix/build

# Use nginx supplied by the base OS
ENV NGINX_CUSTOM_BIN_PATH=/usr/sbin/nginx

# Set the user ID
ARG USER_UID=1001

# Copy start scripts
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

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# ============================================================
# Install base utilities, Datadog (if applicable), Node.js 20 LTS, and Chromium
# ============================================================
ARG DD_API_KEY

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        wget \
        xz-utils \
        tzdata \
    && \
    # ------------------------------------------------------------
    # Install Ruby if Datadog is detected
    # ------------------------------------------------------------
    if [ ! -z "$DD_API_KEY" ] ; then \
        apt-get install -y --no-install-recommends ruby ruby-dev ; \
    fi && \
    # ------------------------------------------------------------
    # Install Chromium and its runtime dependencies
    # ------------------------------------------------------------
    apt-get install -y --no-install-recommends \
        chromium-browser \
        # Fonts for proper rendering (including CJK and Arabic for UAE)
        fonts-liberation \
        fonts-noto \
        fonts-noto-cjk \
        fonts-noto-color-emoji \
        fonts-freefont-ttf \
        # Chromium runtime dependencies
        libnss3 \
        libnspr4 \
        libatk-bridge2.0-0 \
        libatk1.0-0 \
        libatspi2.0-0 \
        libcups2 \
        libdbus-1-3 \
        libdrm2 \
        libxkbcommon0 \
        libxcomposite1 \
        libxdamage1 \
        libxext6 \
        libxfixes3 \
        libxrandr2 \
        libgbm1 \
        libpango-1.0-0 \
        libcairo2 \
        libasound2 \
        libx11-xcb1 \
        libxcb-dri3-0 \
        libxshmfence1 \
        libgtk-3-0 \
    && \
    # ------------------------------------------------------------
    # Clean up apt caches to reduce image size
    # ------------------------------------------------------------
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# ============================================================
# Install Node.js 20 LTS from official binary distribution
# ============================================================
ENV NODE_VERSION=20.18.0
RUN ARCH=$(uname -m) && \
    case "$ARCH" in \
        x86_64)  NODE_ARCH=x64 ;; \
        aarch64) NODE_ARCH=arm64 ;; \
        armv7l)  NODE_ARCH=armv7l ;; \
        *) echo "Unsupported arch: $ARCH" && exit 1 ;; \
    esac && \
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" -o /tmp/node.tar.xz && \
    tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 --no-same-owner && \
    rm -f /tmp/node.tar.xz && \
    # Verify installation
    node --version && \
    npm --version && \
    # Ensure binaries are executable by all users
    chmod -R a+rx /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx

# ============================================================
# Verify Chromium installation and set environment variables
# ============================================================
RUN chromium-browser --version || chromium --version

# Puppeteer / headless browser environment variables
ENV PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true
ENV PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser
ENV CHROMIUM_PATH=/usr/bin/chromium-browser

# Recommended Chromium flags for containerized environments
ENV CHROMIUM_FLAGS="--no-sandbox --disable-dev-shm-usage --disable-gpu --headless --disable-software-rasterizer"

# ============================================================
# Mendix environment setup
# ============================================================
ENV HOME=/opt/mendix/build
ENV PYTHONPATH="/opt/mendix/buildpack/lib/:/opt/mendix/buildpack/:/opt/mendix/buildpack/lib/python3.11/site-packages/"

# Set the user ID
ARG USER_UID=1001

# Copy build artifacts from build container
COPY --from=builder /opt/mendix /opt/mendix

# Ensure Node.js and npm global directories are accessible to the non-root user
RUN mkdir -p /home/mendix/.npm-global && \
    chown -R ${USER_UID}:0 /home/mendix && \
    chmod -R g=u /home/mendix

# Set npm global directory for the non-root user (prevents permission issues)
ENV NPM_CONFIG_PREFIX=/home/mendix/.npm-global
ENV PATH=/home/mendix/.npm-global/bin:$PATH

# Switch to non-root user for runtime
USER ${USER_UID}

# Use nginx supplied by the base OS
ENV NGINX_CUSTOM_BIN_PATH=/usr/sbin/nginx
WORKDIR /opt/mendix/build

# Expose nginx port
ENV PORT=8080
EXPOSE $PORT

ENTRYPOINT ["/opt/mendix/build/startup.py"]
