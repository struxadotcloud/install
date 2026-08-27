<div align="center">

# struxa installer

**One-command installer for Struxa and Wings.**
Interactive setup with reverse proxy, SSL, and full configuration — no manual config required.

<br />

![GitHub Stars](https://www.shieldcn.dev/github/stars/struxadotcloud/install.svg?variant=secondary&size=sm)
![Last commit](https://www.shieldcn.dev/github/last-commit/struxadotcloud/install.svg?variant=secondary&size=sm)
![License · MIT](https://www.shieldcn.dev/badge/License-MIT-000000.svg?variant=secondary&size=sm)

![Shell · Bash](https://www.shieldcn.dev/badge/Shell-Bash-4EAA25.svg?logo=gnubash&variant=branded&size=sm)

</div>

<br />

The installer sets up a full Struxa deployment on a fresh Linux server in a single command. It handles:

- Installing the **Struxa panel** (dashboard + database + watchkeeper via Docker Compose)
- Optionally installing **Wings** (node agent via Docker Compose)
- Auto-generating all secrets — database passwords, JWT key pair, encryption key
- Detecting your running webserver (nginx / Apache / Caddy) and configuring a reverse proxy
- Installing nginx from scratch if no webserver is present
- Obtaining **SSL certificates** via Let's Encrypt (certbot) or generating a self-signed cert
- Creating your **admin account** and **linking Wings to the panel automatically** — no onboarding wizard, no manual token copy

## Related repositories

| Repository | Description |
|---|---|
| [struxadotcloud/struxa](https://github.com/struxadotcloud/struxa) | Main panel — web UI, API, database |
| [struxadotcloud/wings](https://github.com/struxadotcloud/wings) | Node agent — server lifecycle, SFTP, backups |
| [struxadotcloud/install](https://github.com/struxadotcloud/install) | This repo — installer script |
| [struxadotcloud/docs](https://github.com/struxadotcloud/docs) | Documentation site |

## Usage

Run as root on a fresh Linux server (Ubuntu 22.04+ recommended):

```bash
bash <(curl -fsSL https://install.struxa.cloud)
```

The script is interactive — it will walk you through every step.

## What gets installed where

| Path | Contents |
|---|---|
| `/opt/struxa/` | Struxa compose file and generated `.env.prod` |
| `/opt/wings/` | Wings compose file and generated `config.yml` |
| `/etc/pterodactyl/config.yml` | Wings config (system path Wings reads from) |
| `/etc/nginx/sites-available/` | Reverse proxy vhosts (if nginx selected) |

## After installation

The installer prompts for an admin email and password and creates the account itself — just sign in at your panel URL. If you installed Wings, the node is created and linked automatically (Wings sits behind your reverse proxy on port 443); no manual token copy is needed. The panel's in-browser setup wizard remains available for manual installations.

## Updating

```bash
bash <(curl -fsSL https://install.struxa.cloud) update
```

The updater compares versions and skips components that are already up to date (no more "1.4.0 → 1.4.0" re-pulls). Panel and Wings updates are independent prompts — cancelling one does not cancel the other. Use `--panel-only` or `--wings-only` to update a single component.

## Unattended installs

Set `STRUXA_UNATTENDED=1` and provide the answers as environment variables (useful for CI, Ansible, or Vagrant):

| Variable | Default | Description |
|---|---|---|
| `STRUXA_MODE` | `wings` | `dashboard` or `wings` |
| `STRUXA_PANEL_DOMAIN` | — | Panel domain (required) |
| `STRUXA_WINGS_DOMAIN` | — | Wings domain (required with wings) |
| `STRUXA_EMAIL` | — | Admin email (required) |
| `STRUXA_PASSWORD` | — | Admin password, min 8 chars (required) |
| `STRUXA_ADMIN_NAME` | email prefix | Admin display name |
| `STRUXA_LOCATION_NAME` | `Default` | Location name |
| `STRUXA_NODE_NAME` | wings domain | Node name |
| `STRUXA_WEBSERVER` | `nginx` | `nginx`, `apache`, `caddy`, or `none` |
| `STRUXA_SSL` | `selfsigned` | `letsencrypt`, `selfsigned`, or `none` |
| `STRUXA_LETSENCRYPT_EMAIL` | — | Required with `letsencrypt` |
| `STRUXA_IMAGE_TAG` | latest release | Pin a specific panel release |
| `STRUXA_NODE_MEMORY` / `STRUXA_NODE_DISK` | `4096` / `50000` | Node resources in MB |

```bash
STRUXA_UNATTENDED=1 \
STRUXA_MODE=wings \
STRUXA_PANEL_DOMAIN=panel.example.com \
STRUXA_WINGS_DOMAIN=node.example.com \
STRUXA_EMAIL=admin@example.com \
STRUXA_PASSWORD='your-secure-password' \
bash <(curl -fsSL https://install.struxa.cloud)
```

## Requirements

- Linux x86_64 (Ubuntu 22.04+ / Debian 12+ recommended)
- Root access
- `curl` and `openssl` available
- Docker (installed automatically if missing)
- A domain pointed at your server (required for Let's Encrypt SSL)

## License

[MIT](./LICENSE)

<br />

<div align="center">
  <sub>Copyright (c) Disaster Limited</sub>
</div>
