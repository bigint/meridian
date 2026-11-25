A static site served by nginx. Build your site into `dist/` (adjust the path), then:

`Dockerfile`:

```dockerfile
FROM nginx:1.27-alpine
LABEL service="<service>"
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY dist/ /usr/share/nginx/html/
```

`nginx.conf`:

```nginx
server {
  listen 80;
  root /usr/share/nginx/html;
  location = /up { access_log off; return 200 "OK"; }
  location / { try_files $uri $uri/ $uri.html =404; }
}
```

Kamal only boots images labelled with their service. `kamal build` adds the label for you; if your CI builds the image another way, keep the `LABEL service=` line (Meridian fills in the name).
