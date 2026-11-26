# Install

Meridian is one container with SQLite inside it. You need:

- a server that can reach `api.github.com` (outbound only),
- a GitHub account or organisation where you can create a GitHub App,
- an infra repository with Kamal configs.

Meridian never connects to your servers, so it does not need SSH access to them.

## 1. Try it locally (2 minutes)

```bash
docker run -d --name meridian -p 3000:80 -v meridian:/rails/storage \
  -e SECRET_KEY_BASE=$(openssl rand -hex 64) -e MERIDIAN_URL=http://localhost:3000 \
  ghcr.io/bigint/meridian:v0.1.0
```

Open <http://localhost:3000> and create the first admin. The setup code it asks for is in the container's log: `docker logs <container> | grep "setup code"`. To look around without connecting GitHub, seed a demo fleet:

```bash
docker exec meridian bin/rails meridian:demo
```

## 2. Create the GitHub App (5 minutes)

In GitHub, open **Settings → Developer settings → GitHub Apps → New GitHub App** (for an organisation: **Organisation settings → GitHub Apps**).

- **Homepage URL:** your Meridian URL.
- **Webhook URL:** `https://<your Meridian>/webhooks/github`.
- **Webhook secret:** a long random string. Keep it; it becomes `GITHUB_APP_WEBHOOK_SECRET`.
- **Repository permissions:**

  | Permission | Access | Why |
  | --- | --- | --- |
  | Contents | Read and write | Read configs, commit deploys, rollbacks and preview overlays |
  | Pull requests | Read and write | Open pull requests for new apps and the CI workflow |
  | Actions | Read and write | Dispatch redeploys and preview runs |
  | Secrets | Read and write | Set secret values (write-only from Meridian's side) |
  | Workflows | Read and write | Add `.github/workflows/meridian-deploy.yml` |
  | Metadata | Read | Required by GitHub |

- **Subscribe to events:** Push, Pull request, Workflow run.

Create the App, then:

1. Note the **App ID**.
2. Generate a **private key** and download the `.pem` file.
3. Click **Install App** and pick the infra repository, plus the source repositories of any apps you want previews for.
4. The installation ID is the number at the end of the URL you land on.

## 3. Deploy Meridian with Kamal (5 minutes)

```bash
git clone https://github.com/bigint/meridian && cd meridian
```

1. Fill in the five numbered placeholders in `config/deploy.yml`.
2. Export the secrets that `.kamal/secrets` reads:

   ```bash
   export KAMAL_REGISTRY_PASSWORD=...           # a token that can pull ghcr.io images
   export MERIDIAN_SECRET_KEY_BASE=$(openssl rand -hex 64)
   export MERIDIAN_GITHUB_APP_ID=123456
   export MERIDIAN_GITHUB_APP_PRIVATE_KEY="$(cat meridian.private-key.pem)"
   export MERIDIAN_GITHUB_APP_WEBHOOK_SECRET=...
   ```

3. Deploy:

   ```bash
   kamal setup
   ```

If you build the image yourself rather than pulling the published one, set `image:` to your own registry, and `kamal setup` builds it.

## 4. Connect your infra repository (3 minutes)

1. Open Meridian and create the first admin. It asks for a setup code, so only someone who runs the server can do this: find it with `kamal app logs | grep "setup code"`, or run `kamal app exec 'bin/rails meridian:setup_code'`.
2. Go to **Projects → Add project**. Enter `owner/name`, the branch, the installation ID and where your configs live: `config/deploy*.yml` by default, or for example `kamal/*.yml`.
3. Meridian syncs. Every config appears on the board, and parse errors show their file and line.
4. Press **Add CI workflow** and merge the pull request it opens. Add the `KAMAL_SSH_PRIVATE_KEY` and `KAMAL_REGISTRY_PASSWORD` repository secrets, either on the Secrets page or in GitHub.
5. Install the agent on your servers: see [agent.md](agent.md). The board then shows what really runs.

Next, read [configuration.md](configuration.md) and [security.md](security.md).
