# check=skip=InvalidDefaultArgInFrom,FromPlatformFlagConstDisallowed
# One real bigint website, served by nginx the way bigint/infra serves it in production:
# the site's files-only image (/public/, /server.conf, /http.conf from ghcr.io/bigint/<site>)
# copied unchanged under /sites/<site>/, listening on port 3000 with /up for kamal-proxy.
ARG SITE_IMAGE
# The site image holds only files, so its architecture does not matter.
FROM --platform=linux/amd64 ${SITE_IMAGE} AS site

FROM nginxinc/nginx-unprivileged:1.30-alpine
ARG SITE
# Kamal only boots images labelled with their service (its own builder adds this).
LABEL service=$SITE
COPY nginx.conf /etc/nginx/nginx.conf
COPY --from=site / /sites/${SITE}/
