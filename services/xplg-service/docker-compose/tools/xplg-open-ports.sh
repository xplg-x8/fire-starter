#!/usr/bin/env bash
# ============================================================================
# xplg-open-ports.sh — open XPLG service ports on the host firewall     (v1)
#
# Targets:  Ubuntu 22.04 / 24.04 / 25.04(+24.10)   and
#           RHEL/CentOS Stream/Rocky/Alma 8 / 9 / 10
# Backends: firewalld (RHEL-family default, sometimes Ubuntu),
#           ufw       (Ubuntu default),
#           nftables  (bare, no frontend),
#           iptables  (legacy),
#           none      (no host firewall active — nothing to open)
#
# Usage:
#   sudo ./xplg-open-ports.sh [/path/to/.env] [options]
#     --profiles LIST   comma list (master,server,server-additional,ui,
#                       listener,processor,processor-1). Default: from the
#                       .env COMPOSE_PROFILES, else ALL roles.
#     --source CIDR     restrict rules to a peer subnet (e.g. 10.116.0.0/20)
#     --no-udp          do not open the 14xx ingestion ports for udp
#     --zone Z          firewalld zone (default: default zone)
#     --backend B       force: firewalld|ufw|nftables|iptables|auto (default)
#     --remove          remove the rules this script adds (same options!)
#     --dry-run         print the commands without executing (no root needed)
#     --list            just print the resolved port model and exit
#
# Behavior notes:
#  - Idempotent: re-running adds nothing twice; rules are tagged 'xplg-open'
#    where the backend supports comments (nftables/iptables).
#  - Ports are added INDIVIDUALLY (not as ranges) so that the preflight
#    script's per-port firewalld/ufw queries match them.
#  - Never enables a firewall that is off. If none is active, it reports
#    that and reminds about cloud firewalls (DigitalOcean/AWS SG etc).
#  - Persistence: firewalld --permanent + --reload; ufw is persistent by
#    design; iptables via netfilter-persistent or iptables-services when
#    present; bare nftables/iptables fall back to a systemd oneshot unit
#    (xplg-open-ports.service) that re-applies rules after boot — appending
#    to distro nftables.conf is NOT done because rule ORDER (before drops)
#    cannot be guaranteed through config merging.
#  - Docker note: rootful docker publishes ports via the nat DOCKER chain and
#    bypasses INPUT/ufw — rules here mainly matter for rootless podman
#    (pasta/slirp4netns) and for host-level tools. Opening them is still the
#    right hygiene so preflight and audits agree with reality.
# ============================================================================
# tolerate being launched as `sh script` — re-exec under real bash
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -u
export LC_ALL=C

# ── the XPLG port model (keep in sync with preflight ports_for_role) ───────
# 30304-30308/tcp  HTTP UI       | 30444-30448/tcp HTTPS  (master = 30308/30448)
# 11473-11477/tcp  Hazelcast     | 13344-13348/tcp Ignite discovery slots
# 10800-10804/tcp  Ignite client | 10300-10304/tcp aux/metrics
# 1468-1498 (per-role blocks of 5)  ingestion/syslog listeners: tcp AND udp
ports_for_role() {
  case "$1" in
    master)      echo "30308 30448 11473 13344 10800 10300 1468 1469 1470 1471 1472";;
    ui)          echo "30304 30444 11474 13345 10801 10301 1479 1480 1481 1482 1483";;
    listener)    echo "30305 30445 11475 13346 10802 10302 1484 1485 1486 1487 1488";;
    processor)   echo "30306 30446 11476 13347 10803 10303 1489 1490 1491 1492 1493";;
    processor-1) echo "30307 30447 11477 13348 10804 10304 1494 1495 1496 1497 1498";;
    # Traefik edge entry points (only when deployed with docker-compose.traefik.yml):
    #   80/443 -> ui pool, 30303/30443 -> master pool, 8304-8308 role consoles
    traefik)     echo "80 443 30303 30443 8304 8305 8306 8307 8308";;
  esac
}
is_ingest_port() { [ "$1" -ge 1468 ] && [ "$1" -le 1498 ]; }
roles_for_profiles() {
  local out="" p
  IFS=',' read -ra ps <<< "$1"
  for p in "${ps[@]}"; do
    case "$(echo "$p" | tr -d ' ')" in
      master)            out="$out master" ;;
      server)            out="$out ui listener processor" ;;
      server-additional) out="$out processor processor-1" ;;
      ui|listener|processor|processor-1) out="$out $(echo "$p"|tr -d ' ')" ;;
      traefik|edge)      out="$out traefik" ;;
    esac
  done
  echo "$out" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' '
}

have() { command -v "$1" >/dev/null 2>&1; }
info() { printf ' [*] %s\n' "$1" >&2; }
act()  { printf ' [+] %s\n' "$1"; }
warn() { printf ' [!] %s\n' "$1" >&2; }
die()  { printf ' [x] %s\n' "$1" >&2; exit 1; }

# ── args ────────────────────────────────────────────────────────────────────
ENV_FILE=""; PROFILES=""; SRC=""; UDP=1; ZONE=""; BACKEND=auto
REMOVE=0; DRY=0; LIST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --profiles) PROFILES="${2:?}"; shift 2;;
    --source)   SRC="${2:?}"; shift 2;;
    --no-udp)   UDP=0; shift;;
    --zone)     ZONE="${2:?}"; shift 2;;
    --backend)  BACKEND="${2:?}"; shift 2;;
    --remove)   REMOVE=1; shift;;
    --dry-run)  DRY=1; shift;;
    --list)     LIST=1; shift;;
    -h|--help)  grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    -*)         die "unknown option $1 (see --help)";;
    *)          ENV_FILE="$1"; shift;;
  esac
done
case "$BACKEND" in auto|firewalld|ufw|nftables|iptables) : ;; *) die "--backend must be auto|firewalld|ufw|nftables|iptables";; esac
if [ -n "$SRC" ]; then
  echo "$SRC" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$' || die "--source '$SRC' is not an IPv4 address/CIDR"
fi

# ── resolve roles ───────────────────────────────────────────────────────────
if [ -z "$PROFILES" ] && [ -n "$ENV_FILE" ]; then
  [ -f "$ENV_FILE" ] || die "env file $ENV_FILE not found"
  # import ONLY COMPOSE_PROFILES, in an isolated subshell (same pattern as preflight)
  PROFILES="$( ( set -a; . <(tr -d '\r' < "$ENV_FILE") >/dev/null 2>&1; set +a
                 printf '%s' "${COMPOSE_PROFILES:-}" ) )"
  [ -n "$PROFILES" ] && info "profiles from $ENV_FILE: $PROFILES"
fi
if [ -z "$PROFILES" ]; then
  PROFILES="master,server,server-additional"
  info "no profiles given — opening ports for ALL roles (safe superset)"
fi
ROLES="$(roles_for_profiles "$PROFILES")"
[ -n "$ROLES" ] && info "roles: $ROLES" || die "profiles '$PROFILES' resolve to no roles"

# ── build the port/proto list ───────────────────────────────────────────────
ENTRIES="$(
  for r in $ROLES; do
    for p in $(ports_for_role "$r"); do
      echo "$p/tcp"
      [ "$UDP" = 1 ] && is_ingest_port "$p" && echo "$p/udp"
    done
  done | sort -t/ -k2,2 -k1,1n -u
)"
NTCP="$(echo "$ENTRIES" | grep -c '/tcp$')"; NUDP="$(echo "$ENTRIES" | grep -c '/udp$' || true)"
info "port model: $NTCP tcp + ${NUDP:-0} udp ports${SRC:+, restricted to source $SRC}"
if [ "$LIST" = 1 ]; then
  printf '%s\n' "$ENTRIES"; exit 0
fi

# ── run/echo helper ─────────────────────────────────────────────────────────
# run: dry-run prints the command; real execution silences stdout (mutations
# are chatty), stderr stays visible for genuine errors.
run() { if [ "$DRY" = 1 ]; then printf '    %s\n' "$*"; else "$@" >/dev/null; fi; }
# probe: idempotency pre-checks — always false in dry-run so commands print
probe() { [ "$DRY" = 1 ] && return 1; "$@" >/dev/null 2>&1; }
# probe_out: like probe but prints the command's stdout (empty in dry-run)
probe_out() { [ "$DRY" = 1 ] && return 0; "$@" 2>/dev/null; }

if [ "$DRY" = 0 ] && [ "$(id -u)" -ne 0 ]; then
  die "must run as root to change firewall rules (or use --dry-run)"
fi

# ── backend detection ───────────────────────────────────────────────────────
detect_backend() {
  if have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then echo firewalld; return; fi
  if have ufw && ufw status 2>/dev/null | grep -q 'Status: active'; then echo ufw; return; fi
  # bare nftables: a ruleset exists with an input hook chain, unmanaged by the above
  if have nft && nft list ruleset 2>/dev/null | grep -q 'hook input'; then echo nftables; return; fi
  # legacy iptables with actual filtering (non-ACCEPT policy or any INPUT rules)
  if have iptables && iptables -S INPUT 2>/dev/null | grep -vq -- '-P INPUT ACCEPT' ; then
    if [ "$(iptables -S INPUT 2>/dev/null | wc -l)" -gt 1 ] || iptables -S INPUT 2>/dev/null | grep -q 'DROP\|REJECT'; then
      echo iptables; return
    fi
  fi
  echo none
}
if [ "$BACKEND" = auto ]; then
  BACKEND="$(detect_backend)"
else
  # forced backend: verify the tooling actually exists / is usable
  case "$BACKEND" in
    firewalld) have firewall-cmd || { [ "$DRY" = 1 ] && warn "firewall-cmd not installed here — dry-run preview only" || die "--backend firewalld but firewall-cmd not installed"; }
               [ "$DRY" = 0 ] && ! firewall-cmd --state >/dev/null 2>&1 \
                 && die "firewalld is not running — start it first: systemctl enable --now firewalld";;
    ufw)       have ufw || { [ "$DRY" = 1 ] && warn "ufw not installed here — dry-run preview only" || die "--backend ufw but ufw not installed"; }
               [ "$DRY" = 0 ] && ! ufw status 2>/dev/null | grep -q 'Status: active' \
                 && warn "ufw is INACTIVE — rules will be stored but not enforced until 'ufw enable' (NOT done by this script; allow SSH first!)";;
    nftables)  have nft || { [ "$DRY" = 1 ] && warn "nft not installed here — dry-run preview only" || die "--backend nftables but nft not installed"; };;
    iptables)  have iptables || { [ "$DRY" = 1 ] && warn "iptables not installed here — dry-run preview only" || die "--backend iptables but iptables not installed"; };;
  esac
fi
info "firewall backend: $BACKEND"

BOOT_UNIT=/etc/systemd/system/xplg-open-ports.service
BOOT_SCRIPT=/usr/local/sbin/xplg-open-ports-apply.sh

install_boot_unit() { # $1 = "After=" dependency, stdin = apply commands
  [ "$DRY" = 1 ] && { info "(dry-run) would install $BOOT_UNIT re-applying rules at boot"; cat >/dev/null; return; }
  cat > "$BOOT_SCRIPT"; chmod 0755 "$BOOT_SCRIPT"
  cat > "$BOOT_UNIT" <<EOF
[Unit]
Description=Re-apply XPLG firewall openings (generated by xplg-open-ports.sh)
After=$1
Wants=$1

[Service]
Type=oneshot
ExecStart=$BOOT_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload && systemctl enable xplg-open-ports.service >/dev/null 2>&1
  act "installed $BOOT_UNIT (persists rules across reboots)"
}
remove_boot_unit() {
  [ "$DRY" = 1 ] && { info "(dry-run) would remove $BOOT_UNIT"; return; }
  if [ -f "$BOOT_UNIT" ]; then
    systemctl disable xplg-open-ports.service >/dev/null 2>&1
    rm -f "$BOOT_UNIT" "$BOOT_SCRIPT"; systemctl daemon-reload
    act "removed boot unit"
  fi
}

# ── firewalld ───────────────────────────────────────────────────────────────
do_firewalld() {
  local Z_ARG=() P PR e ARGS=() SKIP=0
  [ -n "$ZONE" ] && Z_ARG=(--zone="$ZONE")
  if [ -z "$SRC" ]; then
    # one query for current state, one batched mutation call, one reload —
    # 3 D-Bus round-trips total instead of 2 per port (~160 for a full set)
    local CUR=" $(probe_out firewall-cmd --permanent "${Z_ARG[@]}" --list-ports) "
    for e in $ENTRIES; do
      if [ "$REMOVE" = 1 ]; then
        case "$CUR" in *" $e "*) ARGS+=("--remove-port=$e");; *) SKIP=$((SKIP+1));; esac
      else
        case "$CUR" in *" $e "*) SKIP=$((SKIP+1));; *) ARGS+=("--add-port=$e");; esac
      fi
    done
    info "firewalld: ${#ARGS[@]} port(s) to $( [ "$REMOVE" = 1 ] && echo remove || echo add ), $SKIP already in desired state"
    if [ "${#ARGS[@]}" -gt 0 ]; then
      run firewall-cmd --permanent "${Z_ARG[@]}" "${ARGS[@]}"
    fi
  else
    # rich rules: firewalld tolerates re-adding (ALREADY_ENABLED warning, rc 0)
    # and re-removing (NOT_ENABLED), so batch without pre-querying — the
    # listed-rule string format differs from the input format and cannot be
    # compared reliably.
    for e in $ENTRIES; do
      P="${e%%/*}"; PR="${e##*/}"
      local RULE="rule family=ipv4 source address=$SRC port port=$P protocol=$PR accept"
      if [ "$REMOVE" = 1 ]; then ARGS+=("--remove-rich-rule=$RULE"); else ARGS+=("--add-rich-rule=$RULE"); fi
    done
    info "firewalld: applying ${#ARGS[@]} rich rules in one call"
    run firewall-cmd --permanent "${Z_ARG[@]}" "${ARGS[@]}" 2>/dev/null || true
  fi
  info "reloading firewalld to activate permanent config ..."
  run firewall-cmd --reload
  act "firewalld: $( [ "$REMOVE" = 1 ] && echo removed || echo ensured ) $NTCP tcp + ${NUDP:-0} udp ports (permanent + reloaded)"
  [ -n "$SRC" ] && info "note: source-restricted rules are RICH RULES — preflight's --query-port check reports them as 'not open' by design; verify with: firewall-cmd --list-rich-rules"
}

# ── ufw ─────────────────────────────────────────────────────────────────────
do_ufw() {
  local P PR
  for e in $ENTRIES; do
    P="${e%%/*}"; PR="${e##*/}"
    if [ "$REMOVE" = 1 ]; then
      run ufw --force delete allow proto "$PR" from "${SRC:-any}" to any port "$P" 2>/dev/null
    else
      # idempotent: ufw itself skips existing rules ("Skipping adding existing rule")
      run ufw allow proto "$PR" from "${SRC:-any}" to any port "$P"
    fi
  done
  act "ufw: $( [ "$REMOVE" = 1 ] && echo removed || echo ensured ) $NTCP tcp + ${NUDP:-0} udp rules (persistent)"
}

# ── bare nftables ───────────────────────────────────────────────────────────
nft_input_chains() { # prints: family table chain
  nft list ruleset 2>/dev/null | awk '
    /^table /       {fam=$2; tbl=$3; sub(/ *\{.*/,"",tbl)}
    /^\tchain /     {chn=$2; sub(/ *\{.*/,"",chn)}
    /hook input/    {print fam, tbl, chn}'
}
do_nftables() {
  local FAM TBL CHN TCPSET UDPSET
  TCPSET="{ $(echo "$ENTRIES" | grep '/tcp$' | cut -d/ -f1 | paste -sd, -) }"
  UDPSET="{ $(echo "$ENTRIES" | grep '/udp$' | cut -d/ -f1 | paste -sd, -) }"
  local FOUND=0 APPLY=""
  while read -r FAM TBL CHN; do
    [ -z "$FAM" ] && continue
    case "$TBL/$CHN" in
      firewalld/*|*/ufw*|*UFW*) info "skipping $FAM $TBL $CHN — managed by firewalld/ufw (use that backend instead; raw inserts are wiped on its reload)"; continue;;
    esac
    FOUND=1
    if [ "$REMOVE" = 1 ]; then
      # delete every rule we tagged, by handle
      nft -a list chain "$FAM" "$TBL" "$CHN" 2>/dev/null \
        | awk '/xplg-open/ {for(i=1;i<=NF;i++) if ($i=="handle") print $(i+1)}' \
        | while read -r H; do run nft delete rule "$FAM" "$TBL" "$CHN" handle "$H"; done
      act "nftables: removed xplg-open rules from $FAM $TBL $CHN"
    else
      # idempotence: skip if our tag is already in the chain
      if nft list chain "$FAM" "$TBL" "$CHN" 2>/dev/null | grep -q 'xplg-open'; then
        info "nftables: $FAM $TBL $CHN already has xplg-open rules"
      else
        local M=""
        [ -n "$SRC" ] && M="ip saddr $SRC "
        # INSERT puts rules at the TOP of the chain, before any drop/reject
        run nft insert rule "$FAM" "$TBL" "$CHN" ${M}tcp dport "$TCPSET" accept comment '"xplg-open"'
        [ "${NUDP:-0}" -gt 0 ] && run nft insert rule "$FAM" "$TBL" "$CHN" ${M}udp dport "$UDPSET" accept comment '"xplg-open"'
        act "nftables: inserted accept rules at top of $FAM $TBL $CHN"
      fi
      APPLY="$APPLY
nft list chain $FAM $TBL $CHN | grep -q xplg-open || {
  nft insert rule $FAM $TBL $CHN ${SRC:+ip saddr $SRC }tcp dport $TCPSET accept comment \"xplg-open\"
$( [ "${NUDP:-0}" -gt 0 ] && echo "  nft insert rule $FAM $TBL $CHN ${SRC:+ip saddr $SRC }udp dport $UDPSET accept comment \"xplg-open\"" )
}"
    fi
  done <<< "$(nft_input_chains)"
  [ "$FOUND" = 0 ] && { warn "no nftables input hook chain found — nothing filters INPUT; no rules needed"; return; }
  if [ "$REMOVE" = 1 ]; then remove_boot_unit
  else
    # config-file merging cannot guarantee position BEFORE drop rules, so
    # persistence is a oneshot unit that re-inserts after nftables loads.
    printf '#!/usr/bin/env bash\nset -u\n%s\n' "$APPLY" | install_boot_unit "nftables.service"
  fi
}

# ── legacy iptables ─────────────────────────────────────────────────────────
do_iptables() {
  local P PR SRC_ARGS=() APPLY=""
  [ -n "$SRC" ] && SRC_ARGS=(-s "$SRC")
  for e in $ENTRIES; do
    P="${e%%/*}"; PR="${e##*/}"
    if [ "$REMOVE" = 1 ]; then
      if [ "$DRY" = 1 ]; then
        run iptables -D INPUT "${SRC_ARGS[@]}" -p "$PR" --dport "$P" -m comment --comment xplg-open -j ACCEPT
      else
        while iptables -C INPUT "${SRC_ARGS[@]}" -p "$PR" --dport "$P" -m comment --comment xplg-open -j ACCEPT 2>/dev/null; do
          run iptables -D INPUT "${SRC_ARGS[@]}" -p "$PR" --dport "$P" -m comment --comment xplg-open -j ACCEPT
        done
      fi
    else
      probe iptables -C INPUT "${SRC_ARGS[@]}" -p "$PR" --dport "$P" -m comment --comment xplg-open -j ACCEPT \
        || run iptables -I INPUT "${SRC_ARGS[@]}" -p "$PR" --dport "$P" -m comment --comment xplg-open -j ACCEPT
      APPLY="$APPLY
iptables -C INPUT ${SRC:+-s $SRC }-p $PR --dport $P -m comment --comment xplg-open -j ACCEPT 2>/dev/null || iptables -I INPUT ${SRC:+-s $SRC }-p $PR --dport $P -m comment --comment xplg-open -j ACCEPT"
    fi
  done
  act "iptables: $( [ "$REMOVE" = 1 ] && echo removed || echo ensured ) $NTCP tcp + ${NUDP:-0} udp INPUT rules (tag: xplg-open)"
  if [ "$REMOVE" = 1 ]; then
    if have netfilter-persistent; then run netfilter-persistent save
    elif [ -x /usr/libexec/iptables/iptables.init ]; then run /usr/libexec/iptables/iptables.init save
    fi
    remove_boot_unit
  else
    # persistence, most-common first
    if have netfilter-persistent; then                       # Ubuntu (iptables-persistent)
      run netfilter-persistent save && act "persisted via netfilter-persistent"
    elif [ -x /usr/libexec/iptables/iptables.init ]; then    # RHEL-family iptables-services
      run /usr/libexec/iptables/iptables.init save && act "persisted via iptables-services"
    else
      printf '#!/usr/bin/env bash\nset -u\n%s\n' "$APPLY" | install_boot_unit "network-pre.target"
      warn "no iptables persistence package found — installed a boot unit instead (or: apt install iptables-persistent / dnf install iptables-services)"
    fi
  fi
}

# ── dispatch ────────────────────────────────────────────────────────────────
case "$BACKEND" in
  firewalld) do_firewalld;;
  ufw)       do_ufw;;
  nftables)  do_nftables;;
  iptables)  do_iptables;;
  none)
    info "no active host firewall detected (firewalld stopped, ufw inactive, no filtering nftables/iptables ruleset)"
    info "ports are already reachable on this host — nothing to open"
    ;;
esac

# cloud reminder applies in every case
info "reminder: if this box sits behind a CLOUD firewall (DigitalOcean Cloud Firewall, AWS SG, ...), open the same ports there — host rules cannot override it"
[ "$BACKEND" != none ] && [ "$DRY" = 0 ] && info "verify now with the preflight script (§10 firewall section)"
exit 0
