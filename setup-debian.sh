#!/usr/bin/env bash

set -Eeuo pipefail

# Override these with environment variables when needed, for example:
# SSH_PORT=54322 JOURNAL_SYSTEM_MAX_USE=300M ./setup-debian.sh
SSH_PORT="${SSH_PORT:-4386}"
JOURNAL_SYSTEM_MAX_USE="${JOURNAL_SYSTEM_MAX_USE:-200M}"
JOURNAL_RUNTIME_MAX_USE="${JOURNAL_RUNTIME_MAX_USE:-50M}"
JOURNAL_VACUUM_SIZE="${JOURNAL_VACUUM_SIZE:-200M}"
PACKAGES=(
  fastfetch
  ncdu
)

log() {
  printf '[setup] %s\n' "$*"
}

die() {
  printf '[setup] error: %s\n' "$*" >&2
  exit 1
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "run this script as root"
}

require_debian() {
  [[ -r /etc/os-release ]] || die "cannot detect operating system"
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "debian" || "${ID_LIKE:-}" == *debian* ]] || die "this script is intended for Debian-based systems"
}

validate_port() {
  [[ "${SSH_PORT}" =~ ^[0-9]+$ ]] || die "SSH_PORT must be numeric"
  (( SSH_PORT >= 1024 && SSH_PORT <= 65535 )) || die "SSH_PORT must be between 1024 and 65535"
}

port_is_listening() {
  ss -ltnH "sport = :${SSH_PORT}" 2>/dev/null | grep -q .
}

install_packages() {
  log "updating apt metadata"
  apt-get update

  log "installing packages: ${PACKAGES[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${PACKAGES[@]}"
}

allow_ufw_port_if_needed() {
  if ! command -v ufw >/dev/null 2>&1; then
    return 0
  fi

  if ! ufw status 2>/dev/null | grep -q '^Status: active$'; then
    return 0
  fi

  log "allowing TCP ${SSH_PORT} in ufw"
  ufw allow "${SSH_PORT}/tcp"
}

configure_ssh_port() {
  local sshd_config="/etc/ssh/sshd_config"
  local backup="${sshd_config}.bak.$(date +%Y%m%d%H%M%S)"
  local temp_file

  [[ -f "${sshd_config}" ]] || die "missing ${sshd_config}"
  command -v sshd >/dev/null 2>&1 || die "openssh-server is not installed"

  if port_is_listening && ! grep -Eq "^[[:space:]]*Port[[:space:]]+${SSH_PORT}[[:space:]]*$" "${sshd_config}"; then
    die "TCP port ${SSH_PORT} is already in use"
  fi

  cp "${sshd_config}" "${backup}"
  log "backup created at ${backup}"

  temp_file="$(mktemp)"
  awk -v port="${SSH_PORT}" '
    BEGIN {
      replaced = 0
    }
    /^[[:space:]]*#?[[:space:]]*Port[[:space:]]+/ {
      if (!replaced) {
        print "Port " port
        replaced = 1
      }
      next
    }
    {
      print
    }
    END {
      if (!replaced) {
        print ""
        print "Port " port
      }
    }
  ' "${sshd_config}" > "${temp_file}"
  mv "${temp_file}" "${sshd_config}"

  log "validating sshd configuration"
  sshd -t

  allow_ufw_port_if_needed

  log "restarting ssh service"
  systemctl restart ssh.service 2>/dev/null || systemctl restart sshd.service
}

configure_journald() {
  local dropin_dir="/etc/systemd/journald.conf.d"
  local dropin_file="${dropin_dir}/99-storage-limits.conf"

  mkdir -p "${dropin_dir}"

  cat > "${dropin_file}" <<EOF
[Journal]
SystemMaxUse=${JOURNAL_SYSTEM_MAX_USE}
RuntimeMaxUse=${JOURNAL_RUNTIME_MAX_USE}
EOF

  log "restarting systemd-journald"
  systemctl restart systemd-journald

  log "rotating and vacuuming journal logs"
  journalctl --rotate
  journalctl --vacuum-size="${JOURNAL_VACUUM_SIZE}"
}

main() {
  require_root
  require_debian
  validate_port

  install_packages
  configure_ssh_port
  configure_journald

  log "done"
  log "ssh now listens on TCP ${SSH_PORT}"
}

main "$@"
