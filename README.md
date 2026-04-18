# aegis-debian

Pragmatic Debian server bootstrap.

## What it does

- installs `fastfetch` and `ncdu`
- changes the SSH port
- validates `sshd` config before restart
- limits journald disk usage and vacuums old logs

## Usage

Run as root:

```bash
sudo ./setup-debian.sh
```

Override defaults with environment variables when needed:

```bash
sudo SSH_PORT=54322 JOURNAL_SYSTEM_MAX_USE=300M ./setup-debian.sh
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
