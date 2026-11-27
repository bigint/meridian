# syntax=docker/dockerfile:1
# check=error=true

# The documentation site, https://meridian.yoginth.com: `mint export` builds it
# into static files, and nginx serves them on port 8080 with /up for kamal-proxy.
# Build it from the repository root, since the changelog page comes from
# CHANGELOG.md:
#
#   docker build -f docs/Dockerfile -t meridian-docs .
#   docker run --rm -p 8080:8080 meridian-docs

# Keep in step with .ruby-version and MINT_VERSION in bin/docs.
ARG RUBY_VERSION=4.0.10
ARG MINT_VERSION=4.3.96

# The Changelog page, written from CHANGELOG.md as bin/docs does.
# Both build stages only write static files, so they run on the builder's own
# platform, even for an arm64 image.
FROM --platform=$BUILDPLATFORM docker.io/library/ruby:${RUBY_VERSION}-slim AS changelog
WORKDIR /src
COPY CHANGELOG.md ./
COPY script/docs_changelog.rb script/
COPY docs/ docs/
RUN ruby script/docs_changelog.rb > /dev/null

FROM --platform=$BUILDPLATFORM docker.io/library/node:22-slim AS build
ARG MINT_VERSION
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y unzip && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives
WORKDIR /docs
COPY --from=changelog /src/docs/ ./
# The export copies every file in docs/, so drop what isn't the site: its
# local viewer and README, and this image's own nginx.conf.
RUN npx --yes "mint@${MINT_VERSION}" export --output /tmp/site.zip && \
    mkdir /site && unzip -q /tmp/site.zip -d /site && \
    rm -rf /site/serve.js "/site/Start Docs.command" "/site/Start Docs.bat" /site/README.md /site/nginx.conf

FROM docker.io/nginxinc/nginx-unprivileged:1.31-alpine
# Kamal only boots images labelled with their service, and Meridian's deploys
# use images built here, not by Kamal's own builder.
LABEL service="meridian-docs"
COPY docs/nginx.conf /etc/nginx/nginx.conf
COPY --from=build /site/ /usr/share/nginx/html/
EXPOSE 8080
