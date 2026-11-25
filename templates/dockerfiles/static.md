A static site served by nginx. Build your site into `dist/` (adjust the path), then:

`Dockerfile`:

```dockerfile
FROM nginx:1.27-alpine
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
