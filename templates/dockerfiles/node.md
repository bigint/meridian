Next.js, server-rendered, in `standalone` output mode. In `next.config.js`:

```js
module.exports = { output: "standalone" }
```

Add a health check Kamal can reach at `/up`, e.g. `app/up/route.js`:

```js
export function GET() { return new Response("OK") }
```

`Dockerfile`:

```dockerfile
FROM node:22-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM node:22-alpine
LABEL service="<service>"
WORKDIR /app
ENV NODE_ENV=production PORT=3000 HOSTNAME=0.0.0.0
COPY --from=build /app/.next/standalone ./
COPY --from=build /app/.next/static ./.next/static
COPY --from=build /app/public ./public
EXPOSE 3000
CMD ["node", "server.js"]
```

Kamal only boots images labelled with their service. `kamal build` adds the label for you; if your CI builds the image another way, keep the `LABEL service=` line (Meridian fills in the name).
