# syntax=docker/dockerfile:1

ARG RUBY_VERSION=3.4
ARG DEBIAN_RELEASE=trixie

# ------------------------------------------------------------
# OpenSSL: ハーメルン(syosetu.org)の Cloudflare 対策
# Debian 同梱の OpenSSL で作った TLS ClientHello はボット判定され本文ページが 403 になる。
# Mac(Homebrew)と同じ OpenSSL 3.6 系をビルドし、Ruby の openssl gem をこれにリンクする。
# ------------------------------------------------------------
FROM debian:${DEBIAN_RELEASE}-slim AS openssl
ARG OPENSSL_VERSION=3.6.5
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential ca-certificates perl wget \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /build
RUN wget -q https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz \
 && tar xzf openssl-${OPENSSL_VERSION}.tar.gz \
 && cd openssl-${OPENSSL_VERSION} \
 && ./Configure --prefix=/opt/openssl --libdir=lib --openssldir=/usr/lib/ssl \
      shared no-docs '-Wl,-rpath,/opt/openssl/lib' \
 && make -j"$(nproc)" \
 && make install_sw

# ------------------------------------------------------------
# boko: EPUB -> KFX 変換（chikiny/boko の Fork を使う）
# ------------------------------------------------------------
FROM rust:1-slim-${DEBIAN_RELEASE} AS boko
ARG BOKO_REPO=https://github.com/chikiny/boko.git
ARG BOKO_REF=4f646eea50659d20149ecbc82fe125c857422048
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /build
RUN git init -q boko \
 && cd boko \
 && git remote add origin "${BOKO_REPO}" \
 && git fetch -q --depth 1 origin "${BOKO_REF}" \
 && git checkout -q FETCH_HEAD \
 && cargo build --release --locked --bin boko \
 && install -m 0755 target/release/boko /usr/local/bin/boko

# ------------------------------------------------------------
# 本体
# ------------------------------------------------------------
FROM ruby:${RUBY_VERSION}-slim-${DEBIAN_RELEASE}

# 個人用の改変版なので必ず Fork の release ブランチから specific_install で入れる
ARG NAROU_REPO=https://github.com/chikiny/narou_rb
ARG NAROU_BRANCH=release
# Mac で使っているものと同じ版
ARG AOZORAEPUB3_VERSION=1.1.1b26Q
ARG PUID=1000
ARG PGID=1000

ENV TZ=Asia/Tokyo \
    LANG=C.UTF-8

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openjdk-21-jre-headless \
      inotify-tools \
      zsh \
      tini \
      curl \
      unzip \
      tzdata \
 && rm -rf /var/lib/apt/lists/*

COPY --from=openssl /opt/openssl /opt/openssl
COPY --from=boko /usr/local/bin/boko /usr/local/bin/boko

RUN set -eux; \
    buildDeps='build-essential git'; \
    apt-get update; \
    apt-get install -y --no-install-recommends $buildDeps; \
    gem install openssl -- --with-openssl-dir=/opt/openssl --with-ldflags='-Wl,-rpath,/opt/openssl/lib'; \
    ruby -ropenssl -e 'v = OpenSSL::OPENSSL_LIBRARY_VERSION; puts v; abort "openssl gem is not linked to /opt/openssl" unless v.start_with?("OpenSSL 3.6")'; \
    gem install specific_install; \
    gem specific_install -l "${NAROU_REPO}" -b "${NAROU_BRANCH}"; \
    apt-get purge -y --auto-remove $buildDeps; \
    rm -rf /var/lib/apt/lists/* /root/.gem /usr/local/bundle/cache/*

# AozoraEpub3（narou init で chuki_tag.txt と template にカスタム注記・CSS を埋め込む）
RUN set -eux; \
    cd /tmp; \
    curl -fsSL -o aozora.zip "https://github.com/kyukyunyorituryo/AozoraEpub3/releases/download/v${AOZORAEPUB3_VERSION}/AozoraEpub3-${AOZORAEPUB3_VERSION}.zip"; \
    unzip -q aozora.zip -d aozora; \
    mv "$(dirname "$(find aozora -name AozoraEpub3.jar | head -n 1)")" /aozoraepub3; \
    rm -rf aozora aozora.zip; \
    mkdir -p /tmp/narou-init/.narousetting; \
    cd /tmp/narou-init; \
    narou init -p /aozoraepub3 -l 1.8; \
    cd /; rm -rf /tmp/narou-init

RUN groupadd -g "${PGID}" narou \
 && useradd -u "${PUID}" -g narou -m -d /home/narou -s /bin/bash narou \
 && mkdir -p /novel /convert_output \
 && chown narou:narou /novel /convert_output

ENV HOME=/home/narou

COPY bin/ /usr/local/bin/
RUN chmod +x /usr/local/bin/*

USER narou
WORKDIR /novel

EXPOSE 33000 33001

ENTRYPOINT ["tini", "--", "docker-entrypoint.sh"]
CMD ["narou", "web", "-np", "33000"]
