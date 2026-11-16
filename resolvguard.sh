#!/bin/sh
##############################################################################
# ResolvGuard.sh
#
# Project Created: 2026-Oct-29 by @ExtremeFiretop
# Last Modified: 2026-Nov-15
#
# ResolvGuard™
# Official project: https://github.com/ExtremeFiretop/ResolvGuard
#
# Licensed under the GNU General Public License v3.0.
# Additional terms under GPLv3 Section 7 apply to covered material.
# See ADDITIONAL_TERMS.md.
#
# ResolvGuard™ is a project trademark.
# The GPLv3 license does not grant trademark rights. See TRADEMARKS.md.
##############################################################################
CONFIG_SCHEMA=5

set -u

## Set version for each Production Release ##
readonly SCRIPT_VERSION=0.2.2
readonly SCRIPT_VERSTAG="26111612"
readonly SCRIPT_NAME="ResolvGuard"
## Set to "master" for Production Releases ##
SCRIPT_BRANCH="dev"

# Run install from a staged download, or from the final script path. A normal
# first launch uses the same installation path before opening the SSH menu.
_RG_COMMAND="${1:-menu}"
SOURCE_DIR="$(CDPATH= cd -- "$(dirname "$0")" 2>/dev/null && pwd)"
SOURCE_FILE="$SOURCE_DIR/$(basename "$0")"
INSTALL_ROOT=/jffs/addons/ResolvGuard.d
ROOT="$SOURCE_DIR"
case "$_RG_COMMAND" in install|menu) ROOT="$INSTALL_ROOT" ;; esac
LAUNCH_DIR=/opt/bin
SETTINGS="$ROOT/config/settings.conf"
EXTRA_PROVIDERS="$ROOT/config/extra-providers.tsv"
CHECKS="$ROOT/config/checks.tsv"
RUNTIME=/tmp/resolvguard
PROVIDERS="$RUNTIME/providers.tsv"
STATE_DIR="$ROOT/state"
INSTALL_MARKER="$STATE_DIR/installation-complete"
# Separate onboarding completion from installation and DNS-switch authorization.
QUICK_SETUP_MARKER="$STATE_DIR/quick-setup-complete"
PREF_RULELIST="$STATE_DIR/preferred-rulelist"
PREF_PROVIDERS="$STATE_DIR/preferred-providers.tsv"
PREFERRED_SYNC="$STATE_DIR/preferred-sync-intent"
ACTIVE_POOL="$STATE_DIR/active-pool"
ACTIVE_RULELIST="$STATE_DIR/active-rulelist"
POOLS="$RUNTIME/pools.tsv"
# Volatile, per-member observations. No flash writes; scoped to current approved policy and WAN list.
MEMBER_HISTORY="$RUNTIME/member-health-history"
POLICY_APPROVAL="$STATE_DIR/policy-approval"
WAN_LOCK="$RUNTIME/rg-wan-lock"
CONFIG_LOCK="$RUNTIME/rg-config-lock"
MAINTENANCE_LOCK="$RUNTIME/rg-maintenance-priority"
SCHEDULE_MARKER="$STATE_DIR/monitoring-enabled"
AUTO_FAILOVER_MARKER="$STATE_DIR/automatic-failover-enabled"
SCHEDULE_JOB=ResolvGuardHealth
HOOK_DIR=/jffs/scripts
PENDING_TRANSACTION="$STATE_DIR/pending-transaction"
BOOT_REPORT="$STATE_DIR/boot-status"
RECOVERY_HOLD="$STATE_DIR/recovery-attention"
DIG=/opt/bin/dig
ENTWARE_OPKG=/opt/bin/opkg
STUBBY=/usr/sbin/stubby
# Firmware-local DNSMasq forwarding files. Internal constants, not user policy.
DNSMASQ_SERVERS=/tmp/resolv.dnsmasq
DNSMASQ_MAIN=/etc/dnsmasq.conf

# Choose the firmware's active production Stubby YAML when initializing a new
# installation. 3006 may use stubby-0.yml, while 3004 commonly uses stubby.yml.
# Do not change a saved Integration Settings override on subsequent launches.
# Optional arguments only facilitate offline testing with harmless fixture paths.
_DetectProductionStubbyConfig_() {
  local primary legacy proc_root proc_file args binary

  primary="${1:-/etc/stubby/stubby-0.yml}"
  legacy="${2:-/etc/stubby/stubby.yml}"
  proc_root="${3:-/proc}"

  # Only consult the running process when both firmware layouts are present.
  # The daemon's -C argument is more reliable than the firmware generation.
  if [ -r "$primary" ] && [ -r "$legacy" ]; then
    for proc_file in "$proc_root"/[0-9]*/cmdline; do
      if [ ! -r "$proc_file" ]; then
        continue
      fi

      if ! args="$(tr '\000' ' ' < "$proc_file" 2>/dev/null)"; then
        continue
      fi

      binary="${args%% *}"
      case "$binary" in
        */stubby|stubby)
          # This is the running Stubby process; inspect its active YAML path.
          ;;
        *)
          continue
          ;;
      esac

      case " $args " in
        *" -C $primary "*)
          printf '%s\n' "$primary"
          return 0
          ;;
        *" -C $legacy "*)
          printf '%s\n' "$legacy"
          return 0
          ;;
      esac
    done
  fi

  # Normally only one of these two files exists on the router.
  if [ -r "$primary" ]; then
    printf '%s\n' "$primary"
    return 0
  fi

  if [ -r "$legacy" ]; then
    printf '%s\n' "$legacy"
    return 0
  fi

  # Preserve the historical default when neither file is available.
  # Normal prerequisite validation still rejects a missing production YAML.
  printf '%s\n' "$primary"
}

# A fresh install needs only this script. Create missing config files here, not
# in the package or updater. Existing files are never edited, truncated or
# replaced; a dangerous path (symlink, directory, unreadable file) is refused.
# Build every default as a private, complete temporary file and hardlink it
# into place, so a concurrent invocation cannot overwrite an existing file.
_CreateMissingConfigFile_() {
  local name dest staged default_stubby
  name="$1"
  dest="$ROOT/config/$name"
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    if [ -f "$dest" ] && [ ! -L "$dest" ] && [ -r "$dest" ]; then
      return 0
    fi
    printf 'ERROR: Unsafe existing configuration path: %s\n' "$dest" >&2
    return 1
  fi
  staged="$ROOT/config/.resolvguard-default-$name.$$"
  if [ -e "$staged" ] || [ -L "$staged" ]; then
    printf 'ERROR: Configuration staging path is occupied: %s\n' "$staged" >&2
    return 1
  fi
  if ! (umask 077; set -C; case "$name" in
    settings.conf)
      default_stubby="$(_DetectProductionStubbyConfig_)" || exit 1
      cat <<RG_SETTINGS_DEFAULT
FAIL_THRESHOLD=2
RECOVERY_THRESHOLD=3
TIMEOUT_SECONDS=5
CA_FILE=/etc/ssl/certs/ca-certificates.crt
WAN_STUBBY_CONFIG=$default_stubby

SCHEDULE_INTERVAL_MINUTES=1
FAST_CONFIRM_SECONDS=7
BOOT_MIN_UPTIME_SECONDS=120
SYSLOG_HEALTH_INTERVAL_MINUTES=0
RG_SETTINGS_DEFAULT
      ;;
    checks.tsv) cat <<'RG_CHECKS_DEFAULT'
# hostname|record_type|expected_rcode|expected_answer_count|expected_record_data_or_dash
a.root-servers.net|A|NOERROR|AT_LEAST_1|-
RG_CHECKS_DEFAULT
      ;;
    extra-providers.tsv) cat <<'RG_PROVIDERS_DEFAULT'
# Optional independent backup resolvers (add using Quick Setup or Advanced Options).
# resolver_id|IPv4_or_IPv6|TLS_authentication_hostname|upstream_TLS_port
# google1|8.8.8.8|dns.google|853
# google2|8.8.4.4|dns.google|853
# quad9v6|2620:fe::fe|dns.quad9.net|853
RG_PROVIDERS_DEFAULT
      ;;
    *) exit 1 ;;
  esac > "$staged"); then
    rm -f "$staged"
    printf 'ERROR: Could not create default config: %s\n' "$name" >&2
    return 1
  fi
  if ln "$staged" "$dest" 2>/dev/null; then
    rm -f "$staged" || return 1
    printf '%sCONFIG INITIALIZED:%s %s\n' "${RG_GREEN:-}" "${RG_RESET:-}" "$dest"
    return 0
  fi
  rm -f "$staged"
  # If another ResolvGuard invocation created this file first, honor it.
  if [ -f "$dest" ] && [ ! -L "$dest" ] && [ -r "$dest" ]; then
    return 0
  fi
  printf 'ERROR: Could not safely initialize config: %s\n' "$dest" >&2
  return 1
}

_InitializeMissingConfiguration_() {
  local dir
  dir="$ROOT/config"
  if [ -L "$dir" ] || { [ -e "$dir" ] && [ ! -d "$dir" ]; }; then
    printf 'ERROR: Unsafe configuration directory: %s\n' "$dir" >&2
    return 1
  fi
  if [ ! -d "$dir" ]; then
    (umask 077; mkdir "$dir") 2>/dev/null || [ -d "$dir" ] || {
      printf 'ERROR: Could not create configuration directory: %s\n' "$dir" >&2
      return 1
    }
    [ ! -L "$dir" ] || {
      printf 'ERROR: Configuration directory became a symlink: %s\n' "$dir" >&2
      return 1
    }
  fi
  _CreateMissingConfigFile_ settings.conf &&
    _CreateMissingConfigFile_ checks.tsv &&
    _CreateMissingConfigFile_ extra-providers.tsv
}

# Preserve AMTM's offline, read-only capability probe even on an installation
# whose config directory has not yet been initialized. All other entry points
# initialize only genuinely missing files before settings are sourced.
if [ "${1:-}" = amtmupdate ] && [ "${2:-}" = check ]; then
  [ "$ROOT" = "$INSTALL_ROOT" ] && [ -f "$ROOT/resolvguard.sh" ] &&
    [ ! -L "$ROOT/resolvguard.sh" ] &&
    [ -f "$INSTALL_MARKER" ] && [ ! -L "$INSTALL_MARKER" ] &&
    grep -Fx "ResolvGuard installation complete (schema $CONFIG_SCHEMA)" "$INSTALL_MARKER" >/dev/null 2>&1 && exit 0
  exit 1
fi
# No installer side effects (including config initialization) until the
# installation prerequisites are checked. Existing installations retain the
# normal missing-config repair behavior on ordinary commands.
case "$_RG_COMMAND" in
  install|help|-h|--help) : ;;
  menu) if [ ! -f "$INSTALL_MARKER" ] || [ -L "$INSTALL_MARKER" ]; then
      :
    else
      _InitializeMissingConfiguration_ || exit 2
    fi ;;
  *) _InitializeMissingConfiguration_ || exit 2 ;;
esac
if [ -r "$SETTINGS" ] && [ ! -L "$SETTINGS" ]; then
  . "$SETTINGS"
else
  case "$_RG_COMMAND" in
    install|menu|help|-h|--help) : ;;
    *) echo "Missing or unsafe settings $SETTINGS" >&2; exit 2 ;;
  esac
fi
: "${FAIL_THRESHOLD:=2}" "${RECOVERY_THRESHOLD:=3}" \
  "${TIMEOUT_SECONDS:=5}" \
  "${CA_FILE:=/etc/ssl/certs/ca-certificates.crt}" \
  "${WAN_STUBBY_CONFIG:=$(_DetectProductionStubbyConfig_)}" \
  "${SCHEDULE_INTERVAL_MINUTES:=1}" "${FAST_CONFIRM_SECONDS:=7}" \
  "${BOOT_MIN_UPTIME_SECONDS:=120}" \
  "${SYSLOG_HEALTH_INTERVAL_MINUTES:=0}"

# Older Merlin (e.g. 3004.388.x) uses stubby.yml. If the newer default
# doesn't exist, use the older firmware path without creating any symlink or
# editing firmware-managed files. Respect explicitly configured other paths.
if [ "$WAN_STUBBY_CONFIG" = /etc/stubby/stubby-0.yml ] &&
   [ ! -r "$WAN_STUBBY_CONFIG" ] && [ -r /etc/stubby/stubby.yml ]; then
  WAN_STUBBY_CONFIG=/etc/stubby/stubby.yml
fi

# MerlinAU-style release channels. The repository's production branch is
# named main; accept the familiar SCRIPT_BRANCH=master alias for stable builds.
# Stable updates use version-pinned GitHub Release assets; development updates
# use the raw dev branch and SCRIPT_VERSTAG for same-version build revisions.
readonly SCRIPT_URL_BASE='https://raw.githubusercontent.com/ExtremeFiretop/ResolvGuard'
readonly RELEASE_URL_BASE='https://github.com/ExtremeFiretop/ResolvGuard/releases/download'
readonly RELEASE_INSTALL_ASSET="${SCRIPT_NAME}-install.sh"
readonly RELEASE_UPDATE_ASSET="${SCRIPT_NAME}-update.sh"
case "$SCRIPT_BRANCH" in
  dev)
    UPDATE_CHANNEL=development
    SCRIPT_URL_REPO="${SCRIPT_URL_BASE}/refs/heads/dev"
    ;;
  master|main)
    UPDATE_CHANNEL=stable
    SCRIPT_URL_REPO="${SCRIPT_URL_BASE}/refs/heads/main"
    ;;
  *)
    printf 'ERROR: Unsupported SCRIPT_BRANCH: %s\n' "$SCRIPT_BRANCH" >&2
    exit 2
    ;;
esac
readonly SCRIPT_URL_REPO
readonly UPDATE_CHANNEL
readonly UPDATE_MANIFEST_URL="${SCRIPT_URL_REPO}/version.txt"
readonly UPDATE_DEV_SCRIPT_URL="${SCRIPT_URL_REPO}/resolvguard.sh"

umask 077
mkdir -p "$RUNTIME/states" || exit 1
chmod 700 "$RUNTIME" || exit 1

_Say_() { printf '%s\n' "$*"; }
_LogEvent_() {
  local severity
  severity="$1"; shift
  _Say_ "$*"
  logger -t ResolvGuard -p "user.$severity" "$*" >/dev/null 2>&1 ||
    logger -t ResolvGuard "$*" >/dev/null 2>&1 || :
}
_LogEventOnce_() {
  local key note current staged
  key="$1"; note="$2"
  current=''
  [ ! -L "$RUNTIME/syslog-health-state" ] || return 1
  [ ! -r "$RUNTIME/syslog-health-state" ] || current="$(cat "$RUNTIME/syslog-health-state" 2>/dev/null)"
  [ "$current" != "$key" ] || return 0
  case "$key:$current" in degraded-*:no-backup-*) return 0;; esac
  staged="$RUNTIME/syslog-health-state.new.$$"
  (umask 077; printf '%s\n' "$key" > "$staged") && mv "$staged" "$RUNTIME/syslog-health-state" || return 1
  _LogEvent_ warning "$note"
}
_LogHealthRecovered_() {
  if [ -s "$RUNTIME/syslog-health-state" ] && [ ! -L "$RUNTIME/syslog-health-state" ]; then
    rm -f "$RUNTIME/syslog-health-state" || return 1
    _LogEvent_ notice "$1"
  fi
}
_LogHealthyHeartbeat_() {
  local now then seconds staged
  [ "$SYSLOG_HEALTH_INTERVAL_MINUTES" -gt 0 ] || return 0
  now="$(date +%s 2>/dev/null)" || return 0
  case "$now" in ''|*[!0-9]*) return 0;; esac
  then='0'
  if [ -f "$RUNTIME/last-healthy-syslog" ] && [ ! -L "$RUNTIME/last-healthy-syslog" ]; then
    then="$(cat "$RUNTIME/last-healthy-syslog" 2>/dev/null)"
  fi
  case "$then" in ''|*[!0-9]*) then=0;; esac
  seconds=$((SYSLOG_HEALTH_INTERVAL_MINUTES * 60))
  [ "$now" -lt "$then" ] || [ "$((now - then))" -ge "$seconds" ] || return 0
  staged="$RUNTIME/last-healthy-syslog.new.$$"
  (umask 077; printf '%s\n' "$now" > "$staged") && mv "$staged" "$RUNTIME/last-healthy-syslog" || return 1
  _LogEvent_ info "DNS HEALTHY: preferred WAN Strict DoT checks passed (heartbeat ${SYSLOG_HEALTH_INTERVAL_MINUTES}m)"
}
_Fail_() { _Say_ "ERROR: $*" >&2; return 1; }
_ConfirmYesNo_() {
  local response
  _SetMenuPalette_
  printf '\n  %s%s%s %s[y/N]%s: ' "$RG_BOLD" "$1" "$RG_RESET" "$RG_CYAN" "$RG_RESET"
  IFS= read -r response || return 1
  printf '\n'
  case "$response" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) [ "${2:-}" = quiet ] || _Say_ '  Cancelled.'; return 1 ;;
  esac
}
_IsValidID_() { case "$1" in ''|*[!A-Za-z0-9_-]*) return 1;; *) return 0;; esac; }
_IsValidDomain_() {
  printf '%s\n' "$1" | LC_ALL=C grep -Eq '^[A-Za-z0-9-]+([.][A-Za-z0-9-]+)*$'
}
_IsValidIPv4_() {
  case "$1" in ''|*[!0-9.]*|.*|*..*|*.) return 1;; esac
  echo "$1" | awk -F. 'NF!=4 {exit 1} {for(i=1;i<=4;i++) if($i=="" || $i !~ /^[0-9]+$/ || $i>255 || $i<0) exit 1; exit 0}'
}
# Validate IPv6 in POSIX awk (BusyBox ash/dash compatible; no Python,
# ipcalc, external networking, or GNU awk extensions required).
# Supports :: compression and an IPv4-embedded tail. Zone IDs and brackets
# are deliberately not accepted in resolver identity fields: scoped link-local
# addresses cannot be safely represented as firmware-wide DoT upstreams.
_IsValidIPv6_() {
  printf '%s\n' "$1" | LC_ALL=C awk '
    # A dotted-decimal tail occupies two IPv6 groups.
    function valid_ipv4_tail(address, octets, count, i) {
      count = split(address, octets, ".")
      if (count != 4) {
        return 0
      }

      for (i = 1; i <= 4; i++) {
        if (octets[i] == "" || octets[i] !~ /^[0-9]+$/) {
          return 0
        }
        if (length(octets[i]) > 3 || octets[i] + 0 > 255) {
          return 0
        }
      }

      return 1
    }

    function valid_ipv6(address, normalized, parts, count, i,
                        groups, compressed, embedded) {
      if (address !~ /^[0-9a-fA-F:.]+$/) {
        return 0
      }
      if (index(address, ":") == 0 || address ~ /:::/) {
        return 0
      }
      if (address ~ /^:[^:]/ || address ~ /[^:]:$/) {
        return 0
      }

      # Represent the single allowed :: compression marker as one field.
      normalized = address
      compressed = gsub(/::/, "@", normalized)
      if (compressed > 1) {
        return 0
      }
      gsub(/@/, ":@:", normalized)
      sub(/^:/, "", normalized)
      sub(/:$/, "", normalized)

      count = split(normalized, parts, ":")
      groups = 0
      embedded = 0
      for (i = 1; i <= count; i++) {
        if (parts[i] == "@") {
          continue
        }
        if (parts[i] == "") {
          return 0
        }

        if (index(parts[i], ".")) {
          if (i != count || !valid_ipv4_tail(parts[i])) {
            return 0
          }
          embedded++
          groups += 2
        } else {
          if (length(parts[i]) > 4 || parts[i] !~ /^[0-9a-fA-F]+$/) {
            return 0
          }
          groups++
        }
      }

      if (embedded > 1) {
        return 0
      }
      if (compressed) {
        return groups < 8
      }
      return groups == 8
    }

    {
      if (!valid_ipv6($0)) {
        exit 1
      }
      valid = 1
    }

    END {
      if (!valid) {
        exit 1
      }
    }
  '
}
_IsValidIP_() {
  if _IsValidIPv4_ "$1"; then
    return 0
  fi

  _IsValidIPv6_ "$1"
}
_IsValidPort_() {
  case "$1" in ''|*[!0-9]*) return 1;; esac
  [ "$1" -gt 1024 ] && [ "$1" -le 65535 ]
}
_IsValidRecordType_() {
  printf '%s\n' "$1" | LC_ALL=C grep -Eq '^[A-Z][A-Z0-9]{0,15}$'
}
_IsValidRCODE_() {
  printf '%s\n' "$1" | LC_ALL=C grep -Eq '^[A-Z][A-Z0-9_]{0,31}$'
}
_IsValidAnswerCount_() {
  case "$1" in ANY) return 0;; ''|*[!0-9]*) return 1;; *) return 0;; esac
}

# DNS-check answer constraints are distinct from numeric monitoring thresholds.
# AT_LEAST_1 requires a real answer record of the requested DNS type; the
# packet's total ANSWER count alone can also include CNAME records.
_IsValidDNSAnswerCount_() {
  case "$1" in
    AT_LEAST_1)
      return 0
      ;;
    *)
      _IsValidAnswerCount_ "$1"
      ;;
  esac
}

_ParseWANUpstreams_() {
  [ -r "$WAN_STUBBY_CONFIG" ] || { _Fail_ "WAN Stubby config missing: $WAN_STUBBY_CONFIG"; return 1; }
  awk '
    function trim(s) {
      sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s)
      sub(/[ \t]+#.*/, "", s)
      gsub(/^\047|\047$/, "", s); gsub(/^"|"$/, "", s)
      return s
    }
    function emit() { if (ip != "") print ip "|" tls "|" port }
    /^[ \t]*upstream_recursive_servers:[ \t]*(#.*)?$/ {inside=1; next}
    inside && /^[A-Za-z_][A-Za-z_0-9-]*:/ {emit(); inside=0; exit}
    inside && /^[ \t]*-[ \t]*address_data:[ \t]*/ {
      emit(); ip=$0; sub(/^.*address_data:[ \t]*/, "", ip); ip=trim(ip)
      tls=""; port="853"; next
    }
    inside && /^[ \t]*tls_auth_name:[ \t]*/ {
      tls=$0; sub(/^.*tls_auth_name:[ \t]*/, "", tls); tls=trim(tls); next
    }
    inside && /^[ \t]*tls_port:[ \t]*/ {
      port=$0; sub(/^.*tls_port:[ \t]*/, "", port); port=trim(port); next
    }
    END { if (inside) emit() }
  ' "$WAN_STUBBY_CONFIG"
}

# Runtime provider inventory is ID|IP|TLS-name|TLS-port. Existing saved preferred
# snapshots retain their historical five-field format; the obsolete fourth
# (localhost probe port) is never used or allocated for direct DoT.
_PrepareProviders_() {
  local tmp raw id ip host tlsport extra n
  tmp="$PROVIDERS.new.$$"
  raw="$RUNTIME/discovered-$$"
  : > "$tmp" || return 1
  if [ -r "$PREF_PROVIDERS" ]; then
    if ! _ValidatePreferredSnapshot_; then
      _Fail_ 'Saved preferred DNS snapshot is incomplete or invalid (possibly from an IPv4-only version); automatic switching is blocked. Restore/re-enroll with the complete dual-stack router configuration.'
      rm -f "$tmp"
      return 1
    fi
    # Ignore only the legacy local listener port. Preserve every saved server
    # address, TLS identity, TLS port and original order.
    awk -F'|' 'BEGIN {OFS="|"} {print $1,$2,$3,$5}' "$PREF_PROVIDERS" > "$tmp" || {
      rm -f "$tmp"; return 1;
    }
  else
    _ParseWANUpstreams_ > "$raw" || { rm -f "$tmp" "$raw"; return 1; }
    n=0
    while IFS='|' read -r ip host tlsport extra; do
      [ -n "$ip" ] || continue
      if ! _IsValidIP_ "$ip"; then
        _Fail_ "Invalid WAN IPv4/IPv6 upstream address: $ip; refusing incomplete preferred DNS enrollment"
        rm -f "$tmp" "$raw"
        return 1
      fi
      _IsValidDomain_ "$host" || { _Fail_ "Invalid WAN TLS identity for $ip"; rm -f "$tmp" "$raw"; return 1; }
      _IsValidTLSPort_ "$tlsport" || { _Fail_ "Invalid WAN TLS port for $ip"; rm -f "$tmp" "$raw"; return 1; }
      if awk -F'|' -v i="$ip" -v h="$host" -v p="$tlsport" '$2==i && $3==h && $4==p {found=1} END{exit !found}' "$tmp"; then
        continue
      fi
      n=$((n+1))
      printf 'wan%s|%s|%s|%s\n' "$n" "$ip" "$host" "$tlsport" >> "$tmp" || {
        rm -f "$tmp" "$raw"; return 1;
      }
    done < "$raw"
    rm -f "$raw"
  fi
  if [ -r "$EXTRA_PROVIDERS" ]; then
    while IFS='|' read -r id ip host tlsport extra; do
      case "$id" in ''|\#*) continue;; esac
      tlsport="${tlsport:-853}"
      if awk -F'|' -v i="$ip" -v h="$host" -v p="$tlsport" '$2==i && $3==h && $4==p {found=1} END{exit !found}' "$tmp"; then
        _Say_ "NOTICE: extra resolver $id duplicates an existing endpoint; skipping" >&2
        continue
      fi
      printf '%s|%s|%s|%s\n' "$id" "$ip" "$host" "$tlsport" >> "$tmp" || {
        rm -f "$tmp"; return 1;
      }
    done < "$EXTRA_PROVIDERS"
  fi
  [ -s "$tmp" ] || { _Fail_ 'No usable WAN DoT providers discovered'; rm -f "$tmp"; return 1; }
  mv "$tmp" "$PROVIDERS"
}

_IsValidTLSPort_() { case "$1" in ''|*[!0-9]*) return 1;; esac; [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
_GetProviderInfo_() {
  awk -F'|' -v name="$1" '$1==name {print; found=1; exit} END {if(!found) exit 1}' "$PROVIDERS"
}

_DiscoverResolvers_() {
  local enabled profile
  _SyncPreferredWAN_ || return 1
  _PrepareProviders_ || return 1
  _Say_ "WAN Stubby config: $WAN_STUBBY_CONFIG"
  enabled="$(_ReadNVRAM_ dnspriv_enable)" && profile="$(_ReadNVRAM_ dnspriv_profile)" || {
    _Fail_ 'Unable to read WAN DNS Privacy settings'; return 1;
  }
  _Say_ "WAN DNS Privacy (NVRAM): enabled=$enabled profile=$profile"
  _Say_ 'NOTE: ResolvGuard-managed probes always use authenticated TLS even if WAN is opportunistic.'
  _Say_ 'Discovered providers (id|upstream|TLS_name|upstream_TLS_port):'
  cat "$PROVIDERS"
}

_ValidateConfiguration_() {
  local count id ip hostname tlsport extra duplicates qname qtype rcode answers expected
  _PrepareProviders_ || return 1
  [ -r "$CHECKS" ] && [ -r "$EXTRA_PROVIDERS" ] || {
    _Fail_ 'Missing DNS health checks or backup resolver configuration'; return 1;
  }
  awk -F'|' '$1 !~ /^#/ && $1 != "" && NF!=4 {exit 1}' "$EXTRA_PROVIDERS" || {
    _Fail_ 'Invalid backup provider format (expected ID|IPv4-or-IPv6|TLS-name|TLS-port)'; return 1;
  }
  _IsValidAnswerCount_ "$FAIL_THRESHOLD" && [ "$FAIL_THRESHOLD" -ge 1 ] || { _Fail_ 'FAIL_THRESHOLD must be positive'; return 1; }
  _IsValidAnswerCount_ "$RECOVERY_THRESHOLD" && [ "$RECOVERY_THRESHOLD" -ge 1 ] || { _Fail_ 'RECOVERY_THRESHOLD must be positive'; return 1; }
  case "$SCHEDULE_INTERVAL_MINUTES" in 1|2|5|10|15|20|30|60) : ;; *) _Fail_ 'Invalid monitoring interval'; return 1;; esac
  case "$FAST_CONFIRM_SECONDS" in ''|*[!0-9]*) _Fail_ 'FAST_CONFIRM_SECONDS must be numeric'; return 1;; esac
  [ "$FAST_CONFIRM_SECONDS" -le 15 ] || { _Fail_ 'FAST_CONFIRM_SECONDS exceeds 15 seconds'; return 1; }
  [ "$FAST_CONFIRM_SECONDS" -eq 0 ] || [ "$FAIL_THRESHOLD" -ge 2 ] || {
    _Fail_ 'Fast confirmation requires failure threshold >= 2'; return 1;
  }
  case "$BOOT_MIN_UPTIME_SECONDS" in ''|*[!0-9]*) _Fail_ 'Invalid boot warmup'; return 1;; esac
  [ "$BOOT_MIN_UPTIME_SECONDS" -le 3600 ] || { _Fail_ 'Boot warmup exceeds 3600 seconds'; return 1; }
  case "$SYSLOG_HEALTH_INTERVAL_MINUTES" in 0|15|30|60) :;; *) _Fail_ 'Invalid syslog heartbeat interval'; return 1;; esac
  case "$TIMEOUT_SECONDS" in 1|2|3|4|5|6|7|8|9|10|11|12|13|14|15) :;; *) _Fail_ 'Invalid DNS timeout'; return 1;; esac
  awk -F'|' '$1 !~ /^#/ && $1 != "" {if(seen[$1]++) exit 1}' "$EXTRA_PROVIDERS" || {
    _Fail_ 'Duplicate backup resolver IDs'; return 1;
  }
  count=0
  while IFS='|' read -r id ip hostname tlsport extra; do
    case "$id" in ''|\#*) continue;; esac
    _IsValidID_ "$id" && _IsValidIP_ "$ip" && _IsValidDomain_ "$hostname" &&
      _IsValidTLSPort_ "$tlsport" && [ -z "${extra:-}" ] || {
      _Fail_ "Invalid resolver: $id"; return 1;
    }
    duplicates="$(awk -F'|' -v i="$id" '$1==i {n++} END{print n+0}' "$PROVIDERS")"
    [ "$duplicates" -eq 1 ] || { _Fail_ "Duplicate resolver ID: $id"; return 1; }
    count=$((count+1))
  done < "$PROVIDERS"
  [ "$count" -gt 0 ] || { _Fail_ 'No valid upstream resolvers'; return 1; }
  awk -F'|' '$1 !~ /^#/ && $1 != "" {if (NF!=5 || seen[$1 "|" $2]++) exit 1; n++} END{if(n==0) exit 1}' "$CHECKS" || {
    _Fail_ 'DNS policy is empty, has duplicate hostname/type checks, or contains malformed rows'; return 1;
  }
  while IFS='|' read -r qname qtype rcode answers expected extra; do
    case "$qname" in ''|\#*) continue;; esac
    [ -z "${extra:-}" ] && _IsValidDomain_ "$qname" && _IsValidRecordType_ "$qtype" &&
      _IsValidRCODE_ "$rcode" && _IsValidDNSAnswerCount_ "$answers" && _IsSafeToken_ "$expected" || {
      _Fail_ "Invalid DNS health check: $qname $qtype"; return 1;
    }
  done < "$CHECKS"
  _Say_ 'Configuration validated.'
}

# Use the existing Entware dig binary for direct, per-upstream authenticated DoT.
# Require an actual response over the expected TLS server, not just dig's exit
# status: some BIND 9.20 builds return 0 for certificate failures without a
# DNS response. No fallback to plaintext DNS is permitted.
_RunAuthenticatedDoTQuery_() {
  local id hostname record_type output provider ip tls_name tls_port extra status
  id="$1"; hostname="$2"; record_type="$3"; output="$4"

  # Health policy must see answer records only. The interactive Inspector
  # intentionally retains authority and additional information for diagnosis.
  # Both modes retain +stats for the exact upstream IP/port/TLS marker.
  case "${5:-health}" in
    health) set -- +noall +comments +answer +stats ;;
    inspection) set -- +noall +comments +answer +authority +additional +stats ;;
    *) return 1 ;;
  esac

  provider="$(_GetProviderInfo_ "$id")" || return 1
  IFS='|' read -r id ip tls_name tls_port extra <<EOF_RG_DIRECT_DOT
$provider
EOF_RG_DIRECT_DOT
  [ -z "${extra:-}" ] && _IsValidIP_ "$ip" &&
    _IsValidDomain_ "$tls_name" && _IsValidTLSPort_ "$tls_port" &&
    [ -r "$CA_FILE" ] && [ -x "$DIG" ] || return 1

  # Always target a literal address. Never resolve TLS names through the
  # router's production DNS or silently retry over UDP/TCP port 53.
  if "$DIG" "@$ip" -p "$tls_port" "$hostname" "$record_type" \
      +tls "+tls-ca=$CA_FILE" "+tls-hostname=$tls_name" \
      "+time=$TIMEOUT_SECONDS" +tries=1 \
      "$@" > "$output" 2>&1; then
    status=0
  else
    status=$?
  fi
  [ "$status" -eq 0 ] || return 1

  # Reject TLS failures even when dig reports success. The server identity
  # marker is checked exactly, including IP, port and transport (TLS).
  if grep -E '^;; (TLS |Connection to |communications error|no servers could be reached|connection timed out|couldn.t get an answer)' "$output" >/dev/null 2>&1; then
    return 1
  fi

  grep -Fx ';; Got answer:' "$output" >/dev/null 2>&1 &&
    grep -Eq '^;; ->>HEADER<<- opcode: QUERY, status: [A-Z][A-Z0-9_]*, id: [0-9]+' "$output" &&
    grep -Eq '^;; flags: qr([[:space:]]|;)' "$output" &&
    grep -Eq 'QUERY: 1, ANSWER: [0-9]+' "$output" &&
    grep -Fx ";; SERVER: $ip#$tls_port($ip) (TLS)" "$output" >/dev/null 2>&1 || return 1

  return 0
}

# Only DNS ANSWER SECTION resource records can satisfy health policies.
# Other sections may contain valid records of the requested type, but they
# are not the answer to the policy query. Keep this independent of the dig
# presentation flags as a fail-closed guard if verbose output is encountered.
_HasDNSAnswerRecord_() {
  local response record_type expected_value
  response="$1"; record_type="$2"; expected_value="$3"

  printf '%s\n' "$response" | awk -v qt="$record_type" -v expected="$expected_value" '
    /^;; ANSWER SECTION:$/ { in_answer=1; next }
    /^;; / { in_answer=0; next }
    /^;/ { next }
    in_answer && NF>=5 && $2 ~ /^[0-9]+$/ && $3 == "IN" && $4 == qt &&
      (expected == "-" || $5 == expected) { found=1; exit }
    END { exit found ? 0 : 1 }
  '
}

# Short configuration commits and actual WAN mutations share the config lock.
# Probe cycles retain the WAN lock for failover serialization, but never hold
# the configuration lock while waiting for DNS or user input.
# Reuse the same conservative stale-owner/reclaim safeguards for both locks.
_AcquireNamedLock_() {
  local lockpath owner previous acquire_guard outcome reclaimed

  lockpath="$1"
  acquire_guard="$lockpath.reclaim"

  # The short-lived reclaim guard serializes competing lock acquisitions.
  if ! mkdir "$acquire_guard" 2>/dev/null; then
    return 1
  fi

  outcome=1
  reclaimed=0

  if mkdir "$lockpath" 2>/dev/null; then
    # A new lock belongs only to this process, not to its parent shell.
    if (umask 077; printf '%s\n' "$$" > "$lockpath/owner"); then
      outcome=0
    else
      rmdir "$lockpath" 2>/dev/null || :
    fi
  elif [ -d "$lockpath" ] && [ ! -L "$lockpath" ] &&
       [ -f "$lockpath/owner" ] && [ ! -L "$lockpath/owner" ]; then
    owner="$(cat "$lockpath/owner" 2>/dev/null || :)"

    case "$owner" in
      ''|*[!0-9]*)
        owner=''
        ;;
    esac

    # Only reclaim an unambiguously dead owner's lock. Never steal a live
    # monitor or WAN writer's lock simply because it is taking too long.
    if [ -n "$owner" ] && [ "$owner" != "$$" ] &&
       [ -d /proc ] && [ ! -e "/proc/$owner" ] &&
       ! kill -0 "$owner" 2>/dev/null; then
      previous="$lockpath.dead.$$"

      if [ ! -e "$previous" ] && [ ! -L "$previous" ] &&
         [ "$(cat "$lockpath/owner" 2>/dev/null || :)" = "$owner" ] &&
         mv "$lockpath" "$previous"; then
        if [ -f "$previous/owner" ] && [ ! -L "$previous/owner" ] &&
           [ "$(cat "$previous/owner" 2>/dev/null || :)" = "$owner" ] &&
           rm -f "$previous/owner" && rmdir "$previous"; then
          if mkdir "$lockpath" 2>/dev/null; then
            if (umask 077; printf '%s\n' "$$" > "$lockpath/owner"); then
              outcome=0
              reclaimed=1
            else
              rmdir "$lockpath" 2>/dev/null || :
            fi
          fi
        else
          _Fail_ "Stale lock needs manual inspection: $previous"
        fi
      fi
    fi
  fi

  if ! rmdir "$acquire_guard" 2>/dev/null; then
    _Fail_ "Lock acquisition guard needs manual inspection: $acquire_guard"
    return 1
  fi

  if [ "$outcome" -ne 0 ]; then
    return 1
  fi

  if [ "$reclaimed" -eq 1 ]; then
    _Say_ 'NOTICE: reclaimed lock held by a terminated ResolvGuard process.'
  fi

  return 0
}

_ReleaseNamedLock_() {
  local lockpath owner
  lockpath="$1"

  if [ ! -d "$lockpath" ] || [ -L "$lockpath" ]; then
    return 1
  fi
  if [ ! -f "$lockpath/owner" ] || [ -L "$lockpath/owner" ]; then
    return 1
  fi

  owner="$(cat "$lockpath/owner")"
  if [ "$owner" != "$$" ]; then
    return 1
  fi

  rm -f "$lockpath/owner" && rmdir "$lockpath"
}

_AcquireWANLock_() { _AcquireNamedLock_ "$WAN_LOCK"; }
_ReleaseWANLock_() { _ReleaseNamedLock_ "$WAN_LOCK"; }
_AcquireConfigLock_() { _AcquireNamedLock_ "$CONFIG_LOCK"; }
_ReleaseConfigLock_() { _ReleaseNamedLock_ "$CONFIG_LOCK"; }

# Interactive maintenance has priority over recurring scheduled monitoring.
# This is an admission gate, not a replacement for the WAN transaction lock:
# never take a live WAN lock away from an active scheduler or writer.
_MaintenancePriorityPending_() {
  if [ -e "$MAINTENANCE_LOCK" ] || [ -L "$MAINTENANCE_LOCK" ]; then
    return 0
  fi

  if [ -e "$MAINTENANCE_LOCK.reclaim" ] || [ -L "$MAINTENANCE_LOCK.reclaim" ]; then
    return 0
  fi

  return 1
}

_AcquireMaintenancePriority_() {
  if ! _AcquireNamedLock_ "$MAINTENANCE_LOCK"; then
    _Fail_ 'Another interactive maintenance operation is pending or active'
    return 1
  fi

  RG_MAINTENANCE_PRIORITY_HELD=1
  return 0
}

_ReleaseMaintenancePriority_() {
  if [ "${RG_MAINTENANCE_PRIORITY_HELD:-0}" != 1 ]; then
    return 0
  fi

  if ! _ReleaseNamedLock_ "$MAINTENANCE_LOCK"; then
    return 1
  fi

  RG_MAINTENANCE_PRIORITY_HELD=0
  return 0
}

# The maintenance reservation is also used for interactive policy actions.
# Keeping one priority gate prevents cron from racing either kind of operation.
# The active WAN lock remains exclusive: this function never steals it.
_AcquireWANLockWithInteractivePriority_() {
  local operation attempt

  operation="$1"

  # Reserve admission before waiting for an existing DNS operation to finish.
  if ! _AcquireMaintenancePriority_; then
    return 1
  fi

  attempt=1
  while [ "$attempt" -le 90 ]; do
    if _AcquireWANLock_; then
      return 0
    fi

    if [ "$attempt" -eq 1 ]; then
      if [ "$operation" = policy ]; then
        _Say_ 'DNS policy administration has priority; waiting for the current WAN operation to finish...'
      else
        _Say_ 'DNS maintenance has priority; waiting for the current WAN operation to finish...'
      fi
    fi

    if [ "$attempt" -eq 90 ]; then
      break
    fi

    sleep 1
    attempt=$((attempt + 1))
  done

  if [ "$operation" = policy ]; then
    _Fail_ 'WAN lock still unavailable; policy administration deferred without stealing a live lock'
  else
    _Fail_ 'WAN lock still unavailable; maintenance aborted without stealing a live lock'
  fi

  _ReleaseMaintenancePriority_ >/dev/null 2>&1 || :
  return 1
}

_AcquireWANLockForMaintenance_() {
  _AcquireWANLockWithInteractivePriority_ maintenance
}

# Called only while holding CONFIG_LOCK by maintenance operations.
# Inspector admission briefly holds CONFIG_LOCK before making its private
# session directory, so uninstall cannot race a new inspector session.
_ActiveInspectorSessions_() {
  local session

  # Recognize both current direct-DoT sessions and pre-upgrade inspectors
  # that may still own a legacy port slot during an upgrade transition.
  for session in "$RUNTIME"/inspectors/* "$RUNTIME"/inspector-slots/slot-*; do
    if [ -e "$session" ] || [ -L "$session" ]; then
      return 0
    fi
  done

  return 1
}

# Inspector cleanup never touches the scheduler WAN lock or production Stubby.
_CleanupInspectorSession_() {
  rm -f "$RUNTIME/inspection-$$.txt"

  if [ -n "${RG_INSPECT_DIR:-}" ]; then
    rm -rf "$RG_INSPECT_DIR"
  fi

  if [ "${RG_INSPECT_CONFIG_HELD:-0}" = 1 ]; then
    _ReleaseConfigLock_ >/dev/null 2>&1 || :
  fi
}

# Read-only lock classification for interactive status. Never reclaim a lock just
# to draw a menu, and never call synchronization from the header.
_GetWANLockDisplay_() {
  local owner
  if [ -e "$WAN_LOCK.reclaim" ] || [ -L "$WAN_LOCK.reclaim" ]; then
    _Say_ 'DNS OPERATION / LOCK IN PROGRESS'
    return 0
  fi
  if [ -e "$WAN_LOCK" ] || [ -L "$WAN_LOCK" ]; then
    if [ -d "$WAN_LOCK" ] && [ ! -L "$WAN_LOCK" ] &&
       [ -f "$WAN_LOCK/owner" ] && [ ! -L "$WAN_LOCK/owner" ]; then
      owner="$(cat "$WAN_LOCK/owner" 2>/dev/null || :)"
      case "$owner" in
        ''|*[!0-9]*) : ;;
        *) if kill -0 "$owner" 2>/dev/null; then
             _Say_ 'DNS OPERATION IN PROGRESS'
             return 0
           fi ;;
      esac
    fi
    _Say_ 'WAN LOCK NEEDS REVIEW'
    return 0
  fi
  return 1
}

# Policy review and revocation take the same interactive admission priority as
# maintenance. New cron cycles skip; a current WAN writer always finishes.
_AcquireWANLockForPolicy_() {
  if ! _AcquireWANLockWithInteractivePriority_ policy; then
    return 1
  fi

  RG_POLICY_WAN_HELD=1
  return 0
}

_ReleasePolicyWANLock_() {
  if [ "${RG_POLICY_WAN_HELD:-0}" != 1 ]; then
    return 0
  fi

  if ! _ReleaseWANLock_; then
    return 1
  fi

  RG_POLICY_WAN_HELD=0
  return 0
}

# Policy review also reads shared configuration. Hold CONFIG_LOCK only during
# its initial snapshot and final approval commit, never during user input.
_AcquireConfigLockForPolicy_() {
  local attempt

  attempt=1
  while [ "$attempt" -le 12 ]; do
    if _AcquireConfigLock_; then
      RG_POLICY_CONFIG_HELD=1
      return 0
    fi

    if [ "$attempt" -eq 1 ]; then
      _Say_ 'DNS policy: waiting for an active configuration edit to finish...'
    fi

    if [ "$attempt" -eq 12 ]; then
      break
    fi

    sleep 1
    attempt=$((attempt + 1))
  done

  _Fail_ 'Configuration lock still unavailable; policy administration deferred'
  return 1
}

_ReleasePolicyConfigLock_() {
  if [ "${RG_POLICY_CONFIG_HELD:-0}" != 1 ]; then
    return 0
  fi

  if ! _ReleaseConfigLock_; then
    return 1
  fi

  RG_POLICY_CONFIG_HELD=0
  return 0
}

# This is an EXIT cleanup for the policy-operation subshell. These ownership
# markers must not be local: BusyBox ash can run an EXIT trap after locals
# leave scope. Never remove another process's locks.
_CleanupPolicyLocks_() {
  _ReleasePolicyConfigLock_ >/dev/null 2>&1 || :
  _ReleasePolicyWANLock_ >/dev/null 2>&1 || :
  _ReleaseMaintenancePriority_ >/dev/null 2>&1 || :
}

# Resolve the human-readable identity of a checked resolver. The provider
# inventory already associates each temporary wanN/backupN ID with its actual
# address, TLS port and authentication hostname. Never expose SPKI pins.
_GetHealthResolverIdentity_() {
  local requested_id id address hostname tls_port extra

  requested_id="$1"
  RG_HEALTH_RESOLVER_ADDRESS=''
  RG_HEALTH_RESOLVER_TLS_PORT=''
  RG_HEALTH_RESOLVER_HOSTNAME=''

  if [ -z "${PROVIDERS:-}" ] || [ ! -r "$PROVIDERS" ] || [ -L "$PROVIDERS" ]; then
    return 1
  fi

  while IFS='|' read -r id address hostname tls_port extra; do
    if [ "$id" != "$requested_id" ]; then
      continue
    fi

    RG_HEALTH_RESOLVER_ADDRESS="$address"
    RG_HEALTH_RESOLVER_TLS_PORT="$tls_port"
    RG_HEALTH_RESOLVER_HOSTNAME="$hostname"
    return 0
  done < "$PROVIDERS"

  return 1
}

# Highlight health-check outcomes in an interactive terminal without changing
# the plain output used by cron, redirected commands or diagnostic logs.
# Include the resolver IP directly in manual results so wanN IDs do not require
# consulting the provider inventory manually.
_PrintHealthCheckResult_() {
  local result details displayed_details resolver_id

  result="$1"
  shift
  details="$*"
  displayed_details="$details"

  if [ "${RG_HEALTH_SHOW_RESOLVERS:-0}" = 1 ]; then
    resolver_id="${details%% *}"

    if _GetHealthResolverIdentity_ "$resolver_id"; then
      displayed_details="$resolver_id [$RG_HEALTH_RESOLVER_ADDRESS:$RG_HEALTH_RESOLVER_TLS_PORT]${details#"$resolver_id"}"
    fi

    if [ "$result" = FAIL ]; then
      RG_HEALTH_FAILED_RECORDS=$((RG_HEALTH_FAILED_RECORDS + 1))

      case " ${RG_HEALTH_FAILED_IDS:-} " in
        *" $resolver_id "*)
          ;;
        *)
          RG_HEALTH_FAILED_IDS="${RG_HEALTH_FAILED_IDS:+$RG_HEALTH_FAILED_IDS }$resolver_id"
          ;;
      esac

      # A resolver can fail during a preferred-pool recovery probe without
      # belonging to the active filtered pool. Preserve that distinction.
      RG_HEALTH_FAILURE_PHASES="${RG_HEALTH_FAILURE_PHASES:-}|$resolver_id:${RG_HEALTH_PROBE_PHASE:-active}|"
    fi
  fi

  if [ "${RG_HEALTH_COLOR_ENABLED:-0}" != 1 ]; then
    _Say_ "    $result $displayed_details"
    return 0
  fi

  case "$result" in
    PASS)
      # Keep successful detail lines neutral so a red failure stands out.
      printf '    %sPASS%s %s\n' "$RG_GREEN" "$RG_RESET" "$displayed_details"
      ;;
    FAIL)
      # Emphasize the entire failed check, including its reason.
      printf '    %sFAIL %s%s\n' "$RG_RED" "$displayed_details" "$RG_RESET"
      ;;
    *)
      _Say_ "    $result $displayed_details"
      ;;
  esac
}

# A short end-of-check summary keeps failed resolver identities on screen just
# before returning to the menu. This is presentation only: the probe result,
# failover decisions and monitoring counters are not derived from these lists.
_PrintManualHealthSummary_() {
  local resolver_id source phase_text failed_resolvers

  if [ "${RG_HEALTH_SHOW_RESOLVERS:-0}" != 1 ]; then
    return 0
  fi

  _Say_ ''
  _Say_ '----------------------------------------------------------------'
  _Say_ '  DNS HEALTH CHECK SUMMARY'
  _Say_ '----------------------------------------------------------------'

  if [ "${RG_HEALTH_FAILED_RECORDS:-0}" -eq 0 ]; then
    printf '  %sNo failed DNS record checks observed.%s\n' "$RG_GREEN" "$RG_RESET"
    return 0
  fi

  failed_resolvers=0
  for resolver_id in ${RG_HEALTH_FAILED_IDS:-}; do
    failed_resolvers=$((failed_resolvers + 1))
  done

  printf '  %sFAILED: %s resolver(s), %s DNS record check(s)%s\n' \
    "$RG_RED" "$failed_resolvers" "$RG_HEALTH_FAILED_RECORDS" "$RG_RESET"

  for resolver_id in ${RG_HEALTH_FAILED_IDS:-}; do
    source='address unavailable'
    if _GetHealthResolverIdentity_ "$resolver_id"; then
      source="$RG_HEALTH_RESOLVER_ADDRESS:$RG_HEALTH_RESOLVER_TLS_PORT"
    fi

    phase_text=''
    case "${RG_HEALTH_FAILURE_PHASES:-}" in
      *"|$resolver_id:active|"*)
        phase_text='active pool'
        ;;
    esac
    case "${RG_HEALTH_FAILURE_PHASES:-}" in
      *"|$resolver_id:preferred|"*)
        if [ -n "$phase_text" ]; then
          phase_text="$phase_text + preferred recovery"
        else
          phase_text='preferred recovery (not active)'
        fi
        ;;
    esac
    case "${RG_HEALTH_FAILURE_PHASES:-}" in
      *"|$resolver_id:alternate|"*)
        if [ -n "$phase_text" ]; then
          phase_text="$phase_text + alternate"
        else
          phase_text='alternate pool'
        fi
        ;;
    esac

    printf '  %s%-7s %s%s' "$RG_RED" "$resolver_id" "$source" "$RG_RESET"
    if [ -n "${RG_HEALTH_RESOLVER_HOSTNAME:-}" ]; then
      printf '  TLS: %s' "$RG_HEALTH_RESOLVER_HOSTNAME"
    fi
    if [ -n "$phase_text" ]; then
      printf '  [%s]' "$phase_text"
    fi
    printf '\n'
  done

  _Say_ '  See the red FAIL lines above for individual DNS response errors.'
}

_ProbeDNSRecord_() {
  local id qname qtype want_rcode want_count want_value output actual_rcode actual_count response_file
  id="$1"; qname="$2"; qtype="$3"; want_rcode="$4"; want_count="$5"; want_value="$6"
  # A certificate failure may return dig exit status 0: validate the full
  # authenticated transport response before consulting DNS policy fields.
  response_file="$RUNTIME/health-response-$$.txt"
  if ! _RunAuthenticatedDoTQuery_ "$id" "$qname" "$qtype" "$response_file" health; then
    _PrintHealthCheckResult_ FAIL "$id $qname $qtype: authenticated DoT error/timeout"
    rm -f "$response_file"
    return 1
  fi
  output="$(cat "$response_file")"
  rm -f "$response_file"
  actual_rcode="$(printf '%s\n' "$output" | sed -n 's/.*status: \([A-Z][A-Z0-9_]*\),.*/\1/p' | head -n 1)"
  actual_count="$(printf '%s\n' "$output" | awk '/^;; flags:/ { for(i=1;i<=NF;i++) if($i=="ANSWER:") {gsub(/,/,"",$(i+1)); print $(i+1); exit} }')"
  case "$actual_rcode:$actual_count" in
    :*|*:) _PrintHealthCheckResult_ FAIL "$id $qname $qtype: missing DNS header"; return 1 ;;
  esac
  case "$actual_count" in *[!0-9]*|'') _PrintHealthCheckResult_ FAIL "$id $qname $qtype: malformed answer count"; return 1;; esac
  # Policy mismatches are resolver-health evidence, not infrastructure faults.
  # Wrong Plex A/AAAA records must NOT enter a blanket INCONCLUSIVE veto.
  # Switching still requires corroboration and independently healthy alternatives.
  if [ "$want_rcode" != ANY ] && [ "$actual_rcode" != "$want_rcode" ]; then
    _PrintHealthCheckResult_ FAIL "$id $qname $qtype: RCODE $actual_rcode expected $want_rcode (policy mismatch)"
    return 1
  fi
  case "$want_count" in
    ANY)
      # The administrator explicitly chose to ignore the number of answers.
      ;;
    AT_LEAST_1)
      # DNS ANSWER includes aliases such as CNAME, so a nonzero header count
      # does not prove the requested A, AAAA or other record type was returned.
      if [ "$actual_count" -eq 0 ] ||
         ! _HasDNSAnswerRecord_ "$output" "$qtype" '-'; then
        _PrintHealthCheckResult_ FAIL "$id $qname $qtype: no $qtype answer record (expected at least 1; policy mismatch)"
        return 1
      fi
      ;;
    *)
      if [ "$actual_count" != "$want_count" ]; then
        _PrintHealthCheckResult_ FAIL "$id $qname $qtype: ANSWER count $actual_count expected $want_count (policy mismatch)"
        return 1
      fi
      ;;
  esac
  if [ "$want_value" != '-' ]; then
    if ! _HasDNSAnswerRecord_ "$output" "$qtype" "$want_value"; then
      _PrintHealthCheckResult_ FAIL "$id $qname $qtype: expected answer $want_value absent (policy mismatch)"
      return 1
    fi
  fi
  _PrintHealthCheckResult_ PASS "$id $qname $qtype: $actual_rcode answers=$actual_count"
  return 0
}


_NormalizeProbeHostname_() {
  local input host urlport
  input="$1"
  case "$input" in
    https://*) input="${input#https://}" ;;
    http://*) input="${input#http://}" ;;
    *://*) _Fail_ 'Only HTTP(S) URLs or bare hostnames are accepted (DNS only)'; return 2 ;;
  esac
  host="${input%%/*}"
  host="${host%%\?*}"
  host="${host%%\#*}"
  case "$host" in
    *'@'*|*'['*|*']'*) _Fail_ 'Userinfo and bracketed IPv6 URL hosts are not supported'; return 2 ;;
    *:*)
      urlport="${host#*:}"
      case "$urlport" in *:*) _Fail_ 'Invalid URL authority'; return 2 ;; esac
      _IsValidTLSPort_ "$urlport" || { _Fail_ 'Invalid URL port'; return 2; }
      host="${host%%:*}"
      ;;
  esac
  host="${host%.}"
  [ "${#host}" -le 253 ] &&
    printf '%s\n' "$host" | LC_ALL=C grep -Eq '^[_A-Za-z0-9-]+([.][_A-Za-z0-9-]+)*$' &&
    printf '%s\n' "$host" | awk -F. '{for (i=1;i<=NF;i++) if (length($i)>63) exit 1; exit 0}' || {
      _Fail_ 'Invalid DNS hostname in URL or input'; return 2;
    }
  printf '%s\n' "$host"
}


_GetInspectionAnswerRecords_() {
  awk '
    /^;; (ANSWER|AUTHORITY|ADDITIONAL) SECTION:/ {
      has_section=1
      in_answer=($2 == "ANSWER")
      next
    }
    /^;; / {next}
    !/^;/ && NF >= 5 && $2 ~ /^[0-9]+$/ && $3 == "IN" &&
      (in_answer || !has_section) {
        rec=$4
        for (i=5; i<=NF; i++) rec=rec " " $i
        printf "%s\t%s\n", $2, rec
      }
  ' "$1"
}

_InspectDNSResponse_() {
  local id hostname rr display file code count ttl policy_type
  local answers capturefile source_ip code_colour count_colour ttl_colour policy_colour first_value
  id="$1"; hostname="$2"; rr="$3"; display="$4"; capturefile="${5:-}"; source_ip="${6:-$id}"
  file="$RUNTIME/inspection-$$.txt"
  if ! _RunAuthenticatedDoTQuery_ "$id" "$hostname" "$rr" "$file" inspection; then
    printf '    %-6s %-10s %7s %7s  %s\n' "$rr" 'QUERY ERROR' '-' '-' '-'
    _Say_ '      ERROR: Authenticated DoT query failed, timed out or had no verified response.'
    [ "$display" = full ] && cat "$file"
    return 1
  fi
  code="$(sed -n 's/.*status: \([A-Z][A-Z0-9_]*\),.*/\1/p' "$file" | head -n 1)"
  count="$(awk '/^;; flags:/ {for(i=1;i<=NF;i++) if($i=="ANSWER:") {gsub(/,/,"",$(i+1)); print $(i+1); exit}}' "$file")"
  if [ -z "$code" ] || [ -z "$count" ]; then
    printf '    %-6s %-10s %7s %7s  %s\n' "$rr" 'BAD HEADER' '-' '-' '-'
    _Say_ '      ERROR: No valid DNS response header.'
    [ "$display" = full ] && cat "$file"
    return 1
  fi
  answers="$(_GetInspectionAnswerRecords_ "$file")"
  ttl="$(printf '%s\n' "$answers" | awk -F'\t' '
    $1 ~ /^[0-9]+$/ {if (!found || $1 < min) min=$1; found=1}
    END {if (found) printf "%ss",min; else print "-"}
  ')"
  policy_type='-'
  if [ -r "$CHECKS" ] && awk -F'|' -v n="$hostname" -v t="$rr" \
    '$1 !~ /^#/ && $1==n && $2==t {found=1; exit} END {exit !found}' "$CHECKS"; then
    policy_type='SET'
  fi
  case "$code" in
    NOERROR) code_colour="$RG_GREEN" ;;
    NXDOMAIN) code_colour="$RG_CYAN" ;; # Valid expected NXDOMAIN is possible.
    SERVFAIL|REFUSED|FORMERR|NOTIMP) code_colour="$RG_RED" ;;
    *) code_colour="$RG_YELLOW" ;;
  esac
  case "$count" in 0) count_colour="$RG_CYAN" ;; *) count_colour="$RG_GREEN" ;; esac
  ttl_colour="$RG_YELLOW"
  if [ "$policy_type" = SET ]; then policy_colour="$RG_GREEN"
  else policy_colour="$RG_YELLOW"; fi
  printf '    %-6s %s%-10s%s %s%7s%s %s%7s%s  %s%s%s\n' \
    "$rr" "$code_colour" "$code" "$RG_RESET" \
    "$count_colour" "$count" "$RG_RESET" \
    "$ttl_colour" "$ttl" "$RG_RESET" \
    "$policy_colour" "$policy_type" "$RG_RESET"
  if [ -n "$answers" ]; then
    printf '%s\n' "$answers" | awk -F'\t' -v data_color="$RG_CYAN" -v reset="$RG_RESET" '
      NF > 1 {
        shown++
        if (shown > 8) next
        data=$2
        label="      Data: "
        while (length(data) > 52) {
          printf "%s%s%s%s\n",label,data_color,substr(data,1,52),reset
          data=substr(data,53)
          label="            "
        }
        printf "%s%s%s%s\n",label,data_color,data,reset
      }
      END {if (shown>8) printf "      ... %d more records (use full view)\n",shown-8}
    '
  else
    if [ "$code" = NOERROR ] && [ "$count" = 0 ]; then
      printf '      Data: %s(none; NOERROR with no answer records)%s\n' "$RG_CYAN" "$RG_RESET"
    else
      printf '      Data: %s(no answer records)%s\n' "$RG_CYAN" "$RG_RESET"
    fi
  fi
  if [ "$policy_type" = SET ]; then
    awk -F'|' -v n="$hostname" -v t="$rr" -v col="$RG_CYAN" -v green="$RG_GREEN" -v reset="$RG_RESET" '
      $1 !~ /^#/ && $1==n && $2==t {
        printf "      Policy: %s%s%s expects %s%s%s / %s%s%s answer(s) / %s%s%s\n",green,$1,reset,col,$3,reset,col,$4,reset,col,$5,reset
      }
    ' "$CHECKS"
  else
    printf '      Policy: %sNOT MONITORED%s (no automatic failover from this query)\n' "$RG_YELLOW" "$RG_RESET"
  fi
  awk '/EDE:/ {sub(/^[;[:space:]]+/, ""); printf "      Extended error: %s\n",$0}' "$file"
  if [ "$display" = full ]; then
    _Say_ '      --- Full dig response ---'
    cat "$file"
    _Say_ '      --- End full response ---'
  fi
  if [ -n "$capturefile" ]; then
    case "$rr" in
      A|AAAA)
        first_value="$(printf '%s\n' "$answers" | awk -F '\t' -v kind="$rr" '
          index($2, kind " ")==1 {print substr($2,length(kind)+2); exit}')"
        if ! _IsSafeToken_ "$first_value"; then first_value='-'; fi
        printf '%s|%s|%s|%s|%s|%s\n' \
          "$source_ip" "$hostname" "$rr" "$code" "$count" "$first_value" >> "$capturefile" || return 1
        ;;
    esac
  fi
  return 0
}

_InspectDNS_() (
  local raw target requested type id ip tls tlsport extra rc rr display capturefile
  raw="${1:-}"; type="${2:-BOTH}"; requested="${3:-all}"
  capturefile="${5:-}"
  case "${4:-summary}" in
    [sS][uU][mM][mM][aA][rR][yY]) display=summary ;;
    [fF][uU][lL][lL]) display=full ;;
    *) _Fail_ "Output format must be summary or full (received: ${4:-<empty>})"; return 2 ;;
  esac
  [ -n "$raw" ] || { _Fail_ 'Usage: probe <hostname-or-HTTP(S)-URL> [BOTH|TYPE] [provider-id|all] [summary|full]'; return 2; }
  target="$(_NormalizeProbeHostname_ "$raw")" || return 2
  _SetMenuPalette_
  type="$(printf '%s\n' "$type" | awk '{print toupper($0)}')"
  case "$type" in
    BOTH|A+AAAA) type=BOTH ;;
    *) _IsValidRecordType_ "$type" || { _Fail_ "Invalid DNS record type: $type"; return 2; } ;;
  esac
  case "$requested" in ALL|all|'') requested=all ;; esac
  _RequireProbeDependencies_ || return 1

  # Short admission lock prevents a concurrent uninstall from removing shared
  # configuration before this inspector has acquired its private directory.
  RG_INSPECT_CONFIG_HELD=0
  RG_INSPECT_DIR=''
  trap '_CleanupInspectorSession_' EXIT HUP INT TERM
  inspect_try=1
  while ! _AcquireConfigLock_; do
    if [ "$inspect_try" -ge 6 ]; then
      _Fail_ 'Configuration commit or maintenance in progress; inspector start deferred'
      return 1
    fi
    sleep 1
    inspect_try=$((inspect_try + 1))
  done
  RG_INSPECT_CONFIG_HELD=1
  if [ -L "$RUNTIME/inspectors" ]; then return 1; fi
  mkdir -p "$RUNTIME/inspectors" || return 1
  RG_INSPECT_DIR="$RUNTIME/inspectors/$$"
  [ ! -e "$RG_INSPECT_DIR" ] && [ ! -L "$RG_INSPECT_DIR" ] || return 1
  mkdir "$RG_INSPECT_DIR" || return 1
  PROVIDERS="$RG_INSPECT_DIR/providers.tsv"
  _PrepareProviders_ || return 1
  if ! _ReleaseConfigLock_; then
    _Fail_ 'Inspector could not release short admission lock'
    return 1
  fi
  RG_INSPECT_CONFIG_HELD=0

  if [ "$requested" != all ]; then
    _IsValidID_ "$requested" && _GetProviderInfo_ "$requested" >/dev/null || {
      _Fail_ "Unknown configured provider: $requested (run discover)"; return 2;
    }
  fi
  if [ -n "$capturefile" ]; then
    [ -f "$capturefile" ] && [ ! -L "$capturefile" ] || {
      _Fail_ 'Unsafe inspector result file'; return 1; }
  fi
  _Say_ ''
  _Say_ '================ DNS RESPONSE INSPECTOR ================'
  printf 'DNS inspection: %s%s%s | types=%s%s%s | provider=%s%s%s\n' \
    "$RG_CYAN" "$target" "$RG_RESET" \
    "$RG_YELLOW" "$type" "$RG_RESET" \
    "$RG_CYAN" "$requested" "$RG_RESET"
  printf 'View: %s | Strict authenticated DNS-over-TLS | %sREAD ONLY%s\n' \
    "$display" "$RG_GREEN" "$RG_RESET"
  _Say_ 'RCODE/answer data are OBSERVED; policy expectations are not evaluated.'
  _Say_ '--------------------------------------------------------'
  rc=0
  while IFS='|' read -r id ip tls tlsport extra; do
    [ -n "$id" ] || continue
    [ "$requested" = all ] || [ "$requested" = "$id" ] || continue
    _Say_ ''
    _Say_ '--------------------------------------------------------'
    printf '  %s%s:%s%s  (Strict DoT)\n' \
      "$RG_CYAN" "$ip" "$tlsport" "$RG_RESET"
    printf '  TLS authentication: %s%s%s\n' "$RG_CYAN" "$tls" "$RG_RESET"
    _Say_ ''
    _Say_ '    TYPE   RCODE       ANSWERS     TTL  POLICY'
    _Say_ '    ------ ---------- ------- -------  ------'
    if [ "$type" = BOTH ]; then
      for rr in A AAAA; do
        _InspectDNSResponse_ "$id" "$target" "$rr" "$display" "$capturefile" "$ip" || rc=1
        [ "$display" = summary ] && _Say_ ''
      done
    else
      _InspectDNSResponse_ "$id" "$target" "$type" "$display" "$capturefile" "$ip" || rc=1
    fi
  done < "$PROVIDERS"
  _Say_ ''
  _Say_ 'Inspection completed without changing configuration, WAN DNS, or failure counters.'
  [ "$display" = summary ] && _Say_ 'For raw headers/authority/EDE details: probe <host> BOTH all full'
  return "$rc"
)


# Parse *every* resolver, then validate every address before emitting any
# result. Avoid accepting a valid IPv4 prefix when a later IPv6 entry is bad.
# Preserve the exact serialized NVRAM list for snapshots, filters and rollback.
_ParseDNSRulelist_() {
  local parsed ip port host pin format rest

  # Parse the entire NVRAM list before producing any output. A later invalid
  # entry must invalidate the entire list, not leave a usable partial prefix.
  # The parsed text stays shell-local, so nested calls need no shared tmp file.
  parsed="$(awk '
    BEGIN {
      FS = "<"
      OFS = "|"
      err = 0
    }

    {
      if ($1 != "") {
        err = 1
      }

      for (i = 2; i <= NF; i++) {
        if ($i == "") {
          err = 1
          break
        }

        fields = split($i, record, ">")
        if (fields != 3 && fields != 4) {
          err = 1
          break
        }

        if (expected == 0) {
          expected = fields
        }

        # An empty ASUS GUI TLS port means 853. Normalize comparison only;
        # the original rulelist (including pin) remains untouched on disk.
        if (record[2] == "") {
          record[2] = "853"
        }

        if (fields != expected || record[1] == "" || record[3] == "") {
          err = 1
          break
        }
        if (record[1] !~ /^[0-9A-Fa-f:.]+$/ ||
            record[2] !~ /^[0-9]+$/ ||
            record[3] !~ /^[A-Za-z0-9.-]+$/) {
          err = 1
          break
        }

        pin = (fields == 4 ? record[4] : "")
        print record[1], record[2], record[3], pin, fields
        count++
      }
    }

    END {
      if (err || count == 0) {
        exit 1
      }
    }
  ')" || return 1

  if [ -z "$parsed" ]; then
    return 1
  fi

  # Validate the complete parsed list before emitting it to any caller.
  # Here-doc input avoids the shell state loss associated with a pipeline.
  while IFS='|' read -r ip port host pin format rest; do
    if ! _IsValidIP_ "$ip" || ! _IsValidTLSPort_ "$port" ||
       ! _IsValidDomain_ "$host" || [ -n "${rest:-}" ]; then
      return 1
    fi
  done <<RG_PARSED_RULELIST
$parsed
RG_PARSED_RULELIST

  printf '%s\n' "$parsed"
}

# Prevent accidental reuse of an old, partial preferred snapshot on a
# previously IPv4-only build. Refuse all managed switching until the saved
# provider roster exactly represents the entire original NVRAM serialization.
_ValidatePreferredSnapshot_() {
  local parsed

  # Both halves of the preferred snapshot must be complete and regular files.
  if [ ! -s "$PREF_RULELIST" ] || [ ! -s "$PREF_PROVIDERS" ] ||
     [ -L "$PREF_RULELIST" ] || [ -L "$PREF_PROVIDERS" ]; then
    return 1
  fi

  parsed="$RUNTIME/validate-preferred-$$"
  if [ -e "$parsed" ] || [ -L "$parsed" ]; then
    return 1
  fi

  if ! _ParseDNSRulelist_ < "$PREF_RULELIST" > "$parsed"; then
    rm -f "$parsed"
    return 1
  fi

  # Match the complete router list to the saved providers, in exactly the
  # same order. Case-folded identity comparisons support IPv6 hexadecimal.
  if ! awk -F'|' '
    NR == FNR {
      original[++expected_count] = $1 "|" $2 "|" $3
      next
    }

    {
      if ($1 !~ /^wan[0-9]+$/ || NF != 5) {
        invalid = 1
      } else {
        saved_count++
        expected_id = "wan" saved_count
        observed_identity = tolower($2 "|" $5 "|" $3)
        expected_identity = tolower(original[saved_count])
        if ($1 != expected_id || expected_identity != observed_identity) {
          invalid = 1
        }
      }
    }

    END {
      if (invalid || saved_count == 0 || saved_count != expected_count) {
        exit 1
      }
    }
  ' "$parsed" "$PREF_PROVIDERS"; then
    rm -f "$parsed"
    return 1
  fi

  rm -f "$parsed"
}

_IsStrictProductionDoT_() {
  [ -r "$WAN_STUBBY_CONFIG" ] || return 1
  grep -q '^tls_authentication: GETDNS_AUTHENTICATION_REQUIRED' "$WAN_STUBBY_CONFIG" || return 1
  awk '
    /^dns_transport_list:/ {found=1; inside=1; next}
    inside && /^  - / {if ($2 != "GETDNS_TRANSPORT_TLS") bad=1; tls++ ; next}
    inside && /^[^[:space:]]/ {inside=0}
    END{exit(found && tls==1 && !bad)?0:1}
  ' "$WAN_STUBBY_CONFIG"
}

_ReadNVRAM_() { nvram get "$1"; }

_GetRouterIPv6Mode_() {
  local service
  service="$(_ReadNVRAM_ ipv6_service 2>/dev/null)" || { _Say_ unknown; return 0; }
  case "$service" in
    disabled) _Say_ disabled ;;
    '') _Say_ unknown ;;
    *) _Say_ enabled ;;
  esac
}

# Only initialize a bundled default policy; never rewrite customized checks.
_InitializeDefaultDNSPolicy_() {
  local mode
  mode="$(_GetRouterIPv6Mode_)"
  if [ "$mode" = enabled ] && [ ! -e "$POLICY_APPROVAL" ] && [ ! -L "$POLICY_APPROVAL" ] && awk -F'|' '
      $0 !~ /^#/ && NF {n++; if ($0 != "a.root-servers.net|A|NOERROR|AT_LEAST_1|-") bad=1}
      END {exit !(n==1 && !bad)}' "$CHECKS"; then
    _ChangeTSVFile_ "$CHECKS" check add 'a.root-servers.net|AAAA' \
      'a.root-servers.net|AAAA|NOERROR|ANY|-' >/dev/null || return 1
  fi
  case "$mode" in
    enabled) _Say_ '  Router IPv6: Enabled' ;;
    disabled) _Say_ '  Router IPv6: Disabled' ;;
    *) _Say_ '  Router IPv6: Unknown (using IPv4-first defaults)' ;;
  esac
}

# No NVRAM commit: managed failovers are temporary across router restarts.
_ReadWANRulelist_() { _ReadNVRAM_ dnspriv_rulelist; }

# The preferred endpoint list stays stable even while production uses backups.
_EnrollPreferredDNS_() {
  local raw parsed expected count
  if [ -e "$PREF_RULELIST" ] || [ -e "$PREF_PROVIDERS" ]; then
    if [ -r "$PREF_RULELIST" ] && [ -r "$PREF_PROVIDERS" ]; then
      if ! _ValidatePreferredSnapshot_; then
        _Fail_ 'Existing preferred DNS snapshot does not represent a complete IPv4/IPv6 resolver list; re-enrollment required'
        return 1
      fi
      _Say_ 'Preferred WAN snapshot already enrolled; not overwriting it.'
      return 0
    fi
    _Fail_ 'Incomplete preferred WAN snapshot; refusing to overwrite or proceed'
    return 1
  fi
  [ "$(_ReadNVRAM_ dnspriv_enable)" = 1 ] || { _Fail_ 'DNS Privacy must be enabled before enrollment'; return 1; }
  _IsStrictProductionDoT_ || { _Fail_ 'Production WAN Stubby must be Strict TLS before enrollment'; return 1; }
  _ValidateConfiguration_ || return 1
  raw="$(_ReadWANRulelist_)"
  parsed="$RUNTIME/enroll-rulelist-$$"
  printf '%s\n' "$raw" | _ParseDNSRulelist_ > "$parsed" || { rm -f "$parsed"; _Fail_ 'Unrecognized dnspriv_rulelist serialization'; return 1; }
  count="$(wc -l < "$parsed" | tr -d ' ')"
  expected="$(awk -F'|' '$1 ~ /^wan[0-9]+$/ {n++} END{print n+0}' "$PROVIDERS")"
  [ "$count" = "$expected" ] || { rm -f "$parsed"; _Fail_ 'WAN NVRAM and generated Stubby provider counts disagree'; return 1; }
  if ! awk -F'|' 'NR==FNR {a[FNR]=$2"|"$4"|"$3; next}
      {if (tolower(a[FNR]) != tolower($1"|"$2"|"$3)) bad=1; n++}
      END {exit bad?1:0}' "$PROVIDERS" "$parsed"; then
    rm -f "$parsed"; _Fail_ 'WAN NVRAM and Stubby provider order differ'; return 1
  fi
  mkdir -p "$STATE_DIR" || { rm -f "$parsed"; return 1; }
  # Durable schema-5 snapshots retain a numeric, historical listener-port
  # column for safe rollback to older builds. Direct DoT does not bind or use
  # these values, and its runtime inventory has no listener-port column.
  (umask 077; printf '%s\n' "$raw" > "$PREF_RULELIST.new.$$";     awk -F'|' '$1 ~ /^wan[0-9]+$/ {printf "%s|%s|%s|%d|%s\n",$1,$2,$3,53053+substr($1,4),$4}' "$PROVIDERS" > "$PREF_PROVIDERS.new.$$") || return 1
  mv "$PREF_RULELIST.new.$$" "$PREF_RULELIST" || return 1
  mv "$PREF_PROVIDERS.new.$$" "$PREF_PROVIDERS" || return 1
  rm -f "$parsed"
  _Say_ 'Captured the preferred router-wide WAN DoT list and its identities.'
  _Say_ 'No WAN, DNSMasq, DNS Director, or production Stubby setting was changed.'
}

# Rebuild the *entire* preferred upstream list from the live ASUS DNS Privacy
# rulelist and the active production Stubby config. Do not use previously saved
# provider identities when validating a GUI change.
_BuildLivePreferredProviders_() {
  local raw output parsed live ip port name format extra n
  raw="$1"; output="$2"
  parsed="$RUNTIME/sync-parsed-$$"; live="$RUNTIME/sync-live-$$"
  [ ! -e "$parsed" ] && [ ! -L "$parsed" ] &&
    [ ! -e "$live" ] && [ ! -L "$live" ] || return 1
  printf '%s\n' "$raw" | _ParseDNSRulelist_ > "$parsed" || {
    rm -f "$parsed"; _Fail_ 'Changed WAN DNS rulelist cannot be parsed'; return 1; }
  _ParseWANUpstreams_ > "$live" || {
    rm -f "$parsed" "$live"; return 1; }
  [ -s "$live" ] && [ -s "$parsed" ] || {
    rm -f "$parsed" "$live"; return 1; }
  # Every IPv4/IPv6 endpoint, TLS port, and hostname must agree in order.
  if ! awk -F'|' 'NR==FNR {a[FNR]=$1"|"$2"|"$3; m++; next}
      {n++; if (tolower(a[FNR])!=tolower($1"|"$3"|"$2)) bad=1}
      END {exit (bad || n!=m || n==0)?1:0}' "$parsed" "$live"; then
    rm -f "$parsed" "$live"
    _Fail_ 'WAN NVRAM and production Stubby resolver identity/order do not agree'
    return 1
  fi
  : > "$output" || { rm -f "$parsed" "$live"; return 1; }
  n=0
  while IFS='|' read -r ip port name extra format; do
    _IsValidIP_ "$ip" && _IsValidTLSPort_ "$port" &&
      _IsValidDomain_ "$name" && [ -n "$format" ] || {
        rm -f "$parsed" "$live" "$output"
        _Fail_ 'Only complete, validated IPv4/IPv6 Strict DoT resolver identities can be adopted'
        return 1
      }
    n=$((n+1))
    # Keep numeric legacy snapshot metadata compatible with older releases.
    # No localhost socket or temporary Stubby process uses this value.
    printf 'wan%s|%s|%s|%s|%s\n' "$n" "$ip" "$name" "$((53053+n))" "$port" >> "$output" || {
      rm -f "$parsed" "$live" "$output"; return 1; }
  done < "$parsed"
  rm -f "$parsed" "$live"
  [ "$n" -gt 0 ]
}

# Caller owns WAN_LOCK. Adopt only externally edited, fully verified Strict DoT
# state. Never touch NVRAM; block known managed transactions and unknown recovery.
# An on-disk intent allows a later check to complete a two-file snapshot update
# safely if power is lost between writes. Existing policy approval is NOT renewed.
_SyncPreferredWANLocked_() {
  local raw candidates staging changed
  if [ ! -e "$PREF_RULELIST" ] && [ ! -L "$PREF_RULELIST" ] &&
     [ ! -e "$PREF_PROVIDERS" ] && [ ! -L "$PREF_PROVIDERS" ]; then
    return 0  # Initial enrollment remains the job of Quick Setup.
  fi
  [ -s "$PREF_RULELIST" ] && [ -s "$PREF_PROVIDERS" ] &&
    [ -f "$PREF_RULELIST" ] && [ -f "$PREF_PROVIDERS" ] &&
    [ ! -L "$PREF_RULELIST" ] && [ ! -L "$PREF_PROVIDERS" ] || {
      _Fail_ 'Incomplete or unsafe preferred snapshot; synchronization blocked'; return 1; }
  [ ! -e "$PENDING_TRANSACTION" ] && [ ! -L "$PENDING_TRANSACTION" ] &&
    [ ! -e "$RECOVERY_HOLD" ] && [ ! -L "$RECOVERY_HOLD" ] || {
      _Fail_ 'Unresolved WAN transaction/recovery hold; preferred snapshot preserved'; return 1; }
  [ "$(_ReadNVRAM_ dnspriv_enable)" = 1 ] &&
    [ "$(_ReadNVRAM_ dnspriv_profile)" = 1 ] && _IsStrictProductionDoT_ || {
      _Fail_ 'Strict authenticated production DoT not verified; cannot adopt WAN change'; return 1; }
  raw="$(_ReadWANRulelist_)" || return 1
  [ -n "$raw" ] || return 1
  # A currently tracked ResolvGuard backup is not an external GUI change.
  if [ "$raw" != "$(cat "$PREF_RULELIST")" ] &&
     { [ -e "$ACTIVE_POOL" ] || [ -L "$ACTIVE_POOL" ] ||
       [ -e "$ACTIVE_RULELIST" ] || [ -L "$ACTIVE_RULELIST" ]; }; then
    [ -f "$ACTIVE_POOL" ] && [ ! -L "$ACTIVE_POOL" ] &&
      [ -f "$ACTIVE_RULELIST" ] && [ ! -L "$ACTIVE_RULELIST" ] || {
        _Fail_ 'Incomplete managed backup ownership; cannot auto-adopt'; return 1; }
    if [ "$raw" = "$(cat "$ACTIVE_RULELIST")" ]; then return 0; fi
  fi
  candidates="$RUNTIME/sync-candidate-$$"
  [ ! -e "$candidates" ] && [ ! -L "$candidates" ] || return 1
  _BuildLivePreferredProviders_ "$raw" "$candidates" || return 1
  # An ASUS GUI change can still be settling while Stubby restarts. Re-check
  # after the file comparison, not after writing the saved state.
  if [ "$raw" != "$(_ReadWANRulelist_)" ] || ! _IsStrictProductionDoT_; then
    rm -f "$candidates"
    _Fail_ 'WAN configuration changed during synchronization; retry next check'
    return 1
  fi
  changed=1
  if [ "$raw" = "$(cat "$PREF_RULELIST")" ] &&
     awk -F'|' '
       NR==FNR {identity[FNR]=$1 "|" tolower($2) "|" tolower($3) "|" tolower($5); expected++; next}
       {observed++; if (identity[FNR] != $1 "|" tolower($2) "|" tolower($3) "|" tolower($5)) mismatch=1}
       END {exit (mismatch || observed!=expected || observed==0)?1:0}
     ' "$PREF_PROVIDERS" "$candidates"; then changed=0; fi
  if [ "$changed" -eq 0 ] && [ ! -e "$PREFERRED_SYNC" ] && [ ! -L "$PREFERRED_SYNC" ]; then
    # A manual GUI return to the enrolled preferred pool clears stale tracking.
    if [ -e "$ACTIVE_POOL" ] || [ -e "$ACTIVE_RULELIST" ]; then
      [ ! -L "$ACTIVE_POOL" ] && [ ! -L "$ACTIVE_RULELIST" ] || {
        rm -f "$candidates"; return 1; }
      rm -f "$ACTIVE_POOL" "$ACTIVE_RULELIST" || {
        rm -f "$candidates"; return 1; }
    fi
    rm -f "$candidates"
    return 0
  fi
  [ ! -L "$PREFERRED_SYNC" ] || { rm -f "$candidates"; return 1; }
  if [ -e "$PREFERRED_SYNC" ]; then
    [ -d "$PREFERRED_SYNC" ] &&
      [ -f "$PREFERRED_SYNC/rulelist" ] &&
      [ -f "$PREFERRED_SYNC/providers" ] &&
      [ ! -L "$PREFERRED_SYNC/rulelist" ] &&
      [ ! -L "$PREFERRED_SYNC/providers" ] &&
      [ "$raw" = "$(cat "$PREFERRED_SYNC/rulelist")" ] &&
      cmp -s "$candidates" "$PREFERRED_SYNC/providers" || {
        rm -f "$candidates"
        _Fail_ 'Incomplete/interrupted preferred synchronization; WAN change not accepted'
        return 1
      }
  else
    staging="$STATE_DIR/.preferred-sync-$$"
    [ ! -e "$staging" ] && [ ! -L "$staging" ] || {
      rm -f "$candidates"; return 1; }
    (umask 077; mkdir "$staging" &&
      printf '%s\n' "$raw" > "$staging/rulelist" &&
      cp "$candidates" "$staging/providers") || {
        rm -rf "$staging"; rm -f "$candidates"; return 1; }
    mv "$staging" "$PREFERRED_SYNC" || {
      rm -rf "$staging"; rm -f "$candidates"; return 1; }
  fi
  # Two replaces are not atomic as a pair. The intent remains until both
  # commits succeed, making the operation retryable after interruption.
  (umask 077; cp "$PREFERRED_SYNC/rulelist" "$PREF_RULELIST.new.$$" &&
    cp "$PREFERRED_SYNC/providers" "$PREF_PROVIDERS.new.$$") || {
      rm -f "$PREF_RULELIST.new.$$" "$PREF_PROVIDERS.new.$$" "$candidates"; return 1; }
  mv "$PREF_RULELIST.new.$$" "$PREF_RULELIST" &&
    mv "$PREF_PROVIDERS.new.$$" "$PREF_PROVIDERS" || {
      rm -f "$PREF_RULELIST.new.$$" "$PREF_PROVIDERS.new.$$" "$candidates"; return 1; }
  rm -f "$PREFERRED_SYNC/rulelist" "$PREFERRED_SYNC/providers" &&
    rmdir "$PREFERRED_SYNC" || { rm -f "$candidates"; return 1; }
  rm -f "$candidates" "$ACTIVE_POOL" "$ACTIVE_RULELIST" \
    "$RUNTIME/syslog-health-state" "$RUNTIME/last-healthy-syslog" "$MEMBER_HISTORY" || return 1
  failures=0; recoveries=0
  _WriteMonitoringState_ || return 1
  _LogEvent_ notice 'DNS PREFERRED UPDATED: adopted current ASUS WAN Strict DoT resolver list without WAN writes; policy approval must be renewed before unattended failover'
  return 0
}

_SyncPreferredWAN_() (
  if ! _AcquireWANLock_; then return 1; fi
  trap '_ReleaseWANLock_ >/dev/null 2>&1 || :' EXIT HUP INT TERM
  _SyncPreferredWANLocked_
)

# A filtered WAN pool is an exact, ordered subset of the user's original
# authenticated WAN rulelist. Never synthesize identities or strip TLS pins.
_IsPreferredSubsetRulelist_() {
  local proposed
  proposed="$1"
  [ -s "$PREF_RULELIST" ] && [ -n "$proposed" ] || return 1
  printf '%s\n' "$proposed" | _ParseDNSRulelist_ >/dev/null || return 1
  awk -v original="$(cat "$PREF_RULELIST")" -v candidate="$proposed" 'BEGIN {
    total=split(original, a, "<"); n=split(candidate, b, "<")
    if (a[1]!="" || b[1]!="" || n<2 || n>=total) exit 1
    j=2
    for (i=2;i<=n;i++) {
      while (j<=total && a[j]!=b[i]) j++
      if (j>total) exit 1
      j++
    }
    exit 0
  }'
}

# During a switch the durable transaction is the source of truth for the
# candidate; after commit the owned active-rulelist is the source of truth.
_GetFilteredRulelist_() {
  local pool value
  pool="$1"
  case "$pool" in filtered1|filtered2) :;; *) return 1;; esac
  if [ -f "$PENDING_TRANSACTION/to-pool" ] &&
     [ ! -L "$PENDING_TRANSACTION" ] &&
     [ ! -L "$PENDING_TRANSACTION/to-pool" ] &&
     [ ! -L "$PENDING_TRANSACTION/to-rulelist" ] &&
     [ "$(cat "$PENDING_TRANSACTION/to-pool")" = "$pool" ]; then
    value="$(cat "$PENDING_TRANSACTION/to-rulelist")" || return 1
  elif [ -f "$ACTIVE_POOL" ] && [ -f "$ACTIVE_RULELIST" ] &&
       [ ! -L "$ACTIVE_POOL" ] && [ ! -L "$ACTIVE_RULELIST" ] &&
       [ "$(cat "$ACTIVE_POOL")" = "$pool" ]; then
    value="$(cat "$ACTIVE_RULELIST")" || return 1
  else
    return 1
  fi
  _IsPreferredSubsetRulelist_ "$value" || return 1
  printf '%s\n' "$value"
}

# Compare a managed subset against the exact enrolled ASUS WAN rulelist.
# Match complete serialized records, including any SPKI pin, but return only
# the endpoint identity for display. Pins must not be copied into syslog.
_ListExcludedPreferredDNSMembers_() {
  local active preferred

  active="$1"

  if [ ! -s "$PREF_RULELIST" ] || [ -L "$PREF_RULELIST" ]; then
    return 1
  fi

  preferred="$(cat "$PREF_RULELIST")" || return 1

  awk -v preferred="$preferred" -v active="$active" '
    BEGIN {
      active_count = split(active, active_members, "<")
      preferred_count = split(preferred, preferred_members, "<")

      for (i = 2; i <= active_count; i++) {
        active_inventory[active_members[i]]++
      }

      for (i = 2; i <= preferred_count; i++) {
        entry = preferred_members[i]

        if (active_inventory[entry] > 0) {
          active_inventory[entry]--
          continue
        }

        field_count = split(entry, fields, ">")
        if (field_count != 3 && field_count != 4) {
          exit 1
        }

        port = fields[2]
        if (port == "") {
          port = "853"
        }

        printf "%s|%s|%s\n", fields[1], port, fields[3]
      }
    }
  '
}

# Emit details only after a verified WAN switch (not on each cron probe).
# filtered1/filtered2 are rotating state labels, not permanent server lists.
_LogFilteredDNSMembership_() {
  local old_pool new_pool previous desired excluded count active_count preferred_count
  local address port tls_hostname

  old_pool="$1"
  new_pool="$2"
  previous="$3"
  desired="$4"

  case "$new_pool" in
    filtered1|filtered2)
      excluded="$(_ListExcludedPreferredDNSMembers_ "$desired")" || return 1
      ;;
    preferred)
      case "$old_pool" in
        filtered1|filtered2)
          excluded="$(_ListExcludedPreferredDNSMembers_ "$previous")" || return 1
          ;;
        *)
          return 0
          ;;
      esac
      ;;
    *)
      return 0
      ;;
  esac

  count="$(printf '%s\n' "$excluded" | awk 'NF { n++ } END { print n + 0 }')"
  preferred_count="$(awk -F '<' '{ print NF - 1; exit }' "$PREF_RULELIST")"
  active_count="$(printf '%s\n' "$desired" | awk -F '<' '{ print NF - 1; exit }')"

  if [ "$new_pool" = preferred ]; then
    _LogEvent_ notice "DNS FILTERED RECOVERY: pool=preferred; restored=$count; active=$active_count/$preferred_count"
  else
    _LogEvent_ notice "DNS FILTERED MEMBERSHIP: pool=$new_pool; active=$active_count/$preferred_count; excluded=$count"
  fi

  if [ -z "$excluded" ]; then
    return 0
  fi

  while IFS='|' read -r address port tls_hostname; do
    if [ "$new_pool" = preferred ]; then
      _LogEvent_ notice "DNS RESOLVER RESTORED: address=$address port=$port tls_auth=$tls_hostname"
    else
      _LogEvent_ warning "DNS RESOLVER EXCLUDED: pool=$new_pool address=$address port=$port tls_auth=$tls_hostname"
    fi
  done <<EOF_EXCLUDED_MEMBERS
$excluded
EOF_EXCLUDED_MEMBERS
}

# Construct the filtered list directly from the original NVRAM serialization.
# The ID file contains only confirmed healthy wanN member IDs.
_BuildFilteredRulelistFromMembers_() {
  local ids candidate
  ids="$1"
  [ -s "$ids" ] || return 1
  candidate="$(awk -F'<' 'NR==FNR {
      if ($1 !~ /^wan[0-9]+$/ || seen[$1]++) {bad=1; next}
      indexnum=substr($1,4)+0; keep[indexnum]=1; next
    }
    { if (bad || $1!="") exit 1; for (i=2;i<=NF;i++) if (keep[i-1]) printf "<%s",$i }
    END {print ""}' "$ids" "$PREF_RULELIST")" || return 1
  _IsPreferredSubsetRulelist_ "$candidate" || return 1
  printf '%s\n' "$candidate"
}

# Observe each active upstream independently. Confirmed DNS answer mismatches,
# SERVFAIL and timeout are resolver failures, not infrastructure conditions.
_ProbeWANMemberStatuses_() {
  local pool destination members id ip tls tport extra qname qtype rcode count value result state overall
  pool="$1"; destination="$2"; overall=0
  members="$RUNTIME/wan-members-$$"
  : > "$destination" || return 1
  _GetPoolMembers_ "$pool" > "$members" || { rm -f "$members" "$destination"; return 1; }
  [ -s "$members" ] || { rm -f "$members" "$destination"; return 1; }
  while IFS='|' read -r id ip tls tport extra; do
    state=PASS
    while IFS='|' read -r qname qtype rcode count value extra; do
      case "$qname" in ''|\#*) continue;; esac
      if _ProbeDNSRecord_ "$id" "$qname" "$qtype" "$rcode" "$count" "$value"; then :
      else
        result=$?
        if [ "$result" -eq 2 ]; then state=INCONCLUSIVE
        elif [ "$state" = PASS ]; then state=FAIL
        fi
      fi
    done < "${RG_MONITOR_CHECKS:-$CHECKS}"
    printf '%s|%s\n' "$id" "$state" >> "$destination" || { rm -f "$members"; return 1; }
    if [ "$state" = INCONCLUSIVE ]; then overall=2
    elif [ "$state" = FAIL ] && [ "$overall" -eq 0 ]; then overall=1
    fi
  done < "$members"
  rm -f "$members"
  return "$overall"
}

# Record up to six independent observations per active WAN member in /tmp.
# A single PASS must not erase evidence of intermittent FAIL. No JFFS writes.
# The fingerprint changes with either the live WAN rulelist or approved checks,
# and prevents stale histories authorizing a later unrelated pool/configuration.
_UpdateWANHistory_() {
  local pool first second fingerprint previous step next data source now last ttl
  pool="$1"; first="$2"; second="${3:-}"
  now="$(date -u +%s 2>/dev/null)" || return 1
  case "$now" in ''|*[!0-9]*) return 1;; esac
  ttl=$((SCHEDULE_INTERVAL_MINUTES * 60 * 9))
  [ "$ttl" -ge 600 ] || ttl=600
  fingerprint="$({ _ReadWANRulelist_; cat "${RG_MONITOR_CHECKS:-$CHECKS}"; printf '%s\n' "$pool"; } | _SHA256Digest_ 2>/dev/null)" || return 1
  case "$fingerprint" in ''|*[!0-9a-f]*) return 1;; esac
  previous="$RUNTIME/member-history-old-$$"
  : > "$previous" || return 1
  if [ -f "$MEMBER_HISTORY" ] && [ ! -L "$MEMBER_HISTORY" ] &&
     [ "$(sed -n '1p' "$MEMBER_HISTORY")" = "#scope=$fingerprint" ]; then
    last="$(sed -n '2s/^#observed_at=//p' "$MEMBER_HISTORY")"
    case "$last" in ''|*[!0-9]*) last=0;; esac
    if [ "$now" -ge "$last" ] && [ $((now-last)) -le "$ttl" ]; then
      sed '1,2d' "$MEMBER_HISTORY" > "$previous" || return 1
    fi
  fi
  for source in "$first" "$second"; do
    [ -n "$source" ] || continue
    [ -f "$source" ] && [ ! -L "$source" ] || { rm -f "$previous"; return 1; }
    next="$RUNTIME/member-history-next-$$"
    awk -F'|' '
      FILENAME==ARGV[1] {if ($1 ~ /^wan[0-9]+$/ && $2 ~ /^[PFU]+$/ && length($2)<=6) h[$1]=$2; next}
      {
        if (NF!=2 || $1 !~ /^wan[0-9]+$/ || seen[$1]++) {bad=1; next}
        if ($2=="PASS") x="P"
        else if ($2=="FAIL") x="F"
        else if ($2=="INCONCLUSIVE") x="U"
        else {bad=1; next}
        v=h[$1] x
        if (length(v)>6) v=substr(v,length(v)-5)
        print $1 "|" v
        n++
      }
      END {if (bad || n==0) exit 1}
    ' "$previous" "$source" > "$next" || {
      rm -f "$previous" "$next"; return 1;
    }
    mv "$next" "$previous" || { rm -f "$previous" "$next"; return 1; }
  done
  step="$MEMBER_HISTORY.new.$$"
  { printf '#scope=%s\n#observed_at=%s\n' "$fingerprint" "$now"; cat "$previous"; } > "$step" || {
    rm -f "$previous" "$step"; return 1;
  }
  [ ! -L "$MEMBER_HISTORY" ] && mv "$step" "$MEMBER_HISTORY" || {
    rm -f "$previous" "$step"; return 1;
  }
  rm -f "$previous"
  return 0
}

# A flapping member needs at least three failed observations in the latest
# six AND a failure in this cycle. Transient F/P is retained as suspicion;
# it is not immediate permission to change the WAN. Must still have PASS/PASS
# survivor or a separately verified alternative.
_HasIntermittentFailureEvidence_() {
  local history
  history="$1"
  [ -f "$history" ] && [ ! -L "$history" ] || return 1
  awk -F'|' 'NR>2 && NF==2 && $1 ~ /^wan[0-9]+$/ {
    n=split($2,x,""); f=0
    for(i=1;i<=n;i++) if(x[i]=="F") f++
    if (f>=3) found=1
  } END {exit found?0:1}' "$history"
}

# Classify each WAN member across independent observations. Exclude a member
# that failed both current checks OR has at least three failures in its latest
# six observations with a failure in this cycle. Keep other changing members,
# but NEVER count them as verified healthy; at least one PASS/PASS must remain.
# No malformed/inconclusive, unexpected, duplicated or reordered member may be
# used to authorize a WAN write. Output IDs are in original member order.
# Returns: 0=excludable subset, 1=no confirmed failures, 2=unsafe policy/data,
#          3=all members confirmed failed (eligible for alternate evaluation),
#          4=no independently confirmed healthy survivor.
_PlanConfirmedWANExclusion_() {
  local rc
  : > "$3" || return 2
  awk -F'|' -v history="${4:-/dev/null}" '
    BEGIN {
      while ((getline entry < history)>0) {
        if (entry ~ /^#/) continue
        split(entry, fields, "|")
        if (fields[1] ~ /^wan[0-9]+$/ && fields[2] ~ /^[PFU]+$/ && length(fields[2])<=6) {
          h[fields[1]]=fields[2]
        }
      }
      close(history)
    }
    NR==FNR {
      if (NF!=2 || $1 !~ /^wan[0-9]+$/ || seen_first[$1]++ ||
          ($2!="PASS" && $2!="FAIL" && $2!="INCONCLUSIVE")) bad=1
      first[$1]=$2; order[FNR]=$1; n++
      next
    }
    {
      if (NF!=2 || $1 !~ /^wan[0-9]+$/ || seen_second[$1]++ ||
          ($2!="PASS" && $2!="FAIL" && $2!="INCONCLUSIVE") ||
          order[FNR]!=$1) bad=1
      second[$1]=$2; m++
    }
    END {
      if (bad || !n || n!=m) exit 2
      for (i=1;i<=n;i++) {
        id=order[i]
        if (first[id]=="INCONCLUSIVE" || second[id]=="INCONCLUSIVE") exit 2
      }
      for (i=1;i<=n;i++) {
        id=order[i]
        flaps=0; for (j=1;j<=length(h[id]);j++) if (substr(h[id],j,1)=="F") flaps++
        if ((first[id]=="FAIL" && second[id]=="FAIL") ||
            (flaps>=3 && (first[id]=="FAIL" || second[id]=="FAIL"))) {
          failed++; continue
        }
        if (first[id]=="PASS" && second[id]=="PASS") healthy++
        else changing++
        print id
      }
      if (!failed) exit 1
      if (!healthy && !changing) exit 3
      if (!healthy) exit 4
      exit 0
    }' "$1" "$2" > "$3"
  rc=$?
  [ "$rc" -eq 0 ] || : > "$3"
  return "$rc"
}

# Independent resolvers sharing a TLS identity and port form one backup pool.
_PrepareResolverPools_() {
  local tmp
  tmp="$POOLS.new.$$"
  printf '%s\n' 'preferred|all enrolled WAN servers|-' > "$tmp"
  awk -F'|' '
    $1 ~ /^wan[0-9]+$/ {
      count++
      key=$3"|"$4
      if (!wanseen[key]++) {wn++; wan_tls[wn]=$3; wan_port[wn]=$4}
    }
    END {
      if (wn > 1) for(i=1;i<=wn;i++)
        print "wanpool" i "|" wan_tls[i] "|" wan_port[i]
    }
  ' "$PROVIDERS" >> "$tmp"
  awk -F'|' '
    $1 !~ /^wan[0-9]+$/ && NF==4 {
      key=$3"|"$4
      if (!seen[key]++) {n++; print "backup" n "|" $3 "|" $4}
    }
  ' "$PROVIDERS" >> "$tmp"
  mv "$tmp" "$POOLS"
}

_GetPoolMembers_() {
  local pool tls tport
  pool="$1"
  if [ "$pool" = preferred ]; then
    awk -F'|' '$1 ~ /^wan[0-9]+$/ {print}' "$PROVIDERS"
    return
  fi
  case "$pool" in
    filtered1|filtered2)
      local filtered parsed
      filtered="$(_GetFilteredRulelist_ "$pool")" || return 1
      parsed="$RUNTIME/filtered-members-$$"
      printf '%s\n' "$filtered" | _ParseDNSRulelist_ > "$parsed" || return 1
      awk -F'|' 'NR==FNR {wanted[tolower($1 "|" $3 "|" $2)]++; next}
        $1 ~ /^wan[0-9]+$/ {
          k=tolower($2 "|" $3 "|" $4)
          if (wanted[k]>0) {print; wanted[k]--}
        }' "$parsed" "$PROVIDERS"
      rm -f "$parsed"
      return 0 ;;
  esac
  tls="$(awk -F'|' -v p="$pool" '$1==p {print $2; exit}' "$POOLS")"
  tport="$(awk -F'|' -v p="$pool" '$1==p {print $3; exit}' "$POOLS")"
  [ -n "$tls" ] || return 1
  case "$pool" in
    wanpool*) awk -F'|' -v h="$tls" -v p="$tport" '$1 ~ /^wan[0-9]+$/ && $3==h && $4==p {print}' "$PROVIDERS" ;;
    backup*) awk -F'|' -v h="$tls" -v p="$tport" '$1 !~ /^wan[0-9]+$/ && $3==h && $4==p {print}' "$PROVIDERS" ;;
    *) return 1;;
  esac
}

_ProbeResolverPool_() {
  local pool members id ip tls tport extra outcome rc qname qtype rcode answers expected
  pool="$1"; members="$RUNTIME/pool-members-$$"
  _GetPoolMembers_ "$pool" > "$members" || return 1
  [ -s "$members" ] || { rm -f "$members"; return 1; }
  outcome=0
  while IFS='|' read -r id ip tls tport extra; do
    while IFS='|' read -r qname qtype rcode answers expected extra; do
      case "$qname" in ''|\#*) continue;; esac
      if _ProbeDNSRecord_ "$id" "$qname" "$qtype" "$rcode" "$answers" "$expected"; then :
      else
        rc=$?
        if [ "$rc" -eq 2 ]; then outcome=2
        elif [ "$outcome" -eq 0 ]; then outcome=1
        fi
      fi
    done < "${RG_MONITOR_CHECKS:-$CHECKS}"
  done < "$members"
  rm -f "$members"
  return "$outcome"
}

_BuildBackupRulelist_() {
  local pool parsed n id ip name tport extra members
  pool="$1"; [ "$pool" != preferred ] || { cat "$PREF_RULELIST"; return; }
  case "$pool" in
    filtered1|filtered2) _GetFilteredRulelist_ "$pool"; return $? ;;
    wanpool[0-9]*)
      # A WAN-derived provider group is made of entries from the user's
      # original rulelist; preserve their exact optional TLS-port/pin fields.
      members="$RUNTIME/wanpool-target-$$"
      _GetPoolMembers_ "$pool" | awk -F'|' '{print $1}' > "$members" || return 1
      [ -s "$members" ] || { rm -f "$members"; return 1; }
      _BuildFilteredRulelistFromMembers_ "$members"; n=$?
      rm -f "$members"
      return "$n" ;;
  esac
  parsed="$RUNTIME/preferred-parsed-$$"
  _ParseDNSRulelist_ < "$PREF_RULELIST" > "$parsed" || return 1
  n="$(awk -F'|' 'NR==1 {print $5}' "$parsed")"
  rm -f "$parsed"
  [ "$n" = 3 ] || [ "$n" = 4 ] || return 1
  members="$RUNTIME/build-pool-$$"
  _GetPoolMembers_ "$pool" > "$members" || return 1
  [ -s "$members" ] || { rm -f "$members"; return 1; }
  while IFS='|' read -r id ip name tport extra; do
    _IsValidIP_ "$ip" && _IsValidTLSPort_ "$tport" && _IsValidDomain_ "$name" || return 1
    if [ "$n" = 4 ]; then printf '<%s>%s>%s>' "$ip" "$tport" "$name"
    else printf '<%s>%s>%s' "$ip" "$tport" "$name"; fi
  done < "$members"
  rm -f "$members"
  printf '\n'
}

# Detect other administrators or firmware processes modifying the WAN list.
_GetActiveWANPool_() {
  local raw current
  raw="$(_ReadWANRulelist_)"
  [ -r "$PREF_RULELIST" ] || return 1
  if [ "$raw" = "$(cat "$PREF_RULELIST")" ]; then
    _Say_ preferred; return 0
  fi
  if [ -r "$ACTIVE_POOL" ] && [ -r "$ACTIVE_RULELIST" ] &&
     [ "$raw" = "$(cat "$ACTIVE_RULELIST")" ]; then
    current="$(cat "$ACTIVE_POOL")"
    _GetPoolMembers_ "$current" >/dev/null || return 1
    _Say_ "$current"; return 0
  fi
  return 1
}

_VerifyLiveEndpoints_() {
  local pool parsed desired live
  pool="$1"; parsed="$RUNTIME/verify-rulelist-$$"
  desired="$RUNTIME/verify-desired-$$"; live="$RUNTIME/verify-live-$$"
  if [ "$pool" = preferred ]; then
    _ParseDNSRulelist_ < "$PREF_RULELIST" > "$parsed" || return 1
  else
    _BuildBackupRulelist_ "$pool" | _ParseDNSRulelist_ > "$parsed" || return 1
  fi
  awk -F'|' '{print tolower($1)"|"$2"|"tolower($3)}' "$parsed" > "$desired"
  _ParseWANUpstreams_ | awk -F'|' '{print tolower($1)"|"$3"|"tolower($2)}' > "$live" || return 1
  if ! cmp -s "$desired" "$live"; then
    rm -f "$parsed" "$desired" "$live"; return 1
  fi
  rm -f "$parsed" "$desired" "$live"
  _IsStrictProductionDoT_
}

# Restart/readiness is NOT a health-policy decision. Individual upstream
# SERVFAIL, wrong A/AAAA, or timeouts belong to per-resolver monitoring.
# Require consistent live NVRAM/Stubby identities and responding local services,
# but do not demand a perfect DNS answer from upstream resolvers.
_WaitForProductionPool_() {
  local pool attempt mode success_output
  pool="$1"; mode="${2:-transaction}"; success_output="${3:-verbose}"; attempt=1
  case "$mode" in transaction|monitoring) :;; *) return 1;; esac
  while [ "$attempt" -le 6 ]; do
    if _VerifyLiveEndpoints_ "$pool" &&
       _StubbyDaemonRunning_ &&
       _DNSMasqDaemonRunning_ &&
       _VerifyLANForwardingConfig_ &&
       { [ "$mode" = monitoring ] ||
         { _VerifyStubbyListenerResponse_ && _VerifyLANForwarding_; }; }; then
      if [ "$success_output" != quiet ]; then
        if [ "$mode" = monitoring ]; then
          _Say_ "Production Strict DoT service/configuration verified for $pool; monitoring can diagnose unhealthy upstreams."
        else
          _Say_ "Production Strict DoT listeners and LAN forwarding verified for $pool (attempt $attempt; upstream answers evaluated separately)."
        fi
      fi
      return 0
    fi
    [ "$attempt" -lt 6 ] || break
    sleep 1
    attempt=$((attempt+1))
  done
  _Fail_ "Production Strict DoT service/forwarding unavailable for $pool after 6 checks (independent of upstream health)"
  return 1
}

_DNSMasqDaemonRunning_() {
  local dnsmasq_pids
  dnsmasq_pids="$(pidof dnsmasq 2>/dev/null)" || {
    _Say_ 'PRODUCTION NOT READY: DNSMasq daemon PID not found'; return 1;
  }
  [ -n "$dnsmasq_pids" ] || return 1
  return 0
}
_StubbyDaemonRunning_() {
  # Some supported ASUS firmware shells do not provide the `command` builtin,
  # even though BusyBox pidof works. Query pidof directly, fail closed on
  # command error/no process, and require a nonempty reported PID list.
  local stubby_pids
  stubby_pids="$(pidof stubby 2>/dev/null)" || {
    _Say_ 'PRODUCTION NOT READY: pidof could not find a Stubby daemon'
    return 1
  }
  [ -n "$stubby_pids" ] || {
    _Say_ 'PRODUCTION NOT READY: pidof returned no Stubby PID'
    return 1
  }
  return 0
}

# A second asynchronous firmware restart request is warranted only after the
# first has had an entire bounded readiness window to settle. Never start
# Stubby outside Merlin's service manager or change DNS Privacy to plaintext.
_RestartAndVerifyProductionPool_() {
  local pool
  pool="$1"
  if ! service restart_stubby; then
    _LogEvent_ warning "DNS RECOVERY: initial firmware restart_stubby request reported failure ($pool)"
  fi
  if _WaitForProductionPool_ "$pool"; then return 0; fi
  _LogEvent_ warning "DNS RECOVERY: $pool not operational after first restart; requesting one bounded retry"
  if ! service restart_stubby; then
    _LogEvent_ warning "DNS RECOVERY: retry restart_stubby request reported failure ($pool)"
  fi
  if _WaitForProductionPool_ "$pool"; then return 0; fi
  _LogEvent_ err "DNS RECOVERY FAILED: $pool unavailable after two restart attempts; no plaintext fallback"
  return 1
}

_MarkDNSRecoveryHold_() {
  local staged
  [ ! -L "$RECOVERY_HOLD" ] || { _Fail_ 'Unsafe recovery-attention symlink'; return 1; }
  staged="$RECOVERY_HOLD.new.$$"
  (umask 077; printf '%s\n' "$1" > "$staged") && mv "$staged" "$RECOVERY_HOLD" || {
    rm -f "$staged"; return 1;
  }
}

_CheckLiveSwitchSafety_() {
  [ "$(_ReadNVRAM_ dnspriv_enable)" = 1 ] || { _Fail_ 'DNS Privacy disabled; refusing WAN switch'; return 1; }
  [ -r "$PREF_RULELIST" ] && [ -r "$PREF_PROVIDERS" ] || { _Fail_ 'No preferred snapshot; run enroll first'; return 1; }
  if ! _ValidatePreferredSnapshot_; then
    _Fail_ 'Preferred IPv4/IPv6 snapshot is incomplete; refusing WAN switch'
    return 1
  fi
  _IsStrictProductionDoT_ || { _Fail_ 'Production Stubby is not authenticated TLS-only'; return 1; }
  [ ! -e "$PREFERRED_SYNC" ] && [ ! -L "$PREFERRED_SYNC" ] || return 1
  _GetActiveWANPool_ >/dev/null || { _Fail_ 'WAN configuration changed outside ResolvGuard; refusing to overwrite'; return 1; }
  # Monitoring-only is allowed to inspect resolvers when local forwarding
  # cannot be proved. A managed WAN WRITE must never inherit that exemption.
  _StubbyDaemonRunning_ && _DNSMasqDaemonRunning_ &&
    _VerifyLANForwardingConfig_ || {
      _Fail_ 'WAN switch blocked: local Strict DoT/DNSMasq forwarding ownership unverified'; return 1;
    }
}

_CheckAutomaticRecoveryAuthorization_() {
  [ -f "$SCHEDULE_MARKER" ] && [ ! -L "$SCHEDULE_MARKER" ] &&
    [ -f "$AUTO_FAILOVER_MARKER" ] && [ ! -L "$AUTO_FAILOVER_MARKER" ] || {
      _Say_ 'AUTOMATIC SWITCHING DISABLED: Monitoring Only; no WAN change.'
      return 1
    }
}

_CheckAutomaticFailoverAuthorization_() {
  _CheckAutomaticRecoveryAuthorization_ && _CheckPolicyAuthorization_
}

# Transport-level local DNS response, not an upstream policy decision.
# SERVFAIL/NXDOMAIN/NOERROR can all be legitimate from an alive listener.
# Unexpected/malformed data, dig failures or missing QR header fail closed.
_VerifyLocalDNSResponse_() {
  local server tag out got count flags
  server="$1"; tag="$2"
  out="$RUNTIME/infra-$tag-$$"
  # Query the DNS root (.) for NS records instead of generating arbitrary
  # subdomains beneath example.com. This only verifies a well-formed local
  # listener response; authenticated upstream health is checked separately.
  # Cached root NS data is acceptable for this local-listener readiness test.
  if ! "$DIG" "@$server" . NS +time="$TIMEOUT_SECONDS" +tries=1 +noall +comments +answer +authority > "$out" 2>&1; then
    _Say_ "INFRASTRUCTURE NOT READY: $tag listener did not answer"
    rm -f "$out"; return 1
  fi
  got="$(sed -n 's/.*status: \([A-Z][A-Z0-9_]*\),.*/\1/p' "$out" | head -n 1)"
  count="$(awk '/^;; flags:/ {for(i=1;i<=NF;i++) if($i=="ANSWER:") {gsub(/,/,"",$(i+1));print $(i+1);exit}}' "$out")"
  flags="$(sed -n '/^;; flags:/p' "$out" | head -n 1)"
  case "$got" in NOERROR|NXDOMAIN|SERVFAIL|REFUSED|FORMERR|NOTIMP) :;;
    *) _Say_ "INFRASTRUCTURE NOT READY: $tag returned malformed DNS status"; rm -f "$out"; return 1;;
  esac
  case "$count" in ''|*[!0-9]*) rm -f "$out"; return 1;; esac
  printf '%s\n' "$flags" | grep -Eq '^;; flags:.*(^|[[:space:]])qr([[:space:];])' || {
    rm -f "$out"; return 1;
  }
  # DNSMasq REFUSED (notably EDE 14 Not Ready) is a local forwarding
  # rejection, not merely a SERVFAIL returned by a failing remote resolver.
  if [ "$tag" = lan ] && grep -Ei 'EDE:.*(14|Not Ready)' "$out" >/dev/null 2>&1; then
    _Say_ 'INFRASTRUCTURE NOT READY: LAN DNSMasq reports upstream not ready'
    rm -f "$out"; return 1
  fi
  # SERVFAIL, missing/wrong A/AAAA records and negative responses are
  # monitored separately on *authenticated per-endpoint* probes.
  rm -f "$out"
  return 0
}

_VerifyStubbyListenerResponse_() {
  _VerifyLocalDNSResponse_ 127.0.1.1 stubby
}

# Validate the complete upstream file before trusting the router's LAN DNS path.
# An unqualified server= line MUST point at the local production Stubby
# listener. Domain-scoped exceptions can coexist, but are not a plaintext
# fallback for ordinary DNS queries: DNSMasq uses them for matching names only.
#
# Return the explicit domain exceptions as "domain|server" records so the
# caller can validate their IP addresses and disclose the bypass to the user.
_ScanDNSMasqUpstreamFile_() {
  awk '
    function trim_whitespace(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }

    /^[[:space:]]*#/ || /^[[:space:]]*$/ {
      next
    }

    {
      line = trim_whitespace($0)

      # A DNSMasq #port is not a comment. Only strip # preceded by space.
      sub(/[[:space:]]+#.*$/, "", line)
      line = trim_whitespace(line)

      if (line == "server=127.0.1.1" ||
          line == "server=127.0.1.1#53") {
        default_servers++
        next
      }

      # BusyBox awk treats a slash inside a bracket expression in a regex
      # literal as the end of the regex on some firmware builds. Parse the
      # DNSMasq domain delimiter as plain text instead of matching [^/].
      if (substr(line, 1, 8) == "server=/") {
        scoped_entry = substr(line, 9)
        separator = index(scoped_entry, "/")

        if (separator <= 1) {
          invalid = 1
          next
        }

        domain = substr(scoped_entry, 1, separator - 1)
        destination = substr(scoped_entry, separator + 1)

        if (destination == "" || index(destination, "/") != 0) {
          invalid = 1
          next
        }

        sub(/\.$/, "", domain)

        # Reject root, wildcard, single-label and other overly broad scopes.
        if (domain !~ /^[A-Za-z0-9-]+([.][A-Za-z0-9-]+)+$/ ||
            domain ~ /[.][.]/) {
          invalid = 1
          next
        }

        printf "%s|%s\n", domain, destination
        next
      }

      # Reject all other directives, particularly generic plaintext servers.
      invalid = 1
    }

    END {
      if (default_servers < 1 || invalid) {
        exit 1
      }
    }
  ' "$DNSMASQ_SERVERS"
}

_ValidateDNSMasqUpstreamFile_() {
  local domain_exceptions domain server

  if ! domain_exceptions="$(_ScanDNSMasqUpstreamFile_)"; then
    _Say_ 'LAN DNS NOT READY: invalid DNSMasq upstream or missing Stubby default'
    return 1
  fi

  # A split-DNS exception has a domain scope, but routes that domain outside
  # production DoT. Accept only literal IP endpoints and disclose the scope.
  if [ -n "$domain_exceptions" ]; then
    while IFS='|' read -r domain server; do
      if ! _IsValidIPv4_ "$server" && ! _IsValidIPv6_ "$server"; then
        _Say_ "LAN DNS NOT READY: invalid domain-scoped DNS upstream for $domain"
        return 1
      fi
    done <<EOF_DNSMASQ_SCOPED_SERVERS
$domain_exceptions
EOF_DNSMASQ_SCOPED_SERVERS

    # Validate the exceptions here, but do not print an interactive notice.
    # This validation can run repeatedly while Stubby is starting and during
    # DNS restoration. Quick Setup displays a single, prominent disclosure
    # in the wizard before automatic-failover authorization is requested.
  fi

  return 0
}

# Disclose domain-specific plaintext DNS exceptions before asking the user to
# authorize automatic failover (either during Quick Setup or from the menu).
# Validation stays independent of presentation: this function makes no DNS or
# configuration changes, and pauses only for an interactive terminal.
_ShowDNSMasqScopedSetupWarning_() {
  local domain_exceptions domain upstream

  # The wizard and its authorization helper may both call this routine.
  # A disclosure and acknowledgement are needed only once per invocation.
  if [ "${RG_SCOPED_WARNING_SHOWN:-0}" = 1 ]; then
    return 0
  fi

  if [ ! -r "$DNSMASQ_SERVERS" ]; then
    return 0
  fi

  # A malformed upstream file is reported by the normal readiness checks;
  # never describe an invalid configuration as successfully protected.
  if ! domain_exceptions="$(_ScanDNSMasqUpstreamFile_ 2>/dev/null)"; then
    return 0
  fi

  if [ -z "$domain_exceptions" ]; then
    return 0
  fi

  # Use the same literal-IP validation as the readiness check. The display
  # must not accidentally accept or endorse a malformed split-DNS exception.
  while IFS='|' read -r domain upstream; do
    if ! _IsValidIPv4_ "$upstream" && ! _IsValidIPv6_ "$upstream"; then
      return 0
    fi
  done <<EOF_DNSMASQ_WARNING_VALIDATE
$domain_exceptions
EOF_DNSMASQ_WARNING_VALIDATE

  RG_SCOPED_WARNING_SHOWN=1
  _SetMenuPalette_

  printf '\n%s' "$RG_RED"
  _Say_ '================================================================'
  _Say_ '  WARNING: DNS REQUESTS BYPASS STRICT DNS-OVER-TLS'
  _Say_ '================================================================'
  printf '%s' "$RG_RESET"

  _Say_ '  DNSMasq is configured to use Stubby by default, but these'
  _Say_ '  domain-specific exceptions use separate DNS servers:'
  _Say_ ''

  while IFS='|' read -r domain upstream; do
    printf '  %sDOMAIN:%s   %s\n' "$RG_RED" "$RG_RESET" "$domain"
    printf '  %sUPSTREAM:%s %s\n' "$RG_RED" "$RG_RESET" "$upstream"
  done <<EOF_DNSMASQ_WARNING_LIST
$domain_exceptions
EOF_DNSMASQ_WARNING_LIST

  printf '\n%s' "$RG_RED"
  _Say_ '  Matching queries bypass the default Stubby/Strict DoT path.'
  _Say_ '  ResolvGuard did not create or modify these DNSMasq rules.'
  _Say_ '================================================================'
  printf '%s' "$RG_RESET"

  # Do not consume stdin or block noninteractive scripted invocations.
  # Only an actual interactive SSH terminal needs acknowledgment.
  if [ -t 0 ] && [ -t 1 ]; then
    printf '\n%sPress <Enter> to acknowledge this DNS warning and continue...%s' \
      "$RG_RED" "$RG_RESET"
    IFS= read -r _rg_dns_warning_ack || :
    printf '\n'
  fi

  return 0
}

_VerifyLANForwardingConfig_() {
  local lan

  if [ "$(_ReadNVRAM_ dnspriv_enable)" != 1 ] ||
     [ "$(_ReadNVRAM_ dnspriv_profile)" != 1 ]; then
    _Say_ 'LAN DNS NOT READY: ASUS Strict DNS Privacy is not enabled'
    return 1
  fi

  if [ ! -r "$DNSMASQ_MAIN" ]; then
    _Say_ "LAN DNS NOT READY: DNSMasq main configuration not readable: $DNSMASQ_MAIN"
    return 1
  fi

  if [ ! -r "$DNSMASQ_SERVERS" ]; then
    _Say_ "LAN DNS NOT READY: DNSMasq upstream servers file not readable: $DNSMASQ_SERVERS"
    return 1
  fi

  if ! _ValidateDNSMasqUpstreamFile_; then
    return 1
  fi

  if ! grep -Eq '^[[:space:]]*no-resolv[[:space:]]*$' "$DNSMASQ_MAIN" ||
     ! grep -Eq '^[[:space:]]*servers-file=/tmp/resolv\.dnsmasq[[:space:]]*$' "$DNSMASQ_MAIN"; then
    _Say_ 'LAN DNS NOT READY: DNSMasq does not declare its strict forwarding file'
    return 1
  fi

  lan="$(_ReadNVRAM_ lan_ipaddr)"
  if ! _IsValidIPv4_ "$lan"; then
    _Say_ 'LAN DNS NOT READY: LAN address invalid'
    return 1
  fi

  return 0
}

_VerifyLANForwarding_() {
  local lan
  _VerifyLANForwardingConfig_ || return 1
  lan="$(_ReadNVRAM_ lan_ipaddr)"
  _VerifyLocalDNSResponse_ "$lan" lan
}

# Persist the complete switching intent before touching WAN NVRAM.
_WriteSwitchIntent_() {
  local from to previous desired staged
  from="$1"; to="$2"; previous="$3"; desired="$4"
  [ ! -e "$PENDING_TRANSACTION" ] && [ ! -L "$PENDING_TRANSACTION" ] || {
    _Fail_ 'Unresolved WAN transaction exists; review boot/recovery status'; return 1; }
  mkdir -p "$STATE_DIR" || return 1
  staged="$STATE_DIR/.transaction-$$"
  ( umask 077; mkdir "$staged" &&
    printf '%s\n' "$from" > "$staged/from-pool" &&
    printf '%s\n' "$to" > "$staged/to-pool" &&
    printf '%s\n' "$previous" > "$staged/from-rulelist" &&
    printf '%s\n' "$desired" > "$staged/to-rulelist" ) || {
      rm -rf "$staged"; return 1; }
  mv "$staged" "$PENDING_TRANSACTION" || { rm -rf "$staged"; return 1; }
}

_ClearSwitchIntent_() {
  [ ! -L "$PENDING_TRANSACTION" ] || return 1
  [ ! -e "$PENDING_TRANSACTION" ] || rm -rf "$PENDING_TRANSACTION"
}

# If failure rollback succeeded, remove intent; if it failed, retain evidence.
_RollbackDNSSwitch_() {
  local previous old
  previous="$1"; old="$2"
  if ! nvram set "dnspriv_rulelist=$previous"; then
    _MarkDNSRecoveryHold_ 'WAN rollback NVRAM restore failed; DNS availability unverified' || :
    _LogEvent_ err 'DNS ROLLBACK FAILED: WAN restore command failed; recovery transaction retained'
    _Fail_ 'WAN rollback command failed; keeping recovery transaction on disk'
    return 1
  fi
  if _RestartAndVerifyProductionPool_ "$old" &&
     [ "$(_ReadWANRulelist_)" = "$previous" ]; then
    # A partially persisted new-pool ownership marker must not survive a
    # verified rollback or cause the transaction journal to be discarded.
    if [ "$old" = preferred ]; then
      if [ -L "$ACTIVE_POOL" ] || [ -L "$ACTIVE_RULELIST" ] ||
         ! rm -f "$ACTIVE_POOL" "$ACTIVE_RULELIST"; then
        _MarkDNSRecoveryHold_ 'WAN restored but stale/unsafe managed ownership could not be cleared' || :
        return 1
      fi
    elif [ ! -f "$ACTIVE_POOL" ] || [ -L "$ACTIVE_POOL" ] ||
         [ ! -f "$ACTIVE_RULELIST" ] || [ -L "$ACTIVE_RULELIST" ] ||
         [ "$(cat "$ACTIVE_POOL")" != "$old" ] ||
         [ "$(cat "$ACTIVE_RULELIST")" != "$previous" ]; then
      _MarkDNSRecoveryHold_ 'WAN restored but prior managed ownership cannot be verified' || :
      return 1
    fi
    if ! _ClearSwitchIntent_; then
      _MarkDNSRecoveryHold_ 'WAN rollback operational but transaction journal could not be cleared' || :
      return 1
    fi
    _LogEvent_ warning "DNS ROLLBACK: restored and verified previous WAN pool $old and LAN DNS after failed switch"
    return 0
  fi
  _MarkDNSRecoveryHold_ 'WAN rollback could not verify Strict DoT and LAN DNS; transaction retained' || :
  _LogEvent_ err 'DNS ROLLBACK FAILED: operational DNS verification unsuccessful; transaction retained'
  _Fail_ 'WAN rollback not verified; transaction retained; automatic switching blocked'
  return 1
}

_SHA256Digest_() {
  local output digest input
  input=''
  if [ "$#" -eq 0 ]; then
    input="$RUNTIME/sha256-input.$$"
    if [ -e "$input" ] || [ -L "$input" ]; then
      _Fail_ "SHA-256 input path already exists: $input"
      return 1
    fi
    if ! (umask 077; set -C; cat > "$input"); then
      rm -f "$input"
      _Fail_ 'Cannot stage SHA-256 input in the runtime directory'
      return 1
    fi
    set -- "$input"
  fi

  digest=''
  if output="$(sha256sum "$@" 2>/dev/null)"; then
    digest="${output%% *}"
    case "$digest" in ''|*[!0-9a-fA-F]*) digest='' ;; esac
    [ "${#digest}" -eq 64 ] || digest=''
  fi
  if [ -z "$digest" ] && output="$(openssl dgst -sha256 "$@" 2>/dev/null)"; then
    digest="${output##* }"
    case "$digest" in ''|*[!0-9a-fA-F]*) digest='' ;; esac
    [ "${#digest}" -eq 64 ] || digest=''
  fi
  if [ -z "$digest" ] && output="$(busybox sha256sum "$@" 2>/dev/null)"; then
    digest="${output%% *}"
    case "$digest" in ''|*[!0-9a-fA-F]*) digest='' ;; esac
    [ "${#digest}" -eq 64 ] || digest=''
  fi

  if [ -n "$input" ] && ! rm -f "$input"; then
    _Fail_ 'Cannot remove temporary SHA-256 input'
    return 1
  fi
  if [ -z "$digest" ]; then
    _Fail_ 'SHA-256 calculation failed with all supported implementations'
    return 1
  fi
  printf '%s\n' "$digest" | LC_ALL=C tr 'A-F' 'a-f'
}

# Epoch detects a policy/config edit during a long DNS probe cycle. A changed
# policy must never authorize a WAN switch using pre-edit observations, even
# when the administrator approves the new policy before this cycle ends.
_GetMonitorPolicyEpoch_() {
  local file staged digest

  staged="$RUNTIME/monitor-policy-epoch-$$"
  if [ -e "$staged" ] || [ -L "$staged" ]; then
    return 1
  fi

  # The path label and raw content of each policy file contribute to the
  # fingerprint. Do not omit the file label or change their order.
  if ! (
    umask 077
    for file in "$CHECKS" "$EXTRA_PROVIDERS" "$SETTINGS" \
                "$PREF_RULELIST" "$PREF_PROVIDERS" "$POLICY_APPROVAL"; do
      if ! printf 'policy-file:%s\n' "$file"; then
        exit 1
      fi

      if [ -f "$file" ] && [ ! -L "$file" ]; then
        if ! cat "$file"; then
          exit 1
        fi
      else
        printf '%s\n' '(missing-or-unsafe)' || exit 1
      fi
    done
  ) > "$staged"; then
    rm -f "$staged"
    return 1
  fi

  if ! digest="$(_SHA256Digest_ "$staged")"; then
    rm -f "$staged"
    return 1
  fi

  rm -f "$staged" || return 1
  printf '%s\n' "$digest"
}

_GetPolicyFingerprint_() {
  local digest
  [ -r "$CHECKS" ] || { _Fail_ 'Cannot read DNS health checks for policy fingerprint'; return 1; }
  [ -r "$EXTRA_PROVIDERS" ] || { _Fail_ 'Cannot read backup provider settings for policy fingerprint'; return 1; }
  [ -s "$PREF_RULELIST" ] && [ ! -L "$PREF_RULELIST" ] || {
    _Fail_ 'Preferred WAN DNS snapshot missing, empty, or unsafe'; return 1;
  }
  [ -s "$PREF_PROVIDERS" ] && [ ! -L "$PREF_PROVIDERS" ] || {
    _Fail_ 'Preferred resolver identities missing or unsafe'; return 1; }
  digest="$({
    printf '%s\n' 'ResolvGuard-policy-v5:preferred-identities'
    cat "$PREF_PROVIDERS"
    printf '%s\n' 'ResolvGuard-policy-v5:checks'
    cat "$CHECKS"
    printf '%s\n' 'ResolvGuard-policy-v5:backup-providers'
    cat "$EXTRA_PROVIDERS"
    printf '%s\n' 'ResolvGuard-policy-v5:preferred-nvram'
    cat "$PREF_RULELIST"
    printf 'ResolvGuard-policy-v5:wan-config=%s\n' "$WAN_STUBBY_CONFIG"
    printf 'ResolvGuard-policy-v5:ca-file=%s\n' "$CA_FILE"
    printf 'ResolvGuard-policy-v5:timeout=%s\n' "$TIMEOUT_SECONDS"
    printf 'ResolvGuard-policy-v5:boot-warmup=%s\n' "$BOOT_MIN_UPTIME_SECONDS"
    printf 'ResolvGuard-policy-v5:failure-threshold=%s\n' "$FAIL_THRESHOLD"
    printf 'ResolvGuard-policy-v5:recovery-threshold=%s\n' "$RECOVERY_THRESHOLD"
    printf 'ResolvGuard-policy-v5:schedule-interval-minutes=%s\n' "$SCHEDULE_INTERVAL_MINUTES"
    printf 'ResolvGuard-policy-v5:fast-confirm-seconds=%s\n' "$FAST_CONFIRM_SECONDS"
  } | _SHA256Digest_)" || return 1
  printf '%s\n' "$digest"
}

_GetPolicyApprovalState_() {
  local record marker_hash current
  [ -f "$POLICY_APPROVAL" ] && [ ! -L "$POLICY_APPROVAL" ] || {
    _Say_ 'MISSING (policy approval not recorded)'; return 1; }
  record="$(cat "$POLICY_APPROVAL" 2>/dev/null)" || {
    _Say_ 'INVALID (cannot read approval record)'; return 1; }
  case "$record" in
    v5\|*) marker_hash="${record#v5|}" ;;
    *) _Say_ 'INVALID (approval record format)'; return 1 ;;
  esac
  case "$marker_hash" in
    ''|*[!0-9a-f]*) _Say_ 'INVALID (approval fingerprint)'; return 1 ;;
  esac
  [ "${#marker_hash}" -eq 64 ] || { _Say_ 'INVALID (approval fingerprint length)'; return 1; }
  current="$(_GetPolicyFingerprint_)" || {
    _Say_ 'BLOCKED (SHA256 or policy source unavailable)'; return 1; }
  [ "$current" = "$marker_hash" ] || {
    _Say_ 'CHANGED (approved policy/providers/settings no longer match)'; return 1; }
  _Say_ 'VALID (persistent until configuration change or explicit revocation)'
  return 0
}

_CheckPolicyAuthorization_() {
  local status
  if ! status="$(_GetPolicyApprovalState_)"; then
    _Say_ "POLICY SAFETY HOLD: $status; no automatic WAN switch."
    return 1
  fi
  return 0
}

_ShowPolicyStatus_() {
  local status
  status="$(_GetPolicyApprovalState_)" || :
  _Say_ "Policy switching approval: $status"
}

# Approval records administrator consent to a validated configuration; it is not
# a one-time claim that every upstream is healthy at this instant. Scheduled
# health checks must independently prove safe endpoints before any WAN write.
_ApprovePolicy_() (
  local fingerprint staged approval_prompt view count
  approval_prompt="${1:-Approve DNS policy?}"
  view="${2:-detail}"
  RG_POLICY_CONFIG_HELD=0
  RG_POLICY_WAN_HELD=0
  RG_MAINTENANCE_PRIORITY_HELD=0
  # Install cleanup before waiting: a termination during the bounded wait
  # must not leave behind this policy operation's priority reservation.
  trap '_CleanupPolicyLocks_' EXIT
  trap 'exit 130' INT
  trap 'exit 143' HUP TERM
  _AcquireWANLockForPolicy_ || return 1
  _AcquireConfigLockForPolicy_ || return 1
  [ ! -e "$PENDING_TRANSACTION" ] && [ ! -L "$PENDING_TRANSACTION" ] &&
    [ ! -e "$RECOVERY_HOLD" ] && [ ! -L "$RECOVERY_HOLD" ] || {
    _Fail_ 'Unresolved WAN transaction or recovery hold; policy approval blocked'; return 1; }
  _SyncPreferredWANLocked_ || {
    _Fail_ 'Unable to verify current ASUS preferred DNS; policy approval blocked'; return 1; }
  _ValidateConfiguration_ >/dev/null || return 1
  _RequireProbeDependencies_ || return 1
  [ -r "$PREF_RULELIST" ] && [ -r "$PREF_PROVIDERS" ] &&
    [ ! -L "$PREF_RULELIST" ] && [ ! -L "$PREF_PROVIDERS" ] || {
    _Fail_ 'Preferred WAN enrollment missing or unsafe'; return 1; }
  [ "$(_ReadNVRAM_ dnspriv_enable)" = 1 ] &&
    [ "$(_ReadNVRAM_ dnspriv_profile)" = 1 ] &&
    _VerifyLiveEndpoints_ preferred || {
    _Fail_ 'Strict production DoT identities do not match preferred WAN DNS; approval blocked'; return 1; }
  [ "$(_GetActiveWANPool_ 2>/dev/null)" = preferred ] || {
    _Fail_ 'Policy review requires the verified preferred WAN pool'; return 1; }
  _PrepareResolverPools_ || return 1
  count="$(awk -F'|' '$1 ~ /^(backup|wanpool)[0-9]+$/ {n++} END{print n+0}' "$POOLS")"
  [ "$count" -gt 0 ] || {
    _Fail_ 'No alternate WAN-derived or independent backup pool configured; switching policy cannot be approved'; return 1; }
  fingerprint="$(_GetPolicyFingerprint_)" || {
    _Fail_ 'Unable to fingerprint the DNS policy'; return 1; }
  if [ "$view" = quick ]; then
    printf '  Preferred DNS: %sStrict authenticated DoT verified%s\n' "$RG_GREEN" "$RG_RESET"
    printf '  Alternate groups: %s configured\n' "$count"
  else
    _Say_ 'DNS POLICY REVIEW'
    _Say_ '  Preferred DNS: VERIFIED'
    _Say_ "  Alternate pools: $count"
    _Say_ '  Health checks (host|type|rcode|count|data):'
    while IFS= read -r rule; do
      case "$rule" in ''|\#*) continue;; esac
      printf '    %s\n' "$rule"
    done < "$CHECKS"
  fi
  _Say_ ''
  # Never hold a WAN lock, config lock, or priority reservation while an
  # administrator reads the policy or considers the approval prompt.
  # Monitoring therefore runs normally during an arbitrarily long review.
  _ReleasePolicyConfigLock_ || {
    _Fail_ 'Unable to release configuration lock before confirmation'
    return 1
  }
  _ReleasePolicyWANLock_ || {
    _Fail_ 'Unable to release DNS lock before confirmation'
    return 1
  }
  _ReleaseMaintenancePriority_ || {
    _Fail_ 'Unable to release interactive priority before confirmation'
    return 1
  }
  if [ "$view" = quick ]; then
    _ConfirmYesNo_ "$approval_prompt" quiet || return 1
  else
    _ConfirmYesNo_ "$approval_prompt" || return 1
  fi
  # Re-establish priority after consent, then verify the reviewed policy
  # under both locks before persisting any approval.
  _AcquireWANLockForPolicy_ || return 1
  _AcquireConfigLockForPolicy_ || return 1
  [ ! -e "$PENDING_TRANSACTION" ] && [ ! -L "$PENDING_TRANSACTION" ] &&
    [ ! -e "$RECOVERY_HOLD" ] && [ ! -L "$RECOVERY_HOLD" ] || {
    _Fail_ 'WAN recovery state changed during review; approval refused'; return 1; }
  _SyncPreferredWANLocked_ || return 1
  _ValidateConfiguration_ >/dev/null || return 1
  [ "$(_ReadNVRAM_ dnspriv_enable)" = 1 ] &&
    [ "$(_ReadNVRAM_ dnspriv_profile)" = 1 ] &&
    _VerifyLiveEndpoints_ preferred || {
    _Fail_ 'Production Strict DoT changed during policy review; approval refused'; return 1; }
  [ ! -L "$POLICY_APPROVAL" ] && [ ! -L "$STATE_DIR" ] || {
    _Fail_ 'Unsafe approval storage path'; return 1; }
  mkdir -p "$STATE_DIR" || return 1
  staged="$STATE_DIR/.policy-approval-$$"
  [ ! -e "$staged" ] && [ ! -L "$staged" ] || return 1
  (umask 077; printf 'v5|%s\n' "$fingerprint" > "$staged") || return 1
  if [ "$(_GetPolicyFingerprint_)" != "$fingerprint" ] ||
     [ "$(_GetActiveWANPool_ 2>/dev/null)" != preferred ] ||
     ! _VerifyLiveEndpoints_ preferred ||
     [ -e "$PENDING_TRANSACTION" ] || [ -e "$RECOVERY_HOLD" ]; then
    rm -f "$staged"
    _Fail_ 'Policy, production Strict DoT, or WAN state changed during review; approval refused'
    return 1
  fi
  mv -f "$staged" "$POLICY_APPROVAL" || { rm -f "$staged"; return 1; }
  if [ "$view" = quick ]; then
    printf '  %sPolicy approved.%s\n' "$RG_GREEN" "$RG_RESET"
  else
    _Say_ 'DNS policy: APPROVED'
  fi
)

# A deliberate revocation disables BOTH policy consent and unattended switching.
# Disable switching first, under the same WAN lock used by scheduled operations.
# Reapproving alone must never reactivate an old automatic-failover marker.
_RevokePolicy_() (
  _ConfirmYesNo_ 'Revoke DNS policy approval (also disables automatic failover)?' || return 1
  RG_POLICY_WAN_HELD=0
  RG_POLICY_CONFIG_HELD=0
  RG_MAINTENANCE_PRIORITY_HELD=0
  # Confirmation happens before admission; the scheduler keeps working
  # while the operator reads the prompt.
  trap '_CleanupPolicyLocks_' EXIT
  trap 'exit 130' INT
  trap 'exit 143' HUP TERM
  _AcquireWANLockForPolicy_ || return 1
  [ ! -L "$AUTO_FAILOVER_MARKER" ] && [ ! -L "$POLICY_APPROVAL" ] || {
    _Fail_ 'Unsafe policy/authorization path; refusing revocation'; return 1; }
  rm -f "$AUTO_FAILOVER_MARKER" || {
    _Fail_ 'Unable to disable automatic WAN switching; approval not removed'; return 1; }
  rm -f "$POLICY_APPROVAL" || {
    _Fail_ 'Automatic switching disabled, but approval removal failed; review files'; return 1; }
  _Say_ 'DNS policy: REVOKED'
  _Say_ 'Automatic failover: OFF (monitoring unchanged)'
  if [ "$(_GetActiveWANPool_ 2>/dev/null || :)" != preferred ]; then
    _Say_ 'WARNING: WAN uses an alternate pool; automatic failback is OFF.'
  fi
)

_ManagePolicy_() {
  case "${1:-status}" in
    status) _SyncPreferredWAN_ && _ShowPolicyStatus_ ;;
    approve) _ApprovePolicy_ ;;
    revoke) _RevokePolicy_ ;;
    *) _Fail_ 'Usage: policy [status|approve|revoke]'; return 2 ;;
  esac
}

# A WAN-switch subprocess must release only a configuration lock that it
# acquired itself. The EXIT trap executes after function-local variables may
# have gone out of scope on BusyBox ash, so this ownership marker is NOT local.
# The switching function runs in a subshell, keeping the marker private to it.
_CleanupSwitchConfigLock_() {
  if [ "${RG_SWITCH_CONFIG_LOCK_OWNED:-0}" = 1 ]; then
    _ReleaseConfigLock_ >/dev/null 2>&1 || :
  fi
}

_SwitchDNSPool_() (
  local old new reason prev desired actual verified
  # Config commits may run during read-only probes, but not during WAN writes.
  # A maintenance caller can already own CONFIG_LOCK while holding WAN_LOCK.
  RG_SWITCH_CONFIG_LOCK_OWNED=0
  if [ "${RG_CONFIG_LOCK_ALREADY_HELD:-0}" = 1 ]; then
    if [ ! -d "$CONFIG_LOCK" ] || [ -L "$CONFIG_LOCK" ] ||
       [ ! -f "$CONFIG_LOCK/owner" ] || [ -L "$CONFIG_LOCK/owner" ] ||
       [ "$(cat "$CONFIG_LOCK/owner")" != "$$" ]; then
      _Fail_ 'Maintenance configuration lock ownership cannot be verified'
      return 1
    fi
  else
    if ! _AcquireConfigLock_; then
      _Fail_ 'Configuration commit in progress; WAN switch deferred'
      return 1
    fi
    RG_SWITCH_CONFIG_LOCK_OWNED=1
  fi

  trap '_CleanupSwitchConfigLock_' EXIT HUP INT TERM
  # Probes may run concurrently with a menu edit. A switch is allowed only
  # when the recorded policy epoch still matches the current configuration.
  # A maintenance request made during probing must stop any new scheduled
  # switch decision. A transaction already in progress still completes safely.
  if [ -n "${RG_MONITOR_POLICY_EPOCH:-}" ] && _MaintenancePriorityPending_; then
    _Say_ 'WAN SWITCH SAFETY HOLD: interactive maintenance has priority.'
    return 1
  fi

  if [ -n "${RG_MONITOR_POLICY_EPOCH:-}" ]; then
    if [ "$(_GetMonitorPolicyEpoch_)" != "$RG_MONITOR_POLICY_EPOCH" ]; then
      _Say_ 'WAN SWITCH SAFETY HOLD: configuration changed during DNS probing.'
      return 1
    fi
  fi
  old="$1"; new="$2"; reason="$3"
  case "$new" in
    filtered1|filtered2)
      [ "$new" != "$old" ] && [ "$#" -eq 4 ] &&
        _IsPreferredSubsetRulelist_ "$4" || {
        _Fail_ 'Refusing unverified or same-name filtered WAN target'; return 1; } ;;
    *) [ "$#" -eq 3 ] || return 1 ;;
  esac
  [ ! -e "$PREFERRED_SYNC" ] && [ ! -L "$PREFERRED_SYNC" ] || {
    _Fail_ 'Preferred synchronization is incomplete; no WAN switching'; return 1; }
  _CheckLiveSwitchSafety_ || return 1
  case "$reason" in
    'DNS answer policy failed') _CheckAutomaticFailoverAuthorization_ || return 1 ;;
    'preferred WAN resolvers recovered') _CheckAutomaticRecoveryAuthorization_ || return 1 ;;
  esac
  actual="$(_GetActiveWANPool_)" || return 1
  [ "$old" = "$actual" ] || { _Fail_ 'WAN pool changed during health check; refusing to switch'; return 1; }
  prev="$(_ReadWANRulelist_)"
  case "$new" in
    filtered1|filtered2) desired="$4" ;;
    *) desired="$(_BuildBackupRulelist_ "$new")" || return 1 ;;
  esac
  [ -n "$desired" ] || return 1
  [ "$prev" != "$desired" ] || return 0
  # Persist tracked pool state before updating WAN NVRAM.
  if [ "$new" != preferred ]; then
    (umask 077; printf '%s\n' "$new" > "$ACTIVE_POOL.new.$$"; \
      printf '%s\n' "$desired" > "$ACTIVE_RULELIST.new.$$") || {
        rm -f "$ACTIVE_POOL.new.$$" "$ACTIVE_RULELIST.new.$$"; return 1;
      }
  fi
  # Journal the old and new rulelists before WAN changes.
  if ! _WriteSwitchIntent_ "$old" "$new" "$prev" "$desired"; then
    rm -f "$ACTIVE_POOL.new.$$" "$ACTIVE_RULELIST.new.$$"
    return 1
  fi
  if ! nvram set "dnspriv_rulelist=$desired"; then
    rm -f "$ACTIVE_POOL.new.$$" "$ACTIVE_RULELIST.new.$$"
    [ "$(_ReadWANRulelist_)" = "$prev" ] && _ClearSwitchIntent_ || :
    return 1
  fi
  if ! service restart_stubby; then
    _RollbackDNSSwitch_ "$prev" "$old" || :
    rm -f "$ACTIVE_POOL.new.$$" "$ACTIVE_RULELIST.new.$$"
    _LogEvent_ err "DNS SWITCH FAILED: production Stubby restart failed ($old -> $new); rollback attempted"
    _Fail_ 'Stubby restart failed; attempted to restore previous WAN pool'; return 1
  fi
  verified=1
  if ! _WaitForProductionPool_ "$new"; then verified=0; fi
  if [ "$verified" != 1 ]; then
    _RollbackDNSSwitch_ "$prev" "$old" || :
    rm -f "$ACTIVE_POOL.new.$$" "$ACTIVE_RULELIST.new.$$"
    _LogEvent_ err "DNS SWITCH FAILED: production Stubby validation failed ($old -> $new); rollback attempted"
    _Fail_ 'Production Stubby validation failed; rollback attempted'; return 1
  fi
  if [ "$new" = preferred ]; then
    rm -f "$ACTIVE_POOL" "$ACTIVE_RULELIST"
  else
    if ! mv "$ACTIVE_RULELIST.new.$$" "$ACTIVE_RULELIST" ||
       ! mv "$ACTIVE_POOL.new.$$" "$ACTIVE_POOL"; then
      _RollbackDNSSwitch_ "$prev" "$old" || :
      rm -f "$ACTIVE_POOL.new.$$" "$ACTIVE_RULELIST.new.$$"
      _LogEvent_ err 'DNS SWITCH FAILED: failover ownership could not be saved; rollback attempted'
      _Fail_ 'Unable to persist failover ownership; WAN rollback attempted'
      return 1
    fi
  fi
  _ClearSwitchIntent_ || {
    _LogEvent_ err 'DNS RECOVERY ATTENTION: WAN switched but transaction cleanup failed'
    _Fail_ 'WAN switched but transaction cleanup failed; manual recovery inspection required'; return 1; }
  rm -f "$MEMBER_HISTORY" || :
  if [ "$new" = preferred ]; then
    _LogEvent_ notice "DNS FAILBACK: $old -> preferred; Strict DoT verified ($reason)"
  elif [ "$old" = preferred ]; then
    _LogEvent_ warning "DNS FAILOVER: preferred -> $new; Strict DoT verified ($reason)"
  else
    _LogEvent_ warning "DNS POOL CHANGE: $old -> $new; Strict DoT verified ($reason)"
  fi
  _LogFilteredDNSMembership_ "$old" "$new" "$prev" "$desired" || :
  return 0
)

_ReadMonitoringState_() {
  local f
  f="$RUNTIME/state-counters"
  failures=0; recoveries=0
  if [ -f "$f" ]; then
    failures="$(sed -n 's/^failures=//p' "$f" | head -1)"
    recoveries="$(sed -n 's/^recoveries=//p' "$f" | head -1)"
    _IsValidAnswerCount_ "$failures" || failures=0
    _IsValidAnswerCount_ "$recoveries" || recoveries=0
  fi
}
_WriteMonitoringState_() {
  { _Say_ "failures=$failures"; _Say_ "recoveries=$recoveries"; } > "$RUNTIME/state-counters.new.$$"
  mv "$RUNTIME/state-counters.new.$$" "$RUNTIME/state-counters"
}

# A health-check cycle owns these temporary files and both locks only
# while explicitly acquired. Keep cleanup limited to its own probe processes.
_CleanupMonitorCycle_() {
  rm -f "$RUNTIME/health-response-$$.txt"

  rm -f "$RUNTIME/member-first-$$" \
        "$RUNTIME/member-confirm-$$" \
        "$RUNTIME/member-survivors-$$" \
        "$RUNTIME/monitor-checks-$$"

  if [ "${RG_CONFIG_HELD:-0}" = 1 ]; then
    _ReleaseConfigLock_ >/dev/null 2>&1 || :
  fi

  _ReleaseWANLock_ >/dev/null 2>&1 || :
}

_RunDNSHealthCheck_() (
  local current backup selected pool result alt_rc mode
  local status1 status2 survivors proposed target eligible confirm_needed switch_failure
  mode="${1:-manual}"
  switch_failure=0

  # Never emit terminal escape codes into scheduled logs or captured output.
  # A direct manual CLI check and the menu's CH action share this path.
  RG_HEALTH_COLOR_ENABLED=0
  RG_HEALTH_SHOW_RESOLVERS=0
  RG_HEALTH_FAILED_RECORDS=0
  RG_HEALTH_FAILED_IDS=''
  RG_HEALTH_FAILURE_PHASES=''
  RG_HEALTH_PROBE_PHASE=active

  if [ "$mode" != scheduled ] && [ -t 1 ]; then
    RG_HEALTH_SHOW_RESOLVERS=1
    _SetMenuPalette_

    if [ -n "$RG_GREEN" ] && [ -n "$RG_RED" ]; then
      RG_HEALTH_COLOR_ENABLED=1
    fi
  fi
  [ -r "$PREF_RULELIST" ] || { _Fail_ 'Run enroll before monitoring or switching WAN DoT'; return 1; }
  [ ! -e "$PENDING_TRANSACTION" ] && [ ! -e "$RECOVERY_HOLD" ] || {
    _Fail_ 'Unresolved WAN transaction; use Maintenance & Recovery to inspect preferred-DNS restoration'; return 1; }
  if [ "$mode" = scheduled ] && _MaintenancePriorityPending_; then
    _Say_ 'SKIP: interactive maintenance has priority over scheduled DNS checks.'
    return 0
  fi
  if ! _AcquireWANLock_; then _Fail_ 'Another WAN watchdog or drill holds the lock'; return 1; fi
  status1="$RUNTIME/member-first-$$"; status2="$RUNTIME/member-confirm-$$"
  survivors="$RUNTIME/member-survivors-$$"
  # EXIT traps can run after local variables leave scope on router BusyBox ash.
  # Reconstruct exact per-process temp paths instead of referring to locals.
  trap '_CleanupMonitorCycle_' EXIT HUP INT TERM
  # Close the admission race if maintenance requested priority while the
  # scheduler was waiting for its WAN lock.
  if [ "$mode" = scheduled ] && _MaintenancePriorityPending_; then
    _Say_ 'SKIP: maintenance requested while scheduler was acquiring the WAN lock.'
    return 0
  fi
  RG_CONFIG_HELD=0
  if ! _AcquireConfigLock_; then
    if [ "$mode" = scheduled ]; then
      _Say_ 'SKIP: configuration commit in progress; next scheduled cycle will retry.'
      return 0
    fi
    _Fail_ 'Configuration commit in progress; retry the manual health check'
    return 1
  fi
  RG_CONFIG_HELD=1
  _SyncPreferredWANLocked_ || return 1
  _ValidateConfiguration_ >/dev/null || return 1
  _PrepareResolverPools_ || return 1
  # Capture both the checks and the policy fingerprint under CONFIG_LOCK.
  # Once this snapshot is prepared, lengthy DNS probes need no config lock.
  RG_MONITOR_CHECKS="$RUNTIME/monitor-checks-$$"
  if [ -e "$RG_MONITOR_CHECKS" ] || [ -L "$RG_MONITOR_CHECKS" ]; then
    return 1
  fi

  if ! cp "$CHECKS" "$RG_MONITOR_CHECKS"; then
    return 1
  fi
  RG_MONITOR_POLICY_EPOCH="$(_GetMonitorPolicyEpoch_)" || return 1

  if ! _ReleaseConfigLock_; then
    _Fail_ 'Unable to release config lock'
    return 1
  fi
  RG_CONFIG_HELD=0
  current="$(_GetActiveWANPool_)" || { _Fail_ 'Active WAN NVRAM list differs from enrolled state; refusing'; return 1; }
  _RequireProbeDependencies_ || return 1
  _ReadMonitoringState_
  _Say_ "ROUTER WAN DoT pool=$current preferred=preferred failures=$failures recoveries=$recoveries"
  RG_HEALTH_PROBE_PHASE=active
  case "$current" in
    preferred|filtered1|filtered2)
      if _ProbeWANMemberStatuses_ "$current" "$status1"; then result=0
      else result=$?; fi ;;
    *)
      if _ProbeResolverPool_ "$current"; then result=0
      else result=$?; fi ;;
  esac
  if [ "$result" -eq 0 ]; then
    if [ "$mode" = scheduled ]; then
      _LogHealthRecovered_ "DNS RECOVERED: WAN pool $current health checks are passing" || :
      if [ "$current" = preferred ]; then _LogHealthyHeartbeat_ || :; fi
    fi
    if [ "$current" = preferred ] || [ "$current" = filtered1 ] || [ "$current" = filtered2 ]; then
      _UpdateWANHistory_ "$current" "$status1" || {
        _Fail_ 'Unable to preserve per-resolver health observations'; return 1;
      }
    fi
    failures=0
    if [ "$current" != preferred ]; then
      RG_HEALTH_PROBE_PHASE=preferred
      if [ "${RG_HEALTH_SHOW_RESOLVERS:-0}" = 1 ]; then
        printf '\n  %sChecking preferred pool for possible recovery (not the active pool):%s\n' \
          "$RG_CYAN" "$RG_RESET"
      fi
      if _ProbeResolverPool_ preferred; then
        recoveries=$((recoveries+1))
        if [ "$recoveries" -ge "$RECOVERY_THRESHOLD" ]; then
          if [ "$mode" = scheduled ] && _CheckAutomaticRecoveryAuthorization_; then
            if _SwitchDNSPool_ "$current" preferred 'preferred WAN resolvers recovered'; then
              recoveries=0
            else
              switch_failure=3
            fi
          else
            _Say_ 'MONITOR ONLY: preferred resolvers recovered; automatic WAN failback not authorized.'
          fi
        fi
      else recoveries=0; fi
    else recoveries=0; fi
  elif [ "$result" -eq 2 ]; then
    failures=0; recoveries=0
    _Say_ 'POLICY INCONCLUSIVE: probe returned an unclassifiable result; no WAN switch.'
    [ "$mode" != scheduled ] || _LogEventOnce_ "inconclusive-$current" "DNS POLICY INCONCLUSIVE: pool=$current; automatic switching blocked" || :
  else
    recoveries=0; failures=$((failures+1))
    [ "$mode" != scheduled ] || _LogEventOnce_ "degraded-$current" "DNS DEGRADED: pool=$current; failure confirmation in progress" || :
    confirm_needed=0
    if [ "$mode" = scheduled ] && [ "$FAST_CONFIRM_SECONDS" -gt 0 ] &&
       [ "$failures" -lt "$FAIL_THRESHOLD" ]; then
      _Say_ "FAST CONFIRM: resolver failure; rechecking in ${FAST_CONFIRM_SECONDS}s (no WAN writes during delay)."
      sleep "$FAST_CONFIRM_SECONDS"
      confirm_needed=1
    elif [ "$failures" -ge "$FAIL_THRESHOLD" ]; then
      # Even if fast confirmation is disabled, require two independent member
      # observations before excluding anything from a live WAN rulelist.
      confirm_needed=1
    fi
    if [ "$confirm_needed" -eq 1 ]; then
      if ! _CheckBootReadiness_ ||
         [ "$(_GetActiveWANPool_ 2>/dev/null || :)" != "$current" ] ||
         [ -e "$PENDING_TRANSACTION" ] || [ -e "$RECOVERY_HOLD" ]; then
        failures=0
        _Say_ 'FAST CONFIRM SKIP: readiness/pool/recovery state changed; no WAN switch.'
        _WriteMonitoringState_
        return 0
      fi
      case "$current" in
        preferred|filtered1|filtered2)
          if _ProbeWANMemberStatuses_ "$current" "$status2"; then alt_rc=0
          else alt_rc=$?; fi ;;
        *)
          if _ProbeResolverPool_ "$current"; then alt_rc=0
          else alt_rc=$?; fi ;;
      esac
      case "$current" in
        preferred|filtered1|filtered2)
          _UpdateWANHistory_ "$current" "$status1" "$status2" || {
            _Fail_ 'Unable to preserve per-resolver health observations'; return 1;
          } ;;
      esac
      if [ "$alt_rc" -eq 0 ]; then
        _Say_ 'INTERMITTENT DNS: first observation failed, confirmation passed; failure evidence retained.'
        # The 6-observation history, not a single successful confirmation,
        # decides whether flapping members have enough independent evidence.
      elif [ "$alt_rc" -eq 2 ]; then
        _Say_ 'FAST CONFIRM INCONCLUSIVE: malformed/unknown result; no WAN switch.'
        _WriteMonitoringState_
        return 0
      fi
      if [ "$alt_rc" -ne 0 ] && [ "$mode" = scheduled ] &&
         [ "$FAST_CONFIRM_SECONDS" -gt 0 ] && [ "$failures" -lt "$FAIL_THRESHOLD" ]; then
        failures=$((failures+1))
        _Say_ "FAST CONFIRM FAILED: two resolver-failure evaluations; failures=$failures threshold=$FAIL_THRESHOLD."
      fi
    fi
    if [ "$failures" -ge "$FAIL_THRESHOLD" ] ||
       { [ -n "$status2" ] && [ -s "$status2" ] &&
         _HasIntermittentFailureEvidence_ "$MEMBER_HISTORY"; }; then
      if [ "$mode" = scheduled ]; then
        if ! _CheckBootReadiness_ ||
           [ "$(_GetActiveWANPool_ 2>/dev/null || :)" != "$current" ] ||
           [ -e "$PENDING_TRANSACTION" ] || [ -e "$RECOVERY_HOLD" ]; then
          failures=0
          _Say_ 'FAILOVER SAFETY HOLD: readiness/pool/recovery changed; no WAN switch.'
          _WriteMonitoringState_; return 0
        fi
      fi
      selected=''; proposed=''; eligible=1
      case "$current" in
        preferred|filtered1|filtered2)
          # Permit individually confirmed failures even if unrelated members
          # fluctuate. Keep any fluctuating member in its existing state, but
          # require at least one independent PASS/PASS member before pruning.
          # Only classified endpoint failures are eligible. Malformed member
          # inventory, unclassifiable probe results or no PASS/PASS survivor
          # prevent WAN pruning. All confirmed failures may prompt evaluation
          # of an independently verified alternative pool.
          if [ ! -s "$status2" ]; then
            eligible=0
            _Say_ '  FAILOVER SAFETY HOLD: no second member observation.'
          elif _PlanConfirmedWANExclusion_ "$status1" "$status2" "$survivors" "$MEMBER_HISTORY"; then
            proposed="$(_BuildFilteredRulelistFromMembers_ "$survivors")" || proposed=''
            if [ -n "$proposed" ] && [ "$proposed" != "$(_ReadWANRulelist_)" ]; then
              case "$current" in filtered1) target=filtered2;; *) target=filtered1;; esac
              selected="$target"
              _Say_ '  Confirmed unhealthy endpoint(s), including corroborated intermittent failures; unconfirmed changing members retained.'
            else
              eligible=0
              _Say_ '  FAILOVER SAFETY HOLD: no verified changed WAN subset; retaining current WAN DNS.'
            fi
          else
            case "$?" in
              3) _Say_ '  All active WAN endpoints confirmed unhealthy; evaluating verified alternate DNS pools.' ;;
              1) eligible=0
                 _Say_ '  No individually confirmed failing WAN endpoint; retaining current WAN DNS.' ;;
              4) eligible=0
                 _Say_ '  FAILOVER SAFETY HOLD: no independently confirmed healthy WAN survivor.' ;;
              *) eligible=0
                 _Say_ '  FAILOVER SAFETY HOLD: inconsistent member inventory or inconclusive policy.' ;;
            esac
          fi ;;
      esac
      if [ -n "$selected" ]; then
        if [ "$mode" = scheduled ] && _CheckAutomaticFailoverAuthorization_; then
          if _SwitchDNSPool_ "$current" "$selected" 'DNS answer policy failed' "$proposed"; then
            failures=0
            _Say_ '  Confirmed failing WAN endpoint(s) excluded; remaining configured upstreams retained (changing statuses not presumed healthy).'
          else
            switch_failure=3
          fi
        else
          _Say_ '  MONITOR ONLY: proposed endpoint exclusion not applied; no WAN change.'
        fi
      elif [ "$eligible" -ne 1 ]; then
        _Say_ '  FAILOVER SAFETY HOLD: confirmed-safe subset unavailable; retaining current WAN DNS.'
      else
        # All preferred endpoints failed consistently, or current independent
        # backup pool failed. Verify an eligible alternate before writing WAN.
        while IFS='|' read -r pool backup _; do
          case "$current:$pool" in
            preferred:backup[0-9]*|preferred:wanpool[0-9]*|filtered1:backup[0-9]*|filtered1:wanpool[0-9]*|filtered2:backup[0-9]*|filtered2:wanpool[0-9]*|backup[0-9]*:backup[0-9]*|backup[0-9]*:wanpool[0-9]*|wanpool[0-9]*:backup[0-9]*|wanpool[0-9]*:wanpool[0-9]*) :;;
            *) continue;;
          esac
          [ "$pool" != "$current" ] || continue
          _Say_ "  Checking alternate DNS pool $pool ($backup)"
          RG_HEALTH_PROBE_PHASE=alternate
          if _ProbeResolverPool_ "$pool" && _ProbeResolverPool_ "$pool"; then
            selected="$pool"; break
          fi
        done < "$POOLS"
        if [ -n "$selected" ]; then
          if [ "$mode" = scheduled ] && _CheckAutomaticFailoverAuthorization_; then
            if _SwitchDNSPool_ "$current" "$selected" 'DNS answer policy failed'; then
              failures=0
            else
              switch_failure=3
            fi
          else
            _Say_ '  MONITOR ONLY: alternate DNS pool healthy; no WAN switch authorized.'
          fi
        else
          _Say_ 'NO VERIFIED ELIGIBLE SUBSET OR INDEPENDENT BACKUP; keeping current WAN DNS (no downgrade).'
          [ "$mode" != scheduled ] || _LogEventOnce_ "no-backup-$current" "DNS ALERT: no confirmed safe WAN subset or independent backup; retaining current Strict DoT" || :
        fi
      fi
    fi
  fi
  # Discard observations and counters derived from an obsolete policy.
  # Any actual WAN write has an additional epoch guard at the switch boundary.
  if [ "$(_GetMonitorPolicyEpoch_)" != "$RG_MONITOR_POLICY_EPOCH" ]; then
    failures=0
    recoveries=0
    rm -f "$MEMBER_HISTORY" || :
    _Say_ 'MONITOR SAFETY HOLD: configuration changed during health check; counters reset.'
    switch_failure=0
  fi
  # Surface an attempted-but-failed DNS switch to cron/CLI even when
  # rollback was successful. 0 means no switch failed (including monitor-only
  # and no-authorized-candidate outcomes); 3 identifies a switch failure.
  if [ "$mode" = scheduled ]; then
    if ! _WriteMonitoringState_; then
      _Fail_ 'Unable to persist DNS health counters'
      [ "$switch_failure" -ne 0 ] || return 1
    fi
  fi
  _PrintManualHealthSummary_
  return "$switch_failure"
)

# Only interactive setup / an explicit dependencies command may install packages.
# Never run opkg from cron, boot reconciliation, health checks or failover.
# Entware itself is an operator-managed prerequisite; do not bootstrap it.
_EnsureDigDependency_() {
  # Quick Setup verifies the dependency again, but an already-installed dig
  # needs no second success message. Explicit dependency checks stay verbose.
  if [ -x "$DIG" ]; then
    if [ "${1:-}" != quiet ]; then
      _Say_ "DNS dependency ready: $DIG is available (nothing to install)."
    fi
    return 0
  fi
  _Say_ "Entware DNS query tool is missing: $DIG"
  if [ ! -x "$ENTWARE_OPKG" ]; then
    _Fail_ 'Entware is not installed or opkg is unavailable. Install Entware using amtm, then restart Quick Setup.'
    return 1
  fi
  _Say_ 'ResolvGuard needs the Entware bind-dig package for DNS response checks.'
  _ConfirmYesNo_ 'Install bind-dig with Entware now?' || {
    _Fail_ 'bind-dig is required; installation cancelled. No DNS settings were changed.'
    return 1
  }
  _Say_ 'Refreshing Entware package lists...'
  if ! "$ENTWARE_OPKG" update; then
    _Fail_ 'Entware package index update failed; bind-dig was not installed by ResolvGuard.'
    return 1
  fi
  _Say_ 'Installing bind-dig...'
  if ! "$ENTWARE_OPKG" install bind-dig; then
    _Fail_ 'Entware could not install bind-dig. Review opkg output before retrying.'
    return 1
  fi
  if [ ! -x "$DIG" ]; then
    _Fail_ "bind-dig installation finished but $DIG is still unavailable. Check Entware installation."
    return 1
  fi
  _Say_ 'Dependency ready: bind-dig provides /opt/bin/dig.'
  return 0
}

# Installer-only progress presentation: colors on an interactive terminal,
# with a brief pause between successful phases so SSH users can read them.
# Never delay unattended/redirected output or the normal runtime/cron paths.
_ShowInstallStage_() {
  printf '\n  %s%s[%s/4] %s%s\n' "$RG_CYAN" "$RG_BOLD" "$1" "$2" "$RG_RESET"
  printf '  %s\n' '------------------------------------------------------------'
}

_InstallProgressPause_() {
  if [ -t 0 ] && [ -t 1 ]; then
    sleep "${1:-1}"
  fi
}

# AMTM-style installation lifecycle. The installer performs no DNS enrollment,
# cron writes, WAN changes, or automatic-failover approval. Quick Setup remains
# the separate, operator-driven next step.
_IsInstallationComplete_() {
  [ "$ROOT" = "$INSTALL_ROOT" ] &&
    [ -f "$INSTALL_ROOT/resolvguard.sh" ] && [ ! -L "$INSTALL_ROOT/resolvguard.sh" ] &&
    [ -f "$INSTALL_MARKER" ] && [ ! -L "$INSTALL_MARKER" ] &&
    grep -Fx "ResolvGuard installation complete (schema $CONFIG_SCHEMA)" "$INSTALL_MARKER" >/dev/null 2>&1
}

_InstallPrerequisites_() {
  local cmd
  [ -x "$STUBBY" ] || { _Fail_ "Merlin firmware Stubby is unavailable: $STUBBY"; return 1; }
  [ -r "$CA_FILE" ] || { _Fail_ "TLS CA certificate bundle is unavailable: $CA_FILE"; return 1; }
  for cmd in nvram cru service awk grep sed cp cmp chmod ln mkdir rm sh; do
    which "$cmd" >/dev/null 2>&1 || { _Fail_ "Required router command missing: $cmd"; return 1; }
  done
  [ -f "$SOURCE_FILE" ] && [ ! -L "$SOURCE_FILE" ] && sh -n "$SOURCE_FILE" || {
    _Fail_ 'Installation source script is missing, unsafe or syntactically invalid'; return 1;
  }
  _EnsureDigDependency_ || return 1
  return 0
}

_InstallResolvGuard_() (
  # The EXIT trap runs after shell function-local variables may have gone out
  # of scope on BusyBox ash. This function already runs in a subshell, so
  # keep cleanup state in that subshell rather than declaring it local.
  target="$INSTALL_ROOT/resolvguard.sh"
  source_lock="$INSTALL_ROOT/.install-in-progress"
  stage="$INSTALL_ROOT/.resolvguard.install.$$"
  marker_stage="$STATE_DIR/.installation-complete.$$"
  new_install=0
  created_marker=0
  owned_lock=0
  published_target=0
  if _IsInstallationComplete_; then
    _InstallPrerequisites_ || exit 1
    _InitializeMissingConfiguration_ || exit 1
    _Say_ 'ResolvGuard is already installed; existing configuration preserved.'
    _InstallLauncher_ || :
    exit 0
  fi
  if [ -L "$INSTALL_ROOT" ] || { [ -e "$INSTALL_ROOT" ] && [ ! -d "$INSTALL_ROOT" ]; }; then
    _Fail_ "Unsafe installation directory: $INSTALL_ROOT"; exit 1
  fi
  # A preexisting, unmatched target must never be overwritten by a staged
  # installer. Invoke that installed script's 'install' command to recover it.
  if [ -e "$target" ] || [ -L "$target" ]; then
    [ -f "$target" ] && [ ! -L "$target" ] && [ "$SOURCE_FILE" = "$target" ] || {
      _Fail_ 'Unrecognized incomplete installation at target; refusing to overwrite it'; exit 1;
    }
    # Only genuinely new, unconfigured installs are eligible for failed-install
    # script deletion. Do not strand a previous DNS-enrolled installation.
    if [ ! -e "$PREF_RULELIST" ] && [ ! -L "$PREF_RULELIST" ] &&
       [ ! -e "$SCHEDULE_MARKER" ] && [ ! -L "$SCHEDULE_MARKER" ] &&
       [ ! -e "$PENDING_TRANSACTION" ] && [ ! -L "$PENDING_TRANSACTION" ] &&
       [ ! -e "$RECOVERY_HOLD" ] && [ ! -L "$RECOVERY_HOLD" ] &&
       [ ! -e "$INSTALL_MARKER" ] && [ ! -L "$INSTALL_MARKER" ]; then
      new_install=1
    fi
  fi
  # Acquire the installer lock before dependency installation and cleanup.
  # This prevents a failed concurrent invocation from removing another
  # installer's in-flight main script.
  (umask 077; mkdir -p "$INSTALL_ROOT") || { _Fail_ 'Cannot create installation directory'; exit 1; }
  [ ! -L "$INSTALL_ROOT" ] || { _Fail_ 'Unsafe installation directory symlink'; exit 1; }
  (umask 077; mkdir "$source_lock") 2>/dev/null || {
    _Fail_ 'Another install is in progress (or an install lock needs attention)'; exit 1;
  }
  owned_lock=1
  _SetMenuPalette_
  printf '\n%s%s  ResolvGuard Installation — Initializing%s\n' "$RG_YELLOW" "$RG_BOLD" "$RG_RESET"
  _ShowInstallStage_ 1 'Checking router prerequisites and DNS dependency'
  _InstallationCleanup_() {
    cleanup_rc=$?
    rm -f "$stage" "$marker_stage" 2>/dev/null || :
    if [ "$cleanup_rc" -ne 0 ] && [ "$created_marker" = 1 ]; then
      rm -f "$INSTALL_MARKER" || :
    fi
    if [ "$cleanup_rc" -ne 0 ] && { [ "$new_install" = 1 ] || [ "$published_target" = 1 ]; }; then
      rm -f "$target" || :
    fi
    if [ "$owned_lock" = 1 ]; then
      rmdir "$source_lock" 2>/dev/null || :
    fi
  }
  trap '_InstallationCleanup_' EXIT
  trap 'exit 130' INT
  trap 'exit 143' HUP TERM
  _InstallPrerequisites_ || exit 1
  printf '  %sRouter prerequisites verified.%s\n' "$RG_GREEN" "$RG_RESET"
  _InstallProgressPause_
  _ShowInstallStage_ 2 'Preparing configuration files'
  _InitializeMissingConfiguration_ || exit 1
  printf '  %sConfiguration files ready.%s\n' "$RG_GREEN" "$RG_RESET"
  _InstallProgressPause_
  _ShowInstallStage_ 3 'Publishing the installed script and state'
  [ -d "$STATE_DIR" ] && [ ! -L "$STATE_DIR" ] || {
    [ ! -e "$STATE_DIR" ] && [ ! -L "$STATE_DIR" ] || {
      _Fail_ 'Unsafe state directory'; exit 1;
    }
    (umask 077; mkdir "$STATE_DIR") || { _Fail_ 'Cannot create install state'; exit 1; }
  }
  # A power loss between writing the marker and atomically publishing the
  # main script can leave a marker with no installed file. Safely recover
  # ONLY our exact known marker in this case (never any DNS/recovery state).
  if [ -f "$INSTALL_MARKER" ] && [ ! -L "$INSTALL_MARKER" ] &&
     [ ! -e "$target" ] && [ ! -L "$target" ] &&
     grep -Fx "ResolvGuard installation complete (schema $CONFIG_SCHEMA)" "$INSTALL_MARKER" >/dev/null 2>&1; then
    rm -f "$INSTALL_MARKER" || { _Fail_ 'Cannot clear interrupted installation marker'; exit 1; }
  fi
  [ ! -e "$INSTALL_MARKER" ] && [ ! -L "$INSTALL_MARKER" ] || {
    _Fail_ 'Incomplete or unsafe installation marker already exists'; exit 1;
  }
  [ ! -e "$marker_stage" ] && [ ! -L "$marker_stage" ] || exit 1
  (umask 077; printf 'ResolvGuard installation complete (schema %s)\n' "$CONFIG_SCHEMA" > "$marker_stage") || exit 1
  # Stage script first. The final main-file path is created atomically only
  # after prerequisites and configuration are ready.
  if [ "$SOURCE_FILE" != "$target" ]; then
    [ ! -e "$stage" ] && [ ! -L "$stage" ] || exit 1
    cp "$SOURCE_FILE" "$stage" && chmod 755 "$stage" &&
      cmp -s "$SOURCE_FILE" "$stage" && sh -n "$stage" || {
      _Fail_ 'Failed to verify staged main script'; exit 1;
    }
    [ ! -e "$target" ] && [ ! -L "$target" ] || {
      _Fail_ 'Main script target appeared during installation; refusing to overwrite'; exit 1;
    }
  fi
  mv "$marker_stage" "$INSTALL_MARKER" || { _Fail_ 'Cannot record installation readiness'; exit 1; }
  created_marker=1
  if [ "$SOURCE_FILE" != "$target" ]; then
    ln "$stage" "$target" 2>/dev/null || {
      _Fail_ 'Cannot atomically publish main script'; exit 1;
    }
    published_target=1
  fi
  _IsInstallationComplete_ || { _Fail_ 'Installation verification failed'; exit 1; }
  printf '  %sResolvGuard installed successfully:%s %s\n' "$RG_GREEN" "$RG_RESET" "$target"
  _InstallProgressPause_
  _ShowInstallStage_ 4 'Preparing the optional command launcher'
  _InstallLauncher_ || _Say_ 'NOTICE: Optional launcher could not be installed.'
  printf '\n  %s%sINSTALLATION COMPLETE%s — Quick Setup will open for first-time configuration.\n' \
    "$RG_GREEN" "$RG_BOLD" "$RG_RESET"
  # The Quick Setup header clears the terminal. Give users a chance to see
  # the final installation result before leaving the initializing screen.
  _InstallProgressPause_ 3
  exit 0
)

_RequireProbeDependencies_() {
  [ -x "$DIG" ] || { _Fail_ "DNS query tool unavailable: $DIG (install Entware dig)"; return 1; }
  [ -r "$CA_FILE" ] || { _Fail_ "TLS certificate authority bundle unavailable: $CA_FILE"; return 1; }
}

# Match an interrupted transaction to a pool we can still reconstruct.
_TransactionRulelistMatchesPool_() {
  local pool observed expected
  pool="$1"; observed="$2"
  case "$pool" in
    preferred) [ "$observed" = "$(cat "$PREF_RULELIST")" ] ;;
    backup[0-9]*|wanpool[0-9]*)
      expected="$(_BuildBackupRulelist_ "$pool")" || return 1
      [ -n "$expected" ] && [ "$observed" = "$expected" ] ;;
    filtered1|filtered2) _IsPreferredSubsetRulelist_ "$observed" ;;
    *) return 1 ;;
  esac
}

# Restore only a previously enrolled preferred configuration; never overwrite an
# unknown GUI/NVRAM change. Interrupted transaction evidence remains on failures.
_RestorePreferredDNSLocked_() {
  local current preferred source target from_pool to_pool tracked part
  [ -s "$PREF_RULELIST" ] && [ ! -L "$PREF_RULELIST" ] || {
    _Fail_ 'Preferred DNS snapshot unavailable'; return 1; }
  [ "$(_ReadNVRAM_ dnspriv_enable)" = 1 ] && [ "$(_ReadNVRAM_ dnspriv_profile)" = 1 ] || {
    _Fail_ 'DNS Privacy must remain enabled and Strict'; return 1; }
  preferred="$(cat "$PREF_RULELIST")"
  current="$(_ReadWANRulelist_)" || return 1
  if [ -e "$PENDING_TRANSACTION" ]; then
    [ -d "$PENDING_TRANSACTION" ] && [ ! -L "$PENDING_TRANSACTION" ] || {
      _Fail_ 'Unsafe pending transaction; no WAN write'; return 1; }
    for part in from-pool to-pool from-rulelist to-rulelist; do
      [ -f "$PENDING_TRANSACTION/$part" ] &&
        [ ! -L "$PENDING_TRANSACTION/$part" ] || {
          _Fail_ 'Incomplete or unsafe WAN transaction; no WAN write'; return 1; }
    done
    from_pool="$(cat "$PENDING_TRANSACTION/from-pool")"
    to_pool="$(cat "$PENDING_TRANSACTION/to-pool")"
    source="$(cat "$PENDING_TRANSACTION/from-rulelist")"
    target="$(cat "$PENDING_TRANSACTION/to-rulelist")"
    [ "$from_pool" != "$to_pool" ] && [ -n "$source" ] &&
      [ -n "$target" ] && [ "$source" != "$target" ] &&
      { [ "$current" = "$source" ] || [ "$current" = "$target" ]; } || {
        _Fail_ 'Pending WAN transaction does not match the live WAN state'; return 1; }
    _PrepareProviders_ && _PrepareResolverPools_ &&
      _TransactionRulelistMatchesPool_ "$from_pool" "$source" &&
      _TransactionRulelistMatchesPool_ "$to_pool" "$target" || {
        _Fail_ 'Pending WAN transaction does not match recognized provider pools'; return 1; }
    _Say_ 'Recovering interrupted managed WAN switch to preferred DNS.'
    if [ "$current" != "$preferred" ]; then
      nvram set "dnspriv_rulelist=$preferred" || {
        _MarkDNSRecoveryHold_ 'Manual recovery WAN NVRAM restore failed; journal retained' || :
        return 1;
      }
      _RestartAndVerifyProductionPool_ preferred || {
        _MarkDNSRecoveryHold_ 'Manual recovery could not restore Strict DoT and LAN DNS' || :
        _Fail_ 'Strict DoT/LAN DNS not restored; transaction retained'; return 1;
      }
    elif ! _WaitForProductionPool_ preferred; then
      _RestartAndVerifyProductionPool_ preferred || {
        _MarkDNSRecoveryHold_ 'Manual recovery could not restart Strict DoT and LAN DNS' || :
        _Fail_ 'Strict DoT/LAN DNS not restored; transaction retained'; return 1;
      }
    fi
    [ "$(_ReadWANRulelist_)" = "$preferred" ] && _WaitForProductionPool_ preferred || {
      _MarkDNSRecoveryHold_ 'Manual recovery still unverified; transaction retained' || :
      _Fail_ 'Preferred Strict DoT/LAN DNS not verified; transaction retained'; return 1; }
    _ClearSwitchIntent_ || return 1
    rm -f "$ACTIVE_POOL" "$ACTIVE_RULELIST" "$RECOVERY_HOLD" || return 1
    _WriteBootReport_ 'SAFE - preferred WAN Strict DoT verified' || :
    _Say_ 'Preferred WAN DNS: RESTORED'
    return 0
  fi
  if [ "$current" = "$preferred" ]; then
    # Do not restart an otherwise running production Stubby merely because
    # all upstream resolvers temporarily time out or return wrong answers.
    # An existing recovery hold still demands transaction-grade verification.
    if [ -e "$RECOVERY_HOLD" ] || [ -L "$RECOVERY_HOLD" ]; then
      if ! _WaitForProductionPool_ preferred; then
        _RestartAndVerifyProductionPool_ preferred || return 1
      fi
    else
      _WaitForProductionPool_ preferred monitoring || return 1
    fi
    rm -f "$ACTIVE_POOL" "$ACTIVE_RULELIST" "$RECOVERY_HOLD" || return 1
    _Say_ 'Preferred WAN DNS: already active'
    return 0
  fi
  [ -r "$ACTIVE_POOL" ] && [ -r "$ACTIVE_RULELIST" ] &&
    [ ! -L "$ACTIVE_POOL" ] && [ ! -L "$ACTIVE_RULELIST" ] &&
    [ "$current" = "$(cat "$ACTIVE_RULELIST")" ] || {
      _Fail_ 'Unrecognized WAN configuration; refusing to overwrite external settings'; return 1; }
  tracked="$(cat "$ACTIVE_POOL")"
  case "$tracked" in backup[0-9]*|wanpool[0-9]*|filtered1|filtered2) :;; *) _Fail_ 'Invalid managed backup pool'; return 1;; esac
  _PrepareProviders_ && _PrepareResolverPools_ || return 1
  [ "$(_BuildBackupRulelist_ "$tracked")" = "$current" ] || {
    _Fail_ 'Backup provider configuration differs from enrolled managed state'; return 1; }
  if ! _SwitchDNSPool_ "$tracked" preferred 'manual restore to preferred'; then
    return 1
  fi
  rm -f "$RECOVERY_HOLD" || return 1
  _Say_ 'Preferred WAN DNS: RESTORED'
}

_RestorePreferredDNS_() (
  [ -s "$PREF_RULELIST" ] || { _Fail_ 'Enroll preferred WAN DNS first'; return 1; }
  _ConfirmYesNo_ 'Restore preferred WAN DNS? (May restart Stubby)' || return 1
  if ! _AcquireWANLockForMaintenance_; then
    _Fail_ 'Unable to reserve WAN access for restore'
    return 1
  fi
  trap '_CleanupMaintenanceLocks_' EXIT HUP INT TERM
  _AcquireConfigLock_ || { _Fail_ 'Configuration commit in progress; restore deferred'; return 1; }
  RG_CONFIG_LOCK_ALREADY_HELD=1
  _RestorePreferredDNSLocked_
)



_ShowStatus_() {
  local active current_rulelist excluded address port tls_hostname sync_ok=1
  if ! _SyncPreferredWAN_; then
    sync_ok=0
    _Say_ 'NOTICE: Another DNS operation is active or WAN synchronization is unverified.'
    _Say_ 'Showing read-only status; no synchronization or shared provider-file writes attempted.'
  fi
  if [ "$sync_ok" -eq 1 ]; then
    _PrepareProviders_ || { _Fail_ 'Unable to prepare resolver information'; return 1; }
    _PrepareResolverPools_ || { _Fail_ 'Unable to prepare resolver pools'; return 1; }
  fi
  active="$(_GetActiveWANPool_ 2>/dev/null)" || active='UNKNOWN / EXTERNAL CHANGE'
  if [ "$sync_ok" -eq 0 ]; then
    active="$(_GetWANLockDisplay_ 2>/dev/null)" || active='WAN NOT VERIFIED'
  fi
  _Say_ "$SCRIPT_NAME root=$ROOT SCRIPT_VERSION=$SCRIPT_VERSION SCRIPT_VERSTAG=$SCRIPT_VERSTAG SCRIPT_BRANCH=$SCRIPT_BRANCH"
  _Say_ "Production WAN DoT pool: $active"
  case "$active" in
    filtered1|filtered2)
      # Status is read-only. A failed membership read must not change WAN DNS.
      current_rulelist="$(_ReadWANRulelist_ 2>/dev/null)" || current_rulelist=''
      if [ -n "$current_rulelist" ]; then
        excluded="$(_ListExcludedPreferredDNSMembers_ "$current_rulelist" 2>/dev/null)" || excluded=''
        if [ -n "$excluded" ]; then
          _Say_ 'Currently excluded preferred DNS resolvers:'
          while IFS='|' read -r address port tls_hostname; do
            _Say_ "  address=$address port=$port tls_auth=$tls_hostname"
          done <<EOF_CURRENT_EXCLUSIONS
$excluded
EOF_CURRENT_EXCLUSIONS
        fi
      fi
      ;;
  esac
  _Say_ 'Router-wide mode: all LAN DNS clients retain the existing DNSMasq -> production Stubby path.'
  _Say_ 'Monitor targets do NOT receive domain-specific routing.'
  [ -r "$PREF_RULELIST" ] && _Say_ 'Preferred WAN list captured: yes' || _Say_ 'Preferred WAN list captured: no (run enroll)'
  [ -r "$PREF_RULELIST" ] && _Say_ "Preferred DNS rollback snapshot: $PREF_RULELIST"
  _ReadMonitoringState_
  _Say_ "Failure counter=$failures recovery counter=$recoveries"
  _ShowPolicyStatus_
  _ShowScheduleStatus_
  if [ "$sync_ok" -eq 1 ]; then
    _Say_ 'Available pools:'
    cat "$POOLS"
  else
    _Say_ 'Available pools: deferred until current DNS operation finishes.'
  fi
}



_GetScheduleSpec_() {
  case "$SCHEDULE_INTERVAL_MINUTES" in
    1) printf '* * * * *' ;;
    60) printf '0 * * * *' ;;
    *) printf '*/%s * * * *' "$SCHEDULE_INTERVAL_MINUTES" ;;
  esac
}

_GetScheduleJobCommand_() {
  printf '%s /bin/sh %s/resolvguard.sh scheduled-check >> /tmp/resolvguard/scheduled.log 2>&1' "$(_GetScheduleSpec_)" "$ROOT"
}

_RegisterScheduleCron_() {
  local logfile cron_list
  # Cron opens redirected stdout before the script's own umask executes.
  logfile="$RUNTIME/scheduled.log"
  [ ! -L "$logfile" ] && { [ ! -e "$logfile" ] || [ -f "$logfile" ]; } || {
    _Fail_ 'Unsafe scheduled log path (symlink/non-regular file)'; return 1; }
  if [ ! -e "$logfile" ]; then
    (umask 077; : > "$logfile") || return 1
  fi
  chmod 600 "$logfile" || return 1
  cru a "$SCHEDULE_JOB" "$(_GetScheduleJobCommand_)" || {
    _Fail_ 'Unable to register named Merlin cron job'; return 1; }
  cron_list="$(cru l 2>/dev/null)" || {
    _Fail_ 'Unable to read Merlin cron jobs after registration'; return 1; }
  printf '%s\n' "$cron_list" | grep -F "$SCHEDULE_JOB" >/dev/null || {
    _Fail_ 'Registered cron job could not be verified'; return 1; }
}

_CheckOwnedStartupHook_() {
  local hook begin end
  hook="$HOOK_DIR/services-start"
  [ ! -e "$hook" ] && [ ! -L "$hook" ] && return 0
  [ -f "$hook" ] && [ ! -L "$hook" ] || { _Fail_ 'Unsafe services-start hook (not a regular file)'; return 1; }
  begin="$(grep -Fxc '# RESOLVGUARD BEGIN' "$hook" || :)"
  end="$(grep -Fxc '# RESOLVGUARD END' "$hook" || :)"
  [ "$begin" = "$end" ] && [ "$begin" -le 1 ] || { _Fail_ 'Ambiguous ResolvGuard services-start markers'; return 1; }
  # Do not allow a misplaced closing marker to silently consume other code.
  if [ "$begin" = 1 ]; then
    awk '/^# RESOLVGUARD BEGIN$/ {b=NR} /^# RESOLVGUARD END$/ {e=NR} END {exit(e>b)?0:1}' "$hook" || {
      _Fail_ 'Out-of-order ResolvGuard services-start markers'; return 1; }
    grep -Fqx "/bin/sh $ROOT/resolvguard.sh startup >> /tmp/resolvguard-startup.log 2>&1 &" "$hook" || {
      _Fail_ 'Existing ResolvGuard startup hook content differs; review manually'; return 1; }
  fi
}

_InstallScheduleHook_() {
  local hook staged success_output
  success_output="${1:-verbose}"
  hook="$HOOK_DIR/services-start"
  _CheckOwnedStartupHook_ || return 1
  [ -d "$HOOK_DIR" ] && [ -w "$HOOK_DIR" ] || { _Fail_ "Hook directory unavailable: $HOOK_DIR"; return 1; }
  if [ -f "$hook" ] && grep -Fqx '# RESOLVGUARD BEGIN' "$hook"; then
    [ "$success_output" = quiet ] || _Say_ 'Startup hook: already installed'
    return 0
  fi
  staged="$HOOK_DIR/.services-start-resolvguard-$$"
  if [ -f "$hook" ]; then
    cp -p "$hook" "$staged" || return 1
  else
    (umask 077; printf '#!/bin/sh\n' > "$staged") || return 1
  fi
  {
    printf '%s\n' '# RESOLVGUARD BEGIN'
    printf '/bin/sh %s/resolvguard.sh startup >> /tmp/resolvguard-startup.log 2>&1 &\n' "$ROOT"
    printf '%s\n' '# RESOLVGUARD END'
  } >> "$staged" || { rm -f "$staged"; return 1; }
  chmod +x "$staged" && mv "$staged" "$hook" || {
    rm -f "$staged"; return 1; }
}

_RemoveScheduleHook_() {
  local hook staged
  hook="$HOOK_DIR/services-start"
  _CheckOwnedStartupHook_ || return 1
  [ -f "$hook" ] || return 0
  grep -Fqx '# RESOLVGUARD BEGIN' "$hook" || return 0
  staged="$HOOK_DIR/.services-start-uninstall-$$"
  cp -p "$hook" "$staged" || return 1
  sed '/^# RESOLVGUARD BEGIN$/,/^# RESOLVGUARD END$/d' "$hook" > "$staged" || {
    rm -f "$staged"; return 1; }
  chmod +x "$staged" && mv "$staged" "$hook" || {
    rm -f "$staged"; return 1; }
}

_ShowScheduleStatus_() {
  if [ -r "$SCHEDULE_MARKER" ]; then _Say_ 'Monitoring schedule: ENABLED'
  else _Say_ 'Monitoring schedule: DISABLED (no recurring checks)'; fi
  _Say_ "Interval: $SCHEDULE_INTERVAL_MINUTES minute(s); startup warmup: $BOOT_MIN_UPTIME_SECONDS seconds"
  if [ "$FAST_CONFIRM_SECONDS" -gt 0 ]; then
    _Say_ "Fast failure confirmation: ENABLED (${FAST_CONFIRM_SECONDS}s; scheduled checks only)"
  else
    _Say_ 'Fast failure confirmation: DISABLED'
  fi
  _Say_ "Readiness: NTP and WAN connectivity required"
  if [ -r "$SCHEDULE_MARKER" ]; then
    if [ -f "$HOOK_DIR/services-start" ] && grep -Fqx '# RESOLVGUARD BEGIN' "$HOOK_DIR/services-start"; then
      _Say_ 'Boot hook: installed (services-start)'
    else _Say_ 'WARNING: boot hook missing'; fi
    if cru l 2>/dev/null | grep -F "$SCHEDULE_JOB" >/dev/null; then
      _Say_ "Cron job: registered ($SCHEDULE_JOB)"
    else _Say_ 'WARNING: cron job not currently registered or scheduler is not responding'; fi
  fi
  if [ -r "$BOOT_REPORT" ]; then _Say_ "Last boot reconciliation: $(cat "$BOOT_REPORT")"; fi
  [ ! -e "$PENDING_TRANSACTION" ] || _Say_ "ATTENTION: Interrupted WAN transaction: $PENDING_TRANSACTION"
  [ ! -e "$RECOVERY_HOLD" ] || _Say_ "ATTENTION: $(cat "$RECOVERY_HOLD")"
  if [ ! -r "$SCHEDULE_MARKER" ]; then
    _Say_ 'Operating mode: INACTIVE (scheduled monitoring and automatic switching disabled).'
  elif [ ! -r "$AUTO_FAILOVER_MARKER" ]; then
    _Say_ 'Operating mode: MONITORING ONLY (scheduled checks active; WAN switching disabled).'
  elif _CheckAutomaticFailoverAuthorization_ >/dev/null 2>&1; then
    _Say_ 'Operating mode: AUTOMATIC FAILOVER ENABLED (approved policy).'
  else
    _Say_ 'Operating mode: POLICY SAFETY HOLD (new failovers blocked; managed backup may recover).' 
  fi
}

# A read-only resolver watchdog is useful even if firmware DNSMasq files are
# unavailable or forwarding is temporarily broken. This exemption is ONLY for
# Monitoring Only; it cannot clear a recovery journal or authorize WAN writes.
# Refuse it if the WAN is not EXACTLY the enrolled preferred pool, any managed
# transaction/state/lock remains, or authenticated Stubby identities are wrong.
_AllowMonitoringOnlyWithoutLANForwarding_() {
  [ ! -e "$AUTO_FAILOVER_MARKER" ] && [ ! -L "$AUTO_FAILOVER_MARKER" ] &&
    [ ! -e "$PENDING_TRANSACTION" ] && [ ! -L "$PENDING_TRANSACTION" ] &&
    [ ! -e "$RECOVERY_HOLD" ] && [ ! -L "$RECOVERY_HOLD" ] &&
    [ ! -e "$ACTIVE_POOL" ] && [ ! -L "$ACTIVE_POOL" ] &&
    [ ! -e "$ACTIVE_RULELIST" ] && [ ! -L "$ACTIVE_RULELIST" ] &&
    [ ! -e "$PREFERRED_SYNC" ] && [ ! -L "$PREFERRED_SYNC" ] &&
    [ ! -e "$WAN_LOCK" ] && [ ! -L "$WAN_LOCK" ] || return 1
  [ -s "$PREF_RULELIST" ] && [ ! -L "$PREF_RULELIST" ] &&
    [ -s "$PREF_PROVIDERS" ] && [ ! -L "$PREF_PROVIDERS" ] || return 1
  [ "$(_ReadNVRAM_ dnspriv_enable)" = 1 ] &&
    [ "$(_ReadNVRAM_ dnspriv_profile)" = 1 ] &&
    [ "$(_ReadWANRulelist_)" = "$(cat "$PREF_RULELIST")" ] &&
    _VerifyLiveEndpoints_ preferred && _StubbyDaemonRunning_
}

_EnableScheduledMonitoring_() {
  local staged unattended success_output
  unattended="${1:-ask}"
  success_output="${2:-verbose}"
  [ "$ROOT" = "$INSTALL_ROOT" ] || { _Fail_ 'Enable scheduler only from installed add-on directory'; return 1; }
  _SyncPreferredWAN_ || return 1
  _ValidateConfiguration_ >/dev/null || return 1
  _RequireProbeDependencies_ || return 1
  [ -r "$PREF_RULELIST" ] && [ -r "$PREF_PROVIDERS" ] || {
      _Fail_ 'Enroll preferred WAN DNS before scheduling'; return 1; }
  _CheckOwnedStartupHook_ || return 1
  [ -d "$HOOK_DIR" ] && [ -w "$HOOK_DIR" ] || { _Fail_ "Hook directory unavailable: $HOOK_DIR"; return 1; }
  [ "$(_ReadNVRAM_ dnspriv_enable)" = 1 ] && [ "$(_ReadNVRAM_ dnspriv_profile)" = 1 ] &&
    _IsStrictProductionDoT_ || { _Fail_ 'Strict authenticated production DoT required before scheduling'; return 1; }
  [ "$(_GetActiveWANPool_ 2>/dev/null)" = preferred ] || {
    _Fail_ 'First enable requires enrolled preferred WAN pool active'; return 1; }
  if ! _ReconcileBootState_ quiet; then
    # No recovery evidence may be cleared by this path. Monitoring Only
    # continues checking individual authenticated DoT endpoints, but WAN writes
    # remain prohibited until the DNSMasq forwarding proof passes normally.
    if _AllowMonitoringOnlyWithoutLANForwarding_; then
      _WriteBootReport_ 'MONITORING ONLY - Strict DoT verified; LAN forwarding unverified; automatic switching prohibited' || :
      _Say_ 'WARNING: LAN DNS forwarding unverified; monitoring only.'
    else
      _Fail_ 'Boot/recovery state not verified; monitoring cannot safely start'
      return 1
    fi
  fi
  [ "$(_ReadNVRAM_ jffs2_scripts)" = 1 ] || {
    _Fail_ 'Enable JFFS custom scripts in Merlin Administration -> System first'; return 1; }
  if [ "$unattended" != confirmed ] && [ ! -r "$SCHEDULE_MARKER" ]; then
    _ConfirmYesNo_ 'Enable recurring DNS monitoring?' || return 1
  fi
  mkdir -p "$STATE_DIR" || return 1
  if [ -e "$SCHEDULE_MARKER" ]; then
    _InstallScheduleHook_ quiet && _RegisterScheduleCron_ || {
      _Fail_ 'Unable to verify existing monitoring schedule'; return 1; }
  else
    _InstallScheduleHook_ quiet || return 1
    if ! _RegisterScheduleCron_; then
      cru d "$SCHEDULE_JOB" >/dev/null 2>&1 || :
      _RemoveScheduleHook_ || :
      _Fail_ 'Monitoring was not enabled because cron registration failed'
      return 1
    fi
    staged="$SCHEDULE_MARKER.new.$$"
    if ! (umask 077; printf 'enabled\n' > "$staged") ||
       ! mv "$staged" "$SCHEDULE_MARKER"; then
      rm -f "$staged"
      cru d "$SCHEDULE_JOB" >/dev/null 2>&1 || :
      _RemoveScheduleHook_ || :
      _Fail_ 'Monitoring authorization could not be saved'; return 1
    fi
  fi
  # Preserve syslog event wording for diagnostics/consumers; shorten only CLI output.
  _LogEvent_ notice 'DNS MONITORING ENABLED: recurring health checks scheduled' >/dev/null
  [ "$success_output" = quiet ] || _Say_ "DNS monitoring: ON (every $SCHEDULE_INTERVAL_MINUTES min)"
}

_EnableAutomaticFailover_() {
  local approval_status staged view
  view="${1:-detail}"
  [ ! -e "$PENDING_TRANSACTION" ] && [ ! -e "$RECOVERY_HOLD" ] || {
    _Fail_ 'Unresolved recovery state; automatic switching blocked'; return 1; }
  _SyncPreferredWAN_ || return 1
  _ValidateConfiguration_ >/dev/null || return 1
  [ -r "$PREF_RULELIST" ] && [ -r "$PREF_PROVIDERS" ] || {
    _Fail_ 'Enroll preferred WAN DNS first'; return 1; }
  [ "$(_GetActiveWANPool_ 2>/dev/null)" = preferred ] || {
    _Fail_ 'Automatic switching requires preferred WAN DNS active'; return 1; }
  # Establish eligibility before requesting operator consent. The hard
  # forwarding guard runs AFTER consent but BEFORE any scheduler/automatic
  # authorization: a user who declines should not see a failed WAN-write
  # safety check merely because a firmware DNSMasq artifact is unavailable.
  _PrepareProviders_ && _PrepareResolverPools_ || return 1
  if ! awk -F'|' '$1 ~ /^(backup|wanpool)[0-9]+$/ {found=1} END{exit !found}' "$POOLS"; then
    _Fail_ 'Configure at least two distinct WAN provider groups or an independent backup for automatic failover'
    return 1
  fi
  # Outside Quick Setup, present the same security disclosure before consent.
  # A warning already acknowledged in this wizard is not shown a second time.
  _ShowDNSMasqScopedSetupWarning_

  if ! approval_status="$(_GetPolicyApprovalState_)"; then
    if [ "$view" != quick ]; then
      _Say_ "DNS policy approval required: $approval_status"
    fi
    _ApprovePolicy_ 'Approve policy and enable automatic failover?' "$view" || return 1
  else
    _CheckPolicyAuthorization_ || return 1
    _ConfirmYesNo_ 'Enable automatic WAN DNS failover?' || return 1
  fi
  _CheckPolicyAuthorization_ || return 1
  # Consent is not authorization to write. Strict forwarding/service ownership
  # remains a mandatory fail-closed gate for automatic WAN switching.
  # This must precede both scheduler and automatic-switch marker creation.
  _CheckLiveSwitchSafety_ || return 1
  _EnableScheduledMonitoring_ confirmed quiet || return 1
  if ! _AcquireWANLock_; then
    _Fail_ 'Another DNS operation is active; automatic authorization deferred'; return 1
  fi
  (
    trap '_ReleaseWANLock_ >/dev/null 2>&1 || :' EXIT HUP INT TERM
    [ ! -e "$PENDING_TRANSACTION" ] && [ ! -e "$RECOVERY_HOLD" ] &&
      [ "$(_GetActiveWANPool_ 2>/dev/null)" = preferred ] && _CheckPolicyAuthorization_ || {
        _Fail_ 'WAN/policy changed during authorization'; exit 1; }
    [ ! -L "$AUTO_FAILOVER_MARKER" ] || { _Fail_ 'Unsafe authorization marker'; exit 1; }
    failures=0; recoveries=0
    _WriteMonitoringState_ || { _Fail_ 'Unable to reset monitoring counters'; exit 1; }
    if [ ! -e "$AUTO_FAILOVER_MARKER" ]; then
      staged="$AUTO_FAILOVER_MARKER.new.$$"
      (umask 077; printf 'authorized\n' > "$staged") &&
        mv "$staged" "$AUTO_FAILOVER_MARKER" || {
          rm -f "$staged"; _Fail_ 'Unable to authorize automatic WAN switching'; exit 1; }
    fi
  ) || return 1
  _LogEvent_ notice 'AUTOMATIC FAILOVER ENABLED: approved DNS policy; scheduled health checks active' >/dev/null
  _Say_ "Automatic failover: ON (monitoring every $SCHEDULE_INTERVAL_MINUTES min)"
}

_DisableAutomaticFailover_() {
  if [ ! -e "$AUTO_FAILOVER_MARKER" ]; then
    _Say_ 'Automatic failover: already OFF'; return 0
  fi
  _ConfirmYesNo_ 'Disable automatic DNS switching (keep monitoring)?' || return 1
  [ ! -L "$AUTO_FAILOVER_MARKER" ] || { _Fail_ 'Unsafe authorization marker'; return 1; }
  rm -f "$AUTO_FAILOVER_MARKER" || return 1
  _LogEvent_ notice 'MONITORING ONLY: automatic WAN switching disabled; scheduled checks retained' >/dev/null
  _Say_ 'Automatic failover: OFF (monitoring remains ON)'
  [ "$(_GetActiveWANPool_ 2>/dev/null || :)" = preferred ] ||
    _Say_ 'WARNING: WAN uses an alternate pool; restore preferred DNS manually if needed.'
}

_DisableScheduledMonitoring_() {
  local success_output
  success_output="${1:-verbose}"
  cru d "$SCHEDULE_JOB" >/dev/null 2>&1 || :
  if ! cru l > "$RUNTIME/cron-list-$$" 2>/dev/null; then
    rm -f "$RUNTIME/cron-list-$$"
    [ ! -e "$SCHEDULE_MARKER" ] || {
      _Fail_ 'Cannot verify removal of scheduled job'; return 1; }
  else
    if grep -F "$SCHEDULE_JOB" "$RUNTIME/cron-list-$$" >/dev/null; then
      rm -f "$RUNTIME/cron-list-$$"
      _Fail_ 'Unable to remove ResolvGuard cron job; schedule remains enabled'; return 1
    fi
    rm -f "$RUNTIME/cron-list-$$"
  fi
  _RemoveScheduleHook_ || return 1
  rm -f "$SCHEDULE_MARKER" "$AUTO_FAILOVER_MARKER" || return 1
  _LogEvent_ notice 'DNS MONITORING DISABLED: scheduler and automatic switching authorization removed' >/dev/null
  [ "$success_output" = quiet ] || _Say_ 'DNS monitoring: OFF (automatic failover OFF)'
}

# Refuse scheduled switching until clock, startup warmup and WAN are ready.
_CheckBootReadiness_() {
  local nowyear ntp up wan0 wan1 wan
  nowyear="$(date -u +%Y 2>/dev/null || :)"
  case "$nowyear" in ''|*[!0-9]*) _Say_ 'SKIP: system clock not ready'; return 1;; esac
  [ "$nowyear" -ge 2024 ] || { _Say_ 'SKIP: system clock not synchronized'; return 1; }
  if [ -r /proc/uptime ]; then
    up="$(awk '{split($1,a,".");print a[1]}' /proc/uptime)"
    case "$up" in ''|*[!0-9]*) _Say_ 'SKIP: cannot determine uptime'; return 1;; esac
    [ "$up" -ge "$BOOT_MIN_UPTIME_SECONDS" ] || {
      _Say_ 'SKIP: router still in post-boot warmup'; return 1; }
  fi
  ntp="$(_ReadNVRAM_ ntp_ready 2>/dev/null || :)"
  [ "$ntp" = 1 ] || { _Say_ "SKIP: NTP not confirmed ready (ntp_ready=${ntp:-unset})"; return 1; }
  wan0="$(_ReadNVRAM_ wan0_state_t 2>/dev/null || :)"
  wan1="$(_ReadNVRAM_ wan1_state_t 2>/dev/null || :)"
  wan="$(_ReadNVRAM_ wan_state_t 2>/dev/null || :)"
  [ "$wan0" = 2 ] || [ "$wan1" = 2 ] || [ "$wan" = 2 ] || {
    _Say_ 'SKIP: no Merlin WAN interface reports connected (state 2)'; return 1;
  }
}

_WriteBootReport_() {
  mkdir -p "$STATE_DIR" || return 1
  # Avoid writing the same value to JFFS every cron tick (flash wear).
  if [ -r "$BOOT_REPORT" ] && [ "$(cat "$BOOT_REPORT")" = "$1" ]; then return 0; fi
  (umask 077; printf '%s\n' "$1" > "$BOOT_REPORT.new.$$") &&
    mv "$BOOT_REPORT.new.$$" "$BOOT_REPORT"
}

_ReconcileBootState_() {
  local current preferred tracked expected source target from_pool to_pool part readiness_mode success_output
  success_output="${1:-verbose}"
  [ -r "$PREF_RULELIST" ] || { _Say_ 'BOOT: not enrolled; no changes'; return 1; }
  if [ -e "$WAN_LOCK" ]; then
    if _AcquireWANLock_; then
      _ReleaseWANLock_ >/dev/null 2>&1 || :
    else
      _WriteBootReport_ 'SKIPPED - active/unknown DNS operation holds WAN lock' || :
      _Say_ 'BOOT: WAN operation lock exists; no action'; return 1
    fi
  fi
  # Reconcile a verified external ASUS change first. A temporarily unsettled
  # Stubby file can be retried by the next scheduled check without WAN writes.
  if [ ! -e "$PENDING_TRANSACTION" ] && [ ! -L "$PENDING_TRANSACTION" ] &&
     [ ! -e "$RECOVERY_HOLD" ] && [ ! -L "$RECOVERY_HOLD" ]; then
    if ! _SyncPreferredWAN_; then
      _WriteBootReport_ 'WAIT/BLOCKED - external WAN synchronization not verified' || :
      _Say_ 'BOOT: WAN DNS synchronization not verified; no WAN writes.'
      return 1
    fi
  fi
  current="$(_ReadWANRulelist_)" || return 1
  preferred="$(cat "$PREF_RULELIST")"
  if [ "$current" = "$preferred" ]; then
    # Do not clear a journal or recovery hold based only on matching NVRAM/YAML.
    # This was a confirmed safety gap during the November 11 Stubby outage.
    if [ ! -e "$PENDING_TRANSACTION" ] && [ ! -L "$PENDING_TRANSACTION" ] &&
       [ ! -e "$RECOVERY_HOLD" ] && [ ! -L "$RECOVERY_HOLD" ]; then
      readiness_mode=monitoring
    else
      readiness_mode=transaction
    fi
    if ! _WaitForProductionPool_ preferred "$readiness_mode" "$success_output"; then
      _WriteBootReport_ 'WAIT - preferred configuration present; Strict DoT infrastructure not verified' || :
      _Say_ 'BOOT: preferred settings present, but operational DNS unverified; state retained'
      return 1
    fi
    if [ -e "$PENDING_TRANSACTION" ] || [ -L "$PENDING_TRANSACTION" ]; then
      [ -d "$PENDING_TRANSACTION" ] && [ ! -L "$PENDING_TRANSACTION" ] || {
        _WriteBootReport_ 'BLOCKED - unsafe pending transaction path' || :; return 1;
      }
      for part in from-pool to-pool from-rulelist to-rulelist; do
        [ -f "$PENDING_TRANSACTION/$part" ] && [ ! -L "$PENDING_TRANSACTION/$part" ] || {
          _WriteBootReport_ 'BLOCKED - incomplete pending WAN transaction' || :; return 1;
        }
      done
      source="$(cat "$PENDING_TRANSACTION/from-rulelist")"
      target="$(cat "$PENDING_TRANSACTION/to-rulelist")"
      from_pool="$(cat "$PENDING_TRANSACTION/from-pool")"
      to_pool="$(cat "$PENDING_TRANSACTION/to-pool")"
      [ "$from_pool" != "$to_pool" ] && [ -n "$source" ] &&
        [ -n "$target" ] && [ "$source" != "$target" ] &&
        { [ "$current" = "$source" ] || [ "$current" = "$target" ]; } &&
        _PrepareProviders_ && _PrepareResolverPools_ &&
        _TransactionRulelistMatchesPool_ "$from_pool" "$source" &&
        _TransactionRulelistMatchesPool_ "$to_pool" "$target" || {
          _WriteBootReport_ 'BLOCKED - unrecognized pending WAN transaction' || :
          _Say_ 'BOOT SAFETY HOLD: invalid transaction; evidence retained'; return 1
        }
      _ClearSwitchIntent_ || return 1
    fi
    rm -f "$ACTIVE_POOL" "$ACTIVE_RULELIST" "$RECOVERY_HOLD" || return 1
    _WriteBootReport_ 'SAFE - preferred Strict DoT infrastructure verified; upstreams monitored separately' || :
    [ "$success_output" = quiet ] || _Say_ 'BOOT: verified preferred Strict DoT infrastructure; upstream health handled by monitoring; stale temporary state cleared.'
    return 0
  fi
  if [ ! -e "$PENDING_TRANSACTION" ] &&
     [ -r "$ACTIVE_POOL" ] && [ -r "$ACTIVE_RULELIST" ] &&
     [ "$current" = "$(cat "$ACTIVE_RULELIST")" ]; then
    tracked="$(cat "$ACTIVE_POOL")"
    _PrepareProviders_ && _PrepareResolverPools_ || return 1
    if [ ! -e "$RECOVERY_HOLD" ] && [ ! -L "$RECOVERY_HOLD" ]; then
      readiness_mode=monitoring
    else
      readiness_mode=transaction
    fi
    if _WaitForProductionPool_ "$tracked" "$readiness_mode" "$success_output"; then
      rm -f "$RECOVERY_HOLD"
      _WriteBootReport_ "SAFE - managed backup pool $tracked verified" || :
      [ "$success_output" = quiet ] || _Say_ "BOOT: verified tracked backup pool $tracked; monitoring can resume."
      return 0
    fi
  fi
  if [ -e "$PENDING_TRANSACTION" ]; then
    expected='interrupted WAN transaction'
  else expected='unrecognized WAN change or unverified backup'; fi
  (umask 077; printf '%s\n' "$expected" > "$RECOVERY_HOLD") || :
  _WriteBootReport_ "BLOCKED - $expected" || :
  _Say_ "BOOT SAFETY HOLD: $expected; no WAN settings changed."
  _Say_ "Manual restore: sh $ROOT/resolvguard.sh restore"
  return 1
}

# RESOLVGUARD WEBUI MANUAL CHECK BEGIN
# Manual WebUI checks reuse the policy/authenticated-DoT probe engine but never
# the DNS health watchdog/failover state machine. All work runs in subshells.
_RGManual_() (
  umask 077
  RG_M_DATA="${RUNTIME}/webui"
  RG_M_HOOK=/jffs/scripts/service-event
  RG_M_LOCK=/tmp/addonwebui.lock
  RG_M_BEG='# RESOLVGUARD WEBUI MANUAL BEGIN'
  RG_M_END='# RESOLVGUARD WEBUI MANUAL END'

  message() { printf '%s\n' "ResolvGuard WebUI manual: $*" >&2; }
  quote() {
    printf '%s' "$1" | LC_ALL=C awk '
      BEGIN{printf "\""}
      {
        if(NR>1)printf "\\n"
        for(i=1;i<=length($0);i++) {
          c=substr($0,i,1)
          if(c=="\\")printf "\\\\"
          else if(c=="\"")printf "\\\""
          else if(c==sprintf("%c",9))printf "\\t"
          else if(c==sprintf("%c",13))printf "\\r"
          else if(c=="<")printf "\\u003c"
          else if(c==">")printf "\\u003e"
          else if(c=="&")printf "\\u0026"
          else printf "%s",c
        }
      }
      END{printf "\""}
    '
  }
  epoch() { date +%s 2>/dev/null || printf '0'; }
  atomic() {
    # All published documents are bounded, validated JSON in volatile /tmp.
    [ -d "$RG_M_DATA" ] && [ ! -L "$RG_M_DATA" ] || return 1
    [ ! -L "$RG_M_DATA/manual.htm" ] || return 1
    staged="$RG_M_DATA/.manual-$$.new"
    [ ! -e "$staged" ] && [ ! -L "$staged" ] || return 1
    cat > "$staged" && mv -f "$staged" "$RG_M_DATA/manual.htm"
  }
  error_result() {
    completed=$(epoch)
    {
      printf '{"schema":1,"requestId":';quote "$RG_M_ID"
      printf ',"status":"error","startedEpoch":%s,"completedEpoch":%s,"message":' "$RG_M_STARTED" "$completed"
      quote "$1"
      printf ',"checks":[],"resolvers":[]}\n'
    } | atomic
    message "$1"
    return 1
  }
  hook_body() {
    printf '%s\n' "$RG_M_BEG" \
      'if [ "$1" = "start" ] && [ "$2" = "ResolvGuardManualCheck" ]; then' \
      '  /bin/sh /jffs/addons/ResolvGuard.d/resolvguard.sh webui manual-run >/tmp/resolvguard-webui-manual.log 2>&1 &' \
      'fi' \
      "$RG_M_END"
  }
  update_hook() {
    action="$1"
    [ "$ROOT" = /jffs/addons/ResolvGuard.d ] || { message 'expected installed ResolvGuard path';return 1; }
    [ ! -L "$RG_M_HOOK" ] && { [ ! -e "$RG_M_HOOK" ] || [ -f "$RG_M_HOOK" ]; } || {
      message 'unsafe service-event file';return 1;
    }
    [ -d /jffs/scripts ] && [ ! -L /jffs/scripts ] || { message 'scripts directory missing or unsafe';return 1; }
    exec 9> "$RG_M_LOCK" || return 1
    flock -x 9 || return 1
    count_begin=0;count_end=0
    if [ -f "$RG_M_HOOK" ]; then
      count_begin=$(grep -Fxc "$RG_M_BEG" "$RG_M_HOOK" || :)
      count_end=$(grep -Fxc "$RG_M_END" "$RG_M_HOOK" || :)
    fi
    if [ "$count_begin" -gt 1 ] || [ "$count_end" != "$count_begin" ]; then
      message 'ambiguous existing service-event markers';return 1
    fi
    if [ "$count_begin" = 1 ]; then
      actual=$(sed -n '/^# RESOLVGUARD WEBUI MANUAL BEGIN$/,/^# RESOLVGUARD WEBUI MANUAL END$/p' "$RG_M_HOOK")
      expected=$(hook_body)
      if [ "$actual" != "$expected" ]; then
        message 'owned service-event block differs from expected; refusing modification';return 1
      fi
      [ "$action" = install ] && return 0
    elif [ "$action" = remove ]; then
      return 0
    fi
    staged=/jffs/scripts/.service-event-resolvguard-manual-$$
    [ ! -e "$staged" ] && [ ! -L "$staged" ] || return 1
    if [ -f "$RG_M_HOOK" ]; then
      if [ "$action" = remove ]; then
        sed '/^# RESOLVGUARD WEBUI MANUAL BEGIN$/,/^# RESOLVGUARD WEBUI MANUAL END$/d' "$RG_M_HOOK" > "$staged" || return 1
      else
        cat "$RG_M_HOOK" > "$staged" || return 1
        printf '\n' >> "$staged"
        hook_body >> "$staged" || return 1
      fi
    else
      printf '#!/bin/sh\n\n' > "$staged" || return 1
      hook_body >> "$staged" || return 1
    fi
    chmod 755 "$staged" && mv -f "$staged" "$RG_M_HOOK" || { rm -f "$staged";return 1; }
    return 0
  }
  run() {
    [ "$ROOT" = /jffs/addons/ResolvGuard.d ] || { message 'not running from installed add-on';return 1; }
    [ -d "$RUNTIME" ] && [ ! -L "$RUNTIME" ] || { message 'runtime directory unavailable';return 1; }
    if [ -e "$RG_M_DATA" ] && { [ -L "$RG_M_DATA" ] || [ ! -d "$RG_M_DATA" ]; }; then
      message 'unsafe WebUI runtime directory';return 1
    fi
    mkdir -p "$RG_M_DATA" || return 1
    chmod 700 "$RG_M_DATA" || :
    [ ! -L "$RG_M_DATA/manual.lock" ] || return 1
    exec 7> "$RG_M_DATA/manual.lock" || return 1
    if ! flock -n 7; then
      message 'manual health check already running; request ignored'
      return 1
    fi
    RG_M_STARTED=$(epoch)
    RG_M_ID="${RG_M_STARTED}-$$"
    { printf '{"schema":1,"requestId":';quote "$RG_M_ID"
      printf ',"status":"running","startedEpoch":%s,"completedEpoch":0,"message":"Direct authenticated DoT policy probes running","checks":[],"resolvers":[]}\n' "$RG_M_STARTED"
    } | atomic || return 1

    RG_INSPECT_CONFIG_HELD=0
    RG_INSPECT_DIR=''
    trap '_CleanupInspectorSession_' EXIT HUP INT TERM
    _RequireProbeDependencies_ >/dev/null 2>&1 || { error_result 'Authenticated DoT probe dependency unavailable'; return 1; }
    attempt=0
    until _AcquireConfigLock_; do
      attempt=$((attempt+1))
      [ "$attempt" -lt 6 ] || { error_result 'Configuration busy; manual check deferred';return 1; }
      sleep 1
    done
    RG_INSPECT_CONFIG_HELD=1
    [ ! -L "$RUNTIME/inspectors" ] || { error_result 'Unsafe inspector directory';return 1; }
    mkdir -p "$RUNTIME/inspectors" || { error_result 'Unable to prepare inspector directory';return 1; }
    RG_INSPECT_DIR="$RUNTIME/inspectors/$$"
    [ ! -e "$RG_INSPECT_DIR" ] && [ ! -L "$RG_INSPECT_DIR" ] && mkdir "$RG_INSPECT_DIR" || {
      error_result 'Unable to reserve inspector session';return 1;
    }
    PROVIDERS="$RG_INSPECT_DIR/providers.tsv"
    _ValidateConfiguration_ >/dev/null 2>&1 || { error_result 'Current DNS monitoring policy/configuration failed validation';return 1; }
    [ -f "$CHECKS" ] && [ ! -L "$CHECKS" ] && cp "$CHECKS" "$RG_INSPECT_DIR/checks.tsv" || {
      error_result 'Unable to snapshot the approved DNS checks';return 1;
    }
    if ! _ReleaseConfigLock_; then
      error_result 'Could not release configuration admission lock';return 1
    fi
    RG_INSPECT_CONFIG_HELD=0

    RG_HEALTH_COLOR_ENABLED=0
    RG_HEALTH_SHOW_RESOLVERS=0
    outcomes="$RG_INSPECT_DIR/outcomes.tsv"
    : > "$outcomes" || { error_result 'Unable to create check results';return 1; }
    passed=0;failed=0
    while IFS='|' read -r id ip tls port extra; do
      [ -n "$id" ] || continue
      while IFS='|' read -r name typ rcode count expected extra; do
        case "$name" in ''|\#*) continue;; esac
        # Each call is read-only and authenticates the exact configured TLS peer.
        details=$(_ProbeDNSRecord_ "$id" "$name" "$typ" "$rcode" "$count" "$expected" 2>&1)
        rc=$?
        details=$(printf '%s' "$details" | tr '\n|' '  ' | cut -c 1-360)
        if [ "$rc" -eq 0 ]; then result=PASS;passed=$((passed+1))
        else result=FAIL;failed=$((failed+1)); fi
        printf '%s|%s|%s|%s|%s\n' "$id" "$name" "$typ" "$result" "$details" >> "$outcomes" || {
          error_result 'Unable to save the check details';return 1;
        }
      done < "$RG_INSPECT_DIR/checks.tsv"
    done < "$PROVIDERS"
    [ $((passed+failed)) -gt 0 ] || { error_result 'No DNS policy observations were completed';return 1; }
    complete=$(epoch)
    {
      printf '{"schema":1,"requestId":';quote "$RG_M_ID"
      printf ',"status":"complete","startedEpoch":%s,"completedEpoch":%s' "$RG_M_STARTED" "$complete"
      printf ',"passed":%s,"failed":%s,"checks":[' "$passed" "$failed"
      sep=''
      while IFS='|' read -r id name typ result details; do
        printf '%s{"id":' "$sep";quote "$id"
        printf ',"hostname":';quote "$name"
        printf ',"type":';quote "$typ"
        printf ',"result":';quote "$result"
        printf ',"detail":';quote "$details"
        printf '}'
        sep=,
      done < "$outcomes"
      printf '],"resolvers":['
      sep=''
      while IFS='|' read -r id ip tls port extra; do
        counts=$(awk -F'|' -v key="$id" '$1==key {if($4=="PASS")p++;else if($4=="FAIL")f++} END{printf "%d|%d",p+0,f+0}' "$outcomes")
        good=${counts%%|*};bad=${counts#*|}
        printf '%s{"id":' "$sep";quote "$id"
        printf ',"ip":';quote "$ip"
        printf ',"tls":';quote "$tls"
        printf ',"port":';quote "$port"
        printf ',"passed":%s,"failed":%s}' "$good" "$bad"
        sep=,
      done < "$PROVIDERS"
      printf ']}\n'
    } | atomic || { error_result 'Unable to atomically publish manual results';return 1; }
    return 0
  }
  case "${1:-}" in
    run) run ;;
    status) [ -f "$RG_M_DATA/manual.htm" ] && [ ! -L "$RG_M_DATA/manual.htm" ] && cat "$RG_M_DATA/manual.htm" || { message 'no manual health check result yet';return 1; } ;;
    hook-install) update_hook install ;;
    hook-remove) update_hook remove ;;
    *) message 'Usage: webui [manual-run|manual-status]';return 2 ;;
  esac
)
# RESOLVGUARD WEBUI MANUAL CHECK END
# RESOLVGUARD WEBUI INLINE BEGIN (read-only; generated from reviewed v1.1 controller)
# All controller functions and variables execute in a subshell to avoid
# altering the DNS monitor's globals, options, locks, and exit traps.
_RGWebUI_() (
  umask 077
  RG_ROOT=${RG_WEBUI_ROOT:-$ROOT}
  RG_RUNTIME=${RG_WEBUI_RUNTIME:-$RUNTIME}
  RG_WEB=${RG_WEBUI_WWW:-/www/user}
  RG_MENU=${RG_WEBUI_MENU:-/www/require/modules/menuTree.js}
  RG_MENU_TMP=${RG_WEBUI_MENU_TMP:-/tmp/menuTree.js}
  RG_LOCK=${RG_WEBUI_LOCK:-/tmp/addonwebui.lock}
  RG_SERVERS=${RG_WEBUI_SERVERS:-/tmp/resolv.dnsmasq}
  RG_DATA="$RG_RUNTIME/webui"
  RG_ASSETS="$RG_ROOT/webui"
  RG_TITLE=ResolvGuard
  RG_MARKER='ResolvGuard WebUI Integration v1'

  say() { printf '%s\n' "$*"; }
  err() { printf 'ResolvGuard WebUI: %s\n' "$*" >&2; }
  # HTML/JSON receives no private WAN credentials; never publish config/settings.conf.
  # Print JSON-quoted string with minimal, portable escaping.
  jsonq() {
    printf '%s' "$1" | LC_ALL=C awk '
    BEGIN { printf "\"" }
    {
      if (NR>1) printf "\\n"
      for (i=1;i<=length($0);i++) {
        c=substr($0,i,1)
        if (c=="\\") printf "\\\\"
        else if (c=="\"") printf "\\\""
        else if (c==sprintf("%c",9)) printf "\\t"
        else if (c==sprintf("%c",13)) printf "\\r"
        else if (c=="<") printf "\\u003c"
        else if (c==">") printf "\\u003e"
        else if (c=="&") printf "\\u0026"
        else printf "%s", c
      }
    }
    END { printf "\"" }
    '
  }
  number() { case "$1" in ''|*[!0-9]*) printf '0';; *) printf '%s' "$1";; esac; }
  safe_pool() { case "$1" in preferred|filtered1|filtered2|backup[0-9]*|wanpool[0-9]*) printf '%s' "$1" ;; *) printf unknown ;; esac; }
  mode_name() {
    if [ ! -f "$RG_ROOT/state/monitoring-enabled" ]; then printf inactive
    elif [ ! -f "$RG_ROOT/state/automatic-failover-enabled" ]; then printf monitoring
    elif [ ! -f "$RG_ROOT/state/policy-approval" ]; then printf hold
    else printf automatic; fi
  }
  # Derive exactly the domain-scoped exception type already disclosed by installer.
  # Unrecognized resolver formats are not labelled as verified bypass rules.
  exceptions() {
    [ -f "$RG_SERVERS" ] && [ ! -L "$RG_SERVERS" ] || return 0
    LC_ALL=C awk '
      /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
      {
        line=$0; sub(/^[[:space:]]+/,"",line); sub(/[[:space:]]+$/, "",line)
        sub(/[[:space:]]+#.*$/, "",line); sub(/[[:space:]]+$/, "",line)
        if (substr(line,1,8)!="server=/") next
        item=substr(line,9); idx=index(item,"/"); if(idx<2)next
        d=substr(item,1,idx-1); ip=substr(item,idx+1)
        sub(/[.]$/, "", d)
        if (d !~ /^[A-Za-z0-9-]+([.][A-Za-z0-9-]+)+$/ || d ~ /[.][.]/ || ip=="" || index(ip,"/") || ip !~ /^[0-9a-fA-F:.]+$/) next
        print d"|"ip
      }
    ' "$RG_SERVERS"
  }
  # Import only the completed cron cycle. No probing and no read of current pending
  # cycle; caller invokes this after SCHEDULE UTC END was written.
  extract_cycle() {
    [ -f "$RG_RUNTIME/scheduled.log" ] && [ ! -L "$RG_RUNTIME/scheduled.log" ] || return 1
    LC_ALL=C awk '
     /^SCHEDULE UTC: / {buf=""; start=$3; active=0; next}
     /^SCHEDULE UTC END: / { if ($0 ~ /result=/) {last=buf; last_start=start; last_end=$4; last_rc=$5} next }
     { if (start!="") buf=buf $0 "\n" }
     END { if(last_start!="") {print "CYCLE|"last_start"|"last_end"|"last_rc; printf "%s",last} }
    ' "$RG_RUNTIME/scheduled.log"
  }

  publish() {
    [ -d "$RG_RUNTIME" ] && [ ! -L "$RG_RUNTIME" ] || { err 'runtime unavailable or unsafe'; return 1; }
    if [ -e "$RG_DATA" ] && { [ -L "$RG_DATA" ] || [ ! -d "$RG_DATA" ]; }; then
      err 'refusing unsafe webui runtime directory'; return 1
    fi
    mkdir -p "$RG_DATA" || return 1
    chmod 700 "$RG_DATA" || :
    exec 8> "$RG_DATA/publish.lock" || return 1
    flock -x 8 || return 1
    cycle="$RG_DATA/cycle-$$"
    observations="$RG_DATA/observations-$$"
    trap 'rm -f "$cycle" "$observations" "$RG_DATA"/status-"$$".tmp "$RG_DATA"/history-"$$".tmp "$RG_DATA"/events-"$$".tmp "$RG_DATA"/last-end.new."$$"' EXIT HUP INT TERM
    extract_cycle > "$cycle" || :
    # First publish can precede the first cron cycle. Do not invent green state.
    header=$(sed -n '1p' "$cycle")
    case "$header" in CYCLE\|*) ;; *) header='CYCLE|||result=unknown' ;; esac
    start=$(printf '%s\n' "$header" | cut -d'|' -f2)
    done_at=$(printf '%s\n' "$header" | cut -d'|' -f3)
    result=$(printf '%s\n' "$header" | cut -d'|' -f4 | sed 's/^result=//')
    # Per-resolver state: consider failure on any monitored policy check within
    # the latest complete cycle. Last-pass-only summaries could mask failures.
    awk '
      NR==1 {next}
      {
        line=$0; sub(/^[[:space:]]+/, "", line)
        n=split(line,p,/[[:space:]]+/)
        if(n<3)next
        if (p[1]!="PASS" && p[1]!="FAIL")next
        if(p[2]!~/^[a-zA-Z][a-zA-Z0-9_-]*$/)next
        id=p[2]; if(!(id in seen)){seen[id]=1;ids[++k]=id}
        if(p[1]=="FAIL") fail[id]++
        else pass[id]++
      }
      END {for(i=1;i<=k;i++){id=ids[i];state=fail[id]?"fail":(pass[id]?"ok":"unknown");print id"|"state"|"pass[id]+0"|"fail[id]+0}}
    ' "$cycle" > "$observations"
    # Use the saved enrolled preferred identities; no invented provider names.
    providers="$RG_ROOT/state/preferred-providers.tsv"
    current_pool=preferred
    if [ -f "$RG_ROOT/state/active-pool" ] && [ ! -L "$RG_ROOT/state/active-pool" ]; then
      current_pool=$(sed -n '1p' "$RG_ROOT/state/active-pool")
    fi
    current_pool=$(safe_pool "$current_pool")
    mode=$(mode_name)
    interval=1
    if [ -f "$RG_ROOT/config/settings.conf" ] && [ ! -L "$RG_ROOT/config/settings.conf" ]; then
      setting=$(grep '^SCHEDULE_INTERVAL_MINUTES=' "$RG_ROOT/config/settings.conf" | tail -n 1 | cut -d= -f2 | tr -dc '0-9')
      case "$setting" in 1|2|3|5|10|15|30|60) interval=$setting;; esac
    fi
    epoch=$(date -u +%s 2>/dev/null || printf 0)
    # Make one append per completed cycle by remembering its exact END timestamp.
    old_end=''
    [ -f "$RG_DATA/last-end" ] && old_end=$(cat "$RG_DATA/last-end")
    if [ -n "$done_at" ] && [ "$done_at" != "$old_end" ]; then
      [ ! -L "$RG_DATA/history.tsv" ] || { err 'unsafe history'; return 1; }
      if [ -f "$providers" ] && [ ! -L "$providers" ]; then
        awk -F'|' 'NR==FNR {state[$1]=$2; next}
          $1~/^wan[0-9]+$/ {print $1"|"(state[$1]!=""?state[$1]:"unknown")}
        ' "$observations" "$providers" | while IFS='|' read -r id status; do
          printf '%s|%s|%s\n' "$done_at" "$id" "$status"
        done >> "$RG_DATA/history.tsv"
      fi
      # Preserve the newest 40,320 rows; trim only every 60 completed cycles
      # instead of rewriting the entire file every minute.
      old_trim_count=0
      [ -f "$RG_DATA/trim-count" ] && old_trim_count=$(cat "$RG_DATA/trim-count")
      case "$old_trim_count" in ''|*[!0-9]*) old_trim_count=0 ;; esac
      old_trim_count=$((old_trim_count+1))
      if [ "$old_trim_count" -ge 60 ]; then
        old_trim_count=0
        if [ -f "$RG_DATA/history.tsv" ]; then
          tail -n 40320 "$RG_DATA/history.tsv" > "$RG_DATA/history-$$.tmp" &&
            mv "$RG_DATA/history-$$.tmp" "$RG_DATA/history.tsv"
        fi
      fi
      printf '%s\n' "$old_trim_count" > "$RG_DATA/trim-count.new.$$" &&
        mv "$RG_DATA/trim-count.new.$$" "$RG_DATA/trim-count"
      if [ ! -L "$RG_DATA/events.tsv" ]; then
        grep -E '^(DNS FAILOVER:|DNS FAILBACK:|DNS FILTERED|DNS RESOLVER|DNS RECOVERED:|FAST CONFIRM FAILED:|AUTOMATIC SWITCHING DISABLED:)' "$cycle" 2>/dev/null |
          while IFS= read -r message; do
            # Prevent literal line delimiters from corrupting event records.
            message=$(printf '%s' "$message" | tr '|' '/')
            printf '%s|%s\n' "$done_at" "$message"
          done >> "$RG_DATA/events.tsv"
        tail -n 200 "$RG_DATA/events.tsv" > "$RG_DATA/events-$$.tmp" && mv "$RG_DATA/events-$$.tmp" "$RG_DATA/events.tsv"
      fi
      printf '%s\n' "$done_at" > "$RG_DATA/last-end.new.$$" && mv "$RG_DATA/last-end.new.$$" "$RG_DATA/last-end"
    fi
    # JSON is computed in volatile files and atomically published to the WebUI.
    tmp="$RG_DATA/status-$$.tmp"
    (
      printf '{"schema":1,"source":"router","generatedEpoch":%s,' "$(number "$epoch")"
      printf '"lastStart":'; jsonq "$start"; printf ',"lastEnd":';jsonq "$done_at"
      printf ',"cycleResult":';jsonq "$result"
      printf ',"pool":';jsonq "$current_pool"
      printf ',"mode":';jsonq "$mode"
      printf ',"scheduleMinutes":%s' "$(number "$interval")"
      printf ',"exceptionsReadable":%s' "$( [ -f "$RG_SERVERS" ] && [ ! -L "$RG_SERVERS" ] && printf true || printf false )"
      printf ',"pendingTransaction":%s,"recoveryHold":%s,' \
        "$( [ -e "$RG_ROOT/state/pending-transaction" ] && printf true || printf false )" \
        "$( [ -e "$RG_ROOT/state/recovery-attention" ] && printf true || printf false )"
      printf '"resolvers":['
      sep=''
      runtime_providers="$RG_RUNTIME/providers.tsv"
      if [ -f "$runtime_providers" ] && [ ! -L "$runtime_providers" ]; then
        # Runtime roster: id|address|tls_hostname|DoT_port.
        while IFS='|' read -r id ip tls dotport extra; do
          case "$id" in wan[0-9]*|google[0-9]*|backup[0-9]*|[a-zA-Z]*[0-9]) ;; *) continue ;; esac
          # The loop below never accepts arbitrary HTML; values are JSON-escaped.
          state=unknown; pass=0; fail=0
          row=$(awk -F'|' -v k="$id" '$1==k {print;exit}' "$observations")
          if [ -n "$row" ]; then
            state=$(printf '%s' "$row" | cut -d'|' -f2)
            pass=$(printf '%s' "$row" | cut -d'|' -f3)
            fail=$(printf '%s' "$row" | cut -d'|' -f4)
          fi
          printf '%s{"id":' "$sep";jsonq "$id"; printf ',"ip":';jsonq "$ip"
          printf ',"tls":';jsonq "$tls";printf ',"port":';jsonq "$dotport"
          printf ',"state":';jsonq "$state";printf ',"policyPass":%s,"policyFail":%s}' "$(number "$pass")" "$(number "$fail")"
          sep=,
        done < "$runtime_providers"
      elif [ -f "$providers" ] && [ ! -L "$providers" ]; then
        while IFS='|' read -r id ip tls legacy_port dotport extra; do
          case "$id" in wan[0-9]*) ;; *) continue ;; esac
          state=unknown; pass=0; fail=0
          row=$(awk -F'|' -v k="$id" '$1==k {print;exit}' "$observations")
          if [ -n "$row" ]; then
            state=$(printf '%s' "$row" | cut -d'|' -f2)
            pass=$(printf '%s' "$row" | cut -d'|' -f3)
            fail=$(printf '%s' "$row" | cut -d'|' -f4)
          fi
          printf '%s{"id":' "$sep";jsonq "$id"; printf ',"ip":';jsonq "$ip"
          printf ',"tls":';jsonq "$tls";printf ',"port":';jsonq "$dotport"
          printf ',"state":';jsonq "$state";printf ',"policyPass":%s,"policyFail":%s}' "$(number "$pass")" "$(number "$fail")"
          sep=,
        done < "$providers"
      fi
      printf '],"exceptions":['
      sep=''
      exceptions | while IFS='|' read -r domain upstream; do
        printf '%s{"domain":' "$sep";jsonq "$domain";printf ',"upstream":';jsonq "$upstream";printf '}'
        sep=,
      done
      printf '],"events":['
      sep=''
      if [ -f "$RG_DATA/events.tsv" ] && [ ! -L "$RG_DATA/events.tsv" ]; then
        tail -n 24 "$RG_DATA/events.tsv" | while IFS='|' read -r at event; do
          printf '%s{"at":' "$sep";jsonq "$at";printf ',"message":';jsonq "$event";printf '}'
          sep=,
        done
      fi
      printf ']}'
    ) > "$tmp" || return 1
    mv "$tmp" "$RG_DATA/status.htm" || return 1
    # History is aggregated in one awk process; avoid forking an awk per row.
    # Worst-of-bucket states prevent masking real failures. The underlying RAM
    # history still retains one observation per resolver per completed cycle.
    tmp="$RG_DATA/history-$$.tmp"
    (
      printf '{"schema":1,"buckets":['
      if [ -f "$RG_DATA/history.tsv" ] && [ ! -L "$RG_DATA/history.tsv" ]; then
        awk -F'|' '
          function emit(bucket,id,state,n,fail,unknown) {
            if (commas++) printf ","
            printf "{\"at\":\"%s\",\"id\":\"%s\",\"state\":\"%s\",\"samples\":%d,\"failures\":%d,\"unknowns\":%d}",bucket,id,state,n,fail,unknown
          }
          $1 ~ /^[0-9]{4}-/ { }
          NF==3 && $1 ~ /^[0-9][0-9][0-9][0-9]-/ && $2 ~ /^wan[0-9]+$/ && $3 ~ /^(ok|fail|unknown)$/ {
            # yyyy-mm-ddThh:mm:ssZ, all timestamps from ResolvGuard UTC cron.
            t=substr($1,1,13)
            half=substr($1,15,2)+0 < 30 ? "00" : "30"
            bucket=t ":" half ":00Z"
            key=bucket SUBSEP $2
            if (!(key in seen)) { seen[key]=1; keys[++count]=key; bs[key]=bucket; ids[key]=$2 }
            n[key]++; if($3=="fail") f[key]++; else if($3=="unknown") u[key]++
          }
          END {
            # Deterministic chronological ordering is inherited from append-only
            # observations. Sort not required for chronological record history.
            for (i=1;i<=count;i++) {
              key=keys[i]; state=f[key]>0?"fail":(u[key]>0?"unknown":"ok")
              emit(bs[key],ids[key],state,n[key],f[key],u[key])
            }
          }
        ' "$RG_DATA/history.tsv"
      fi
      printf ']}'
    ) > "$tmp" || return 1
    mv "$tmp" "$RG_DATA/history.htm" || return 1
    rm -f "$cycle" "$observations"
    trap - EXIT HUP INT TERM
    return 0
  }

  # Only the page bearing our own marker + title can be reused or removed.
  find_slot() {
    i=1
    while [ "$i" -le 20 ]; do
      page="user${i}.asp"
      title="$RG_WEB/user${i}.title"
      if [ -f "$title" ] && [ "$(cat "$title")" = "$RG_TITLE" ]; then
        if [ -f "$RG_WEB/$page" ] && grep -Fq "$RG_MARKER" "$RG_WEB/$page"; then
          say "$page"; return 0
        fi
        err 'ResolvGuard-titled page has an unexpected body; refusing to replace'; return 1
      fi
      i=$((i+1))
    done
    i=1
    while [ "$i" -le 20 ]; do
      if [ ! -e "$RG_WEB/user${i}.asp" ] && [ ! -e "$RG_WEB/user${i}.title" ]; then
        say "user${i}.asp"; return 0
      fi
      i=$((i+1))
    done
    err 'all Merlin user page slots occupied'; return 1
  }
  lock_menu() {
    [ -d "$RG_WEB" ] && [ -d "$(dirname "$RG_MENU")" ] || return 1
    exec 9> "$RG_LOCK" || return 1
    flock -x 9 || return 1
  }
  unlock_menu() { flock -u 9 || :; }
  # Caller owns /tmp/addonwebui.lock, shared with MerlinAU and other add-ons.
  rewrite_menu() {
    action="$1";page="$2"
    if [ ! -f "$RG_MENU_TMP" ]; then
      [ -f "$RG_MENU" ] || return 1
      cp -p "$RG_MENU" "$RG_MENU_TMP" || return 1
    fi
    staged="$RG_MENU_TMP.resolvguard.$$"
    # Drop only the exact ResolvGuard tab (including the old Administration
    # location); preserve every other existing addon and firmware menu entry.
    awk -v target="$page" -v action="$action" '
      index($0,"tabName: \"ResolvGuard\"") && $0 ~ /url: \"user[0-9]+[.]asp\"/ {next}
      {print}
      action=="add" && index($0,"url: \"Advanced_WAN_Content.asp\"") {
        print "{url: \""target"\", tabName: \"ResolvGuard\"},"; inserted=1
      }
      END {if(action=="add" && !inserted)exit 4}
    ' "$RG_MENU_TMP" > "$staged" || { rm -f "$staged"; return 1; }
    cp -p "$RG_MENU_TMP" "$RG_MENU_TMP.bak.resolvguard.$$" || { rm -f "$staged"; return 1; }
    mv "$staged" "$RG_MENU_TMP" || return 1
    umount "$RG_MENU" 2>/dev/null || :
    if ! mount -o bind "$RG_MENU_TMP" "$RG_MENU"; then
      # An attempted rollback is safer than leaving the firmware menu detached.
      mv "$RG_MENU_TMP.bak.resolvguard.$$" "$RG_MENU_TMP" || :
      mount -o bind "$RG_MENU_TMP" "$RG_MENU" 2>/dev/null || :
      err 'menu bind mount failed; prior menu restored where possible'
      return 1
    fi
    rm -f "$RG_MENU_TMP.bak.resolvguard.$$"
  }

  mount_page() {
    [ -f "$RG_ASSETS/ResolvGuard.asp" ] && [ ! -L "$RG_ASSETS/ResolvGuard.asp" ] || { err 'ASP missing or symlink'; return 1; }
    lock_menu || { err 'unable to acquire MerlinAU-compatible WebUI lock'; return 1; }
    page=$(find_slot) || { unlock_menu; return 1; }
    # Do not alter the existing live page when firmware lacks the WAN anchor.
    menu_source="$RG_MENU_TMP"
    [ -f "$menu_source" ] || menu_source="$RG_MENU"
    if ! grep -F 'url: "Advanced_WAN_Content.asp"' "$menu_source" >/dev/null 2>&1; then
      err 'WAN Internet Connection menu anchor not found; old page/menu left unchanged'
      unlock_menu
      return 1
    fi
    [ -f "$RG_ASSETS/dashboard.htm" ] && [ ! -L "$RG_ASSETS/dashboard.htm" ] || {
      err 'embedded dashboard asset missing or unsafe'; unlock_menu; return 1;
    }
    # The firmware WebUI is volatile; persistent source is in /jffs/addons.
    cp "$RG_ASSETS/ResolvGuard.asp" "$RG_WEB/$page" || { unlock_menu; return 1; }
    printf '%s\n' "$RG_TITLE" > "$RG_WEB/${page%.asp}.title" || { unlock_menu; return 1; }
    dir="$RG_WEB/ResolvGuard"
    if [ -L "$dir" ] || { [ -e "$dir" ] && [ ! -d "$dir" ]; }; then
      err 'unsafe asset directory';unlock_menu; return 1
    fi
    mkdir -p "$dir" "$RG_DATA" || { unlock_menu; return 1; }
    # Link read-only public JSON snapshots, never config/settings or secrets.
    for name in status.htm history.htm manual.htm dashboard.htm; do
      if [ -e "$dir/$name" ] && [ ! -L "$dir/$name" ]; then
        err 'refusing to replace non-owned web asset';unlock_menu; return 1
      fi
      case "$name" in
        dashboard.htm) source_file="$RG_ASSETS/dashboard.htm" ;;
        *) source_file="$RG_DATA/$name" ;;
      esac
      ln -sf "$source_file" "$dir/$name" || { unlock_menu; return 1; }
    done
    rewrite_menu add "$page"
    rc=$?
    unlock_menu
    if [ "$rc" -eq 0 ]; then say "Mounted ResolvGuard at /$page (JSON: /ext/ResolvGuard/status.htm)";fi
    return "$rc"
  }

  unmount_page() {
    lock_menu || { err 'unable to acquire WebUI lock'; return 1; }
    # Do not accidentally allocate a free slot on uninstall.
    found=''
    for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      if [ -f "$RG_WEB/user$n.title" ] && [ "$(cat "$RG_WEB/user$n.title")" = "$RG_TITLE" ]; then
        if [ -f "$RG_WEB/user$n.asp" ] && grep -Fq "$RG_MARKER" "$RG_WEB/user$n.asp"; then
          found="user$n.asp";break
        else
          err 'owned title but mismatched HTML; refusing cleanup';unlock_menu; return 1
        fi
      fi
    done
    if [ -n "$found" ]; then
      rewrite_menu remove "$found" || { unlock_menu; return 1; }
      rm -f "$RG_WEB/$found" "$RG_WEB/${found%.asp}.title" || { unlock_menu; return 1; }
    fi
    for name in status.htm history.htm manual.htm dashboard.htm; do
      case "$name" in
        dashboard.htm) source_file="$RG_ASSETS/dashboard.htm" ;;
        *) source_file="$RG_DATA/$name" ;;
      esac
      if [ -L "$RG_WEB/ResolvGuard/$name" ] && [ "$(readlink "$RG_WEB/ResolvGuard/$name")" = "$source_file" ]; then
        rm -f "$RG_WEB/ResolvGuard/$name"
      fi
    done
    rmdir "$RG_WEB/ResolvGuard" 2>/dev/null || :
    unlock_menu
    say 'ResolvGuard WebUI unmounted (production DNS untouched)'
  }

  case "${1:-help}" in
    publish) publish ;;
    mount) mount_page && _RGManual_ hook-install ;;
    unmount) _RGManual_ hook-remove && unmount_page ;;
    startup)
      i=0
      while [ "$i" -lt 6 ]; do
        if [ -d "$RG_WEB" ] && [ -f "$RG_MENU" ] && mount_page && _RGManual_ hook-install; then
          publish || :
          exit 0
        fi
        i=$((i+1));sleep 10
      done
      err 'startup mount deferred; run webui mount manually'
      exit 1 ;;
    status)
      if [ -f "$RG_DATA/status.htm" ]; then cat "$RG_DATA/status.htm";printf '\n'
      else err 'no completed snapshot; run publish after a scheduled check';exit 1;fi ;;
    manual-run) _RGManual_ run ;;
    manual-status) _RGManual_ status ;;
    *) say 'Usage: sh resolvguard.sh webui [mount|unmount|publish|startup|status|manual-run|manual-status]' ;;
  esac

)
# RESOLVGUARD WEBUI INLINE END
_ScheduleStartup_() {
  # Start optional UI mounting in background; never block DNS boot recovery.
  if [ -f "$ROOT/webui/ResolvGuard.asp" ] && [ ! -L "$ROOT/webui/ResolvGuard.asp" ]; then
    ( _RGWebUI_ startup > /tmp/resolvguard-webui-startup.log 2>&1 ) &
  fi
  [ -r "$SCHEDULE_MARKER" ] || { _Say_ 'Startup: schedule not enabled; nothing to do'; return 0; }
  _RegisterScheduleCron_ || return 1
  # No writes to production DNS or automatic health checks during boot.
  _ReconcileBootState_ || :
  _Say_ 'Startup: ResolvGuard cron registration restored, WAN left untouched.'
}

# Bound volatile scheduled-log growth without writing to JFFS.
_RotateScheduleLog_() {
  local file size staged
  file="$RUNTIME/scheduled.log"
  [ -f "$file" ] || return 0
  size="$(wc -c < "$file" | tr -d ' ')"
  case "$size" in ''|*[!0-9]*) return 0;; esac
  [ "$size" -gt 262144 ] || return 0
  staged="$RUNTIME/scheduled-log-trim-$$"
  tail -n 300 "$file" > "$staged" && cat "$staged" > "$file"
  rm -f "$staged"
}

_RunScheduledCheck_() {
  local outcome
  [ -r "$SCHEDULE_MARKER" ] || { _Say_ 'SKIP: monitoring schedule not enabled'; return 0; }
  if _MaintenancePriorityPending_; then
    _Say_ 'SKIP: interactive DNS maintenance has priority; scheduled check deferred.'
    return 0
  fi
  _RotateScheduleLog_ || :
  _Say_ "SCHEDULE UTC: $(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || _Say_ 'clock-unavailable')"
  _CheckBootReadiness_ || return 0
  [ ! -e "$PENDING_TRANSACTION" ] && [ ! -e "$RECOVERY_HOLD" ] || {
    _Say_ 'SKIP: unresolved WAN transaction or recovery hold; no WAN switching'; return 0;
  }
  if _RunDNSHealthCheck_ scheduled; then outcome=0
  else outcome=$?
  fi
  _Say_ "SCHEDULE UTC END: $(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || _Say_ 'clock-unavailable') result=$outcome"
  # Publish only after a completed scheduled evaluation; never alter DNS outcomes.
  if [ -f "$ROOT/webui/ResolvGuard.asp" ] && [ ! -L "$ROOT/webui/ResolvGuard.asp" ]; then
    _RGWebUI_ publish >/dev/null 2>&1 || :
  fi
  return "$outcome"
}

_ManageScheduledMonitoring_() {
  case "${1:-status}" in
    status) _ShowScheduleStatus_ ;;
    enable) _EnableScheduledMonitoring_ ;;
    disable) _DisableScheduledMonitoring_ ;;
    logs) if [ -r "$RUNTIME/scheduled.log" ]; then tail -n 80 "$RUNTIME/scheduled.log"; else _Say_ 'No scheduled health-check log yet'; fi ;;
    *) _Fail_ 'Usage: schedule [status|enable|disable|logs]'; return 2 ;;
  esac
}

# The recurring monitoring toggle remains in Monitoring Settings. This uses the
# exact scheduler enable/disable helpers and confirmation safeguards from v0.1.8.45.
_ToggleRecurringMonitoring_() {
  local prompt
  if [ -r "$SCHEDULE_MARKER" ]; then
    if [ -r "$AUTO_FAILOVER_MARKER" ]; then
      prompt='Disable recurring DNS monitoring and automatic failover?'
    else
      prompt='Disable recurring DNS monitoring?'
    fi
    if _ConfirmYesNo_ "$prompt" quiet; then
      _DisableScheduledMonitoring_
    fi
  else
    _EnableScheduledMonitoring_
  fi
}

_ShowMonitoringDiagnosticsMenu_() {
  local choice
  while :; do
    _ShowHeader_ 'Monitoring, Diagnostics & Logs'
    _PrintMenuItem_ ss 'Show Schedule and Recovery Status'
    _PrintMenuItem_ lo 'View Recent Scheduled Check Log'
    _PrintMenuItem_ dp 'Show Discovered Providers and Resolver Pools'
    _PrintMenuItem_ ts 'Full Technical Status'
    _PrintMenuItem_ e 'Back'
    _PrintMenuFooter_
    IFS= read -r choice || return 0
    choice="$(_NormalizeMenuChoice_ "$choice")"
    printf '\n'
    case "$choice" in
      SS) _ShowScheduleStatus_; _PromptEnter_ ;;
      LO) _ManageScheduledMonitoring_ logs; _PromptEnter_ ;;
      DP) _ShowDiscoveredProvidersAndPools_; _PromptEnter_ ;;
      TS) _ShowStatus_; _PromptEnter_ ;;
      E|EXIT) return 0 ;;
      *) _ShowInvalidSelection_ ;;
    esac
  done
}

# Color only interactive terminals.
_SetMenuPalette_() {
  RG_RESET=''; RG_BOLD=''; RG_GREEN=''; RG_YELLOW=''
  RG_RED=''; RG_CYAN=''; RG_WHITE=''
  if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && [ -z "${NO_COLOR:-}" ]; then
    RG_ESC="$(printf '\033')"
    RG_RESET="${RG_ESC}[0m"
    RG_BOLD="${RG_ESC}[1m"
    RG_GREEN="${RG_ESC}[1;32m"
    RG_YELLOW="${RG_ESC}[1;33m"
    RG_RED="${RG_ESC}[1;31m"
    RG_CYAN="${RG_ESC}[1;36m"
    RG_WHITE="${RG_ESC}[1;37m"
  fi
}

_PrintMenuRule_() { _Say_ '----------------------------------------------------------------'; }

_ShowLogo_() {
  local logo_version
  logo_version="v$SCRIPT_VERSION"
  if [ "$UPDATE_CHANNEL" = development ]; then
    logo_version="${logo_version}_${SCRIPT_VERSTAG} [dev]"
  fi
  printf '\n%s' "$RG_YELLOW"
  cat <<'RG_LOGO'
    ____                 _      ____                     _
   |  _ \ ___  ___  ___ | |_   / ___|_   _  __ _ _ __ __| |
   | |_) / _ \/ __|/ _ \| \ \ / |  _| | | |/ _` | '__/ _` |
   |  _ <  __/\__ \ (_) | |\ V /|_| | |_| | (_| | | | (_| |
   |_| \_\___||___/\___/|_| \_/\____|\__,_|\__,_|_|  \__,_|
RG_LOGO
  printf '%*s%s%s%s\n' "$((59-${#logo_version}))" '' "$RG_GREEN" "$logo_version" "$RG_RESET"
  rg_banner='======== Intelligent DNS Monitoring & Failover ========'
  rg_pad=$(((64 - ${#rg_banner}) / 2))
  printf '\n%*s%s%s%s\n\n' "$rg_pad" '' "$RG_YELLOW" "$rg_banner" "$RG_RESET"
}

_ShowMenuState_() {
  local label colour profile pool
  profile="$(nvram get dnspriv_profile 2>/dev/null || :)"
  case "$profile" in
    1) label='Strict (Authenticated TLS)'; colour="$RG_GREEN" ;;
    0) label='Opportunistic'; colour="$RG_RED" ;;
    *) label='Unknown'; colour="$RG_YELLOW" ;;
  esac
  printf '  %-24s%s%s%s\n' 'DNS Privacy Profile:' "$colour" "$label" "$RG_RESET"
  if [ -r "$PREF_RULELIST" ]; then
    if ! pool="$(_GetWANLockDisplay_ 2>/dev/null)"; then
      pool="$(_GetActiveWANPool_ 2>/dev/null)" || pool='EXTERNAL / UNVERIFIED'
    fi
  else
    pool='Not enrolled'
  fi
  printf '  %-24s%s%s%s\n' 'Active WAN DNS Pool:' "$RG_CYAN" "$pool" "$RG_RESET"
  if [ ! -r "$SCHEDULE_MARKER" ]; then
    printf '  %-24s%sINACTIVE%s\n' 'Operating Mode:' "$RG_YELLOW" "$RG_RESET"
  elif _CheckAutomaticFailoverAuthorization_ >/dev/null 2>&1; then
    printf '  %-24s%sAUTOMATIC FAILOVER%s\n' 'Operating Mode:' "$RG_GREEN" "$RG_RESET"
  else
    printf '  %-24s%sMONITORING ONLY%s\n' 'Operating Mode:' "$RG_YELLOW" "$RG_RESET"
  fi
  if [ -r "$SCHEDULE_MARKER" ]; then
    printf '  %-24s%sEVERY %s MIN%s\n' 'Scheduled DNS Checks:' "$RG_GREEN" "$SCHEDULE_INTERVAL_MINUTES" "$RG_RESET"
  else
    printf '  %-24s%sDISABLED%s\n' 'Scheduled DNS Checks:' "$RG_YELLOW" "$RG_RESET"
  fi
  if [ -r "$SCHEDULE_MARKER" ] && [ -r "$AUTO_FAILOVER_MARKER" ]; then
    if _CheckAutomaticFailoverAuthorization_ >/dev/null 2>&1; then
      printf '  %-24s%sAUTHORIZED%s\n' 'Unattended Switching:' "$RG_GREEN" "$RG_RESET"
    else
      printf '  %-24s%sPOLICY SAFETY HOLD%s\n' 'Unattended Switching:' "$RG_YELLOW" "$RG_RESET"
    fi
  else
    printf '  %-24s%sDISABLED / NOT AUTHORIZED%s\n' 'Unattended Switching:' "$RG_RED" "$RG_RESET"
  fi
}

_ShowHeader_() {
  local section
  section="${1:-Main Menu}"
  _SetMenuPalette_
  if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]; then
    printf '\033[2J\033[H'
  fi
  _ShowLogo_
  printf '%s' "$RG_WHITE"
  _PrintMenuRule_
  _ShowMenuState_
  _PrintMenuRule_
  if [ "$section" != 'Main Menu' ]; then
    printf '  %s%s%s\n' "$RG_BOLD" "$section" "$RG_RESET"
    _PrintMenuRule_
  fi
}

_ShowSetupStep_() {
  printf '\n  %s%s%s%s  %s%s%s\n' \
    "$RG_CYAN" "$RG_BOLD" "$1/3" "$RG_RESET" "$RG_BOLD" "$2" "$RG_RESET"
  printf '  %s\n' '------------------------------------------------------------'
}

_UpperMenuKeyChar_() {
  case "$1" in
    a|A) printf 'A' ;;
    b|B) printf 'B' ;;
    c|C) printf 'C' ;;
    d|D) printf 'D' ;;
    e|E) printf 'E' ;;
    f|F) printf 'F' ;;
    g|G) printf 'G' ;;
    h|H) printf 'H' ;;
    i|I) printf 'I' ;;
    j|J) printf 'J' ;;
    k|K) printf 'K' ;;
    l|L) printf 'L' ;;
    m|M) printf 'M' ;;
    n|N) printf 'N' ;;
    o|O) printf 'O' ;;
    p|P) printf 'P' ;;
    q|Q) printf 'Q' ;;
    r|R) printf 'R' ;;
    s|S) printf 'S' ;;
    t|T) printf 'T' ;;
    u|U) printf 'U' ;;
    v|V) printf 'V' ;;
    w|W) printf 'W' ;;
    x|X) printf 'X' ;;
    y|Y) printf 'Y' ;;
    z|Z) printf 'Z' ;;
    *) printf '%s' "$1" ;;
  esac
}

_NormalizeMenuChoice_() {
  local token first second cr
  token="$1"
  cr="$(printf '\r')"
  # An SSH/terminal paste can leave a trailing carriage return.
  case "$token" in *"$cr") token="${token%"$cr"}" ;; esac
  # Ignore incidental spaces around the shortcut, but not inside it.
  while :; do
    case "$token" in
      ' '*) token="${token# }" ;;
      *' ') token="${token% }" ;;
      *) break ;;
    esac
  done
  case "$token" in
    '') return 0 ;;
    [Ee][Xx][Ii][Tt]) printf 'EXIT' ;;
    ?) _UpperMenuKeyChar_ "$token" ;;
    ??)
      first="${token%?}"
      second="${token#?}"
      _UpperMenuKeyChar_ "$first"
      _UpperMenuKeyChar_ "$second"
      ;;
    *) printf '%s' "$token" ;;
  esac
}

_PrintMenuItem_() {
  printf '\n\n  %s%2s%s.  %s' "$RG_GREEN" "$1" "$RG_RESET" "$2"
}

_PrintMenuNote_() { printf '\n       [%s]' "$1"; }

_PrintMenuFooter_() {
  printf '\n'
  _PrintMenuRule_
  printf '\nEnter selection:  '
}

_PromptEnter_() {
  printf '\nPress <Enter> to continue...'
  IFS= read -r _rg_pause || :
}

_ShowInvalidSelection_() {
  printf '\n%sINVALID selection.%s Please try again.\n' "$RG_RED" "$RG_RESET"
  _PromptEnter_
}

_InstallLauncher_() {
  local dest tmp
  case "$INSTALL_ROOT" in *[!A-Za-z0-9_./-]*|'')
    _Fail_ 'Unsafe install path for shell launcher'; return 1;; esac
  if [ ! -d "$LAUNCH_DIR" ] || [ ! -w "$LAUNCH_DIR" ]; then
    _Say_ "NOTICE: Launcher directory unavailable: $LAUNCH_DIR"
    _Say_ "Launch manually: sh $INSTALL_ROOT/resolvguard.sh"
    return 0
  fi
  dest="$LAUNCH_DIR/resolvguard"
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    if [ ! -L "$dest" ] && [ -f "$dest" ] &&
       grep -Fx '# ResolvGuard-owned launcher' "$dest" >/dev/null 2>&1 &&
       grep -Fx "exec /bin/sh $INSTALL_ROOT/resolvguard.sh \"\$@\"" "$dest" >/dev/null 2>&1; then
      _Say_ "Launcher already installed: $dest"
      return 0
    fi
    _Say_ "NOTICE: Existing command left untouched: $dest"
    return 0
  fi
  tmp="$dest.new.$$"
  [ ! -e "$tmp" ] && [ ! -L "$tmp" ] || {
    _Fail_ 'Temporary launcher path already exists'; return 1; }
  ( umask 077; set -C; {
      printf '%s\n' '#!/bin/sh' '# ResolvGuard-owned launcher'
      printf 'exec /bin/sh %s/resolvguard.sh "$@"\n' "$INSTALL_ROOT"
    } > "$tmp" ) || { rm -f "$tmp"; _Fail_ 'Unable to write launcher'; return 1; }
  chmod 755 "$tmp" || { rm -f "$tmp"; _Fail_ 'Unable to set launcher permissions'; return 1; }
  if ! ln "$tmp" "$dest" 2>/dev/null; then
    rm -f "$tmp"
    _Say_ "NOTICE: Launcher path already exists or cannot be created; left untouched: $dest"
    return 0
  fi
  rm -f "$tmp" || _Say_ "NOTICE: Temporary launcher file needs cleanup: $tmp"
  _Say_ "Installed launcher: $dest"
  case ":$PATH:" in *":$LAUNCH_DIR:"*) _Say_ 'You can launch the SSH menu with: resolvguard' ;;
    *) _Say_ "Launch with: $dest (add $LAUNCH_DIR to PATH for short command)" ;;
  esac
}


_Ask_() {
  local label default
  label="$1"; default="${2:-}"
  _SetMenuPalette_
  if [ -n "$default" ]; then
    printf '\n  %s%s%s %s[%s]%s: ' "$RG_BOLD" "$label" "$RG_RESET" "$RG_CYAN" "$default" "$RG_RESET"
  else
    printf '\n  %s%s%s: ' "$RG_BOLD" "$label" "$RG_RESET"
  fi
  IFS= read -r RG_ANSWER || return 1
  [ -n "$RG_ANSWER" ] || RG_ANSWER="$default"
}

_IsSafeToken_() {
  case "$1" in ''|*[!A-Za-z0-9_.:@/+?%=-]*) return 1;; *) return 0;; esac
}

_CheckConfigurationSafety_() {
  [ ! -e "$PENDING_TRANSACTION" ] && [ ! -L "$PENDING_TRANSACTION" ] &&
    [ ! -e "$RECOVERY_HOLD" ] && [ ! -L "$RECOVERY_HOLD" ] || {
      _Fail_ 'Resolve the interrupted WAN transaction before editing configuration'; return 1; }
  if [ -s "$PREF_RULELIST" ]; then
    [ "$(_GetActiveWANPool_ 2>/dev/null)" = preferred ] || {
      _Fail_ 'Restore preferred WAN DNS before editing configuration'; return 1; }
  fi
}

_CommitConfigurationLocked_() {
  local file1 stage1 file2 stage2 backup1 backup2 old_interval report ok
  file1="$1"; stage1="$2"; file2="${3:-}"; stage2="${4:-}"
  [ -f "$file1" ] && [ ! -L "$file1" ] && [ -f "$stage1" ] && [ ! -L "$stage1" ] || return 1
  if [ -n "$file2" ]; then
    [ -f "$file2" ] && [ ! -L "$file2" ] && [ -f "$stage2" ] && [ ! -L "$stage2" ] || return 1
  fi
  backup1="$file1.rg-backup.$$"; backup2=''
  [ ! -e "$backup1" ] && [ ! -L "$backup1" ] || return 1
  cp -p "$file1" "$backup1" || return 1
  if [ -n "$file2" ]; then
    backup2="$file2.rg-backup.$$"
    if [ -e "$backup2" ] || [ -L "$backup2" ] || ! cp -p "$file2" "$backup2"; then
      rm -f "$backup1"; return 1
    fi
  fi
  old_interval="$SCHEDULE_INTERVAL_MINUTES"
  report="$RUNTIME/config-validation-$$"
  ok=1
  chmod 600 "$stage1" && mv "$stage1" "$file1" || ok=0
  if [ "$ok" = 1 ] && [ -n "$file2" ]; then
    chmod 600 "$stage2" && mv "$stage2" "$file2" || ok=0
  fi
  if [ "$ok" = 1 ]; then
    if sh "$ROOT/resolvguard.sh" validate > "$report" 2>&1; then
      if [ "$file1" = "$SETTINGS" ] || [ "$file2" = "$SETTINGS" ]; then . "$SETTINGS"; fi
      if [ -e "$SCHEDULE_MARKER" ] && [ "$old_interval" != "$SCHEDULE_INTERVAL_MINUTES" ]; then
        _RegisterScheduleCron_ || ok=0
      fi
    else
      cat "$report" >&2
      ok=0
    fi
  fi
  rm -f "$report"
  if [ "$ok" != 1 ]; then
    mv -f "$backup1" "$file1" || _Fail_ "CRITICAL: could not restore $file1"
    if [ -n "$backup2" ]; then mv -f "$backup2" "$file2" || _Fail_ "CRITICAL: could not restore $file2"; fi
    . "$SETTINGS"
    if [ -e "$SCHEDULE_MARKER" ]; then _RegisterScheduleCron_ || :; fi
    rm -f "$stage1" "$stage2"
    _Fail_ 'Configuration rejected; previous values restored'
    return 1
  fi
  rm -f "$backup1" "$backup2" "$stage2"
  _Say_ 'Configuration: SAVED'
  if [ -e "$AUTO_FAILOVER_MARKER" ]; then
    _Say_ 'DNS policy: REAPPROVAL REQUIRED'
  fi
}

_StageTSVFile_() {
  local file mode kind key value staged
  file="$1"; mode="$2"; kind="$3"; key="$4"; value="$5"; staged="$6"
  awk -F'|' -v op="$mode" -v kind="$kind" -v target="$key" -v replacement="$value" '
    BEGIN {OFS="|"}
    {
      k=($0 ~ /^#/ || $0=="" ? "" : (kind=="check" ? $1 "|" $2 : $1))
      if (k==target) {
        found++
        if (op=="edit") print replacement
      } else print $0
    }
    END {
      if (op=="add" && found==0) print replacement
      else if (op=="add" || found!=1) exit 1
    }
  ' "$file" > "$staged" || { rm -f "$staged"; _Fail_ 'Target missing, already present or duplicated'; return 1; }
}

_ChangeTSVFile_() (
  local file kind mode key value staged
  file="$1"; kind="$2"; mode="$3"; key="$4"; value="${5:-}"
  _AcquireConfigLock_ || { _Fail_ 'Another configuration commit is running'; return 1; }
  trap '_ReleaseConfigLock_ >/dev/null 2>&1 || :' EXIT HUP INT TERM
  _CheckConfigurationSafety_ || return 1
  staged="$file.rg-stage.$$"
  [ ! -e "$staged" ] && [ ! -L "$staged" ] || return 1
  _StageTSVFile_ "$file" "$mode" "$kind" "$key" "$value" "$staged" || return 1
  _CommitConfigurationLocked_ "$file" "$staged"
)


_SetSetting_() {
  local key value staged
  key="$1"; value="$2"
  case "$key" in
    SCHEDULE_INTERVAL_MINUTES) case "$value" in 1|2|5|10|15|20|30|60) :;; *) _Fail_ 'Choose 1/2/5/10/15/20/30/60'; return 1;; esac ;;
    FAST_CONFIRM_SECONDS) case "$value" in ''|*[!0-9]*) return 1;; esac
      [ "$value" -ge 0 ] && [ "$value" -le 15 ] || return 1 ;;
    FAIL_THRESHOLD|RECOVERY_THRESHOLD) case "$value" in ''|*[!0-9]*) return 1;; esac
      [ "$value" -ge 1 ] && [ "$value" -le 20 ] || return 1 ;;
    TIMEOUT_SECONDS) case "$value" in 1|2|3|4|5|6|7|8|9|10|11|12|13|14|15) :;; *) return 1;; esac ;;
    BOOT_MIN_UPTIME_SECONDS) case "$value" in ''|*[!0-9]*) return 1;; esac
      [ "$value" -ge 0 ] && [ "$value" -le 3600 ] || return 1 ;;
    SYSLOG_HEALTH_INTERVAL_MINUTES) case "$value" in 0|15|30|60) :;; *) return 1;; esac ;;
    CA_FILE|WAN_STUBBY_CONFIG)
      case "$value" in /*) _IsSafeToken_ "$value" || return 1;; *) _Fail_ 'Enter an absolute path'; return 1;; esac
      [ -r "$value" ] || { _Fail_ 'File does not exist or cannot be read'; return 1; } ;;
    *) _Fail_ 'Unknown setting'; return 1 ;;
  esac
  (
    _AcquireConfigLock_ || { _Fail_ 'Another configuration commit is running'; return 1; }
    trap '_ReleaseConfigLock_ >/dev/null 2>&1 || :' EXIT HUP INT TERM
    _CheckConfigurationSafety_ || return 1
    staged="$SETTINGS.rg-stage.$$"
    [ ! -e "$staged" ] && [ ! -L "$staged" ] || return 1
    if ! awk -v k="$key" -v v="$value" '
      index($0,k "=")==1 {print k "=" v; seen++; next}
      {print}
      END {if (seen>1) exit 1; if (seen==0) print k "=" v}
    ' "$SETTINGS" > "$staged"; then
      rm -f "$staged"; return 1
    fi
    _CommitConfigurationLocked_ "$SETTINGS" "$staged"
  ) || return 1
  . "$SETTINGS"
}


_PromptSetting_() {
  local key current hint
  key="$1"; current="$2"; hint="$3"
  _Ask_ "$hint" "$current" || return 1
  _SetSetting_ "$key" "$RG_ANSWER"
}

_ShowMonitoringSettingsMenu_() {
  local choice
  while :; do
    _ShowHeader_ 'Monitoring Settings'
    _PrintMenuItem_ si "Schedule interval: ${SCHEDULE_INTERVAL_MINUTES} min"
    _PrintMenuItem_ fc "Fast failure confirmation: ${FAST_CONFIRM_SECONDS}s"
    _PrintMenuItem_ ft "Failure threshold: $FAIL_THRESHOLD"
    _PrintMenuItem_ rt "Recovery threshold: $RECOVERY_THRESHOLD"
    _PrintMenuItem_ qt "DoT query timeout: ${TIMEOUT_SECONDS}s"
    _PrintMenuItem_ sw "Startup warmup: ${BOOT_MIN_UPTIME_SECONDS}s"
    _PrintMenuItem_ sh "Healthy syslog heartbeat: ${SYSLOG_HEALTH_INTERVAL_MINUTES} min (0=off)"
    if [ -r "$SCHEDULE_MARKER" ]; then
      if [ -r "$AUTO_FAILOVER_MARKER" ]; then
        _PrintMenuItem_ rc 'Recurring DNS Monitoring: ON (Toggle; OFF also disables failover)'
      else
        _PrintMenuItem_ rc 'Recurring DNS Monitoring: ON (Toggle)'
      fi
    else
      _PrintMenuItem_ rc 'Recurring DNS Monitoring: OFF (Toggle)'
    fi
    _PrintMenuItem_ e 'Back'
    _PrintMenuFooter_
    IFS= read -r choice || return 0
    choice="$(_NormalizeMenuChoice_ "$choice")"
    printf '\n'
    case "$choice" in
      SI) _PromptSetting_ SCHEDULE_INTERVAL_MINUTES "$SCHEDULE_INTERVAL_MINUTES" 'Interval (1/2/5/10/15/20/30/60)' ; _PromptEnter_ ;;
      FC) _PromptSetting_ FAST_CONFIRM_SECONDS "$FAST_CONFIRM_SECONDS" 'Fast confirmation seconds (0-15)' ; _PromptEnter_ ;;
      FT) _PromptSetting_ FAIL_THRESHOLD "$FAIL_THRESHOLD" 'Failure threshold (1-20)' ; _PromptEnter_ ;;
      RT) _PromptSetting_ RECOVERY_THRESHOLD "$RECOVERY_THRESHOLD" 'Recovery threshold (1-20)' ; _PromptEnter_ ;;
      QT) _PromptSetting_ TIMEOUT_SECONDS "$TIMEOUT_SECONDS" 'DNS query timeout (1-15)' ; _PromptEnter_ ;;
      SW) _PromptSetting_ BOOT_MIN_UPTIME_SECONDS "$BOOT_MIN_UPTIME_SECONDS" 'Boot warmup (0-3600s)' ; _PromptEnter_ ;;
      SH) _PromptSetting_ SYSLOG_HEALTH_INTERVAL_MINUTES "$SYSLOG_HEALTH_INTERVAL_MINUTES" 'Syslog heartbeat minutes (0/15/30/60)' ; _PromptEnter_ ;;
      RC) _ToggleRecurringMonitoring_; _PromptEnter_ ;;
      E|EXIT) return 0 ;;
      *) _ShowInvalidSelection_ ;;
    esac
  done
}

_ShowIntegrationSettingsMenu_() {
  local choice
  while :; do
    _ShowHeader_ 'DNS Integration Settings'
    _PrintMenuItem_ ca "CA certificate bundle: $CA_FILE"
    _PrintMenuItem_ sc "Production Stubby config: $WAN_STUBBY_CONFIG"
    _PrintMenuItem_ e 'Back'
    _PrintMenuFooter_
    IFS= read -r choice || return 0
    choice="$(_NormalizeMenuChoice_ "$choice")"
    printf '\n'
    case "$choice" in
      CA) _PromptSetting_ CA_FILE "$CA_FILE" 'CA bundle path'; _PromptEnter_ ;;
      SC) _PromptSetting_ WAN_STUBBY_CONFIG "$WAN_STUBBY_CONFIG" 'Production Stubby YAML path'; _PromptEnter_ ;;
      E|EXIT) return 0 ;;
      *) _ShowInvalidSelection_ ;;
    esac
  done
}

_IsValidDNSCheck_() {
  _IsValidDomain_ "$1" && _IsValidRecordType_ "$2" && _IsValidRCODE_ "$3" &&
    _IsValidDNSAnswerCount_ "$4" && _IsSafeToken_ "$5"
}

_PromptDNSCheck_() {
  local qname qtype rcode count rdata
  _Ask_ 'DNS hostname' "${1:-}" || return 1; qname="$RG_ANSWER"
  _Ask_ 'DNS record type (A/AAAA etc.)' "${2:-A}" || return 1; qtype="$RG_ANSWER"
  _Ask_ 'Expected RCODE' "${3:-NOERROR}" || return 1; rcode="$RG_ANSWER"
  _Ask_ 'Expected answer count (ANY, AT_LEAST_1, or exact number)' "${4:-ANY}" || return 1; count="$RG_ANSWER"
  _Ask_ 'Expected record data (- to ignore)' "${5:--}" || return 1; rdata="$RG_ANSWER"
  _IsValidDNSCheck_ "$qname" "$qtype" "$rcode" "$count" "$rdata" || {
    _Fail_ 'Invalid DNS check fields'; return 1;
  }
  RG_CHECK_ROW="$qname|$qtype|$rcode|$count|$rdata"
}


_ShowDNSHealthChecksMenu_() {
  local choice host type oldrow oldkey _rg_c _rg_n _rg_v
  while :; do
    _ShowHeader_ 'DNS Health Checks'
    _Say_ '  Hostname | Type | RCODE | Count | Expected data'
    awk -F'|' '$1 !~ /^#/ && NF==5 {printf "  %s | %s | %s | %s | %s\n",$1,$2,$3,$4,$5}' "$CHECKS"
    _PrintMenuItem_ ad 'Add DNS health check'
    _PrintMenuItem_ ch 'Change existing health check'
    _PrintMenuItem_ de 'Delete health check'
    _PrintMenuItem_ e 'Back'
    _PrintMenuFooter_
    IFS= read -r choice || return 0
    choice="$(_NormalizeMenuChoice_ "$choice")"; printf '\n'
    case "$choice" in
      AD)
        _PromptDNSCheck_ || { _PromptEnter_; continue; }
        oldkey="$(printf '%s\n' "$RG_CHECK_ROW" | cut -d'|' -f1-2)"
        _ChangeTSVFile_ "$CHECKS" check add "$oldkey" "$RG_CHECK_ROW"; _PromptEnter_ ;;
      CH|DE)
        _Ask_ 'Existing hostname' '' || return 0; host="$RG_ANSWER"
        _Ask_ 'Existing record type' A || return 0; type="$RG_ANSWER"
        oldkey="$host|$type"
        oldrow="$(awk -F'|' -v h="$host" -v t="$type" '$1==h && $2==t {print;exit}' "$CHECKS")"
        [ -n "$oldrow" ] || { _Fail_ 'DNS health check not found'; _PromptEnter_; continue; }
        if [ "$choice" = DE ]; then
          _ConfirmYesNo_ "Delete DNS check $oldkey?" && _ChangeTSVFile_ "$CHECKS" check del "$oldkey"
        else
          IFS='|' read -r host type _rg_c _rg_n _rg_v <<EOF_RG_CHECK
$oldrow
EOF_RG_CHECK
          _PromptDNSCheck_ "$host" "$type" "$_rg_c" "$_rg_n" "$_rg_v" &&
            _ChangeTSVFile_ "$CHECKS" check edit "$oldkey" "$RG_CHECK_ROW"
        fi
        _PromptEnter_ ;;
      E|EXIT) return 0 ;;
      *) _ShowInvalidSelection_ ;;
    esac
  done
}

# Shared backup preset catalog: Quick Setup and Advanced Add use identical
# upstream IPs, Strict DoT identities, and provider abbreviations.
_PrintBackupPresetChoices_() {
  printf '  %sgo.%s %-20s %s\n' "$RG_GREEN" "$RG_RESET" Google '8.8.8.8, 8.8.4.4'
  printf '  %scs.%s %-20s %s\n' "$RG_GREEN" "$RG_RESET" 'Cloudflare Security' '1.1.1.2, 1.0.0.2'
  printf '  %sqs.%s %-20s %s\n' "$RG_GREEN" "$RG_RESET" 'Quad9 Security' '9.9.9.9, 149.112.112.112'
  printf '  %scd.%s Custom DoT resolvers (guided configuration)\n' "$RG_GREEN" "$RG_RESET"
}

_SetBackupPreset_() {
  RG_PRESET_NAME=''; RG_PRESET_IP1=''; RG_PRESET_IP2=''; RG_PRESET_HOST=''; RG_PRESET_IDPREFIX=''
  case "$1" in
    GO) RG_PRESET_NAME=Google; RG_PRESET_IP1=8.8.8.8; RG_PRESET_IP2=8.8.4.4; RG_PRESET_HOST=dns.google; RG_PRESET_IDPREFIX=google ;;
    CS) RG_PRESET_NAME='Cloudflare Security'; RG_PRESET_IP1=1.1.1.2; RG_PRESET_IP2=1.0.0.2; RG_PRESET_HOST=security.cloudflare-dns.com; RG_PRESET_IDPREFIX=cloudflare ;;
    QS) RG_PRESET_NAME='Quad9 Security'; RG_PRESET_IP1=9.9.9.9; RG_PRESET_IP2=149.112.112.112; RG_PRESET_HOST=dns.quad9.net; RG_PRESET_IDPREFIX=quad9 ;;
    *) return 1 ;;
  esac
}

_ChooseBackupAddMode_() {
  local selection
  while :; do
    _ShowHeader_ 'Add Backup DoT Resolvers'
    _Say_ 'Select a preset pair, or add one custom resolver.'
    _PrintBackupPresetChoices_
    printf '  %se.%s  Cancel / Back\n' "$RG_GREEN" "$RG_RESET"
    _PrintMenuFooter_
    IFS= read -r selection || return 1
    selection="$(_NormalizeMenuChoice_ "$selection")"
    printf '\n'
    case "$selection" in
      GO|CS|QS|CD) RG_BACKUP_ADD_CHOICE="$selection"; return 0 ;;
      E|EXIT) return 1 ;;
      *) _ShowInvalidSelection_ ;;
    esac
  done
}

# The preset is committed as ONE validated configuration transaction: either
# both endpoints are saved, or the pre-existing backup file is restored.
_InstallBackupPreset_() (
  local choice id1 id2 staged
  choice="$1"
  _SetBackupPreset_ "$choice" || return 1
  id1="${RG_PRESET_IDPREFIX}1"
  id2="${RG_PRESET_IDPREFIX}2"
  _AcquireConfigLock_ || { _Fail_ 'Another configuration commit is running'; return 1; }
  trap '_ReleaseConfigLock_ >/dev/null 2>&1 || :' EXIT HUP INT TERM
  _CheckConfigurationSafety_ || return 1
  _PrepareProviders_ || return 1
  if awk -F'|' -v h="$RG_PRESET_HOST" -v port=853 -v a="$RG_PRESET_IP1" -v b="$RG_PRESET_IP2" \
    '$1 ~ /^wan[0-9]+$/ && (($3==h && $4==port) || $2==a || $2==b) {found=1} END {exit !found}' "$PROVIDERS"; then
    _Fail_ 'This provider is already enrolled in preferred WAN DNS; choose a different independent backup'
    return 1
  fi
  if awk -F'|' -v h="$RG_PRESET_HOST" -v port=853 -v a="$RG_PRESET_IP1" -v b="$RG_PRESET_IP2" -v one="$id1" -v two="$id2" '
    $1 !~ /^#/ && $1 != "" && ($1==one || $1==two || ($3==h && $4==port) || $2==a || $2==b) {found=1}
    END {exit !found}' "$EXTRA_PROVIDERS"; then
    _Fail_ 'Preset already configured, partially present, or IDs conflict; review existing backup entries first'
    return 1
  fi
  staged="$EXTRA_PROVIDERS.rg-stage.$$"
  [ ! -e "$staged" ] && [ ! -L "$staged" ] || return 1
  cp "$EXTRA_PROVIDERS" "$staged" || return 1
  if ! printf '%s|%s|%s|853\n%s|%s|%s|853\n' \
    "$id1" "$RG_PRESET_IP1" "$RG_PRESET_HOST" \
    "$id2" "$RG_PRESET_IP2" "$RG_PRESET_HOST" >> "$staged"; then
    rm -f "$staged"; return 1
  fi
  _CommitConfigurationLocked_ "$EXTRA_PROVIDERS" "$staged" || return 1
  _Say_ "Backup DNS: ADDED ($RG_PRESET_NAME; $id1, $id2)"
  _Say_ 'DNS policy: REAPPROVAL REQUIRED'
)

_AskBackupField_() {
  _Ask_ "$1" "${2:-}" || return 1
  case "$(_NormalizeMenuChoice_ "$RG_ANSWER")" in
    E|EXIT) _Say_ '  Backup edit cancelled without saving.'; return 1 ;;
  esac
}

_ShowBackupResolversMenu_() {
  local choice id ip tls tport oldrow
  while :; do
    _ShowHeader_ 'Backup DoT Resolvers'
    _Say_ '  ID | IPv4/IPv6 | TLS authentication hostname | TLS port'
    awk -F'|' '$1 !~ /^#/ && NF==4 {printf "  %s | %s | %s | %s\n",$1,$2,$3,$4}' "$EXTRA_PROVIDERS"
    _PrintMenuItem_ ad 'Add backup resolver (presets or custom)'
    _PrintMenuItem_ ch 'Change backup resolver'
    _PrintMenuItem_ de 'Delete backup resolver'
    _PrintMenuItem_ e 'Back'
    _PrintMenuFooter_
    IFS= read -r choice || return 0
    choice="$(_NormalizeMenuChoice_ "$choice")"; printf '\n'
    case "$choice" in
      AD|CH)
        # Advise before collecting input; commits repeat this check under the
        # WAN lock so scheduled failover cannot race a configuration write.
        _CheckConfigurationSafety_ || { _PromptEnter_; continue; }
        if [ "$choice" = AD ]; then
          _ChooseBackupAddMode_ || continue
          if [ "$RG_BACKUP_ADD_CHOICE" != CD ]; then
            _SetBackupPreset_ "$RG_BACKUP_ADD_CHOICE" || continue
            _Say_ "Selected: $RG_PRESET_NAME ($RG_PRESET_IP1, $RG_PRESET_IP2)"
            _ConfirmYesNo_ 'Add both backup endpoints?' || continue
            _InstallBackupPreset_ "$RG_BACKUP_ADD_CHOICE"
            _PromptEnter_
            continue
          fi
        fi
        if [ "$choice" = CH ]; then
          _AskBackupField_ 'Existing resolver ID' '' || continue; id="$RG_ANSWER"
          oldrow="$(awk -F'|' -v z="$id" '$1==z {print;exit}' "$EXTRA_PROVIDERS")"
          [ -n "$oldrow" ] || { _Fail_ 'Resolver not found'; _PromptEnter_; continue; }
          IFS='|' read -r id ip tls tport <<EOF_RG_PROVIDER
$oldrow
EOF_RG_PROVIDER
        else
          _AskBackupField_ 'New resolver ID' '' || continue; id="$RG_ANSWER"
          ip=''; tls=''; tport='853'
        fi
        _Say_ 'Enter e or exit at any prompt to cancel.'
        _AskBackupField_ 'Resolver IPv4/IPv6' "$ip" || continue; ip="$RG_ANSWER"
        _AskBackupField_ 'Certificate TLS authentication hostname' "$tls" || continue; tls="$RG_ANSWER"
        _AskBackupField_ 'Upstream TLS port' "${tport:-853}" || continue; tport="$RG_ANSWER"
        if ! _IsValidID_ "$id" || ! _IsValidIP_ "$ip" || ! _IsValidDomain_ "$tls" || ! _IsValidTLSPort_ "$tport"; then
          _Fail_ 'Invalid provider ID, IPv4/IPv6, TLS name or port'; _PromptEnter_; continue
        fi
        case "$id" in wan[0-9]*) _Fail_ 'Resolver IDs beginning wan + number are reserved'; _PromptEnter_; continue;; esac
        if [ "$choice" = AD ]; then
          _ChangeTSVFile_ "$EXTRA_PROVIDERS" provider add "$id" "$id|$ip|$tls|$tport"
        else
          _ChangeTSVFile_ "$EXTRA_PROVIDERS" provider edit "$id" "$id|$ip|$tls|$tport"
        fi
        _PromptEnter_ ;;
      DE)
        _CheckConfigurationSafety_ || { _PromptEnter_; continue; }
        _AskBackupField_ 'Resolver ID to delete' '' || continue; id="$RG_ANSWER"
        _ConfirmYesNo_ "Delete backup resolver $id?" && _ChangeTSVFile_ "$EXTRA_PROVIDERS" provider del "$id"
        _PromptEnter_ ;;
      E|EXIT) return 0 ;;
      *) _ShowInvalidSelection_ ;;
    esac
  done
}

_ShowConfigurationMenu_() {
  local choice
  while :; do
    _ShowHeader_ 'Configuration'
    _PrintMenuItem_ ms 'Monitoring Settings'
    _PrintMenuItem_ is 'Integration Settings'
    _PrintMenuItem_ hc 'Health Checks'
    _PrintMenuItem_ br 'Backup DoT Resolvers'
    _PrintMenuItem_ e 'Back'
    _PrintMenuFooter_
    IFS= read -r choice || return 0
    choice="$(_NormalizeMenuChoice_ "$choice")"
    printf '\n'
    case "$choice" in
      MS) _ShowMonitoringSettingsMenu_ ;;
      IS) _ShowIntegrationSettingsMenu_ ;;
      HC) _ShowDNSHealthChecksMenu_ ;;
      BR) _ShowBackupResolversMenu_ ;;
      E|EXIT) return 0 ;;
      *) _ShowInvalidSelection_ ;;
    esac
  done
}


# Online update: GitHub-hosted version.txt and version-pinned single-script Release asset.
# An update replaces the installed script and removes its temporary rollback
# files. Router NVRAM, DNS policy, enrollment, and transaction state are not
# modified by the update process.
_FetchHTTPS_() {
  local url dest
  url="$1"; dest="$2"
  case "$url" in https://*) : ;; *) _Fail_ 'HTTPS URL required'; return 1 ;; esac
  # Deliberately require curl. HTTPS-only redirects and CA verification must not
  # silently degrade to a downloader with weaker transport validation.
  if curl -fsSL --retry 2 --retry-delay 1 --connect-timeout 10 --max-time 60 \
      --proto '=https' --proto-redir '=https' -o "$dest" "$url" 2>/dev/null &&
      [ -s "$dest" ] && [ ! -L "$dest" ]; then
    return 0
  fi
  rm -f "$dest"
  _Fail_ 'Authenticated HTTPS download failed'
  return 1
}

_IsValidVersion_() { printf '%s\n' "$1" | LC_ALL=C grep -Eq '^[0-9]+([.][0-9]+){1,3}$'; }
_IsNewerVersion_() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    n=split(a,x,"."); m=split(b,y,"."); k=(n>m?n:m)
    for(i=1;i<=k;i++) {u=x[i]+0; v=y[i]+0; if(u>v)exit 0; if(u<v)exit 1}
    exit 1
  }'
}

# Development's version.txt stays a single line. Read the build tag from
# the development script itself instead of adding a second manifest field.
_ReadDevBuildTag_() {
  local candidate buildtag dev_script_url
  dev_script_url="${1:-$UPDATE_DEV_SCRIPT_URL}"
  candidate="$RUNTIME/dev-script-check.$$"
  [ ! -e "$candidate" ] && [ ! -L "$candidate" ] || {
    _Fail_ 'Development script staging path already exists'; return 1;
  }
  if ! _FetchHTTPS_ "$dev_script_url" "$candidate"; then
    rm -f "$candidate"; return 1
  fi
  if [ "$(wc -c < "$candidate")" -gt 1048576 ] || ! sh -n "$candidate" ||
      ! grep -Fx "readonly SCRIPT_VERSION=$RELEASE_VERSION" "$candidate" >/dev/null 2>&1 ||
      ! grep -Fx "readonly SCRIPT_NAME=\"$SCRIPT_NAME\"" "$candidate" >/dev/null 2>&1 ||
      ! grep -Fx 'SCRIPT_BRANCH="dev"' "$candidate" >/dev/null 2>&1 ||
      ! grep -Fx "CONFIG_SCHEMA=$CONFIG_SCHEMA" "$candidate" >/dev/null 2>&1 ||
      ! grep -F 'amtmupdate)' "$candidate" >/dev/null 2>&1; then
    rm -f "$candidate"
    _Fail_ 'Development source failed version, channel, schema or syntax validation'
    return 1
  fi
  buildtag="$(sed -n 's/^readonly SCRIPT_VERSTAG="\([0-9][0-9]*\)"$/\1/p' "$candidate")"
  rm -f "$candidate" || return 1
  if ! printf '%s\n' "$buildtag" | LC_ALL=C grep -Eq '^[0-9]{8,14}$'; then
    _Fail_ 'Invalid or missing development build tag'; return 1
  fi
  RELEASE_VERSTAG="$buildtag"
  return 0
}

_IsNewerBuildTag_() {
  # Numeric comparison via awk works for 8-14 digit tags on 32-bit ash.
  awk -v remote="$1" -v localtag="$2" 'BEGIN { exit !(remote+0 > localtag+0) }'
}

_ReadReleaseManifest_() {
  local manifest records requested_channel requested_manifest_url requested_dev_url
  requested_channel="${1:-$UPDATE_CHANNEL}"
  case "$requested_channel" in
    development)
      requested_manifest_url="$SCRIPT_URL_BASE/refs/heads/dev/version.txt"
      requested_dev_url="$SCRIPT_URL_BASE/refs/heads/dev/resolvguard.sh"
      ;;
    stable)
      requested_manifest_url="$SCRIPT_URL_BASE/refs/heads/main/version.txt"
      requested_dev_url=''
      ;;
    *)
      _Fail_ "Unsupported update channel: $requested_channel"
      return 1
      ;;
  esac
  manifest="$RUNTIME/release-version.$$"
  [ ! -e "$manifest" ] && [ ! -L "$manifest" ] || {
    _Fail_ 'Update version staging path already exists'; return 1;
  }
  if ! _FetchHTTPS_ "$requested_manifest_url" "$manifest"; then
    rm -f "$manifest"; return 1
  fi
  records="$(awk 'END { print NR }' "$manifest")"
  if [ "$records" != 1 ] || [ "$(wc -c < "$manifest")" -gt 64 ]; then
    rm -f "$manifest"; _Fail_ 'Invalid version.txt (expected exactly one version line)'; return 1
  fi
  RELEASE_VERSION="$(sed -n '1p' "$manifest")"
  rm -f "$manifest" || return 1
  _IsValidVersion_ "$RELEASE_VERSION" || { _Fail_ 'Invalid remote version'; return 1; }
  # Channel and asset URL are locally pinned: version.txt cannot redirect
  # downloads to an arbitrary host or asset name.
  RELEASE_VERSTAG=''
  RELEASE_CHANNEL="$requested_channel"
  if [ "$requested_channel" = development ]; then
    RELEASE_SCRIPT_URL="$requested_dev_url"
    _ReadDevBuildTag_ "$requested_dev_url" || return 1
  else
    RELEASE_SCRIPT_URL="$RELEASE_URL_BASE/v$RELEASE_VERSION/$RELEASE_UPDATE_ASSET"
  fi
  return 0
}

_UpdateSafetyPreflight_() {
  _IsInstallationComplete_ || {
    _Fail_ 'ResolvGuard installation has not completed'; return 1;
  }
  [ "$ROOT" = "$INSTALL_ROOT" ] || {
    _Fail_ 'Updates are restricted to the installed add-on directory'; return 1;
  }
  [ -f "$ROOT/resolvguard.sh" ] && [ ! -L "$ROOT/resolvguard.sh" ] || {
    _Fail_ 'Installed script is missing or a symbolic link'; return 1;
  }
  [ -d "$STATE_DIR" ] && [ ! -L "$STATE_DIR" ] || {
    _Fail_ 'State directory missing or unsafe'; return 1;
  }
  for path in "$PENDING_TRANSACTION" "$RECOVERY_HOLD" "$PREFERRED_SYNC" \
              "$ACTIVE_POOL" "$ACTIVE_RULELIST"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      _Fail_ "Managed WAN/recovery state prevents updating: $path"
      return 1
    fi
  done
  return 0
}

# Used by restore, update and uninstall after acquiring the WAN lock. The config
# lock may be absent if its later acquisition failed; do not release it then.
_CleanupMaintenanceLocks_() {
  if [ "${RG_CONFIG_LOCK_ALREADY_HELD:-0}" = 1 ]; then
    _ReleaseConfigLock_ >/dev/null 2>&1 || :
    RG_CONFIG_LOCK_ALREADY_HELD=0
  fi

  _ReleaseWANLock_ >/dev/null 2>&1 || :
  _ReleaseMaintenancePriority_ >/dev/null 2>&1 || :
}

_ApplyVerifiedUpdate_() (
  local stage newscript staged installed backup tempbackup
  umask 077
  _UpdateSafetyPreflight_ || exit 1
  if ! _AcquireWANLockForMaintenance_; then
    _Fail_ 'Unable to reserve WAN access for update'
    exit 1
  fi
  # Protect against cron/manual operations and synchronize the short script
  # replacement with interactive configuration commits.
  trap '_CleanupMaintenanceLocks_' EXIT
  trap 'exit 130' INT
  trap 'exit 143' HUP TERM
  _UpdateSafetyPreflight_ || exit 1
  stage="$RUNTIME/update-$$"
  [ ! -e "$stage" ] && [ ! -L "$stage" ] && mkdir "$stage" || {
    _Fail_ 'Unsafe update staging directory'; exit 1;
  }
  # Production uses a version-pinned .sh Release asset; development uses
  # the raw dev .sh script. Neither path downloads configuration files.
  newscript="$stage/$RELEASE_UPDATE_ASSET"
  if ! _FetchHTTPS_ "$RELEASE_SCRIPT_URL" "$newscript"; then
    rm -rf "$stage"; exit 1
  fi
  [ "$(wc -c < "$newscript")" -le 1048576 ] || {
    rm -rf "$stage"; _Fail_ 'Update script exceeds size limit'; exit 1;
  }
  sh -n "$newscript" || {
    rm -rf "$stage"; _Fail_ 'Downloaded script failed shell syntax validation'; exit 1;
  }
  grep -Fx "readonly SCRIPT_VERSION=$RELEASE_VERSION" "$newscript" >/dev/null 2>&1 &&
    grep -Fx "readonly SCRIPT_NAME=\"$SCRIPT_NAME\"" "$newscript" >/dev/null 2>&1 &&
    grep -Fx "CONFIG_SCHEMA=$CONFIG_SCHEMA" "$newscript" >/dev/null 2>&1 &&
    grep -F 'amtmupdate)' "$newscript" >/dev/null 2>&1 || {
    rm -rf "$stage"; _Fail_ 'Incompatible script name, version, schema or updater interface'; exit 1;
  }
  if [ "$RELEASE_CHANNEL" = development ]; then
    grep -Fx 'SCRIPT_BRANCH="dev"' "$newscript" >/dev/null 2>&1 &&
      grep -Fx "readonly SCRIPT_VERSTAG=\"$RELEASE_VERSTAG\"" "$newscript" >/dev/null 2>&1 || {
      rm -rf "$stage"; _Fail_ 'Development update branch or build tag mismatch'; exit 1;
    }
  else
    grep -Fx 'SCRIPT_BRANCH="master"' "$newscript" >/dev/null 2>&1 || {
      rm -rf "$stage"; _Fail_ 'Release asset is not marked as stable'; exit 1;
    }
  fi
  _AcquireConfigLock_ || {
    rm -rf "$stage"
    _Fail_ 'Configuration commit in progress; script replacement deferred'
    exit 1
  }
  RG_CONFIG_LOCK_ALREADY_HELD=1
  _UpdateSafetyPreflight_ || exit 1
  installed="$ROOT/resolvguard.sh"
  staged="$ROOT/.resolvguard.sh.update.$$"
  tempbackup="$STATE_DIR/.updater-previous.sh.$$"
  backup="$STATE_DIR/updater-previous.sh"

  # The replacement is staged beside the installed script so the final move
  # stays on the same filesystem. The old script is retained only until the
  # new installation has been verified (or a failed installation restored).
  for path in "$staged" "$tempbackup"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      rm -rf "$stage"
      _Fail_ 'Update destination staging path occupied'
      exit 1
    fi
  done

  # Previous builds saved a persistent updater-previous.sh. Accept an ordinary
  # legacy file so that a successful update can retire it, but refuse unsafe
  # state entries rather than deleting unknown files or following symlinks.
  if [ -L "$backup" ]; then
    rm -rf "$stage"
    _Fail_ 'Existing updater backup is a symbolic link'
    exit 1
  fi

  if [ -e "$backup" ] && [ ! -f "$backup" ]; then
    rm -rf "$stage"
    _Fail_ 'Existing updater backup is not a regular file'
    exit 1
  fi

  if ! cp "$newscript" "$staged" || ! chmod 755 "$staged" ||
     ! cp "$installed" "$tempbackup" || ! chmod 600 "$tempbackup"; then
    rm -f "$staged" "$tempbackup"
    rm -rf "$stage"
    _Fail_ 'Cannot stage new script or temporarily preserve old script'
    exit 1
  fi

  if ! mv -f "$staged" "$installed"; then
    rm -f "$staged"
    rm -rf "$stage"

    # Preserve the temporary copy when replacement fails unexpectedly: the
    # installed script may no longer be identical to the previous version.
    if cmp -s "$installed" "$tempbackup"; then
      rm -f "$tempbackup" || :
      _Fail_ 'Atomic script replacement failed; original installation retained'
    else
      _Fail_ "CRITICAL: script replacement failed; previous script retained at $tempbackup"
    fi
    exit 1
  fi

  # A mismatch after replacement must restore the previous script before any
  # rollback file is deleted. Keep that file if restoration cannot be proven.
  if ! cmp -s "$installed" "$newscript"; then
    if cp "$tempbackup" "$staged" && chmod 755 "$staged" &&
       mv -f "$staged" "$installed" && cmp -s "$installed" "$tempbackup"; then
      rm -f "$tempbackup" || _Fail_ "Temporary rollback cleanup failed: $tempbackup"
      rm -rf "$stage"
      _Fail_ 'Update verification failed; previous script restored and verified'
    else
      rm -f "$staged"
      rm -rf "$stage"
      _Fail_ "CRITICAL: update verification and rollback failed; prior script retained at $tempbackup"
    fi
    exit 1
  fi

  # No permanent previous-version backup is retained after success. Clean up
  # the temporary rollback file and the legacy persistent file (if any).
  # A failed removal is reported as incomplete maintenance, never as a clean
  # success, even though the newly installed script already passed verification.
  if ! rm -f "$tempbackup"; then
    rm -rf "$stage"
    _Fail_ "Update installed and verified, but temporary rollback cleanup failed: $tempbackup"
    exit 1
  fi

  if [ -f "$backup" ] && ! rm -f "$backup"; then
    rm -rf "$stage"
    _Fail_ "Update installed and verified, but legacy backup cleanup failed: $backup"
    exit 1
  fi

  if ! rm -rf "$stage"; then
    _Fail_ "Update installed and verified, but download staging cleanup failed: $stage"
    exit 1
  fi

  if [ "$RELEASE_CHANNEL" = development ]; then
    _Say_ "ResolvGuard development update: ${SCRIPT_VERSION}_${SCRIPT_VERSTAG} -> ${RELEASE_VERSION}_${RELEASE_VERSTAG}"
  else
    _Say_ "ResolvGuard updated: $SCRIPT_VERSION -> $RELEASE_VERSION"
  fi
  _Say_ 'Update installed and verified successfully.'
  _Say_ 'Temporary update files cleaned up.'
  exit 0
)

# MerlinAU-style CLI: "develop" installs the newest development script;
# "stable" installs the current stable Release asset (even if that is an
# older version). The installed script's SCRIPT_BRANCH marker persists the
# selected channel; subsequent amtmupdate operations follow that channel.
# The normal verified updater lock/rollback path is reused for both commands.
_SwitchReleaseChannel_() {
  local target_channel

  case "${1:-}" in
    develop)
      target_channel=development
      ;;
    stable)
      target_channel=stable
      ;;
    *)
      _Fail_ 'Usage: resolvguard [develop|stable]'
      return 1
      ;;
  esac

  if ! _UpdateSafetyPreflight_; then
    return 1
  fi

  if [ "$UPDATE_CHANNEL" = "$target_channel" ]; then
    _Say_ "Already using the $target_channel channel; checking for updates."
    _ManageOnlineUpdate_ update
    return $?
  fi

  if ! _ReadReleaseManifest_ "$target_channel"; then
    return 1
  fi

  # A development build may have a higher version than published stable.
  # An explicit channel change must never silently downgrade it.
  if _IsNewerVersion_ "$SCRIPT_VERSION" "$RELEASE_VERSION"; then
    _Say_ "NOTICE: $target_channel currently offers v$RELEASE_VERSION, older than installed v$SCRIPT_VERSION."

    if ! _ConfirmYesNo_ 'Install the older release to switch channels?'; then
      _Say_ 'Channel switch cancelled; installed script unchanged.'
      return 1
    fi
  fi

  _Say_ "Switching ResolvGuard from $UPDATE_CHANNEL to $target_channel."
  _ApplyVerifiedUpdate_
}

_ManageOnlineUpdate_() {
  local mode
  mode="${1:-update}"
  case "$mode" in
    check)
      # amtm compatibility probe: no network, no WAN changes or disk writes.
      [ "$ROOT" = "$INSTALL_ROOT" ] && [ -f "$ROOT/resolvguard.sh" ] &&
        [ -n "$UPDATE_MANIFEST_URL" ] && [ -n "$RELEASE_URL_BASE" ] || return 1
      return 0
      ;;
    status|update) : ;;
    *) _Fail_ 'Usage: amtmupdate [check|status|update]'; return 1 ;;
  esac
  _IsInstallationComplete_ || { _Fail_ 'Complete ResolvGuard installation before checking for updates'; return 1; }
  UPDATE_AVAILABLE=0
  [ "$ROOT" = "$INSTALL_ROOT" ] || { _Fail_ 'Update status only supported from installed location'; return 1; }
  _ReadReleaseManifest_ || return 1
  if _IsNewerVersion_ "$RELEASE_VERSION" "$SCRIPT_VERSION"; then
    UPDATE_AVAILABLE=1
  elif [ "$UPDATE_CHANNEL" = development ] &&
       [ "$RELEASE_VERSION" = "$SCRIPT_VERSION" ] &&
       _IsNewerBuildTag_ "$RELEASE_VERSTAG" "$SCRIPT_VERSTAG"; then
    UPDATE_AVAILABLE=1
  fi
  if [ "$UPDATE_AVAILABLE" != 1 ]; then
    _Say_ "ResolvGuard $SCRIPT_VERSION: UP TO DATE ($UPDATE_CHANNEL)"
    return 0
  fi
  if [ "$UPDATE_CHANNEL" = development ]; then
    _Say_ "$SCRIPT_NAME development update available: ${SCRIPT_VERSION}_${SCRIPT_VERSTAG} -> ${RELEASE_VERSION}_${RELEASE_VERSTAG}"
  else
    _Say_ "$SCRIPT_NAME stable update available: $SCRIPT_VERSION -> $RELEASE_VERSION"
  fi
  [ "$mode" = update ] || return 0
  _ApplyVerifiedUpdate_
}

_RemoveOwnedHooks_() {
  local launcher
  _RemoveScheduleHook_ || return 1
  cru d "$SCHEDULE_JOB" >/dev/null 2>&1 || :
  launcher="$LAUNCH_DIR/resolvguard"
  if [ -f "$launcher" ] && [ ! -L "$launcher" ] &&
     grep -Fx '# ResolvGuard-owned launcher' "$launcher" >/dev/null 2>&1 &&
     grep -Fx "exec /bin/sh $ROOT/resolvguard.sh \"\$@\"" "$launcher" >/dev/null 2>&1; then
    rm -f "$launcher" || return 1
  fi
}

# Uninstall succeeds only after the enrolled WAN DNS and running Stubby verify.
_VerifyPreferredDNSForUninstall_() {
  [ -s "$PREF_RULELIST" ] && [ ! -L "$PREF_RULELIST" ] &&
    [ -s "$PREF_PROVIDERS" ] && [ ! -L "$PREF_PROVIDERS" ] || {
      _Fail_ 'Enrolled preferred DNS snapshot missing or unsafe; uninstall blocked'
      return 1
    }
  [ "$(_ReadNVRAM_ dnspriv_enable)" = 1 ] &&
    [ "$(_ReadNVRAM_ dnspriv_profile)" = 1 ] || {
      _Fail_ 'DNS Privacy is not enabled in Strict mode; uninstall blocked'
      return 1
    }
  [ "$(_ReadWANRulelist_)" = "$(cat "$PREF_RULELIST")" ] || {
    _Fail_ 'Preferred WAN DNS rulelist is not active; uninstall blocked'
    return 1
  }
  [ ! -e "$PENDING_TRANSACTION" ] && [ ! -L "$PENDING_TRANSACTION" ] &&
    [ ! -e "$ACTIVE_POOL" ] && [ ! -L "$ACTIVE_POOL" ] &&
    [ ! -e "$ACTIVE_RULELIST" ] && [ ! -L "$ACTIVE_RULELIST" ] &&
    [ ! -e "$RECOVERY_HOLD" ] && [ ! -L "$RECOVERY_HOLD" ] || {
      _Fail_ 'Managed WAN transaction or recovery state remains; uninstall blocked'
      return 1
    }
  # With the enrolled preferred WAN rulelist already active and NO managed
  # transaction or backup ownership, uninstall does not modify WAN DNS.
  # Require actual Strict DoT/Stubby identity and a live Stubby process, but do
  # NOT run the six-attempt DNSMasq forwarding/recovery wait: its success was
  # not required by the former fallback, and its failure generated repeated
  # warnings even though uninstall was safe to complete. Full readiness is
  # still required when restoring an owned backup or reconciling a journal.
  _VerifyLiveEndpoints_ preferred && _StubbyDaemonRunning_ || {
    _Fail_ 'Preferred authenticated Stubby identity/service not verified; uninstall blocked'
    return 1
  }
  # Success is summarized by the uninstall command; failures are reported above.
}

# An unconfigured installation must have no enrollment or managed state.
# Missing snapshots alone are insufficient evidence that WAN DNS was never changed.
_UninstallNeverEnrolled_() {
  local contents jobs hook
  [ ! -L "$STATE_DIR" ] || {
    _Fail_ 'Unsafe state directory (symlink); uninstall blocked'; return 1; }
  if [ -e "$STATE_DIR" ]; then
    [ -d "$STATE_DIR" ] || {
      _Fail_ 'Unexpected non-directory state path; uninstall blocked'; return 1; }
    # Installation readiness is not DNS ownership or recovery evidence.
    # All other saved state remains protected by the original guard.
    [ ! -L "$INSTALL_MARKER" ] || {
      _Fail_ 'Unsafe installation marker; uninstall blocked'; return 1; }
    contents="$(find "$STATE_DIR" -mindepth 1 ! -path "$INSTALL_MARKER" -print -quit 2>/dev/null)" || return 1
    [ -z "$contents" ] || {
      _Fail_ 'Unenrolled installation has saved state; refusing to discard possible DNS recovery evidence'
      return 1
    }
  fi
  [ ! -e "$PREF_RULELIST" ] && [ ! -L "$PREF_RULELIST" ] &&
    [ ! -e "$PREF_PROVIDERS" ] && [ ! -L "$PREF_PROVIDERS" ] || return 1
  hook="$HOOK_DIR/services-start"
  if [ -f "$hook" ] && [ ! -L "$hook" ]; then
    if grep -F "$ROOT/resolvguard.sh" "$hook" >/dev/null 2>&1 ||
       grep -Fqx '# RESOLVGUARD BEGIN' "$hook" ||
       grep -Fqx '# RESOLVGUARD END' "$hook"; then
      _Fail_ 'Unenrolled installation still has a startup hook; uninstall blocked'
      return 1
    fi
  fi
  jobs="$(cru l 2>/dev/null)" || {
    _Fail_ 'Cannot confirm absence of ResolvGuard cron job; uninstall blocked'
    return 1
  }
  if printf '%s\n' "$jobs" | grep -E 'ResolvGuardHealth|ResolvGuard\.d/resolvguard\.sh' >/dev/null 2>&1; then
    _Fail_ 'Unenrolled installation still has a scheduled job; uninstall blocked'
    return 1
  fi
  return 0
}

_UninstallLocked_() {
  local never_enrolled
  # Admission is closed by the configuration lock held by _DoUnInstallation_.
  # Refuse deleting the add-on while an independent read-only inspector lives.
  if _ActiveInspectorSessions_; then
    _Fail_ 'An independent DNS inspector is still active; finish inspection before uninstall'
    return 1
  fi
  # Recovery of an already journaled managed switch takes precedence over
  # external synchronization. Do not strand an otherwise recoverable uninstall.
  if [ -e "$PENDING_TRANSACTION" ] || [ -L "$PENDING_TRANSACTION" ] ||
     [ -e "$RECOVERY_HOLD" ] || [ -L "$RECOVERY_HOLD" ]; then
    _RestorePreferredDNSLocked_ || return 1
  fi
  _SyncPreferredWANLocked_ || return 1
  _CheckOwnedStartupHook_ || return 1
  never_enrolled=0
  if [ ! -e "$PREF_RULELIST" ] && [ ! -L "$PREF_RULELIST" ] &&
     [ ! -e "$PREF_PROVIDERS" ] && [ ! -L "$PREF_PROVIDERS" ]; then
    _UninstallNeverEnrolled_ || return 1
    never_enrolled=1
    # Unenrolled installations cannot claim ownership of WAN DNS.
  else
    if [ "$(_ReadWANRulelist_)" = "$(cat "$PREF_RULELIST")" ]; then
      # The current ASUS selection is already preferred. Leave it untouched;
      # there is no reason to restart Stubby or revert a newer GUI choice.
      _VerifyLiveEndpoints_ preferred || {
        _Fail_ 'Current ASUS Strict DoT config not verified; uninstall blocked'; return 1; }
    else
      if ! _RestorePreferredDNSLocked_; then
        _Fail_ 'Managed backup restoration failed; installation retained'; return 1
      fi
    fi
    _VerifyPreferredDNSForUninstall_ || return 1
  fi

  _DisableScheduledMonitoring_ quiet || {
    _Fail_ 'Schedule cleanup failed; installation retained'
    return 1
  }
  _RemoveOwnedHooks_ || {
    _Fail_ 'Integration cleanup failed; installation retained'
    return 1
  }

  if [ "$never_enrolled" -eq 0 ]; then
    [ "$(_ReadWANRulelist_)" = "$(cat "$PREF_RULELIST")" ] &&
      _VerifyLiveEndpoints_ preferred || {
        _Fail_ 'Preferred WAN DNS changed during uninstall; installation retained'
        return 1
      }
  else
    _UninstallNeverEnrolled_ || return 1
  fi
  # Remove only ResolvGuard-owned WebUI resources before deleting the add-on.
  if [ -f "$ROOT/webui/ResolvGuard.asp" ] && [ ! -L "$ROOT/webui/ResolvGuard.asp" ]; then
    _RGWebUI_ unmount || {
      _Fail_ 'WebUI cleanup failed; installation retained for inspection'
      return 1
    }
  fi
  rm -rf "$ROOT" || {
    _Fail_ 'Failed to remove add-on files; inspect the remaining installation'
    return 1
  }
}

_DoUnInstallation_() {
  if [ "$ROOT" != '/jffs/addons/ResolvGuard.d' ]; then
    _Fail_ 'Uninstall is restricted to /jffs/addons/ResolvGuard.d'
    return 1
  fi
  if [ ! -e "$PREF_RULELIST" ] && [ ! -L "$PREF_RULELIST" ] &&
     [ ! -e "$PREF_PROVIDERS" ] && [ ! -L "$PREF_PROVIDERS" ]; then
    _ConfirmYesNo_ 'Uninstall ResolvGuard?' || return 1
  else
    _ConfirmYesNo_ 'Uninstall ResolvGuard? (restore managed DNS if needed)' || return 1
  fi

  if ! _AcquireWANLockForMaintenance_; then
    _Fail_ 'Unable to reserve WAN access for uninstall'
    return 1
  fi
  trap '_CleanupMaintenanceLocks_' EXIT
  trap 'exit 130' INT
  trap 'exit 143' HUP TERM
  # A scheduled probe may be active, but an uninstall must acquire both
  # locks before removing any shared installation or state files.
  if ! _AcquireConfigLock_; then
    _Fail_ 'Configuration commit in progress; uninstall deferred'
    _CleanupMaintenanceLocks_
    trap - EXIT HUP INT TERM
    return 1
  fi
  RG_CONFIG_LOCK_ALREADY_HELD=1
  if ! _UninstallLocked_; then
    _CleanupMaintenanceLocks_
    trap - EXIT HUP INT TERM
    return 1
  fi
  if ! _ReleaseConfigLock_; then
    _Fail_ 'Uninstall completed, but configuration lock release failed; inspect runtime state'
    exit 1
  fi
  RG_CONFIG_LOCK_ALREADY_HELD=0
  if ! _ReleaseWANLock_; then
    _Fail_ 'Add-on removed but WAN lock release failed; inspect runtime lock manually'
    exit 1
  fi
  if ! _ReleaseMaintenancePriority_; then
    _Fail_ 'Add-on removed but maintenance priority release failed; inspect runtime state'
    exit 1
  fi
  trap - EXIT HUP INT TERM
  if [ "$RUNTIME" = /tmp/resolvguard ]; then
    rm -rf "$RUNTIME" || _Say_ 'NOTICE: Temporary runtime cleanup incomplete.'
  fi
  _Say_ 'ResolvGuard: UNINSTALLED'
  exit 0
}

_SaveInspectedDNSCheck_() {
  local source host rr code count value mode expected_count expected_value
  local existing_row match_count key proposed status_colour
  source="$1"; host="$2"; rr="$3"; code="$4"; count="$5"; value="$6"
  case "$rr:$code" in
    A:NOERROR|AAAA:NOERROR|A:NXDOMAIN|AAAA:NXDOMAIN) : ;;
    *) _Fail_ 'Only successful NOERROR or intentional NXDOMAIN responses can become health checks'; return 1 ;;
  esac
  _IsValidDomain_ "$host" && _IsValidAnswerCount_ "$count" && _IsSafeToken_ "$value" || {
    _Fail_ 'Invalid selected response'; return 1;
  }
  expected_count=ANY; expected_value='-'
  if [ "$code" = NXDOMAIN ]; then
    [ "$count" = 0 ] || { _Fail_ 'Invalid NXDOMAIN count'; return 1; }
    expected_count=0
  else
    _Say_ ''
    _Say_ 'Choose how strictly to monitor this response:'
    _Say_ '  1. RCODE only (recommended for dynamic sites)'
    printf '  2. RCODE and exact answer count (%s)\n' "$count"
    if [ "$value" != '-' ]; then
      printf '  3. RCODE and exact address (%s)\n' "$value"
      _Say_ '  4. RCODE, address and count'
    fi
    _Say_ '  e. Finish without saving this health check (exit also works)'
    _Ask_ 'Rule precision' 1 || return 1
    mode="$(_NormalizeMenuChoice_ "$RG_ANSWER")"
    case "$mode" in
      1) : ;;
      2) expected_count="$count" ;;
      3|4)
        [ "$value" != '-' ] || { _Fail_ 'No address in the observed answer'; return 1; }
        case "$rr" in
          A) _IsValidIPv4_ "$value" || { _Fail_ 'Invalid IPv4 result'; return 1; } ;;
          AAAA) case "$value" in *:*) :;; *) _Fail_ 'Invalid IPv6 result'; return 1;; esac
            case "$value" in *[!0-9A-Fa-f:.]*) _Fail_ 'Invalid IPv6 result'; return 1;; esac ;;
        esac
        expected_value="$value"
        [ "$mode" != 4 ] || expected_count="$count"
        ;;
      E|EXIT) _Say_ 'No health check saved from this selection.'; return 2 ;;
      *) _Fail_ 'Invalid rule precision (choose a number or e/exit)'; return 1 ;;
    esac
  fi
  key="$host|$rr"
  proposed="$key|$code|$expected_count|$expected_value"
  match_count="$(awk -F'|' -v h="$host" -v t="$rr" '$1!~/^#/ && $1==h && $2==t {n++} END{print n+0}' "$CHECKS")"
  [ "$match_count" -le 1 ] || { _Fail_ 'Duplicate policy rows; resolve under Advanced Options'; return 1; }
  existing_row="$(awk -F'|' -v h="$host" -v t="$rr" '$1==h && $2==t {print; exit}' "$CHECKS")"
  _Say_ ''
  printf '  %s%sPROPOSED DNS HEALTH CHECK%s\n' "$RG_BOLD" "$RG_CYAN" "$RG_RESET"
  printf '  %-17s %s%s%s\n' 'Hostname:' "$RG_CYAN" "$host" "$RG_RESET"
  printf '  %-17s %s%s%s\n' 'Record type:' "$RG_BOLD" "$rr" "$RG_RESET"
  case "$code" in NOERROR) status_colour="$RG_GREEN" ;; *) status_colour="$RG_CYAN" ;; esac
  printf '  %-17s %s%s%s\n' 'Expected status:' "$status_colour" "$code" "$RG_RESET"
  printf '  %-17s %s%s%s\n' 'Answer count:' "$RG_YELLOW" "$expected_count" "$RG_RESET"
  printf '  %-17s %s%s%s\n' 'Required data:' "$RG_CYAN" "$expected_value" "$RG_RESET"
  printf '  %-17s %s%s%s (authenticated DoT)\n' 'Observed using:' "$RG_CYAN" "$source" "$RG_RESET"
  if [ -n "$existing_row" ]; then
    printf '\n  %s%sREPLACE%s existing check for %s%s%s\n' "$RG_BOLD" "$RG_YELLOW" "$RG_RESET" "$RG_CYAN" "$key" "$RG_RESET"
    printf '  Existing: %s\n' "$existing_row"
  else
    printf '\n  %s%sADD%s health check for %s%s%s\n' "$RG_BOLD" "$RG_GREEN" "$RG_RESET" "$RG_CYAN" "$key" "$RG_RESET"
  fi
  printf '  %sNote:%s Exact counts/addresses can change; policy approval will need renewal.\n' "$RG_YELLOW" "$RG_RESET"
  _ConfirmYesNo_ 'Save this DNS health check?' || return 1
  if [ "$existing_row" = "$proposed" ]; then
    _Say_ 'Already configured; no changes made.'
    return 0
  fi
  if [ -n "$existing_row" ]; then
    _ChangeTSVFile_ "$CHECKS" check edit "$key" "$proposed"
  else
    _ChangeTSVFile_ "$CHECKS" check add "$key" "$proposed"
  fi
}

_InspectAndSaveHealthCheck_() (
  local capture host selection row source_ip qname rr code count addr i available result_colour
  local mode recommended record_types save_status
  capture="$RUNTIME/inspect-selection-$$.tsv"
  [ ! -e "$capture" ] && [ ! -L "$capture" ] || { _Fail_ 'Inspector selection already exists'; return 1; }
  (umask 077; : > "$capture") || return 1
  trap 'rm -f "$RUNTIME/inspect-selection-$$.tsv"' EXIT HUP INT TERM
  _Say_ 'Live DNS Inspection and Guided Health Checks'
  _Say_ 'Enter a hostname or HTTP(S) URL. ResolvGuard queries every configured'
  _Say_ 'resolver through strict authenticated DoT, without changing WAN DNS.'
  _Ask_ 'Hostname or HTTP(S) URL' '' || return 1
  [ -n "$RG_ANSWER" ] || { _Say_ 'Cancelled.'; return 0; }
  host="$RG_ANSWER"
  mode="$(_GetRouterIPv6Mode_)"
  case "$mode" in
    enabled) recommended=BOTH; _Say_ '  IPv6 is enabled; A and AAAA recommended.' ;;
    disabled) recommended=A; _Say_ '  IPv6 is disabled; A recommended. AAAA remains available.' ;;
    *) recommended=A; _Say_ '  IPv6 state unknown; A recommended. AAAA remains available.' ;;
  esac
  _Ask_ 'Record types (A/AAAA/BOTH)' "$recommended" || return 1
  record_types="$(printf '%s' "$RG_ANSWER" | tr '[:lower:]' '[:upper:]')"
  case "$record_types" in A|AAAA|BOTH) :;; *) _Fail_ 'Choose A, AAAA or BOTH'; return 1;; esac
  if ! _InspectDNS_ "$host" "$record_types" all summary "$capture"; then
    _Say_ 'Some resolver responses failed. Only usable results are offered below.'
  fi
  [ -s "$capture" ] || { _Say_ 'No DNS responses to select.'; return 1; }
  while :; do
    _Say_ ''
    printf '  %s%sSELECT AN OBSERVED DNS RESPONSE%s\n' "$RG_BOLD" "$RG_CYAN" "$RG_RESET"
    i=0; available=0
    while IFS='|' read -r source_ip qname rr code count addr; do
      case "$rr:$code" in
        A:NOERROR|AAAA:NOERROR|A:NXDOMAIN|AAAA:NXDOMAIN)
          i=$((i+1)); available=$((available+1))
          case "$code" in NOERROR) result_colour="$RG_GREEN" ;; *) result_colour="$RG_CYAN" ;; esac
          printf '  %s%2d%s. %s%-15s%s %s%-4s%s %s%-9s%s %scount=%s%s' \
            "$RG_GREEN" "$i" "$RG_RESET" \
            "$RG_CYAN" "$source_ip" "$RG_RESET" \
            "$RG_BOLD" "$rr" "$RG_RESET" \
            "$result_colour" "$code" "$RG_RESET" \
            "$RG_YELLOW" "$count" "$RG_RESET"
          [ "$addr" = '-' ] || printf '  %sdata=%s%s' "$RG_CYAN" "$addr" "$RG_RESET"
          printf '\n'
          ;;
        *)
          printf '   --  %s%-15s%s %-4s %s%-9s%s (error; not selectable)\n' \
            "$RG_CYAN" "$source_ip" "$RG_RESET" "$rr" "$RG_RED" "$code" "$RG_RESET" ;;
      esac
    done < "$capture"
    [ "$available" -gt 0 ] || { _Say_ 'No successful DNS responses to save.'; return 1; }
    _Say_ '  Select a number only if you want to create a DNS health check.'
    _Say_ '  e. Finish inspection (exit also works)'
    _Ask_ 'Result number or e to finish' '' || return 1
    selection="$(_NormalizeMenuChoice_ "$RG_ANSWER")"
    case "$selection" in
      E|EXIT) _Say_ 'Inspection finished. No additional changes requested.'; return 0 ;;
      '') _ShowInvalidSelection_; continue ;;
      *[!0-9]*|0) _Fail_ 'Invalid result number'; return 1 ;;
    esac
    [ "$selection" -le "$available" ] || { _Fail_ 'Result number out of range'; return 1; }
    row="$(awk -F'|' -v n="$selection" '
        ($3=="A" || $3=="AAAA") && ($4=="NOERROR" || $4=="NXDOMAIN") {if (++i==n) {print;exit}}' "$capture")"
    [ -n "$row" ] || { _Fail_ 'Selected result unavailable'; return 1; }
    IFS='|' read -r source_ip qname rr code count addr <<EOF_RG_PICK
$row
EOF_RG_PICK
    if _SaveInspectedDNSCheck_ "$source_ip" "$qname" "$rr" "$code" "$count" "$addr"; then
      :
    else
      save_status=$?
      # A cancelled precision selection is a normal return, not a wizard failure.
      [ "$save_status" -ne 2 ] || return 0
      return "$save_status"
    fi
    if ! _ConfirmYesNo_ 'Add another health check from these results?' quiet; then
      return 0
    fi
  done
)

# Shared diagnostic action used from the merged read-only monitoring menu.
_ShowDiscoveredProvidersAndPools_() {
  if _DiscoverResolvers_ && _PrepareResolverPools_; then
    _Say_ 'Resolver pools:'; cat "$POOLS"
  else
    _Say_ 'Resolver discovery: BUSY or WAN verification pending. Retry shortly.'
  fi
}

_ShowPolicyMenu_() {
  local choice
  while :; do
    _ShowHeader_ 'Advanced Policy Administration'
    _PrintMenuItem_ ap 'Review / Approve DNS Policy'
    _PrintMenuItem_ rp 'Revoke DNS Policy'
    _PrintMenuItem_ e 'Back'
    _PrintMenuFooter_
    IFS= read -r choice || return 0
    choice="$(_NormalizeMenuChoice_ "$choice")"
    printf '\n'
    case "$choice" in
      AP) _ApprovePolicy_; _PromptEnter_ ;;
      RP) _RevokePolicy_; _PromptEnter_ ;;
      E|EXIT) return 0 ;;
      *) _ShowInvalidSelection_ ;;
    esac
  done
}

_ShowAdvancedSettingsMenu_() {
  local choice
  while :; do
    _ShowHeader_ 'Maintenance & Recovery'
    _PrintMenuItem_ re 'Restore Enrolled Preferred WAN DNS'
    _PrintMenuItem_ up 'Check for Updates'
    _PrintMenuItem_ dp 'Check / Install bind-dig'
    _PrintMenuItem_ un 'Uninstall ResolvGuard'
    _PrintMenuItem_ e 'Back'
    _PrintMenuFooter_
    IFS= read -r choice || return 0
    choice="$(_NormalizeMenuChoice_ "$choice")"
    printf '\n'
    case "$choice" in
      RE) _RestorePreferredDNS_; _PromptEnter_ ;;
      DP) _EnsureDigDependency_; _PromptEnter_ ;;
      UP)
        if _ManageOnlineUpdate_ status && [ "${UPDATE_AVAILABLE:-0}" = 1 ]; then
          if _ConfirmYesNo_ 'Install available update?'; then
            if _ManageOnlineUpdate_ update; then
              # The verified updater runs in a subshell. Its WAN/configuration
              # locks and cleanup traps finish before control returns here.
              # Replace this running menu rather than displaying the old
              # SCRIPT_VERSTAG after installing a newer script on disk.
              _Say_ 'Restarting ResolvGuard...'
              exec /bin/sh "$ROOT/resolvguard.sh" menu

              # exec does not return on success. This is only a fallback if
              # the shell cannot start the installed script.
              _Fail_ 'Unable to restart the updated ResolvGuard script'
            fi
          fi
        fi
        _PromptEnter_
        ;;
      UN) _DoUnInstallation_; _PromptEnter_ ;;
      E|EXIT) return 0 ;;
      *) _ShowInvalidSelection_ ;;
    esac
  done
}

# Summarize only the pool types actually prepared; an empty independent
# backup list must never be described as having independent backups.
_DescribeAlternatePools_() {
  awk -F'|' '
    $1 ~ /^wanpool[0-9]+$/ {wan++}
    $1 ~ /^backup[0-9]+$/ {independent++}
    END {printf "%d WAN-derived, %d independent\n", wan+0, independent+0}
  ' "$POOLS"
}

# Keep status values aligned and highlight their meaning only in a terminal.
# _ShowHeader_ has already initialized the menu palette. The same function
# emits plain text when stdout is redirected or NO_COLOR is set.
_PrintQuickStatusRow_() {
  local label value colour

  label="$1"
  value="$2"
  colour="${3:-}"

  printf '  %-23s %s%s%s\n' "$label" "$colour" "$value" "$RG_RESET"
}

_ShowQuickStatus_() {
  local active mode approval pool_summary sync_ok
  local pool_colour mode_colour approval_colour

  sync_ok=1
  _ShowHeader_ 'Protection Status'

  # A concurrent DNS operation must not cause the menu to reclaim a WAN lock.
  # Continue to show a read-only snapshot when synchronization is unavailable.
  if ! _SyncPreferredWAN_; then
    sync_ok=0
    printf '\n  %s%sNOTICE: STATUS TEMPORARILY LIMITED%s\n' \
      "$RG_YELLOW" "$RG_BOLD" "$RG_RESET"
    _Say_ '  DNS operation active or WAN synchronization unverified.'
    _Say_ '  Showing read-only status; alternate pool discovery is deferred.'
  fi

  _Say_ ''

  if [ -r "$PREF_RULELIST" ] && [ -r "$PREF_PROVIDERS" ]; then
    active="$(_GetActiveWANPool_ 2>/dev/null)" || active='UNKNOWN / EXTERNAL CHANGE'

    if [ "$sync_ok" -eq 0 ]; then
      active="$(_GetWANLockDisplay_ 2>/dev/null)" || active='WAN NOT VERIFIED'
    fi

    case "$active" in
      preferred)
        pool_colour="$RG_GREEN"
        ;;
      filtered1|filtered2)
        pool_colour="$RG_YELLOW"
        ;;
      *'PROGRESS'*|*'NOT VERIFIED'*)
        pool_colour="$RG_YELLOW"
        ;;
      *)
        pool_colour="$RG_RED"
        ;;
    esac

    _PrintQuickStatusRow_ 'WAN DNS pool:' "$active" "$pool_colour"
    _PrintQuickStatusRow_ 'Preferred snapshot:' 'SAVED' "$RG_GREEN"
  else
    _PrintQuickStatusRow_ 'WAN DNS pool:' 'NOT ENROLLED' "$RG_YELLOW"
    _PrintQuickStatusRow_ 'Preferred snapshot:' 'NOT SET UP' "$RG_RED"
  fi

  if [ ! -r "$SCHEDULE_MARKER" ]; then
    mode='INACTIVE'
    mode_colour="$RG_YELLOW"
  elif _CheckAutomaticFailoverAuthorization_ >/dev/null 2>&1; then
    mode='AUTOMATIC FAILOVER ON'
    mode_colour="$RG_GREEN"
  elif [ -r "$AUTO_FAILOVER_MARKER" ]; then
    mode='POLICY SAFETY HOLD'
    mode_colour="$RG_RED"
  else
    mode='MONITORING ONLY'
    mode_colour="$RG_CYAN"
  fi
  _PrintQuickStatusRow_ 'Protection:' "$mode" "$mode_colour"

  if [ -r "$SCHEDULE_MARKER" ]; then
    _PrintQuickStatusRow_ 'Monitoring:' \
      "EVERY $SCHEDULE_INTERVAL_MINUTES MIN" "$RG_GREEN"
  else
    _PrintQuickStatusRow_ 'Monitoring:' 'OFF' "$RG_YELLOW"
  fi

  approval="$(_GetPolicyApprovalState_ 2>/dev/null)" || :
  case "$approval" in
    VALID\ \(*)
      approval='VALID'
      approval_colour="$RG_GREEN"
      ;;
    MISSING*)
      approval_colour="$RG_YELLOW"
      ;;
    *)
      approval_colour="$RG_RED"
      ;;
  esac
  _PrintQuickStatusRow_ 'Policy approval:' "${approval:-UNKNOWN}" "$approval_colour"

  if [ "$sync_ok" -eq 0 ]; then
    _PrintQuickStatusRow_ 'Alternate pools:' 'BUSY / NOT VERIFIED' "$RG_YELLOW"
  elif _PrepareProviders_ >/dev/null 2>&1 && _PrepareResolverPools_; then
    pool_summary="$(_DescribeAlternatePools_)" || pool_summary='UNAVAILABLE'
    _PrintQuickStatusRow_ 'Alternate pools:' "$pool_summary" "$RG_CYAN"
  else
    _PrintQuickStatusRow_ 'Alternate pools:' 'NOT READY' "$RG_RED"
  fi

  if [ "$sync_ok" -eq 1 ]; then
    case "$active" in
      filtered1|filtered2)
        printf '\n  %sNOTE:%s A filtered pool excludes one or more preferred resolvers.\n' \
          "$RG_YELLOW" "$RG_RESET"
        _Say_ '  See Advanced Options > Monitoring & Diagnostics > Full Technical Status.'
        ;;
    esac
  fi

  _Say_ ''
}

_ConfigureQuickBackup_() {
  local selected name ip1 ip2 host proposed staged
  _PrepareProviders_ && _PrepareResolverPools_ || return 1
  if awk -F'|' '$1 ~ /^(backup|wanpool)[0-9]+$/ {found=1} END{exit !found}' "$POOLS"; then
    _ShowSetupStep_ 2 'ALTERNATE DNS POOLS'
    printf '  %sConfigured alternate pools: %s%s\n' "$RG_GREEN" "$(_DescribeAlternatePools_)" "$RG_RESET"
    return 0
  fi
  if awk -F'|' '$1 !~ /^#/ && $1!="" {found=1} END{exit !found}' "$EXTRA_PROVIDERS"; then
    _Fail_ 'Existing custom entries are not usable. Review Backup DoT Resolvers under Advanced Options > DNS Configuration.'
    return 1
  fi
  while :; do
    _ShowSetupStep_ 2 'BACKUP DNS'
    _PrintBackupPresetChoices_
    if awk -F'|' '$1 ~ /^wan[0-9]+$/ && $3=="dns.google" {found=1} END{exit !found}' "$PREF_PROVIDERS"; then
      proposed=cs
    else
      proposed=go
    fi
    _Ask_ 'Backup provider' "$proposed" || return 1
    selected="$(_NormalizeMenuChoice_ "$RG_ANSWER")"
    case "$selected" in
      GO|CS|QS)
        _SetBackupPreset_ "$selected" || return 1
        name="$RG_PRESET_NAME"; ip1="$RG_PRESET_IP1"; ip2="$RG_PRESET_IP2"; host="$RG_PRESET_HOST" ;;
      CD)
        _ShowBackupResolversMenu_
        _PrepareProviders_ && _PrepareResolverPools_ || return 1
        if awk -F'|' '$1 ~ /^backup[0-9]+$/ {found=1} END{exit !found}' "$POOLS"; then
          printf '\n  %sCustom backup DNS saved.%s\n' "$RG_GREEN" "$RG_RESET"
          return 0
        fi
        _Say_ '  No independent backup configured. Choose a preset or add a custom resolver.'
        continue ;;
      *) _Say_ 'Choose go, cs, qs, or cd.'; continue ;;
    esac
    if awk -F'|' -v h="$host" '$1 ~ /^wan[0-9]+$/ && $3==h {found=1} END{exit !found}' "$PREF_PROVIDERS"; then
      _Say_ "That provider is already your preferred WAN DNS. Choose a different provider."
      continue
    fi
    break
  done
  printf '\n  %sSelected:%s %s (%s, %s)\n' "$RG_BOLD" "$RG_RESET" "$name" "$ip1" "$ip2"
  _ConfirmYesNo_ 'Use this backup DNS?' || return 1
  (
    _AcquireWANLock_ || { _Fail_ 'Another WAN operation is running'; exit 1; }
    trap '_ReleaseWANLock_ >/dev/null 2>&1 || :' EXIT HUP INT TERM
    _CheckConfigurationSafety_ || exit 1
    staged="$EXTRA_PROVIDERS.rg-stage.$$"
    [ ! -e "$staged" ] && [ ! -L "$staged" ] || exit 1
    cp "$EXTRA_PROVIDERS" "$staged" || exit 1
    printf 'quickbackup1|%s|%s|853\nquickbackup2|%s|%s|853\n' \
      "$ip1" "$host" "$ip2" "$host" >> "$staged" || exit 1
    _CommitConfigurationLocked_ "$EXTRA_PROVIDERS" "$staged" >/dev/null
  ) || return 1
  _PrepareProviders_ && _PrepareResolverPools_ || return 1
  awk -F'|' '$1 ~ /^backup[0-9]+$/ {found=1} END{exit !found}' "$POOLS" || {
    _Fail_ 'No independent backup pool was created'; return 1; }
  printf '  %sBackup saved.%s\n' "$RG_GREEN" "$RG_RESET"
}

_RunQuickSetupWizard_() {
  _ShowHeader_ 'Quick Setup'
  _EnsureDigDependency_ quiet || return 1
  _ShowSetupStep_ 1 'PREFERRED DNS'
  _SyncPreferredWAN_ || return 1
  _ValidateConfiguration_ >/dev/null || return 1
  if [ "$ROOT" = "$INSTALL_ROOT" ]; then
    _InstallLauncher_ >/dev/null 2>&1 || :
  fi
  [ "$(_ReadNVRAM_ dnspriv_enable)" = 1 ] &&
    [ "$(_ReadNVRAM_ dnspriv_profile)" = 1 ] && _IsStrictProductionDoT_ || {
      _Fail_ 'Enable Strict DNS Privacy in ASUSWRT-Merlin before setup'; return 1; }
  _PrepareProviders_ || return 1
  if [ ! -r "$PREF_RULELIST" ] || [ ! -r "$PREF_PROVIDERS" ]; then
    # Never offer a partial preferred/restore point: match the entire live
    # NVRAM resolver list to the active firmware-generated Stubby identities.
    local verified configured
    verified="$RUNTIME/quicksetup-verified-$$"
    configured="$RUNTIME/quicksetup-configured-$$"
    if ! _BuildLivePreferredProviders_ "$(_ReadWANRulelist_)" "$verified"; then
      rm -f "$verified"
      _Fail_ 'Complete IPv4/IPv6 preferred DNS could not be verified; enrollment refused'
      return 1
    fi

    awk -F'|' '
      $1 ~ /^wan[0-9]+$/ {
        print
      }
    ' "$PROVIDERS" > "$configured"

    # Legacy saved snapshots have a fifth field; the active probe roster
    # deliberately has four. Compare only the endpoint identities.
    if ! awk -F'|' '
      NR==FNR { expected[FNR]=$1 "|" tolower($2) "|" tolower($3) "|" $5; n++; next }
      { seen++; if (expected[FNR] != $1 "|" tolower($2) "|" tolower($3) "|" $4) wrong=1 }
      END {exit (wrong || n==0 || seen!=n)?1:0}
    ' "$verified" "$configured"; then
      rm -f "$verified" "$configured"
      _Fail_ 'Configured Stubby and WAN preferred resolver lists differ; enrollment refused'
      return 1
    fi
    rm -f "$verified" "$configured"
    printf '  %sCurrent router DNS (Strict DoT):%s\n' "$RG_BOLD" "$RG_RESET"
    awk -F'|' -v col="$RG_CYAN" -v reset="$RG_RESET" \
      '$1 ~ /^wan[0-9]+$/ {printf "    %s%-39s%s %s\n",col,$2,reset,$3}' "$PROVIDERS"
    _ConfirmYesNo_ 'Use ALL these as preferred DNS (and restore point)?' || return 1
    _EnrollPreferredDNS_ >/dev/null || return 1
    printf '  %sPreferred DNS saved.%s\n' "$RG_GREEN" "$RG_RESET"
  else
    printf '  %sPreferred DNS already saved.%s\n' "$RG_GREEN" "$RG_RESET"
  fi
  [ "$(_GetActiveWANPool_ 2>/dev/null)" = preferred ] || {
    _Fail_ 'WAN DNS is not on the enrolled preferred pool. Restore it through Advanced Options > Maintenance first.'
    return 1
  }
  _ConfigureQuickBackup_ || return 1
  _ShowSetupStep_ 3 'DNS CHECKS & PROTECTION'
  _InitializeDefaultDNSPolicy_ || return 1
  if awk -F'|' '
      $0 !~ /^#/ && NF {n++; if ($0 != "a.root-servers.net|A|NOERROR|AT_LEAST_1|-" &&
        $0 != "a.root-servers.net|AAAA|NOERROR|ANY|-") bad=1}
      END {exit !(n>=1 && n<=2 && !bad)}' "$CHECKS"; then
    if grep -Fqx 'a.root-servers.net|AAAA|NOERROR|ANY|-' "$CHECKS"; then
      _Say_ '  Health checks: a.root-servers.net (A at least 1, AAAA RCODE only)'
    else
      _Say_ '  Health checks: a.root-servers.net (A at least 1)'
    fi
  else
    _Say_ '  Your saved DNS health checks will be used.'
  fi
  if _ConfirmYesNo_ 'Customize health checks now?' quiet; then
    _InspectAndSaveHealthCheck_ || {
      _Say_ '  No changes saved; existing checks will be used.'
    }
  fi
  # Disclose domain-scoped DNS bypasses before requesting approval for
  # automatic WAN switching. Interactive SSH users must acknowledge the
  # warning; noninteractive callers receive plain text without a pause.
  _ShowDNSMasqScopedSetupWarning_

  if [ -r "$AUTO_FAILOVER_MARKER" ] && _CheckAutomaticFailoverAuthorization_ >/dev/null 2>&1; then
    printf '  %sAutomatic failover already enabled.%s\n' "$RG_GREEN" "$RG_RESET"
    return 0
  fi
  _EnableAutomaticFailover_ quick || {
    if _ConfirmYesNo_ 'Start scheduled DNS checks without automatic failover?' quiet; then
      _EnableScheduledMonitoring_ confirmed quiet || return 1
      printf '  %sMONITORING ONLY%s  Scheduled checks ON; WAN switching OFF.\n' "$RG_CYAN" "$RG_RESET"
      return 0
    fi
    if [ -r "$SCHEDULE_MARKER" ]; then
      _Say_ '  Existing scheduled monitoring remains enabled; WAN switching stays off.'
    else
      _Say_ '  INACTIVE: Scheduled monitoring OFF; automatic failover OFF.'
    fi
    # Declining both optional operating modes is an intentional setup choice,
    # not a validation failure. Enrollment and saved checks remain available.
    return 0
  }
  # _EnableAutomaticFailover_ has already reported the active mode; the caller
  # reports onboarding completion once after its marker is written.

}

# Installation-complete means only that the add-on is published. Preferred DNS
# enrollment happens during step 1 of Quick Setup, before the wizard can finish.
# Neither enrollment nor the default checks nor operating-mode markers can
# prove that the operator completed all onboarding prompts: both operating
# modes may intentionally be declined. Store a separate completion record.
_IsQuickSetupComplete_() {
  [ -f "$QUICK_SETUP_MARKER" ] && [ ! -L "$QUICK_SETUP_MARKER" ] &&
    grep -Fx 'ResolvGuard Quick Setup complete' "$QUICK_SETUP_MARKER" >/dev/null 2>&1
}

_RecordQuickSetupComplete_() {
  local staged
  _IsQuickSetupComplete_ && return 0
  # Do not replace or follow a malformed or symlinked completion record.
  [ ! -e "$QUICK_SETUP_MARKER" ] && [ ! -L "$QUICK_SETUP_MARKER" ] || {
    _Fail_ 'Unsafe Quick Setup completion record; inspect saved state before retrying'; return 1;
  }
  [ -d "$STATE_DIR" ] && [ ! -L "$STATE_DIR" ] || {
    _Fail_ 'Installation state directory is missing or unsafe'; return 1;
  }
  staged="$STATE_DIR/.quick-setup-complete.$$"
  [ ! -e "$staged" ] && [ ! -L "$staged" ] || return 1
  if ! (umask 077; set -C; printf 'ResolvGuard Quick Setup complete\n' > "$staged"); then
    rm -f "$staged"
    _Fail_ 'Could not stage Quick Setup completion'; return 1
  fi
  if ! ln "$staged" "$QUICK_SETUP_MARKER" 2>/dev/null; then
    rm -f "$staged"
    _Fail_ 'Could not record Quick Setup completion'; return 1
  fi
  rm -f "$staged" || _Say_ 'NOTICE: Quick Setup temporary record needs cleanup.'
  return 0
}

_QuickSetup_() {
  # An explicit CLI quick-setup request may rerun onboarding. A valid completion
  # record hides the main-menu entry but must not block this intentional action.
  # Still reject an invalid or symlinked record instead of replacing it.
  if ! _IsQuickSetupComplete_; then
    if [ -e "$QUICK_SETUP_MARKER" ] || [ -L "$QUICK_SETUP_MARKER" ]; then
      _Fail_ 'Invalid Quick Setup completion record; use Maintenance & Recovery to inspect state'
      return 1
    fi
  fi
  _RunQuickSetupWizard_ || return 1
  _RecordQuickSetupComplete_ || return 1
  _Say_ 'Quick Setup: COMPLETE'
}

# A newly installed script starts its onboarding once. Subsequent launches of
# an installed but incompletely onboarded script leave Quick Setup selectable, rather than forcing
# a repeated interactive wizard (which could prevent ordinary diagnostics).
_StartFirstRunSetup_() {
  _Say_ 'Starting initial ResolvGuard Quick Setup.'
  if ! _QuickSetup_; then
    _Say_ 'Quick Setup did not complete. You can resume it from the main menu.'
  fi
}

_ShowAdvancedOptionsMenu_() {
  local choice
  while :; do
    _ShowHeader_ 'Advanced Options'
    _PrintMenuItem_ dc 'DNS Configuration, Health Checks and Resolvers'
    _PrintMenuItem_ md 'Monitoring, Diagnostics & Logs'
    _PrintMenuItem_ pa 'Policy Approval and Revocation'
    _PrintMenuItem_ mr 'Maintenance & Recovery'
    _PrintMenuItem_ e 'Back'
    _PrintMenuFooter_
    IFS= read -r choice || return 0
    choice="$(_NormalizeMenuChoice_ "$choice")"
    printf '\n'
    case "$choice" in
      DC) _ShowConfigurationMenu_ ;;
      # Backwards-compatible hidden alias: dt opens the merged diagnostics menu.
      MD|DT) _ShowMonitoringDiagnosticsMenu_ ;;
      PA) _ShowPolicyMenu_ ;;
      MR) _ShowAdvancedSettingsMenu_ ;;
      E|EXIT) return 0 ;;
      *) _ShowInvalidSelection_ ;;
    esac
  done
}

_ToggleAutomaticFailover_() {
  if [ -r "$AUTO_FAILOVER_MARKER" ]; then
    _DisableAutomaticFailover_
  elif [ ! -r "$PREF_RULELIST" ] || [ ! -r "$PREF_PROVIDERS" ]; then
    if _IsQuickSetupComplete_; then
      _Fail_ 'Preferred DNS enrollment is missing. Inspect the installation and recovery state; automatic failover remains off.'
      return 1
    fi
    _Say_ 'First-time setup is not complete. Opening Quick Setup.'
    _QuickSetup_
  else
    _PrepareProviders_ && _PrepareResolverPools_ || return 1
    if ! awk -F'|' '$1 ~ /^(backup|wanpool)[0-9]+$/ {found=1} END{exit !found}' "$POOLS"; then
      if _IsQuickSetupComplete_; then
        _Fail_ 'No alternate DNS pool is configured. Add backup resolvers in Advanced Options > DNS Configuration.'
        return 1
      fi
      _Say_ 'No alternate WAN pool is configured. Opening incomplete Quick Setup.'
      _QuickSetup_
    else
      _EnableAutomaticFailover_
    fi
  fi
}

# Blank Enter at any selection menu is invalid; only e/exit navigates.
# Defaults and confirmation prompts intentionally retain their own Enter semantics.
_MainMenu_() {
  local choice state
  while :; do
    _ShowHeader_ 'Main Menu'
    if ! _IsQuickSetupComplete_; then
      _PrintMenuItem_ qs 'Quick Setup (Complete Initial Setup)'
    fi
    if _CheckAutomaticFailoverAuthorization_ >/dev/null 2>&1; then
      state='ON'
    elif [ -r "$AUTO_FAILOVER_MARKER" ]; then
      state='SAFETY HOLD'
    else
      state='OFF'
    fi
    _PrintMenuItem_ af "Automatic DNS Failover: $state (Toggle)"
    _PrintMenuItem_ vs 'View Status'
    _PrintMenuItem_ ch 'Check DNS Health Now'
    _PrintMenuItem_ in 'Inspect Live DNS'
    _PrintMenuItem_ ad 'Advanced Options'
    _PrintMenuItem_ e 'Exit'
    _PrintMenuFooter_
    IFS= read -r choice || return 0
    choice="$(_NormalizeMenuChoice_ "$choice")"
    printf '\n'
    case "$choice" in
      QS)
        if _IsQuickSetupComplete_; then
          _Say_ 'Quick Setup is complete; use the individual configuration menu options.'
        else
          _QuickSetup_
        fi
        _PromptEnter_ ;;
      AF) _ToggleAutomaticFailover_; _PromptEnter_ ;;
      VS) _ShowQuickStatus_; _PromptEnter_ ;;
      CH) _ValidateConfiguration_ >/dev/null && _RunDNSHealthCheck_; _PromptEnter_ ;;
      IN) _InspectAndSaveHealthCheck_; _PromptEnter_ ;;
      AD) _ShowAdvancedOptionsMenu_ ;;
      E|EXIT) return 0 ;;
      *) _ShowInvalidSelection_ ;;
    esac
  done
}

# Direct CLI operations on the installed path must not bypass the installer.
# Boot and scheduled jobs must never prompt for dependencies or install Entware.
case "${1:-menu}" in
  install|menu|uninstall|amtmupdate|develop|stable|help|-h|--help) : ;;
  startup|scheduled-check)
    _IsInstallationComplete_ || { _Fail_ 'Install ResolvGuard before enabling unattended operation'; exit 1; } ;;
  *) if [ "$ROOT" = "$INSTALL_ROOT" ]; then
      _IsInstallationComplete_ || _InstallResolvGuard_ || exit 1
     fi ;;
esac

case "${1:-menu}" in
  install)
    _InstallResolvGuard_ || exit 1
    if ! _IsQuickSetupComplete_; then _StartFirstRunSetup_; fi
    _MainMenu_ ;;
  menu)
    if ! _IsInstallationComplete_; then
      _InstallResolvGuard_ || exit 1
      _StartFirstRunSetup_
    fi
    _MainMenu_ ;;
  configure) _ShowConfigurationMenu_ ;;
  quick-setup) _QuickSetup_ ;;
  dependencies|deps) _EnsureDigDependency_ ;;
  uninstall) _DoUnInstallation_ ;;
  amtmupdate) _ManageOnlineUpdate_ "${2:-update}" ;;
  develop|stable) _SwitchReleaseChannel_ "$1" ;;
  schedule) _ManageScheduledMonitoring_ "${2:-status}" ;;
  policy) _ManagePolicy_ "${2:-status}" ;;
  startup) _ScheduleStartup_ ;;
  scheduled-check) _RunScheduledCheck_ ;;
  webui) _RGWebUI_ "${2:-status}" ;;
  validate) (
    PROVIDERS="$RUNTIME/providers-validation-$$.tsv"
    trap 'rm -f "$RUNTIME/providers-validation-$$.tsv"' EXIT HUP INT TERM
    _ValidateConfiguration_
  ) ;;
  enroll) _EnrollPreferredDNS_ ;;
  restore) _RestorePreferredDNS_ ;;
  pools) _SyncPreferredWAN_ && _PrepareProviders_ && _PrepareResolverPools_ && cat "$POOLS" ;;
  discover) _DiscoverResolvers_ ;;
  check) _RunDNSHealthCheck_ ;;
  probe) _InspectDNS_ "${2:-}" "${3:-BOTH}" "${4:-all}" "${5:-summary}" ;;
  status) _ShowStatus_ ;;
  help|-h|--help)
    cat <<HELP
ResolvGuard v$SCRIPT_VERSION (WAN DNS-over-TLS monitoring and failover)
Usage: sh $ROOT/resolvguard.sh [install|menu|quick-setup|dependencies|configure|uninstall|discover|validate|enroll|pools|check|status|restore|probe <hostname-or-URL> [BOTH|TYPE] [provider-id|all] [summary|full]|schedule [status|enable|disable|logs]|startup|webui [mount|unmount|publish|status]|policy [status|approve|revoke]|amtmupdate [check|status|update]|develop|stable]

No arguments: if installation is needed, install and offer Quick Setup once; otherwise open the SSH menu. An incomplete setup remains selectable from the menu. e or exit leaves the current menu.
install verifies prerequisites (including optional bind-dig installation), initializes missing config, and publishes the main script only after preparation succeeds.
A failed first-time install removes an initially placed script; an existing DNS-enrolled installation is never removed on failed prerequisite repair.
Quick Setup runs after first installation; if cancelled, it remains on the menu until completed. After completion, use the dedicated menu options, or deliberately rerun the wizard using the quick-setup CLI command.
Default INACTIVE: no scheduled monitoring and no automatic WAN DNS changes.
Manual restoration is available through Maintenance & Recovery.
The preferred WAN snapshot and transaction journal live in ResolvGuard.d/state.
Probes use short-lived local authenticated DoT resolvers.
Monitored hostnames are NEVER forwarded through separate DNS routes.
probe is a read-only DNS response inspector. Main Menu IN option can save selected successful observations as policy checks with explicit confirmation.
Install and first run initialize missing config/settings.conf, config/checks.tsv and config/extra-providers.tsv without overwriting existing files.
Quick Setup checks for Entware bind-dig and offers to install it with permission if missing. A separate onboarding completion record is written only after successful setup (including Monitoring Only or deliberately inactive operation). Run dependencies to check/install dig separately.
Extracting the package does not enable cron or startup hooks; choose monitoring or automatic failover in the menu.
Main Menu toggles Automatic DNS Failover; policy review and scheduling are integrated.
Unattended failover requires a persistent, operator-approved DNS policy.
Unexpected answer data/count is monitored as resolver-health failure. Automatic WAN switching still requires corroboration, a safe independently verified destination, and approved policy. An uncorroborated or universally stale DNS policy cannot authorize a switch.
On boot, startup re-registers cron and reconciles known WAN state without WAN writes.
Confirmed failed WAN endpoints may be temporarily excluded; known healthy original endpoints return after sustained successful checks.
Stable updates read GitHub main/version.txt and use version-pinned GitHub Release assets.
Development builds read dev/version.txt and use the raw dev script; SCRIPT_VERSTAG identifies same-version revisions.
Run develop or stable to fetch, validate, and switch to the corresponding channel. A switch to an older stable version asks for confirmation.
The chosen channel persists in the downloaded script's SCRIPT_BRANCH marker; subsequent updates stay on that channel.
Run amtmupdate status to check for a newer release; run amtmupdate update to install it.
amtmupdate check is the offline amtm capability probe; amtmupdate defaults to update.
Updates preserve configuration, enrollment, DNS, and recovery state; unsafe WAN ownership blocks updating.
HELP
    ;;
  *) _Fail_ "Unknown command: $1"; exit 2 ;;
esac
