# Shadows Over Westgate Wiki.js Production Deployment

This repository contains the custom `westgate` Wiki.js theme in
`client/themes/westgate`.

The key production constraint is:

- The stock stable Wiki.js image does not contain this theme.
- Building this repository checkout directly produces a development build.
- Wiki.js reads `package.json` during setup; if `"dev": true`, the live setup
  page shows the unreleased-development warning.

For production, build a custom image from an official stable Wiki.js release
source snapshot, copy in the Westgate customizations, and patch the release
metadata before building the image.

Official references:

- Install overview: https://docs.requarks.io/install
- Docker guide: https://docs.requarks.io/s/en/install/docker
- Requirements: https://docs.requarks.io/s/en/install/requirements
- Stable release landing page: https://js.wiki/
- Releases: https://github.com/Requarks/wiki/releases

## Production Version Policy

Do not deploy from a live clone of `master`, `main`, or any development branch.

As of April 24, 2026:

- `js.wiki` lists `2.5.312` as the current stable release.
- GitHub also shows `v2.5.313`, but it is marked pre-release / pending.

For live deployment, pin to a known stable version. The examples below use
`2.5.312`. Replace it only after verifying that the newer version is marked
stable in the official docs / site.

## Recommended VPS Shape

- Ubuntu 22.04 or 24.04 LTS
- 2 vCPU
- 2 GB RAM
- SSD storage sized for uploads and PostgreSQL backups
- A real hostname such as `wiki.example.com`

Wiki.js should be served from its own host or subdomain, not from a subpath
like `example.com/wiki`.

## Install Docker On The VPS

```bash
sudo apt update
sudo apt install -y ca-certificates curl git
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

Optional:

```bash
sudo usermod -aG docker "$USER"
newgrp docker
```

## Clone This Repository

This repository is the customization source, not the production base image.

```bash
mkdir -p "$HOME/westgate"
cd "$HOME/westgate"
git clone <YOUR_REPO_URL> customizations
cd customizations
```

## Create The Deployment Directory

```bash
mkdir -p "$HOME/westgate/deploy"
cd "$HOME/westgate/deploy"
```

Create `.env`:

```bash
cat > .env <<'EOF'
POSTGRES_DB=wiki
POSTGRES_USER=wikijs
POSTGRES_PASSWORD=change-this-long-random-password
WIKI_VERSION=2.5.312
WIKI_RELEASE_DATE=2026-02-12T02:45:00.000Z
WIKI_IMAGE=westgate-wikijs:2.5.312
WIKI_HTTP_PORT=3000
EOF
```

Create `docker-compose.yml`:

```yaml
services:
  db:
    image: postgres:15-alpine
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - db-data:/var/lib/postgresql/data

  wiki:
    image: ${WIKI_IMAGE}
    restart: unless-stopped
    depends_on:
      - db
    environment:
      DB_TYPE: postgres
      DB_HOST: db
      DB_PORT: 5432
      DB_USER: ${POSTGRES_USER}
      DB_PASS: ${POSTGRES_PASSWORD}
      DB_NAME: ${POSTGRES_DB}
    ports:
      - "127.0.0.1:${WIKI_HTTP_PORT}:3000"
    volumes:
      - wiki-content:/wiki/data/content

volumes:
  db-data:
  wiki-content:
```

## Build A Stable Custom Image

Create a clean build workspace:

```bash
cd "$HOME/westgate/deploy"
set -a
. ./.env
set +a

mkdir -p "$HOME/westgate/build"
cd "$HOME/westgate/build"
rm -rf wiki-src
curl -fsSL "https://github.com/Requarks/wiki/archive/refs/tags/v${WIKI_VERSION}.tar.gz" | tar -xz
mv "wiki-${WIKI_VERSION}" wiki-src
```

Copy the Westgate theme into the stable source tree:

```bash
rsync -a "$HOME/westgate/customizations/client/themes/westgate/" "$HOME/westgate/build/wiki-src/client/themes/westgate/"
```

If this repository later carries additional production overrides outside the
theme folder, copy those into `wiki-src` as well before building. Typical paths
to review are:

- `client/components/`
- `client/scss/`
- `server/views/`
- `patches/`

Patch the release metadata that Wiki.js reads at runtime:

```bash
cd "$HOME/westgate/build/wiki-src"
sed -i 's/"dev": true/"dev": false/' package.json
sed -i "s/\"version\": \"2.0.0\"/\"version\": \"${WIKI_VERSION}\"/" package.json
sed -i "s/\"releaseDate\": \".*\"/\"releaseDate\": \"${WIKI_RELEASE_DATE}\"/" package.json
```

Build the custom image from the official Wiki.js Dockerfile in the stable source
snapshot:

```bash
docker build -f dev/build/Dockerfile -t "${WIKI_IMAGE}" .
```

This gives you:

- a stable, pinned Wiki.js source base
- the custom `westgate` theme compiled into the bundle
- no development warning on the setup screen

## Start Wiki.js

```bash
cd "$HOME/westgate/deploy"
docker compose up -d
docker compose logs -f wiki
```

Open:

```text
http://YOUR_SERVER_IP:3000
```

If you are using the localhost-only port binding shown above, access it through
the reverse proxy instead of directly.

## Put It Behind HTTPS

Caddy is the simplest reverse proxy for this setup.

```bash
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update
sudo apt install -y caddy
```

Create `/etc/caddy/Caddyfile`:

```caddyfile
wiki.example.com {
  reverse_proxy 127.0.0.1:3000
}
```

Reload Caddy:

```bash
sudo systemctl reload caddy
```

## First-Run Setup

During the setup wizard:

- set the public URL to `https://wiki.example.com`
- create the administrator account
- finish installation normally

If the setup screen still shows the development warning, the image was built
from a source tree where `package.json` still had `"dev": true`.

## Select The Westgate Theme

After first login, choose the `Westgate` theme in the admin UI if it appears.

If needed, confirm the active theme directly in PostgreSQL:

```bash
cd "$HOME/westgate/deploy"
set -a
. ./.env
set +a
docker compose exec db psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}"
```

Inspect the theming row:

```sql
SELECT key, value FROM settings WHERE key = 'theming';
```

Make sure the JSON `theme` property is `westgate`, then restart Wiki.js:

```bash
docker compose restart wiki
```

## Updating Wiki.js

When you want to upgrade:

1. Pick a newer release only after confirming it is stable in the official docs
   or on `js.wiki`.
2. Update `WIKI_VERSION`, `WIKI_RELEASE_DATE`, and `WIKI_IMAGE` in
   `$HOME/westgate/deploy/.env`.
3. Rebuild the stable build context from that release.
4. Re-copy the Westgate theme and any shared overrides.
5. Re-apply the `package.json` metadata patch.
6. Rebuild the image and restart compose.

Commands:

```bash
cd "$HOME/westgate/deploy"
set -a
. ./.env
set +a

cd "$HOME/westgate/build"
rm -rf wiki-src
curl -fsSL "https://github.com/Requarks/wiki/archive/refs/tags/v${WIKI_VERSION}.tar.gz" | tar -xz
mv "wiki-${WIKI_VERSION}" wiki-src
rsync -a "$HOME/westgate/customizations/client/themes/westgate/" "$HOME/westgate/build/wiki-src/client/themes/westgate/"

cd "$HOME/westgate/build/wiki-src"
sed -i 's/"dev": true/"dev": false/' package.json
sed -i "s/\"version\": \"2.0.0\"/\"version\": \"${WIKI_VERSION}\"/" package.json
sed -i "s/\"releaseDate\": \".*\"/\"releaseDate\": \"${WIKI_RELEASE_DATE}\"/" package.json
docker build -f dev/build/Dockerfile -t "${WIKI_IMAGE}" .

cd "$HOME/westgate/deploy"
docker compose up -d
docker compose logs -f wiki
```

## Backups

Back up PostgreSQL:

```bash
cd "$HOME/westgate/deploy"
docker compose exec db pg_dump -U "${POSTGRES_USER}" "${POSTGRES_DB}" > "wiki-$(date +%F).sql"
```

If you use local file storage, also back up the Docker volume used for
`/wiki/data/content`.

## Troubleshooting

If the setup page says you are running an unstable development version:

- confirm you built from an official stable release tarball
- confirm `package.json` in `wiki-src` has `"dev": false`
- destroy and rebuild the custom image after fixing the metadata

If the site starts but the theme is missing:

- confirm `client/themes/westgate/theme.yml` exists in `wiki-src`
- rebuild the image after copying the theme
- confirm the active theme setting is `westgate`

If Wiki.js cannot connect to PostgreSQL:

- check `docker compose logs db`
- check `docker compose logs wiki`
- verify `POSTGRES_*` values in `.env`
- verify the `wiki` service still uses `DB_HOST=db`
