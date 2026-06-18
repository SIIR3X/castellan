# shellcheck shell=bash
#
# Castellan - interactive configuration library (sourced by ./harden).
# Provides a clean, terminal-only host setup wizard (init), an editor that
# reuses it (configure), and a host listing (list). There are no profiles and
# no measure selector: Castellan applies every measure (see group_vars/all.yml);
# the wizard only collects per-host connection details and optional parameters.
# Relies on helpers defined in ./harden: info/ok/warn/die and HOST_VARS_DIR.

# --- terminal prompt primitives (no whiptail) --------------------------------
# All prompts print the default in [brackets]; an empty answer keeps it. Nothing
# is pre-filled on the input line, so there is never stale text to erase.

cc_ask() {  # prompt default -> echoes value (default when blank)
  local prompt="$1" def="${2:-}" v
  if [ -n "$def" ]; then
    read -r -p "  ${prompt} [${def}]: " v
  else
    read -r -p "  ${prompt}: " v
  fi
  printf '%s' "${v:-$def}"
}

cc_ask_req() {  # prompt default -> loops until non-empty
  local prompt="$1" def="${2:-}" v
  while :; do
    v="$(cc_ask "$prompt" "$def")"
    [ -n "$v" ] && { printf '%s' "$v"; return; }
    warn "A value is required."
  done
}

cc_ask_int() {  # prompt default -> loops until a number
  local prompt="$1" def="${2:-}" v
  while :; do
    v="$(cc_ask "$prompt" "$def")"
    [[ "$v" =~ ^[0-9]+$ ]] && { printf '%s' "$v"; return; }
    warn "Enter a number."
  done
}

cc_ask_yesno() {  # prompt default(y|n) -> returns 0 (yes) / 1 (no)
  local prompt="$1" def="${2:-n}" v
  while :; do
    v="$(cc_ask "${prompt} (y/n)" "$def")"
    case "$v" in
      y|Y|yes) return 0 ;;
      n|N|no)  return 1 ;;
      *) warn "Answer y or n." ;;
    esac
  done
}

# cc_choose prompt default tag1 label1 tag2 label2 ...  -> echoes chosen tag.
cc_choose() {
  local prompt="$1" def="$2"; shift 2
  local -a tags=() labels=(); local i=1 dnum=1
  while [ $# -gt 0 ]; do
    tags+=("$1"); labels+=("$2")
    [ "$1" = "$def" ] && dnum=$i
    shift 2; i=$((i+1))
  done
  echo "  ${prompt}:" >&2
  for ((i=0; i<${#tags[@]}; i++)); do
    printf '    %d) %s\n' "$((i+1))" "${labels[$i]}" >&2
  done
  local c
  while :; do
    read -r -p "  choice [${dnum}]: " c
    [ -z "$c" ] && c="$dnum"
    if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le "${#tags[@]}" ]; then
      printf '%s' "${tags[$((c-1))]}"; return
    fi
    warn "Pick a number between 1 and ${#tags[@]}." >&2
  done
}

cc_section() { printf '\n== %s ==\n' "$1" >&2; }

# --- host_vars helpers -------------------------------------------------------
cc_hv_path() { printf '%s/%s.yml' "$HOST_VARS_DIR" "$1"; }

# Read a scalar key from a host_vars file (first match, value trimmed/unquoted).
cc_hv_get() {
  local file="$1" key="$2" line
  line="$(grep -E "^[[:space:]]*${key}[[:space:]]*:" "$file" 2>/dev/null | head -n1)" || true
  [ -n "$line" ] || return 0
  printf '%s' "$line" | sed -E "s/^[[:space:]]*${key}[[:space:]]*:[[:space:]]*//; s/[[:space:]]*#.*$//; s/^\[//; s/\]$//; s/^\"//; s/\"$//; s/^'//; s/'$//"
}

# --- shared questionnaire ----------------------------------------------------
# Populates the CC_* variables below from prompts, using the passed values as
# defaults (so `configure` pre-loads the current config). Pure terminal I/O.
cc_questionnaire() {
  # $1 is the host name (used by cc_write_host, not needed here).
  # Defaults (current values when editing, sensible fallbacks otherwise).
  local d_ip="$2" d_cmode="$3" d_iuser="$4" d_iport="$5" d_ikey="$6" \
        d_admin="$7" d_pubkey="$8" d_sudo="$9" d_sport="${10}" d_af="${11}" \
        d_ports="${12}" d_ban="${13}" d_reboot="${14}" d_email="${15}" \
        d_syslog="${16}" d_grub="${17}" d_mfa="${18}"

  cc_section "Initial connection (first contact with the host)"
  CC_ip="$(cc_ask_req "Target IP or FQDN" "$d_ip")"
  CC_cmode="$(cc_choose "Connection method" "${d_cmode:-root_password}" \
      root_password "root + password" \
      root_key      "root + private key" \
      user_sudo     "existing user + sudo")"
  case "$CC_cmode" in
    user_sudo) CC_iuser="$(cc_ask_req "Existing sudo user" "${d_iuser:-ubuntu}")" ;;
    *)         CC_iuser="root" ;;
  esac
  CC_iport="$(cc_ask_int "Initial SSH port" "${d_iport:-22}")"
  CC_ikey=""
  [ "$CC_cmode" = root_key ] && \
    CC_ikey="$(cc_ask "Private key path for first contact" "${d_ikey:-$HOME/.ssh/id_ed25519}")"

  cc_section "Admin identity to create"
  CC_admin="$(cc_ask_req "Admin user to create" "${d_admin:-castellan}")"
  CC_pubkey="$(cc_ask_req "Public key to deploy (path)" "${d_pubkey:-$HOME/.ssh/id_ed25519.pub}")"
  CC_sudo="$(cc_choose "Sudo for the admin" "${d_sudo:-nopasswd}" \
      nopasswd "nopasswd (key only, automation)" \
      password "password (2nd factor)")"

  cc_section "SSH and firewall"
  CC_sport="$(cc_ask_int "Hardened SSH port (opened in ufw first)" "${d_sport:-22}")"
  CC_af="$(cc_choose "SSH address family" "${d_af:-inet}" \
      inet  "IPv4 only (recommended)" \
      any   "IPv4 + IPv6" \
      inet6 "IPv6 only")"
  CC_ports="$(cc_ask "Extra ports to open (comma list, e.g. 80,443)" "$d_ports")"
  CC_ban="$(cc_ask "Your IP to never ban (fail2ban)" "$d_ban")"
  if cc_ask_yesno "Allow automatic reboot after updates?" "${d_reboot:-n}"; then
    CC_reboot=true; else CC_reboot=false; fi

  cc_section "Optional measure parameters (Enter to skip)"
  CC_email="$(cc_ask "Notification email (update/login alerts)" "$d_email")"
  CC_syslog="$(cc_ask "Remote syslog target (host:port)" "$d_syslog")"
  CC_grub="$(cc_ask "GRUB password hash (grub-mkpasswd-pbkdf2)" "$d_grub")"
  if cc_ask_yesno "Enable TOTP 2FA over SSH (needs per-user enrollment)?" "${d_mfa:-n}"; then
    CC_mfa=true; else CC_mfa=false; fi
}

cc_write_host() {  # host file -> writes a flat host_vars YAML from CC_*
  local host="$1" file="$2"
  {
    printf -- '---\n# Castellan per-host configuration for %s (generated by ./harden init).\n' "$host"
    printf '# Castellan applies every measure; this file only sets connection details\n'
    printf '# and optional parameters. No secrets here (see docs/config.md).\n\n'
    printf 'target_ip:        %s\n' "$CC_ip"
    printf 'connection_mode:  %s\n' "$CC_cmode"
    printf 'initial_user:     %s\n' "$CC_iuser"
    printf 'initial_port:     %s\n' "$CC_iport"
    [ -n "$CC_ikey" ] && printf 'initial_key:      %s\n' "$CC_ikey"
    printf '\nadmin_user:        %s\n' "$CC_admin"
    printf 'admin_pubkey_file: %s\n' "$CC_pubkey"
    printf 'sudo_mode:         %s\n' "$CC_sudo"
    printf '\nssh_port:           %s\n' "$CC_sport"
    printf 'ssh_address_family: %s\n' "$CC_af"
    printf 'ssh_allow_groups:   [ssh-users]\n'
    printf 'ufw_allowed_ports:  [%s]\n' "$(printf '%s' "$CC_ports" | sed 's/[[:space:]]*,[[:space:]]*/, /g')"
    printf 'f2b_ignoreip:       [%s]\n' "$([ -n "$CC_ban" ] && printf '"%s"' "$CC_ban")"
    printf 'auto_reboot:        %s\n' "$CC_reboot"
    if [ -n "$CC_email" ] || [ -n "$CC_syslog" ] || [ -n "$CC_grub" ] || [ "$CC_mfa" = true ]; then
      printf '\n# Optional measure parameters.\n'
      [ -n "$CC_email" ]  && printf 'notify_email:                %s\n' "$CC_email"
      [ -n "$CC_syslog" ] && printf 'audit_logging_syslog_target: "%s"\n' "$CC_syslog"
      [ -n "$CC_grub" ]   && printf 'boot_grub_password_hash:     "%s"\n' "$CC_grub"
      [ "$CC_mfa" = true ] && printf 'enable_mfa:                  true\n'
    fi
  } > "$file"
}

cc_recap() {
  cc_section "Summary"
  printf '  target_ip          %s\n' "$CC_ip" >&2
  printf '  connection         %s (user %s, port %s)\n' "$CC_cmode" "$CC_iuser" "$CC_iport" >&2
  printf '  admin_user         %s (sudo: %s)\n' "$CC_admin" "$CC_sudo" >&2
  printf '  admin_pubkey_file  %s\n' "$CC_pubkey" >&2
  printf '  ssh_port           %s (%s)\n' "$CC_sport" "$CC_af" >&2
  printf '  extra ports        %s\n' "${CC_ports:--}" >&2
  printf '  f2b ignoreip       %s\n' "${CC_ban:--}" >&2
  printf '  auto_reboot        %s\n' "$CC_reboot" >&2
  printf '  notify_email       %s\n' "${CC_email:--}" >&2
  printf '  syslog target      %s\n' "${CC_syslog:--}" >&2
  printf '  GRUB password      %s\n' "$([ -n "$CC_grub" ] && echo set || echo '-')" >&2
  printf '  MFA (TOTP)         %s\n' "$CC_mfa" >&2
}

# --- init wizard -------------------------------------------------------------
cc_wizard() {
  set +e
  local host="$1" file; file="$(cc_hv_path "$host")"
  [ -f "$file" ] && die "Config already exists: ${file} (edit via ./harden configure ${host})."
  mkdir -p "$HOST_VARS_DIR"
  info "Interactive setup for '${host}'. Press Enter to accept a [default]."
  cc_questionnaire "$host" "" "root_password" "root" "22" "" \
    "castellan" "$HOME/.ssh/id_ed25519.pub" "nopasswd" "22" "inet" \
    "" "" "n" "" "" "" "n"
  cc_recap
  if ! cc_ask_yesno "Write this configuration?" "y"; then
    warn "Aborted; nothing written."; return 1
  fi
  cc_write_host "$host" "$file"
  ok "Wrote ${file}"
  info "Host '${host}' is now in the inventory (dynamic). All measures will be applied."
  info "Next: ./harden audit ${host} --ask-pass   then   ./harden apply ${host} --ask-pass"
}

# --- configure (edit an existing host) ---------------------------------------
cc_configure() {
  set +e
  local host="$1" file; file="$(cc_hv_path "$host")"
  [ -f "$file" ] || die "No config for '${host}'. Run: ./harden init ${host}"
  info "Editing '${host}' (current values shown as [defaults])."
  local mfa=n; [ "$(cc_hv_get "$file" enable_mfa)" = true ] && mfa=y
  local reboot=n; [ "$(cc_hv_get "$file" auto_reboot)" = true ] && reboot=y
  cc_questionnaire "$host" \
    "$(cc_hv_get "$file" target_ip)" \
    "$(cc_hv_get "$file" connection_mode)" \
    "$(cc_hv_get "$file" initial_user)" \
    "$(cc_hv_get "$file" initial_port)" \
    "$(cc_hv_get "$file" initial_key)" \
    "$(cc_hv_get "$file" admin_user)" \
    "$(cc_hv_get "$file" admin_pubkey_file)" \
    "$(cc_hv_get "$file" sudo_mode)" \
    "$(cc_hv_get "$file" ssh_port)" \
    "$(cc_hv_get "$file" ssh_address_family)" \
    "$(cc_hv_get "$file" ufw_allowed_ports)" \
    "$(cc_hv_get "$file" f2b_ignoreip)" \
    "$reboot" \
    "$(cc_hv_get "$file" notify_email)" \
    "$(cc_hv_get "$file" audit_logging_syslog_target)" \
    "$(cc_hv_get "$file" boot_grub_password_hash)" \
    "$mfa"
  cc_recap
  if ! cc_ask_yesno "Save changes to ${file}?" "y"; then
    warn "Aborted; file unchanged."; return 1
  fi
  cc_write_host "$host" "$file"
  ok "Saved ${file}"
}

# --- list --------------------------------------------------------------------
cc_list() {
  set +e
  local f host ip cmode sport
  [ -d "$HOST_VARS_DIR" ] || { warn "No hosts configured yet (./harden init <host>)."; return; }
  printf '%-22s %-18s %-14s %s\n' "HOST" "TARGET" "CONNECTION" "SSH PORT"
  for f in "$HOST_VARS_DIR"/*.yml; do
    [ -e "$f" ] || continue
    host="$(basename "$f" .yml)"
    ip="$(cc_hv_get "$f" target_ip)"
    cmode="$(cc_hv_get "$f" connection_mode)"
    sport="$(cc_hv_get "$f" ssh_port)"
    printf '%-22s %-18s %-14s %s\n' "$host" "${ip:--}" "${cmode:--}" "${sport:--}"
  done
}
