#!/usr/bin/env bash

set -Eeuo pipefail

# Override these with environment variables when needed, for example:
# SSH_PORT=54322 JOURNAL_SYSTEM_MAX_USE=300M ./setup-debian.sh --dry-run
DRY_RUN=0
SSH_PORT="${SSH_PORT:-4386}"
SWAPFILE_PATH="${SWAPFILE_PATH:-/swapfile}"
SWAP_SIZE_MIB="${SWAP_SIZE_MIB:-auto}"
JOURNAL_SYSTEM_MAX_USE="${JOURNAL_SYSTEM_MAX_USE:-200M}"
JOURNAL_RUNTIME_MAX_USE="${JOURNAL_RUNTIME_MAX_USE:-50M}"
JOURNAL_VACUUM_SIZE="${JOURNAL_VACUUM_SIZE:-200M}"
EFFECTIVE_SWAP_SIZE_MIB=0
PACKAGES=(
  fastfetch
  ncdu
)
STEPS=(
  refresh_system
  install_packages
  configure_swap
  configure_ssh_port
  configure_journald
)

log() {
  printf '[setup] %s\n' "$*"
}

die() {
  printf '[setup] error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: ./setup-debian.sh [--dry-run]

Options:
  -n, --dry-run  Show what would run without changing the system
  -h, --help     Show this help
EOF
}

run() {
  if (( DRY_RUN )); then
    printf '[setup] dry-run:'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi

  "$@"
}

write_file() {
  local target="$1"

  if (( DRY_RUN )); then
    log "dry-run: write ${target}"
    cat >/dev/null
    return 0
  fi

  cat > "${target}"
}

append_line_if_missing() {
  local target="$1"
  local line="$2"

  if grep -Fqx "${line}" "${target}"; then
    return 0
  fi

  if (( DRY_RUN )); then
    log "dry-run: append to ${target}: ${line}"
    return 0
  fi

  printf '%s\n' "${line}" >> "${target}"
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      -n|--dry-run)
        DRY_RUN=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
    shift
  done
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

resolve_swap_size_mib() {
  local detected_ram_mib

  if [[ "${SWAP_SIZE_MIB}" == "auto" ]]; then
    detected_ram_mib="$(awk '/^MemTotal:/ { print int(($2 + 1023) / 1024) }' /proc/meminfo)"
    [[ -n "${detected_ram_mib}" ]] || die "failed to detect system RAM"
    EFFECTIVE_SWAP_SIZE_MIB="${detected_ram_mib}"
    return 0
  fi

  [[ "${SWAP_SIZE_MIB}" =~ ^[0-9]+$ ]] || die "SWAP_SIZE_MIB must be numeric or 'auto'"
  (( SWAP_SIZE_MIB > 0 )) || die "SWAP_SIZE_MIB must be greater than 0"
  EFFECTIVE_SWAP_SIZE_MIB="${SWAP_SIZE_MIB}"
}

port_is_listening() {
  ss -ltnH "sport = :${SSH_PORT}" 2>/dev/null | grep -q .
}

render_sshd_config() {
  local source_file="$1"

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
  ' "${source_file}"
}

refresh_system() {
  log "updating apt metadata"
  run apt-get update

  log "upgrading installed packages"
  run env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
}

install_packages() {
  log "installing packages: ${PACKAGES[*]}"
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${PACKAGES[@]}"
}

swap_is_active() {
  swapon --show=NAME --noheadings | grep -Fxq "${SWAPFILE_PATH}"
}

configure_swap() {
  local fstab_line="${SWAPFILE_PATH} none swap sw 0 0"

  log "ensuring swap file at ${SWAPFILE_PATH} (${EFFECTIVE_SWAP_SIZE_MIB} MiB)"

  if swap_is_active; then
    log "swap file already active at ${SWAPFILE_PATH}"
    append_line_if_missing /etc/fstab "${fstab_line}"
    return 0
  fi

  if [[ -e "${SWAPFILE_PATH}" ]]; then
    die "swap path ${SWAPFILE_PATH} already exists but is not active"
  fi

  if command -v fallocate >/dev/null 2>&1; then
    run fallocate -l "${EFFECTIVE_SWAP_SIZE_MIB}M" "${SWAPFILE_PATH}"
  else
    run dd if=/dev/zero of="${SWAPFILE_PATH}" bs=1M count="${EFFECTIVE_SWAP_SIZE_MIB}" status=progress
  fi

  run chmod 600 "${SWAPFILE_PATH}"
  run mkswap "${SWAPFILE_PATH}"
  run swapon "${SWAPFILE_PATH}"
  append_line_if_missing /etc/fstab "${fstab_line}"
}

allow_ufw_port_if_needed() {
  if ! command -v ufw >/dev/null 2>&1; then
    return 0
  fi

  if ! ufw status 2>/dev/null | grep -q '^Status: active$'; then
    return 0
  fi

  log "allowing TCP ${SSH_PORT} in ufw"
  run ufw allow "${SSH_PORT}/tcp"
}

configure_ssh_port() {
  local sshd_config="/etc/ssh/sshd_config"
  local backup
  local temp_file

  [[ -f "${sshd_config}" ]] || die "missing ${sshd_config}"
  command -v sshd >/dev/null 2>&1 || die "openssh-server is not installed"
  backup="${sshd_config}.bak.$(date +%Y%m%d%H%M%S)"

  if port_is_listening && ! grep -Eq "^[[:space:]]*Port[[:space:]]+${SSH_PORT}[[:space:]]*$" "${sshd_config}"; then
    die "TCP port ${SSH_PORT} is already in use"
  fi

  temp_file="$(mktemp)"
  trap 'rm -f "${temp_file}"' RETURN
  render_sshd_config "${sshd_config}" > "${temp_file}"

  log "validating sshd configuration"
  sshd -t -f "${temp_file}"

  if (( DRY_RUN )); then
    log "dry-run: backup ${sshd_config} -> ${backup}"
    log "dry-run: install new sshd config at ${sshd_config}"
  else
    cp "${sshd_config}" "${backup}"
    log "backup created at ${backup}"
    chmod --reference="${sshd_config}" "${temp_file}"
    chown --reference="${sshd_config}" "${temp_file}"
    mv "${temp_file}" "${sshd_config}"
  fi

  allow_ufw_port_if_needed

  log "restarting ssh service"
  if (( DRY_RUN )); then
    log "dry-run: systemctl restart ssh.service || systemctl restart sshd.service"
  else
    systemctl restart ssh.service 2>/dev/null || systemctl restart sshd.service
  fi
}

configure_journald() {
  local dropin_dir="/etc/systemd/journald.conf.d"
  local dropin_file="${dropin_dir}/99-storage-limits.conf"

  run mkdir -p "${dropin_dir}"
  write_file "${dropin_file}" <<EOF
[Journal]
SystemMaxUse=${JOURNAL_SYSTEM_MAX_USE}
RuntimeMaxUse=${JOURNAL_RUNTIME_MAX_USE}
EOF

  log "restarting systemd-journald"
  run systemctl restart systemd-journald

  log "rotating and vacuuming journal logs"
  run journalctl --rotate
  run journalctl --vacuum-size="${JOURNAL_VACUUM_SIZE}"
}

run_steps() {
  local step

  for step in "${STEPS[@]}"; do
    log "step: ${step}"
    "${step}"
  done
}

main() {
  parse_args "$@"
  require_root
  require_debian
  validate_port
  resolve_swap_size_mib
  run_steps

  log "done"
  log "ssh now listens on TCP ${SSH_PORT}"
}

main "$@"
