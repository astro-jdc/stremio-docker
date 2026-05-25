# syntax=docker/dockerfile:1
# Base: Node 20 on Alpine 3.23
FROM node:20-alpine3.23 AS base

RUN --mount=type=cache,id=apk-base,target=/var/cache/apk \
  apk update && apk upgrade

##########################################################################
# FFmpeg stage: jellyfin-ffmpeg v4.4.1-4 for all architectures
FROM base AS ffmpeg

ENV BIN="/usr/bin"

COPY ./patches/ffmpeg-mathops-binutils241.patch /tmp/ffmpeg-mathops-binutils241.patch
COPY ./patches/ffmpeg-mlpdsp-armv5te-binutils243.patch /tmp/ffmpeg-mlpdsp-armv5te-binutils243.patch

# Install build dependencies
RUN apk add --no-cache --virtual .build-dependencies \
  gnutls \
  freetype-dev \
  gnutls-dev \
  lame-dev \
  libass-dev \
  libogg-dev \
  libtheora-dev \
  libvorbis-dev \
  libvpx-dev \
  libwebp-dev \
  libssh2 \
  opus-dev \
  rtmpdump-dev \
  x264-dev \
  x265-dev \
  yasm-dev \
  build-base \
  coreutils \
  gnutls \
  nasm \
  dav1d-dev \
  libbluray-dev \
  libdrm-dev \
  zimg-dev \
  aom-dev \
  xvidcore-dev \
  fdk-aac-dev \
  libva-dev \
  linux-headers \
  git \
  x264

# Build ffmpeg: jellyfin-ffmpeg v4.4.1-4 for all architectures.
# linux-headers (in .build-dependencies) auto-enables V4L2 M2M for aarch64 (RK3588 rkvdec2).
# VAAPI is disabled on 32-bit ARM (not supported) and enabled on x86_64.
RUN DIR=$(mktemp -d) && \
  cd "${DIR}" && \
  case "$(uname -m)" in \
    armv6l|armv7l) VAAPI_FLAGS="--disable-vaapi --disable-hwaccel=h264_vaapi --disable-hwaccel=hevc_vaapi" ;; \
    x86_64)        VAAPI_FLAGS="--enable-vaapi --enable-hwaccel=h264_vaapi --enable-hwaccel=hevc_vaapi" ;; \
    *)             VAAPI_FLAGS="" ;; \
  esac && \
  git clone --depth 1 --branch v4.4.1-4 https://github.com/jellyfin/jellyfin-ffmpeg.git && \
  cd jellyfin-ffmpeg* && \
  awk '/^diff --git /,0' /tmp/ffmpeg-mathops-binutils241.patch | patch -p1 && \
  awk '/^diff --git /,0' /tmp/ffmpeg-mlpdsp-armv5te-binutils243.patch | patch -p1 && \
  ./configure \
    --bindir="$BIN" \
    --prefix=/usr/lib/jellyfin-ffmpeg \
    --disable-debug \
    --disable-doc \
    --disable-ffplay \
    --disable-shared \
    --disable-libxcb \
    --disable-sdl2 \
    --disable-xlib \
    --extra-cflags="-Wno-error -Wno-error=deprecated-declarations -Wno-error=discarded-qualifiers" \
    --extra-version=Jellyfin \
    --enable-lto \
    --enable-gpl \
    --enable-version3 \
    --enable-gmp \
    --enable-gnutls \
    --enable-libdrm \
    --enable-libass \
    --enable-libfreetype \
    --enable-libfribidi \
    --enable-libfontconfig \
    --enable-libbluray \
    --enable-libmp3lame \
    --enable-libopus \
    --enable-libtheora \
    --enable-libvorbis \
    --enable-libdav1d \
    --enable-libwebp \
    --enable-libvpx \
    --enable-libx264 \
    --enable-libx265 \
    --enable-libzimg \
    --enable-small \
    --enable-nonfree \
    --enable-libxvid \
    --enable-libaom \
    --enable-libfdk_aac \
    ${VAAPI_FLAGS} \
    --toolchain=hardened && \
  make -j"$(nproc)" && \
  make install && \
  find /usr/lib/jellyfin-ffmpeg -name '*.a' -delete && \
  rm -rf /usr/lib/jellyfin-ffmpeg/include && \
  make distclean && \
  rm -rf "${DIR}" && \
  apk del --purge .build-dependencies

##########################################################################
# Builder image
FROM base AS builder-web

WORKDIR /srv
RUN apk add --no-cache git wget

ARG BRANCH=development
RUN REPO="https://github.com/Stremio/stremio-web.git"; \
  if [ "$BRANCH" == "release" ]; then \
    git clone "$REPO" --depth 1 --branch \
      $(git ls-remote --tags --refs $REPO | awk '{print $2}' | sort -V | tail -n1 | cut -d/ -f3); \
  else \
    git clone --depth 1 --branch "$BRANCH" https://github.com/Stremio/stremio-web.git; \
  fi

WORKDIR /srv/stremio-web

COPY ./load_localStorage.js ./src/load_localStorage.js
RUN sed -i "/entry: {/a \\        loader: './src/load_localStorage.js'," webpack.config.js

RUN npm install -g pnpm@9 --force
RUN pnpm install --frozen-lockfile --reporter=silent
RUN pnpm run build

RUN wget $(wget -O- https://raw.githubusercontent.com/Stremio/stremio-shell/master/server-url.txt) && \
  wget -mkEpnp -nH \
    "https://app.strem.io/" \
    "https://app.strem.io/worker.js" \
    "https://app.strem.io/images/stremio.png" \
    "https://app.strem.io/images/empty.png" \
    -P build/shell/ || true

##########################################################################
# Main image
FROM base AS final

ARG VERSION=main
LABEL org.opencontainers.image.source=https://github.com/tsaridas/stremio-docker
LABEL org.opencontainers.image.description="Stremio Web Player and Server"
LABEL org.opencontainers.image.licenses=MIT
LABEL version=${VERSION}

WORKDIR /srv/stremio-server
COPY --from=builder-web /srv/stremio-web/build ./build
COPY --from=builder-web /srv/stremio-web/server.js ./

RUN apk add --no-cache nginx apache2-utils

COPY ./nginx/ /etc/nginx/
COPY ./stremio-web-service-run.sh ./
COPY ./certificate.js ./
RUN chmod +x stremio-web-service-run.sh
COPY ./restart_if_idle.sh ./
RUN chmod +x restart_if_idle.sh
COPY localStorage.json ./

ENV FFMPEG_BIN=
ENV FFPROBE_BIN=
ENV WEBUI_LOCATION=
ENV WEBUI_INTERNAL_PORT=
ENV OPEN=
ENV HLS_DEBUG=
ENV DEBUG=
ENV DEBUG_MIME=
ENV DEBUG_FD=
ENV FFMPEG_DEBUG=
ENV FFSPLIT_DEBUG=
ENV NODE_DEBUG=
ENV NODE_ENV=production
ENV HTTPS_CERT_ENDPOINT=
ENV DISABLE_CACHING=
ENV READABLE_STREAM=
ENV APP_PATH=
ENV NO_CORS=1
ENV CASTING_DISABLED=
ENV IPADDRESS=
ENV DOMAIN=
ENV CERT_FILE=
ENV SERVER_URL=
ENV AUTO_SERVER_URL=0

# Copy ffmpeg binaries
COPY --from=ffmpeg /usr/bin/ffmpeg /usr/bin/ffprobe /usr/bin/
COPY --from=ffmpeg /usr/lib/jellyfin-ffmpeg /usr/lib/jellyfin-ffmpeg

# Add common runtime libs
RUN apk add --no-cache \
  libwebp libwebpmux libvorbis x265-libs x264-libs libass opus \
  libgmpxx lame-libs gnutls libvpx libtheora libdrm libbluray \
  zimg libdav1d aom-libs xvidcore fdk-aac libva

# Add arch-specific runtime libs
RUN if [ "$(uname -m)" = "x86_64" ]; then \
    apk add --no-cache intel-media-driver mesa-va-gallium; \
  fi

RUN --mount=type=cache,id=apk-base,target=/var/cache/apk \
  apk update && apk upgrade

# Clean up
RUN rm -rf /opt/yarn-v* /usr/local/lib/node_modules \
  && rm -f /usr/local/bin/yarn /usr/local/bin/yarnpkg \
     /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack \
  && rm -rf /usr/share/man/* /usr/share/doc/* \
  && rm -rf /var/cache/apk/* /tmp/*

VOLUME ["/root/.stremio-server"]

EXPOSE 8080

ENTRYPOINT []
CMD ["./stremio-web-service-run.sh"]