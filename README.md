# aegis-debian

Pragmatic Debian server bootstrap.

Small repo for bringing up a fresh Debian machine with a single script.

The script is meant to stay simple, readable, and easy to extend as new server setup steps are added.

## Usage

Run as root:

```bash
sudo ./setup-debian.sh
```

Preview changes without touching the system:

```bash
sudo ./setup-debian.sh --dry-run
```

Override behavior with environment variables when needed:

```bash
sudo SSH_PORT=54322 SWAP_SIZE_MIB=4096 ./setup-debian.sh
```

## Notes

- Keep your current SSH session open while testing SSH-related changes.
- Review the variables near the top of [setup-debian.sh](/home/john/programming/cloud-init/setup-debian.sh:1) if you want to change defaults.
