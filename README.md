# aegis-debian

Pragmatic Debian server bootstrap.

## What it does

- runs `apt update` and `apt upgrade`
- installs `fastfetch` and `ncdu`
- changes the SSH port
- validates `sshd` config before restart
- limits journald disk usage and vacuums old logs
- supports `--dry-run` for previewing changes

## Usage

Run as root:

```bash
sudo ./setup-debian.sh
```

Override defaults with environment variables when needed:

```bash
sudo SSH_PORT=54322 JOURNAL_SYSTEM_MAX_USE=300M ./setup-debian.sh
```

Preview changes without touching the system:

```bash
sudo ./setup-debian.sh --dry-run
```

## Defaults

- `SSH_PORT=4386`
- `JOURNAL_SYSTEM_MAX_USE=200M`
- `JOURNAL_RUNTIME_MAX_USE=50M`
- `JOURNAL_VACUUM_SIZE=200M`

## Notes

- Keep your current SSH session open until you confirm the new port works.
- If `ufw` is active, the script allows the new SSH port automatically.
- SSH port changes reduce background noise, but key-only auth and tight firewall rules matter more.
- The script runs named setup steps in order, which keeps future additions straightforward.
