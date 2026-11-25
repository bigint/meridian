# The demo app: nginx serving its own version, with a /up health check.
FROM nginx:1.27-alpine
ARG VERSION=dev
ARG SERVICE=web
# Kamal only boots images labelled with their service (its own builder adds this).
LABEL service=$SERVICE
RUN printf 'server {\n  listen 80;\n  location = /up { return 200 "OK\\n"; }\n  location / { default_type text/plain; return 200 "demo %s on $hostname\\n"; }\n}\n' "$VERSION" > /etc/nginx/conf.d/default.conf
