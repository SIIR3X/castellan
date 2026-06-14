# shellcheck shell=bash
#
# Castellan - interactive configuration library (sourced by ./harden).
# Provides: the measure catalog, a whiptail-or-plain TUI, the `init` wizard and
# the hierarchical `configure` selector (roles -> measures, whole-role toggle).
# Relies on the helpers defined in ./harden: info/ok/warn/die and HOST_VARS_DIR.

# --- Measure catalog ---------------------------------------------------------
# One line per opt-in measure: role|var|type|code|label
#   type: bool (checkbox) | int | str | choice | csv (checkbox + value prompt)
#   a "(!)" prefix in the label flags a risky/irreversible measure.
# Roles that are off unless the profile (or this catalog) turns them on.
CC_OPTIN_ROLES="confinement integrity boot mfa"
CC_CATALOG="$(cat <<'EOF'
accounts|accounts_remove_unused|bool|1.13|Remove unused system accounts
accounts|accounts_max_logins|int|1.14|Limit concurrent logins per user
ssh|ssh_banner|bool|2.14|Pre-auth legal banner
ssh|ssh_address_family|choice|2.17|Restrict address family (any/inet/inet6)
ssh|ssh_allow_fido2|bool|3.2|Accept FIDO2/U2F security keys
firewall|ufw_block_icmp_echo|bool|4.9|Drop ICMP echo-request (ping)
updates|updates_pending_alert|bool|6.8|Email pending-update alerts (needs notify_email)
sysctl|sysctl_restrict_perf|bool|7.14|Restrict perf_event (paranoid=3)
sysctl|sysctl_disable_userns|bool|8.5|Disable unprivileged user namespaces
sysctl|sysctl_disable_module_load|bool|7.18|(!) Lock kernel module loading - IRREVERSIBLE
filesystem|filesystem_harden_var_tmp|bool|9.2|Harden /var/tmp as tmpfs
filesystem|filesystem_harden_home|bool|9.3|Harden /home (nosuid,nodev)
filesystem|filesystem_disable_usb|bool|9.9|Disable USB mass-storage
filesystem|filesystem_enable_quotas|bool|9.10|Enable disk quotas
services|services_mask|bool|10.2|Mask (not just disable) unused services
services|services_remove_compilers|bool|10.5|(!) Remove compilers/build tools
services|services_disable_ipv6|bool|10.6|(!) Disable IPv6 entirely
audit_logging|audit_logging_immutable|bool|11.3|(!) Immutable audit rules - needs reboot
audit_logging|audit_logging_syslog_target|str|11.6|Forward logs to remote syslog (host:port)
network|network_disable_wireless|bool|14.4|Disable wireless modules
network|network_egress_filter|bool|14.7|(!) Egress (outbound) filtering
cron|cron_disable_timers|csv|16.4|Mask systemd timers (comma-separated)
integrity|integrity_rkhunter|bool|12.3|Install rkhunter + chkrootkit
integrity|integrity_clamav|bool|12.4|(!) Install ClamAV antivirus (heavy)
boot|boot_disable_ctrl_alt_del|bool|15.5|Mask Ctrl-Alt-Del reboot
boot|boot_harden_kernel_cmdline|bool|15.4|Kernel security cmdline params
compliance|compliance_alerting|bool|18.5|Alert on SSH logins (needs notify_email)
EOF
)"

CC_BLOCK_BEGIN="# >>> castellan: profile & measures (managed by ./harden configure) >>>"
CC_BLOCK_END="# <<< castellan <<<"

# State, populated by cc_load_state and edited by the menus.
declare -A CC_STATE          # var -> value (bool="true", others=literal)
CC_PROFILE="standard"

# --- catalog helpers ---------------------------------------------------------
cc_roles() { printf '%s\n' "$CC_CATALOG" | awk -F'|' 'NF{print $1}' | awk '!seen[$0]++'; }
cc_role_lines() { printf '%s\n' "$CC_CATALOG" | awk -F'|' -v r="$1" '$1==r'; }
cc_field() { printf '%s\n' "$1" | cut -d'|' -f"$2"; }

# --- TUI primitives (whiptail if present, else plain read) -------------------
cc_tui() { [ -n "${CASTELLAN_NO_TUI:-}" ] && return 1; command -v whiptail >/dev/null 2>&1; }

cc_input() {  # title default -> echoes value (may be empty)
  local title="$1" def="${2:-}"
  if cc_tui; then
    whiptail --title "Castellan" --inputbox "$title" 10 72 "$def" 3>&1 1>&2 2>&3
  else
    local v; read -r -p "$title [${def}]: " v; printf '%s' "${v:-$def}"
  fi
}

cc_menu() {  # title  then pairs: tag label tag label ...  -> echoes chosen tag
  local title="$1"; shift
  if cc_tui; then
    whiptail --title "Castellan" --notags --menu "$title" 22 76 14 "$@" 3>&1 1>&2 2>&3
  else
    local i=1 tag label; local -a tags=()
    echo "== ${title} ==" >&2
    while [ $# -gt 0 ]; do tag="$1"; label="$2"; shift 2; tags+=("$tag"); printf '  %2d) %s\n' "$i" "$label" >&2; i=$((i+1)); done
    local c; read -r -p "Choice #: " c
    [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le "${#tags[@]}" ] && printf '%s' "${tags[$((c-1))]}"
  fi
}

# cc_checklist: title  then triples: tag "label" state(ON/OFF) ...
# echoes the selected tags, one per line.
cc_checklist() {
  local title="$1"; shift
  if cc_tui; then
    local res
    res="$(whiptail --title "Castellan" --notags --separate-output --checklist "$title" 22 78 14 "$@" 3>&1 1>&2 2>&3)" || return 1
    printf '%s\n' "$res"
  else
    local -a tags=() labels=() states=()
    while [ $# -gt 0 ]; do tags+=("$1"); labels+=("$2"); states+=("$3"); shift 3; done
    local n=${#tags[@]} i
    echo "== ${title} ==  (toggle: number; 'a'=all on; 'n'=all off; Enter=done)" >&2
    while :; do
      for ((i=0;i<n;i++)); do printf '  %2d) [%s] %s\n' "$((i+1))" "$([ "${states[$i]}" = ON ] && echo x || echo ' ')" "${labels[$i]}" >&2; done
      local c; read -r -p "> " c
      case "$c" in
        "") break ;;
        a|A) for ((i=0;i<n;i++)); do states[$i]=ON; done ;;
        n|N) for ((i=0;i<n;i++)); do states[$i]=OFF; done ;;
        *) if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le "$n" ]; then
             i=$((c-1)); [ "${states[$i]}" = ON ] && states[$i]=OFF || states[$i]=ON
           fi ;;
      esac
    done
    for ((i=0;i<n;i++)); do [ "${states[$i]}" = ON ] && printf '%s\n' "${tags[$i]}"; done
    return 0
  fi
}

cc_yesno() {  # title -> 0 yes / 1 no
  local title="$1"
  if cc_tui; then whiptail --title "Castellan" --yesno "$title" 10 72 3>&1 1>&2 2>&3
  else local v; read -r -p "$title [y/N]: " v; [[ "$v" =~ ^[yY] ]]; fi
}

# --- host_vars read/write ----------------------------------------------------
cc_hv_path() { printf '%s/%s.yml' "$HOST_VARS_DIR" "$1"; }

# Read a scalar key from a host_vars file (first match, value trimmed/unquoted).
cc_hv_get() {
  local file="$1" key="$2" line
  line="$(grep -E "^[[:space:]]*${key}[[:space:]]*:" "$file" 2>/dev/null | head -n1)" || true
  [ -n "$line" ] || return 0
  printf '%s' "$line" | sed -E "s/^[[:space:]]*${key}[[:space:]]*:[[:space:]]*//; s/[[:space:]]*#.*$//; s/^\"//; s/\"$//; s/^'//; s/'$//"
}

# Load CC_PROFILE + CC_STATE from a host_vars file.
cc_load_state() {
  local file="$1" var type v
  CC_STATE=(); CC_PROFILE="$(cc_hv_get "$file" hardening_profile)"; [ -n "$CC_PROFILE" ] || CC_PROFILE=standard
  while IFS='|' read -r _role var type _code _label; do
    [ -n "$var" ] || continue
    v="$(cc_hv_get "$file" "$var")"
    case "$type" in
      bool) [ "$v" = "true" ] && CC_STATE[$var]="true" ;;
      *)    [ -n "$v" ] && [ "$v" != "[]" ] && [ "$v" != '""' ] && CC_STATE[$var]="$v" ;;
    esac
  done <<< "$CC_CATALOG"
}

# Rewrite the managed block of a host_vars file from CC_PROFILE + CC_STATE.
cc_write_block() {
  local file="$1" tmp var role
  tmp="$(mktemp)"
  # Keep everything outside the managed block.
  awk -v b="$CC_BLOCK_BEGIN" -v e="$CC_BLOCK_END" '
    $0==b {skip=1} skip && $0==e {skip=0; next} !skip {print}
  ' "$file" > "$tmp"
  # Drop a trailing blank line, then append a fresh block.
  sed -i -e :a -e '/^[[:space:]]*$/{$d;N;ba}' "$tmp"
  {
    printf '\n%s\n' "$CC_BLOCK_BEGIN"
    printf 'hardening_profile: %s\n' "$CC_PROFILE"
    # Enable opt-in roles that have at least one selected measure.
    for role in $CC_OPTIN_ROLES; do
      if cc_role_has_enabled "$role"; then printf 'enable_%s: true\n' "$role"; fi
    done
    for var in $(printf '%s\n' "${!CC_STATE[@]}" | sort); do
      cc_emit_var "$var" "${CC_STATE[$var]}"
    done
    # 11.6 companion: a target implies enabling the forwarder.
    [ -n "${CC_STATE[audit_logging_syslog_target]:-}" ] && printf 'audit_logging_remote_syslog: true\n'
    printf '%s\n' "$CC_BLOCK_END"
  } >> "$tmp"
  mv "$tmp" "$file"
}

cc_role_has_enabled() {  # role -> 0 if any of its catalog vars is set
  local role="$1" var
  while IFS='|' read -r _r var _t _c _l; do
    [ -n "$var" ] || continue
    [ -n "${CC_STATE[$var]:-}" ] && return 0
  done <<< "$(cc_role_lines "$role")"
  return 1
}

cc_var_type() { printf '%s\n' "$CC_CATALOG" | awk -F'|' -v v="$1" '$2==v{print $3; exit}'; }

cc_emit_var() {  # var value -> YAML line
  local var="$1" val="$2" type; type="$(cc_var_type "$var")"
  case "$type" in
    bool)   printf '%s: true\n' "$var" ;;
    int)    printf '%s: %s\n' "$var" "$val" ;;
    csv)    printf '%s: [%s]\n' "$var" "$(printf '%s' "$val" | sed 's/[[:space:]]*,[[:space:]]*/, /g')" ;;
    *)      printf '%s: "%s"\n' "$var" "$val" ;;   # str / choice
  esac
}

# --- role checklist (expand a role, toggle measures, whole-role toggle) ------
cc_edit_role() {
  local role="$1"
  local -a items=() tags=() types=()
  local var type code label state allon=1
  while IFS='|' read -r _r var type code label; do
    [ -n "$var" ] || continue
    tags+=("$var"); types+=("$type")
    if [ -n "${CC_STATE[$var]:-}" ]; then state=ON; else state=OFF; allon=0; fi
    items+=("$var" "${code}  ${label}" "$state")
  done <<< "$(cc_role_lines "$role")"
  [ "${#tags[@]}" -eq 0 ] && { warn "No opt-in measures for role '$role'."; return; }

  # Prepend the whole-role toggle.
  local all_state=OFF; [ "$allon" -eq 1 ] && all_state=ON
  local selected
  selected="$(cc_checklist "Role: ${role}  (space toggles)" \
      "__ALL__" ">> WHOLE ROLE (every measure)" "$all_state" "${items[@]}")" || return

  local -A chosen=(); local t
  while IFS= read -r t; do [ -n "$t" ] && chosen[$t]=1; done <<< "$selected"

  local i=0
  for var in "${tags[@]}"; do
    type="${types[$i]}"; i=$((i+1))
    local want=0
    [ -n "${chosen[$var]:-}" ] && want=1
    [ -n "${chosen[__ALL__]:-}" ] && want=1     # whole-role override
    if [ "$want" -eq 1 ]; then
      if [ -z "${CC_STATE[$var]:-}" ]; then cc_prompt_value "$var" "$type"; fi
    else
      unset 'CC_STATE['"$var"']'
    fi
  done
}

# Ask for the value of a freshly-enabled non-bool measure (bool just stores true).
cc_prompt_value() {
  local var="$1" type="$2" v
  case "$type" in
    bool)   CC_STATE[$var]="true" ;;
    int)    v="$(cc_input "Value for ${var}:" "10")"; CC_STATE[$var]="${v:-10}" ;;
    choice) v="$(cc_input "${var} (any/inet/inet6):" "inet")"; CC_STATE[$var]="${v:-inet}" ;;
    csv)    v="$(cc_input "${var} (comma-separated):" "")"; [ -n "$v" ] && CC_STATE[$var]="$v" || unset 'CC_STATE['"$var"']' ;;
    *)      v="$(cc_input "Value for ${var}:" "")"; [ -n "$v" ] && CC_STATE[$var]="$v" || unset 'CC_STATE['"$var"']' ;;
  esac
}

# --- configure: main loop ----------------------------------------------------
cc_configure() {
  set +e   # interactive: failed [ ] tests are expected, not fatal
  local host="$1" file; file="$(cc_hv_path "$host")"
  [ -f "$file" ] || die "No config for '${host}'. Run: ./harden init ${host}"
  cc_load_state "$file"
  while :; do
    local -a menu=("__profile__" "Profile .......... ${CC_PROFILE}")
    local role n
    while IFS= read -r role; do
      n="$(cc_role_enabled_count "$role")"
      menu+=("$role" "$(printf '%-14s %s extra' "$role" "$n")")
    done <<< "$(cc_roles)"
    menu+=("__save__" "Save" "__quit__" "Quit without saving")
    local choice; choice="$(cc_menu "Configure ${host}" "${menu[@]}")" || break
    case "$choice" in
      "") break ;;
      __profile__) local p; p="$(cc_menu "Hardening profile" minimal "minimal - essential spine" standard "standard - recommended" paranoid "paranoid - + opt-in roles")"; [ -n "$p" ] && CC_PROFILE="$p" ;;
      __save__) cc_write_block "$file"; ok "Saved ${file}"; return 0 ;;
      __quit__) return 0 ;;
      *) cc_edit_role "$choice" ;;
    esac
  done
  cc_write_block "$file"; ok "Saved ${file}"
}

cc_role_enabled_count() {  # role -> "x/y"
  local role="$1" var total=0 on=0
  while IFS='|' read -r _r var _t _c _l; do
    [ -n "$var" ] || continue
    total=$((total+1)); [ -n "${CC_STATE[$var]:-}" ] && on=$((on+1))
  done <<< "$(cc_role_lines "$role")"
  printf '%s/%s' "$on" "$total"
}

# --- init wizard -------------------------------------------------------------
cc_wizard() {
  set +e   # interactive: failed [ ] tests are expected, not fatal
  local host="$1" file; file="$(cc_hv_path "$host")"
  [ -f "$file" ] && die "Config already exists: ${file} (edit via ./harden configure ${host})."
  mkdir -p "$HOST_VARS_DIR"
  info "Interactive setup for '${host}' (Enter accepts the default)."

  local ip cmode iuser iport ikey admin pubkey sudo sport ports ban prof email
  ip="$(cc_input "Target IP or FQDN:" "$host")"
  cmode="$(cc_menu "Initial connection method" root_password "root + password" root_key "root + private key" user_sudo "existing user + sudo")"
  [ -n "$cmode" ] || cmode=root_password
  case "$cmode" in
    user_sudo) iuser="$(cc_input "Existing sudo user for first contact:" "ubuntu")" ;;
    *)         iuser="root" ;;
  esac
  iport="$(cc_input "Initial SSH port:" "22")"
  [ "$cmode" = root_key ] && ikey="$(cc_input "Private key path for first contact:" "${HOME}/.ssh/id_ed25519")"
  admin="$(cc_input "Admin user to create:" "castellan")"
  pubkey="$(cc_input "Public key to deploy (path):" "${HOME}/.ssh/id_ed25519.pub")"
  sudo="$(cc_menu "Sudo for the admin" nopasswd "nopasswd (key only, automation)" password "password (2nd factor)")"
  [ -n "$sudo" ] || sudo=nopasswd
  sport="$(cc_input "Hardened SSH port (open in ufw first!):" "22")"
  ports="$(cc_input "Extra ports to open (comma list, e.g. 80,443):" "")"
  ban="$(cc_input "Your IP to never ban (fail2ban):" "")"
  prof="$(cc_menu "Hardening profile" minimal "minimal" standard "standard (recommended)" paranoid "paranoid")"
  [ -n "$prof" ] || prof=standard
  email="$(cc_input "Notification email (optional, for alerts):" "")"

  {
    printf -- '---\n# Castellan per-host configuration for %s (generated by ./harden init).\n\n' "$host"
    printf 'target_ip:        %s\n' "$ip"
    printf 'connection_mode:  %s\n' "$cmode"
    printf 'initial_user:     %s\n' "$iuser"
    printf 'initial_port:     %s\n' "$iport"
    [ -n "${ikey:-}" ] && printf 'initial_key:      %s\n' "$ikey"
    printf '\nadmin_user:        %s\n' "$admin"
    printf 'admin_pubkey_file: %s\n' "$pubkey"
    printf 'sudo_mode:         %s\n' "$sudo"
    printf '\nssh_port:          %s\n' "$sport"
    printf 'ssh_allow_groups:  [ssh-users]\n'
    printf 'ufw_allowed_ports: [%s]\n' "$(printf '%s' "$ports" | sed 's/[[:space:]]*,[[:space:]]*/, /g')"
    printf 'f2b_ignoreip:      [%s]\n' "$([ -n "$ban" ] && printf '"%s"' "$ban")"
    printf 'auto_reboot:       false\n'
    [ -n "$email" ] && printf 'notify_email:      %s\n' "$email"
  } > "$file"

  # Initial managed block (profile only; measures added via ./harden configure).
  CC_STATE=(); CC_PROFILE="$prof"; cc_write_block "$file"
  ok "Wrote ${file}"
  info "Host '${host}' is now in the inventory automatically (dynamic inventory)."
  if cc_yesno "Open the measure selector now (./harden configure ${host})?"; then
    cc_configure "$host"
  fi
  info "Next: ./harden audit ${host} --ask-pass   then   ./harden apply ${host} --ask-pass"
}

# --- list --------------------------------------------------------------------
cc_list() {
  set +e   # interactive: failed [ ] tests are expected, not fatal
  local f host
  [ -d "$HOST_VARS_DIR" ] || { warn "No hosts configured yet (./harden init <host>)."; return; }
  printf '%-28s %-10s %s\n' "HOST" "PROFILE" "ENABLED MEASURES"
  for f in "$HOST_VARS_DIR"/*.yml; do
    [ -e "$f" ] || continue
    host="$(basename "$f" .yml)"
    cc_load_state "$f"
    printf '%-28s %-10s %s\n' "$host" "$CC_PROFILE" "$([ "${#CC_STATE[@]}" -gt 0 ] && (printf '%s\n' "${!CC_STATE[@]}" | sort | paste -sd, -) || echo '-')"
  done
}
