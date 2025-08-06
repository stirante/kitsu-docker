# Stage 1: Build Kitsu (Vue/Node front-end) from source
FROM node:current-alpine AS build-kitsu

ARG KITSU_REPO=https://github.com/stirante/kitsu.git
ARG KITSU_REF=main

# Add git
RUN apk add --no-cache git

# Build Vue app
RUN git clone --depth 1 --branch "$KITSU_REF" "$KITSU_REPO" /kitsu-src \
    && cd /kitsu-src \
    && npm ci \
    && npm run build

# Stage 2: runtime image (Ubuntu Jammy + Zou + Nginx + DB etc.)
FROM ubuntu:jammy

ENV DEBIAN_FRONTEND=noninteractive
ENV PG_VERSION=14
ENV DB_USERNAME=root DB_HOST=""

ARG ZOU_REPO=https://github.com/stirante/zou.git
ARG ZOU_REF=main

USER root

# hadolint ignore=DL3008
RUN mkdir -p /opt/zou /var/log/zou /opt/zou/previews && \
    apt-get update && \
    apt-get install --no-install-recommends -q -y \
        bzip2 \
        build-essential \
        ffmpeg \
        git \
        gcc \
        nginx \
        postgresql \
        postgresql-client \
        python3 \
        python3-dev \
        python3-pip \
        python3-venv \
        libjpeg-dev \
        libpq-dev \
        redis-server \
        software-properties-common \
        supervisor \
        xmlsec1 \
        wget && \
        apt-get clean && \
        rm -rf /var/lib/apt/lists/*

# Create database
USER postgres

# hadolint ignore=DL3001
RUN service postgresql start && \
    createuser root && createdb -T template0 -E UTF8 --owner root root && \
    createdb -T template0 -E UTF8 --owner root zoudb && \
    service postgresql stop

# hadolint ignore=DL3002
USER root

# Wait for the startup or shutdown to complete
COPY --chown=postgres:postgres --chmod=0644 ./docker/pg_ctl.conf /etc/postgresql/${PG_VERSION}/main/pg_ctl.conf
COPY --chown=postgres:postgres --chmod=0644 ./docker/postgresql-log.conf /etc/postgresql/${PG_VERSION}/main/conf.d/postgresql-log.conf
# hadolint ignore=DL3013
RUN set -eux; \
    sed -i "s/bind .*/bind 127.0.0.1/g" /etc/redis/redis.conf; \
    git config --global --add advice.detachedHead false; \
    python3 -m venv /opt/zou/env; \
    /opt/zou/env/bin/pip install --no-cache-dir --upgrade pip setuptools wheel; \
    git clone --depth 1 --branch "${ZOU_REF}" "${ZOU_REPO}" /opt/zou/zou-src; \
    /opt/zou/env/bin/pip install --no-cache-dir -e /opt/zou/zou-src; \
    /opt/zou/env/bin/pip install --no-cache-dir sendria psycopg2-binary; \
    rm /etc/nginx/sites-enabled/default

# Symlink sendria so Supervisor finds it
RUN ln -s /opt/zou/env/bin/sendria /usr/local/bin/sendria

# Copy built Vue app
COPY --from=build-kitsu /kitsu-src/dist/ /opt/zou/kitsu/

WORKDIR /opt/zou

COPY ./docker/gunicorn.py /etc/zou/gunicorn.py
COPY ./docker/gunicorn-events.py /etc/zou/gunicorn-events.py
COPY ./docker/nginx.conf /etc/nginx/sites-enabled/zou
COPY docker/supervisord.conf /etc/supervisord.conf
COPY --chmod=0755 ./docker/init_zou.sh /opt/zou/
COPY --chmod=0755 ./docker/start_zou.sh /opt/zou/

# Fix for development on Windows: CRLF -> LF
RUN apt-get update && apt-get install -y --no-install-recommends dos2unix \
    && dos2unix /opt/zou/init_zou.sh /opt/zou/start_zou.sh \
    && chmod +x /opt/zou/init_zou.sh /opt/zou/start_zou.sh \
    && rm -rf /var/lib/apt/lists/*

RUN ls -al /opt/zou
RUN echo Initialising Zou... && \
    /opt/zou/init_zou.sh

EXPOSE 80
EXPOSE 1080
VOLUME ["/var/lib/postgresql", "/opt/zou/previews"]
CMD ["/opt/zou/start_zou.sh"]
