# Installer test suite

Full end-to-end tests of `install.sh` on real VMs via Vagrant (VirtualBox).

## Covered

| VM | Coverage |
|---|---|
| `ubuntu2204` | Full install from the **previous** stable release (pinned via `STRUXA_IMAGE_TAG`), then the old→new update path |
| `ubuntu2404` | Full install of latest release: admin bootstrap, wings auto-link, update idempotency, `--wings-only` |
| `debian13` | Full install of latest release (same assertions as ubuntu2404) |

All VMs additionally run the install-script unit tests (below).

Each unpinned VM asserts:

1. All containers running (mysql, minio, web, watchkeeper; migrate exited 0; wings up)
2. Panel reachable directly (`:3001`) and through nginx (`panel.test:443`)
3. The admin account created by the installer can sign in via better-auth; the `/setup` wizard redirects away
4. `/etc/pterodactyl/config.yml` contains a live `uuid`/`token_id`/`token`, `remote: https://panel.test`, `port: 8080`, `ssl: enabled: false` (nginx terminates TLS)
5. The wings token authenticates against the panel's `/api/remote/*` routes (the panel↔wings handshake)
6. `install.sh update` on an up-to-date install reports "already up to date" and exits 0
7. `install.sh update --wings-only` exits 0 and leaves `IMAGE_TAG` untouched

The pinned VM (ubuntu2204) installs the previous stable release — whose panel image predates the bootstrap endpoint, so the installer degrades to the manual-setup path — then asserts `install.sh update` bumps `IMAGE_TAG` to latest and the stack stays healthy.

## Installer unit tests (`tests/unit.sh`)

Runs inside each VM as part of `tests/run.sh`, or standalone: `sudo bash tests/unit.sh` (needs the repo mounted at `/vagrant`). It loads the script's function definitions (everything before `MAIN`), disables telemetry, and asserts:

- `distro_id` matches `/etc/os-release`
- `ver_compare` ordering (smaller, `v`-prefix stripping, equal, multi-digit components)
- `json_escape` output has no literal newlines and escapes quotes
- `scrub_secrets` redacts known secret values and leaves other text intact
- `ask_yn` unattended defaults (yes/no)
- `validate_unattended` rejects missing vars, short passwords, bad emails, bad SSL modes; accepts a complete env
- `resolve_release_tag` honors the `STRUXA_IMAGE_TAG` pin without network access
- the persistent install id survives across calls

Black-box invocations: mutually exclusive `--panel-only` + `--wings-only` exit 1; an unattended install without required vars exits 1 and lists them; non-root execution is rejected (root check).

## Running

```bash
# everything (3 VMs, sequential; first run downloads ~2 GB per VM and takes 30-60+ min)
./scripts/run-tests.sh

# one distro
./scripts/run-tests.sh --box debian13

# keep VMs after the run for debugging
./scripts/run-tests.sh --box ubuntu2204 --keep

# skip the old->new update test
./scripts/run-tests.sh --no-pin
```

The previous stable release for the pin is resolved from the GitHub releases API; if none exists the pinned test degrades to an unpinned run automatically.

## Notes

- Provider: **VirtualBox** (default). `vagrant` and VirtualBox must be installed on the host.
- The Let's Encrypt path is **not** covered (requires public DNS); tests use self-signed certs (`STRUXA_SSL=selfsigned`).
- All runs pass `--no-telemetry`.
- In-VM assertions run as root: `vagrant ssh <box> -c 'sudo bash /vagrant/tests/run.sh'`.
- The panel→wings direction (panel calling the node) requires the wings domain to resolve from inside the panel container, which needs real DNS in production. Tests assert the wings→panel direction instead.

## CI

`.github/workflows/ci.yml` runs `bash -n` + shellcheck on push/PR. The Vagrant suite is intentionally on-demand only (too heavy for CI runners).
