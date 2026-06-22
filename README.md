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

Once the installer completes, Wings will be running but **not yet connected** to the panel — it needs a token from the panel to authenticate.

1. Log in to your panel and go to **Admin → Nodes → Create New Node**
2. Fill in the node details, then open the **Configuration** tab
3. Copy `token_id` and `token` into `/etc/pterodactyl/config.yml`
4. Restart Wings:

   ```bash
   cd /opt/wings && docker compose restart
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
