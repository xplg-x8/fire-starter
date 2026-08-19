#!/usr/bin/env bash
# ============================================================================
# preflight.sh — xplg-service server readiness verification          (v3)
# Usage:   ./preflight.sh /path/to/.env   [--fix-dirs]
# Exit:    0 = READY (no FAIL), 1 = NOT READY, 2 = usage/parse error
# Safe on: Ubuntu/Debian, RHEL/CentOS/Rocky/Alma. Read-only except --fix-dirs
# (creates node dirs) and harmless write-probes (removed after test).
# Verifies: engine (docker/podman, rootful/rootless, daemon user, versions,
# cgroups v2), compose implementation + MINIMUM VERSION, registry TLS + auth,
# host users/groups vs SERVICE_UID/SERVICE_GID, filesystem ownership of the
# env-provided paths, ports (tcp+udp, preferring the live compose model),
# SELinux, NFS, RAM/CPU/disk vs active profiles, remote seed reachability,
# time sync. Writes an ACTION-ITEMS report file.
#
# Changes vs v2:
#  - .env is loaded in an isolated subshell and only whitelisted names are
#    imported, so the file can no longer clobber PASS/WARN/FAIL and invert
#    the verdict; `export NAME=value` lines are now honoured; unquoted values
#    containing spaces are linted instead of silently executing.
#  - missing XPLG_SEED_n_IP is a FAIL instead of silently skipping the peer.
#  - host ports are taken from `compose config` when available (tcp AND udp),
#    with the hardcoded table kept only as a fallback and cross-checked for
#    drift; occupancy is informational when our own stack is already running.
#  - /etc/hosts alias scan covers every column, not just the second.
#  - fixes: LC_ALL export, `ulimit -n unlimited`, literal grep for the
#    registry, seed entries without a port, /dev/shm accounting, docker.io
#    endpoint, DOCKER_HOST socket, `image exists` on docker.
# ============================================================================
set -u
export LC_ALL=C

# ── minimum versions (single place to tune) ─────────────────────────────────
MIN_DOCKER=20.10        # cgroups v2 + compose v2 plugin era; below → FAIL
MIN_DCOMPOSE=2.20       # docker compose v2 plugin; v1 docker-compose → FAIL
MIN_PODMAN=4.7          # deploy.resources honored via compose spec; below → WARN
MIN_PODMAN_COMPOSE=1.0.6

# ── result plumbing ─────────────────────────────────────────────────────────
PASS=0; WARN=0; FAIL=0
declare -a TODOS=()
if [ -t 1 ]; then G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; B=$'\e[1m'; N=$'\e[0m'; else G=; Y=; R=; B=; N=; fi
ok()   { PASS=$((PASS+1)); printf ' %s[PASS]%s %s\n' "$G" "$N" "$1"; }
warn() { WARN=$((WARN+1)); printf ' %s[WARN]%s %s\n' "$Y" "$N" "$1"; TODOS+=("SHOULD: $1"); }
fail() { FAIL=$((FAIL+1)); printf ' %s[FAIL]%s %s\n' "$R" "$N" "$1"; TODOS+=("MUST:   $1"); }
note() { printf ' %s[NOTE]%s %s\n' "$B" "$N" "$1"; }   # informational, no action item
hdr()  { printf '\n%s== %s ==%s\n' "$B" "$1" "$N"; }
have() { command -v "$1" >/dev/null 2>&1; }
# version compare: vergte A B → true if A >= B (semver-ish via sort -V)
vergte(){ [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }
# indirect read with default, safe under set -u
ivar() { local _n="$1"; printf '%s' "${!_n:-${2:-}}"; }

ENV_FILE="${1:-}"; FIX_DIRS=0
[ "${2:-}" = "--fix-dirs" ] && FIX_DIRS=1
if [ -z "$ENV_FILE" ] || [ ! -f "$ENV_FILE" ]; then
  echo "Usage: $0 /path/to/.env [--fix-dirs]" >&2; exit 2
fi

# ── load env ────────────────────────────────────────────────────────────────
# The file is sourced (so `export NAME=value`, quoting and expansions behave
# exactly as compose sees them) but inside a subshell; only whitelisted names
# are re-imported, %q-quoted. The .env therefore cannot touch this script's
# own state (counters, colours, role model).
TMPENV="$(mktemp)"; trap 'rm -f "$TMPENV"' EXIT
tr -d '\r' < "$ENV_FILE" > "$TMPENV"
ENV_ERR="$( ( set -a; . "$TMPENV"; set +a ) 2>&1 >/dev/null )"
IMPORTED="$( ( set -a; . "$TMPENV" >/dev/null 2>&1; set +a
               for _n in $(compgen -e); do
                 case "$_n" in
                   XPLG_*|SERVICE_UID|SERVICE_GID|SELF_ALIAS|COMPOSE_PROFILES)
                     printf '%s=%q\n' "$_n" "${!_n}" ;;
                 esac
               done ) )"
eval "$IMPORTED"

SELF_ALIAS="${SELF_ALIAS:-}"
COMPOSE_PROFILES="${COMPOSE_PROFILES:-}"
BASE="${XPLG_BASE_HOST_PATH:-/home/xplg/docker-volume/xplg/xplg-service}"
SHARED="${XPLG_SHARED_HOST_PATH:-$BASE/home/data}"
IMAGE="${XPLG_IMAGE:-docker.xplg.com/xplg:8.2.0-Main}"
SUID="${SERVICE_UID:-30303}"; SGID="${SERVICE_GID:-0}"
SEEDS="${XPLG_IGNITE_DISCOVERY_SEEDS:-xplg-seed-1:13345,xplg-seed-1:13346,xplg-seed-1:13347,xplg-seed-2:13345,xplg-seed-2:13346,xplg-seed-2:13347,xplg-seed-3:13345,xplg-seed-3:13346,xplg-seed-3:13347,xplg-seed-4:13345,xplg-seed-4:13346,xplg-seed-4:13347}"
HZ_MEMBERS="${XPLG_HAZELCAST_MEMBERS:-xplg-seed-1,xplg-seed-2,xplg-seed-3,xplg-seed-4}"

# compose file discovered early: sections 3, 6 and 11 all need it
CF=""
for c in docker-compose.yml compose.yaml compose.yml docker-compose.yaml; do [ -f "$c" ] && CF="$c" && break; done

# ── role/port model (FALLBACK ONLY — the live compose file wins, see §6) ────
roles_for_profiles() {
  local out=""
  IFS=',' read -ra ps <<< "$1"
  for p in "${ps[@]}"; do
    case "$(echo "$p" | tr -d ' ')" in
      master)            out="$out master" ;;
      server)            out="$out ui listener processor" ;;
      server-additional) out="$out processor processor-1" ;;
      ui|listener|processor|processor-1) out="$out $(echo "$p"|tr -d ' ')" ;;
      * ) ;;
    esac
  done
  echo "$out" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' '
}
ports_for_role() {
  case "$1" in
    master)      echo "30308 30448 11473 13344 10800 10300 1468 1469 1470 1471 1472";;
    ui)          echo "30304 30444 11474 13345 10801 10301 1479 1480 1481 1482 1483";;
    listener)    echo "30305 30445 11475 13346 10802 10302 1484 1485 1486 1487 1488";;
    processor)   echo "30306 30446 11476 13347 10803 10303 1489 1490 1491 1492 1493";;
    processor-1) echo "30307 30447 11477 13348 10804 10304 1494 1495 1496 1497 1498";;
  esac
}
mem_gib_for_role() {
  local small="${XPLG_MEMORY_LIMIT:-4g}" proc="${XPLG_PROCESSOR_MEMORY_LIMIT:-8g}"
  to_g() { echo "$1" | awk '{v=$0; gsub(/[gG]$/,"",v); if ($0 ~ /[mM]$/) {gsub(/[mM]$/,"",v); v=v/1024}; print v}'; }
  case "$1" in master|ui|listener) to_g "$small";; *) to_g "$proc";; esac
}
cpu_for_role() {
  case "$1" in master|ui|listener) echo "${XPLG_CPU_RESERVATION:-2}";; *) echo "${XPLG_PROCESSOR_CPU_RESERVATION:-3}";; esac
}

# ════════════════════════════════════════════════════════════════════════════
hdr "1. OS & base tooling"
OS_ID="unknown"; OS_LIKE=""
if [ -r /etc/os-release ]; then . /etc/os-release; OS_ID="${ID:-unknown}"; OS_LIKE="${ID_LIKE:-}"; fi
case "$OS_ID $OS_LIKE" in
  *ubuntu*|*debian*|*rhel*|*centos*|*rocky*|*alma*|*fedora*) ok "supported OS: $OS_ID (${VERSION_ID:-?})";;
  *) warn "unrecognized OS '$OS_ID' — script assumes systemd + iproute2";;
esac
[ -n "${BASH_VERSINFO:-}" ] && [ "${BASH_VERSINFO[0]}" -ge 4 ] \
  && ok "bash ${BASH_VERSION%%(*}" || fail "bash >= 4 required (run with bash, not sh)"
for t in awk sed grep stat df getent timeout curl findmnt sort id; do
  have "$t" && ok "tool: $t" || fail "missing tool: $t (install curl/coreutils/util-linux)"
done
# iproute2 is strongly preferred but §6 degrades gracefully, so it is not fatal
for t in ss ip; do
  have "$t" && ok "tool: $t" || warn "missing tool: $t (install iproute2 — port/interface checks degrade)"
done

hdr "2. .env sanity"
[ -n "$ENV_ERR" ] && warn ".env produced output/errors while loading: $(echo "$ENV_ERR" | head -2 | tr '\n' ' ')"
# unquoted values containing spaces are executed as commands by every consumer
if UQ="$(grep -nE '^(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=[^"'"'"']*[[:space:]]' "$TMPENV" 2>/dev/null)"; then
  [ -n "$UQ" ] && warn ".env has unquoted values containing spaces (will break when sourced): $(echo "$UQ" | head -3 | tr '\n' ' ')"
else
  ok ".env values are quoted or space-free"
fi
case "$SELF_ALIAS" in
  xplg-seed-[1-6]) ok "SELF_ALIAS=$SELF_ALIAS";;
  "") SELF_ALIAS="xplg-seed-1"; warn "SELF_ALIAS unset — defaulting to xplg-seed-1 (single-engine dev only; MULTI-SERVER MUST SET IT)";;
  *)  fail "SELF_ALIAS '$SELF_ALIAS' not in xplg-seed-1..6"; SELF_ALIAS="xplg-seed-1";;
esac
[ -n "$COMPOSE_PROFILES" ] && ok "COMPOSE_PROFILES=$COMPOSE_PROFILES" || fail "COMPOSE_PROFILES not set"
IFS=',' read -ra _ps <<< "$COMPOSE_PROFILES"
for _p in "${_ps[@]}"; do
  _p="$(echo "$_p" | tr -d ' ')"
  case "$_p" in master|server|server-additional|ui|listener|processor|processor-1|"") : ;;
    *) fail "unknown profile '$_p'";; esac
done
ROLES="$(roles_for_profiles "$COMPOSE_PROFILES")"
[ -n "$ROLES" ] && ok "roles on this server: $ROLES" || fail "profiles resolve to no containers"
case "${XPLG_IGNITE_INIT_NODE:-false}" in
  true)  note "XPLG_IGNITE_INIT_NODE=true — must be true on exactly ONE server fleet-wide, with >=3 nodes live at first init";;
  false) ok "XPLG_IGNITE_INIT_NODE=false";;
  *)     fail "XPLG_IGNITE_INIT_NODE must be true|false";;
esac
case "$SUID" in ''|*[!0-9]*) fail "SERVICE_UID '$SUID' is not numeric";; *) ok "SERVICE_UID=$SUID";; esac
case "$SGID" in ''|*[!0-9]*) fail "SERVICE_GID '$SGID' is not numeric";; *) ok "SERVICE_GID=$SGID";; esac
[ "$SUID" = "0" ] && fail "SERVICE_UID=0 — containers MUST NOT run as root uid"
SELF_N="${SELF_ALIAS##*-}"
SELF_IP="$(ivar "XPLG_SEED_${SELF_N}_IP")"
if [ -z "$SELF_IP" ]; then
  warn "XPLG_SEED_${SELF_N}_IP unset for this host — fine for single-engine dev, MUST be set for a cluster"
  SELF_IP="127.0.0.1"
else
  ok "XPLG_SEED_${SELF_N}_IP=$SELF_IP (advertised via alias)"
  if have ip; then
    ip -o addr 2>/dev/null | grep -qw "$SELF_IP" \
      && ok "self IP $SELF_IP is bound on a local interface" \
      || fail "self IP $SELF_IP is NOT an address of this host"
  fi
fi
SEED_BAD=0
for e in $(echo "$SEEDS" | tr ',' ' '); do
  h="${e%%:*}"
  case "$h" in xplg-seed-[1-6]) : ;; *) fail "ignite seed '$e' host is not xplg-seed-1..6"; SEED_BAD=1;; esac
  if [ "$e" = "$h" ]; then
    fail "ignite seed '$e' has no port — expected alias:slot (13344-13348)"; SEED_BAD=1
  else
    p="${e##*:}"
    case "$p" in 13344|13345|13346|13347|13348) : ;; *) fail "ignite seed '$e' port is not a role slot 13344-13348"; SEED_BAD=1;; esac
  fi
done
for e in $(echo "$HZ_MEMBERS" | tr ',' ' '); do
  h="${e%%:*}"
  case "$h" in xplg-seed-[1-6]) : ;; *) fail "hazelcast member '$e' host is not xplg-seed-1..6"; SEED_BAD=1;; esac
  if [ "$e" != "$h" ]; then
    p="${e##*:}"
    case "$p" in 1147[3-7]) : ;; *) fail "hazelcast member '$e' port outside 11473-11477"; SEED_BAD=1;; esac
  fi
done
[ "$SEED_BAD" = 0 ] && ok "ignite seeds (alias:slot) & hazelcast members (host-only or alias:slot) valid"
# every alias referenced by the cluster must have an IP in the .env
MISS_IP=""
for a in $(printf '%s %s' "$SEEDS" "$HZ_MEMBERS" | tr ',' ' '); do
  hh="${a%%:*}"
  case "$hh" in xplg-seed-[1-6]) : ;; *) continue;; esac
  nn="${hh##*-}"
  [ -z "$(ivar "XPLG_SEED_${nn}_IP")" ] && case " $MISS_IP " in *" $hh "*) : ;; *) MISS_IP="$MISS_IP $hh";; esac
done
if [ -n "$MISS_IP" ]; then
  fail "no XPLG_SEED_n_IP for:$MISS_IP — these peers cannot be reached or reachability-tested (set them in .env)"
else
  ok "every referenced seed alias has an IP in .env"
fi
# /etc/hosts must not pin xplg-seed aliases to different IPs than the env map
if grep -qE 'xplg-seed-[1-6]' /etc/hosts 2>/dev/null; then
  HB=0
  while read -r hip rest; do
    case "$hip" in \#*) continue;; esac
    for hname in $rest; do
      case "$hname" in
        \#*) break;;
        xplg-seed-[1-6])
          hn="${hname##*-}"; want="$(ivar "XPLG_SEED_${hn}_IP")"
          [ -n "$want" ] && [ "$hip" != "$want" ] && { warn "/etc/hosts maps $hname->$hip but .env says $want (containers use extra_hosts; host tools may disagree)"; HB=1; }
        ;;
      esac
    done
  done < <(grep -E 'xplg-seed-[1-6]' /etc/hosts)
  [ "$HB" = 0 ] && ok "/etc/hosts xplg-seed entries consistent with .env"
else
  ok "/etc/hosts has no conflicting xplg-seed entries"
fi

hdr "3. Container engine, runtime user & versions"
ENGINE=""; ROOTLESS=0
if have docker && docker info >/dev/null 2>&1; then ENGINE=docker
elif have podman && podman info >/dev/null 2>&1; then ENGINE=podman
fi
if [ -z "$ENGINE" ]; then
  if have docker || have podman; then
    fail "engine binary present but daemon unreachable for user $(id -un) — docker: check 'systemctl status docker' + membership in docker group; podman: check subuid + 'podman system migrate'"
  else
    fail "no container engine installed (install docker-ce or podman)"
  fi
else
  ok "engine: $ENGINE ($($ENGINE --version 2>/dev/null | head -1))"
  ok "deploy user: $(id -un) (uid=$(id -u), gid=$(id -g), groups: $(id -nG | tr ' ' ','))"
  have podman && have docker && [ "$ENGINE" = docker ] \
    && note "both docker and podman are installed; docker answered first and will be used"
  if [ "$ENGINE" = docker ]; then
    DV="$(docker version --format '{{.Server.Version}}' 2>/dev/null || docker info --format '{{.ServerVersion}}' 2>/dev/null || echo 0)"
    vergte "$DV" "$MIN_DOCKER" && ok "docker engine $DV >= $MIN_DOCKER" \
      || fail "docker engine $DV < $MIN_DOCKER — upgrade docker-ce"
    if docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless; then
      warn "docker ROOTLESS detected — works, but host files appear as subuids (confusing); podman+keep-id is the supported rootless standard"
    else
      # dockerd runs as root; report how this user reaches it (socket or DOCKER_HOST)
      SOCK="${DOCKER_HOST:-/var/run/docker.sock}"; SOCK="${SOCK#unix://}"
      if [ -S "$SOCK" ]; then
        ok "daemon socket $SOCK ($(stat -c '%U:%G' "$SOCK" 2>/dev/null)) — dockerd runs as root (rootful)"
        if [ "$(id -u)" -ne 0 ]; then
          id -nG | grep -qw "$(stat -c '%G' "$SOCK")" \
            && ok "user $(id -un) is in '$(stat -c '%G' "$SOCK")' group (socket access)" \
            || warn "user $(id -un) reaches docker via other means (sudo/ACL?) — ensure the DEPLOY user has stable socket access: usermod -aG docker $(id -un)"
        fi
      elif [ -n "${DOCKER_HOST:-}" ]; then
        warn "docker reached via DOCKER_HOST=$DOCKER_HOST (not a local socket) — preflight checks THIS host's ports/filesystem, which may not be where containers run"
      else
        warn "docker daemon reachable but no socket at $SOCK — verify how this user connects"
      fi
    fi
    [ -f /sys/fs/cgroup/cgroup.controllers ] && ok "cgroups v2" || warn "cgroups v1 — limits work under docker but v2 recommended"
  else # podman
    PV="$(podman version --format '{{.Client.Version}}' 2>/dev/null || echo 0)"
    vergte "$PV" "$MIN_PODMAN" && ok "podman $PV >= $MIN_PODMAN (deploy.resources limits honored)" \
      || warn "podman $PV < $MIN_PODMAN — deploy.resources limits may be ignored; verify with 'podman stats' after up"
    [ "$(id -u)" -ne 0 ] && ROOTLESS=1 && ok "podman rootless mode (uid $(id -u)) — target scenario, no root anywhere"
    [ "$(id -u)" -eq 0 ] && warn "podman running AS ROOT (rootful) — allowed, but rootless + keep-id is the enterprise standard"
    CGV="$(podman info --format '{{.Host.CgroupsVersion}}' 2>/dev/null || true)"
    if [ "$CGV" = "v2" ]; then ok "cgroups v2 (memory limits + heap % will work)"
    else fail "cgroups ${CGV:-unknown} — memory limits IGNORED rootless; heap % would size from HOST RAM"; fi
    systemctl --user is-enabled podman-restart >/dev/null 2>&1 \
      && ok "podman-restart enabled (restart: unless-stopped honored)" \
      || warn "podman-restart not enabled: systemctl --user enable --now podman-restart"
    if [ "$ROOTLESS" = 1 ]; then
      U="$(id -un)"
      if grep -q "^$U:" /etc/subuid 2>/dev/null && grep -q "^$U:" /etc/subgid 2>/dev/null; then
        ok "subuid/subgid ranges present for $U"
        SUBCNT="$(awk -F: -v u="$U" '$1==u{print $3; exit}' /etc/subuid)"
        [ "${SUBCNT:-0}" -ge 65536 ] && ok "subuid range size $SUBCNT >= 65536 (uid $SUID mappable)" \
          || fail "subuid range size ${SUBCNT:-0} < 65536 — uid $SUID cannot map: usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $U && podman system migrate"
      else
        fail "no subuid/subgid for $U — sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $U && podman system migrate"
      fi
      if [ -f compose.podman.yaml ]; then
        grep -q "keep-id:uid=$SUID" compose.podman.yaml \
          && ok "compose.podman.yaml present with keep-id:uid=$SUID (host files will be owned by $U)" \
          || warn "compose.podman.yaml present but keep-id uid != SERVICE_UID=$SUID — align them"
      elif [ -n "$CF" ] && grep -qE '^\s*userns_mode:\s*"?keep-id' "$CF" 2>/dev/null; then
        ok "keep-id enabled directly in $CF"
      else
        warn "rootless podman WITHOUT keep-id — files land as high subuids; add compose.podman.yaml (userns_mode: keep-id:uid=$SUID,gid=$SGID) and deploy with -f compose.yaml -f compose.podman.yaml"
      fi
    fi
    loginctl show-user "$(id -un)" 2>/dev/null | grep -q 'Linger=yes' \
      && ok "linger enabled (services survive logout)" \
      || warn "no linger: sudo loginctl enable-linger $(id -un)"
    if [ "$ROOTLESS" = 1 ] && [ -z "${XDG_RUNTIME_DIR:-}" ]; then
      fail "XDG_RUNTIME_DIR unset — you are likely in a 'sudo -u' shell; rootless podman needs a REAL login session (ssh / machinectl shell $(id -un)@)"
    fi
  fi
  # compose implementation + MINIMUM VERSION
  COMPOSE=""
  if $ENGINE compose version >/dev/null 2>&1; then
    COMPOSE="$ENGINE compose"
    CV="$($ENGINE compose version --short 2>/dev/null | sed 's/^v//')"
    if [ "$ENGINE" = docker ]; then
      vergte "${CV:-0}" "$MIN_DCOMPOSE" && ok "docker compose plugin $CV >= $MIN_DCOMPOSE" \
        || fail "docker compose plugin ${CV:-?} < $MIN_DCOMPOSE — upgrade docker-compose-plugin"
    else
      ok "podman compose wrapper detected ($CV) — delegates to an installed provider"
    fi
  elif have podman-compose; then
    COMPOSE="podman-compose"
    PCV="$(podman-compose version 2>/dev/null | awk '/podman-compose version/{print $3; exit}')"
    vergte "${PCV:-0}" "$MIN_PODMAN_COMPOSE" && ok "podman-compose $PCV >= $MIN_PODMAN_COMPOSE" \
      || warn "podman-compose ${PCV:-?} < $MIN_PODMAN_COMPOSE — profiles/anchors handling buggy on old versions; pip install --upgrade podman-compose"
  elif have docker-compose; then
    V1="$(docker-compose version --short 2>/dev/null || echo 1.x)"
    case "$V1" in
      1*) COMPOSE=""; fail "legacy docker-compose v1 ($V1) is EOL and unsupported — install the docker-compose-plugin (v2)";;
      *)  COMPOSE="docker-compose"; ok "standalone docker-compose $V1";;
    esac
  else
    fail "no compose implementation found (docker compose plugin / podman-compose)"
  fi
fi
COMPOSE="${COMPOSE:-}"

hdr "4. Host users & groups vs SERVICE_UID=$SUID / SERVICE_GID=$SGID"
GNAME="$(getent group "$SGID" | cut -d: -f1)"
if [ -n "$GNAME" ]; then
  if [ "$SGID" = "0" ]; then
    ok "gid 0 = group '$GNAME' — files will show group 'root' (LABEL ONLY, zero privilege; see docs)"
  else
    ok "gid $SGID = group '$GNAME' — files will show group '$GNAME'"
  fi
else
  warn "no host group with gid $SGID — files will show numeric gid; optional: groupadd -g $SGID xplg"
fi
UNAME="$(getent passwd "$SUID" | cut -d: -f1)"
if [ "$ENGINE" = podman ] && [ "$ROOTLESS" = 1 ]; then
  ok "rootless+keep-id: in-container uid $SUID maps to host user '$(id -un)' — host files owned by $(id -un), host passwd entry for $SUID not required"
  [ -n "$UNAME" ] && [ "$UNAME" != "$(id -un)" ] && warn "host also has a user '$UNAME' with uid $SUID — unrelated to the containers under keep-id, may confuse audits"
else
  if [ -n "$UNAME" ]; then
    ok "uid $SUID = host user '$UNAME' — files will show owner '$UNAME'"
    UPGID="$(id -g "$UNAME" 2>/dev/null)"
    [ "$UPGID" = "$SGID" ] || warn "host user '$UNAME' primary gid=$UPGID != SERVICE_GID=$SGID — cosmetic only (container ignores host passwd), align if desired"
  else
    warn "no host user with uid $SUID — 'ls -l' will show numeric '$SUID'; optional for clean display: groupadd -g $SGID xplg 2>/dev/null; useradd -u $SUID -g $SGID -M -s /usr/sbin/nologin xplg"
  fi
fi
if [ "$(id -u)" -eq 0 ] && [ "$ENGINE" = podman ]; then
  warn "you are deploying as root — this becomes rootful podman (files $SUID:$SGID), NOT the rootless keep-id standard"
fi

hdr "5. Registry connectivity & auth ($IMAGE)"
REG="${IMAGE%%/*}"
if echo "$REG" | grep -q '[.:]'; then :; else REG="docker.io"; fi
# docker.io does not serve /v2/ itself; the registry endpoint is registry-1
[ "$REG" = "docker.io" ] && REG_EP="registry-1.docker.io" || REG_EP="$REG"
HTTP_CODE="$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' "https://$REG_EP/v2/" 2>/dev/null)"; HTTP_CODE="${HTTP_CODE:-000}"
case "$HTTP_CODE" in
  200|401|403) ok "registry https://$REG_EP/v2/ reachable (TLS ok, HTTP $HTTP_CODE)";;
  000) fail "registry $REG_EP unreachable on 443 (DNS/proxy/firewall — check 'curl -v https://$REG_EP/v2/', corporate CA in /etc/pki or /usr/local/share/ca-certificates)";;
  *)   warn "registry $REG_EP answered HTTP $HTTP_CODE — verify proxy/WAF in path";;
esac
AUTH_FOUND=0
for f in "$HOME/.docker/config.json" "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers/auth.json" "$HOME/.config/containers/auth.json"; do
  [ -f "$f" ] && grep -qF "\"$REG\"" "$f" 2>/dev/null && { ok "credentials for $REG found in $f"; AUTH_FOUND=1; break; }
done
[ "$AUTH_FOUND" = 0 ] && warn "no stored credentials for $REG — run: ${ENGINE:-docker} login $REG (needed unless the repo is public or image pre-loaded)"
if [ -n "$ENGINE" ]; then
  IMG_OK=0
  if [ "$ENGINE" = podman ]; then
    podman image exists "$IMAGE" 2>/dev/null && IMG_OK=1
  else
    docker image inspect "$IMAGE" >/dev/null 2>&1 && IMG_OK=1
  fi
  if [ "$IMG_OK" = 1 ]; then
    ok "image present locally"
    ARCH="$($ENGINE image inspect "$IMAGE" --format '{{.Architecture}}' 2>/dev/null)"
    HOSTARCH="$(uname -m)"
    case "$HOSTARCH/$ARCH" in
      x86_64/amd64|aarch64/arm64|arm64/arm64|amd64/amd64|*/) : ;;
      *) warn "image architecture '$ARCH' may not match host '$HOSTARCH'";;
    esac
  elif have skopeo && skopeo inspect --retry-times 2 "docker://$IMAGE" >/dev/null 2>&1; then
    ok "image manifest readable via skopeo (credentials ok)"
  else
    warn "image not local and not verified remotely — run: $ENGINE pull $IMAGE (check $ENGINE login $REG)"
  fi
fi

hdr "6. Ports (this server's roles: $ROLES)"
# Prefer the ports the compose file actually publishes — the hardcoded table
# drifts silently when the compose slots change.
WANT=""   # newline-separated "port/proto"
if [ -n "$COMPOSE" ] && [ -n "$CF" ]; then
  EXTRA_F=""
  [ "$ENGINE" = podman ] && [ "$ROOTLESS" = 1 ] && [ -f compose.podman.yaml ] && EXTRA_F="-f $CF -f compose.podman.yaml"
  # shellcheck disable=SC2086
  CFG="$(COMPOSE_PROFILES="$COMPOSE_PROFILES" $COMPOSE ${EXTRA_F:--f $CF} --env-file "$ENV_FILE" config 2>/dev/null)"
  WANT="$(printf '%s\n' "$CFG" | awk '
    /published:/ {gsub(/[^0-9]/,"",$2); p=$2}
    /protocol:/  {if (p!=""){print p"/"$2; p=""}}' | sort -u)"
fi
if [ -n "$WANT" ]; then
  ok "port model taken from $CF ($(printf '%s\n' "$WANT" | wc -l) published ports)"
  # cross-check the hardcoded table so drift is visible instead of silent
  TBL="$(for r in $ROLES; do ports_for_role "$r"; done | tr ' ' '\n' | sed '/^$/d' | sort -u)"
  CMP="$(printf '%s\n' "$WANT" | cut -d/ -f1 | sort -u)"
  DRIFT="$(comm -3 <(printf '%s\n' "$TBL") <(printf '%s\n' "$CMP") | tr -d '\t' | tr '\n' ' ')"
  [ -z "$DRIFT" ] && ok "built-in port table matches the compose file" \
    || warn "built-in port table has drifted from $CF (differing ports: $DRIFT) — update ports_for_role()"
else
  warn "could not read ports from a compose file — falling back to the built-in table, which may not match your deployment"
  WANT="$(for r in $ROLES; do for p in $(ports_for_role "$r"); do echo "$p/tcp"; done; done | sort -u)"
fi
# is our own stack already up? then occupancy is expected, not a conflict
STACK_UP=0
if [ -n "$COMPOSE" ] && [ -n "$CF" ]; then
  # shellcheck disable=SC2086
  [ -n "$(COMPOSE_PROFILES="$COMPOSE_PROFILES" $COMPOSE -f $CF --env-file "$ENV_FILE" ps -q 2>/dev/null)" ] && STACK_UP=1
fi
[ "$STACK_UP" = 1 ] && note "this stack is already running — occupied ports are reported as WARN, not FAIL"
LTCP=""; LUDP=""; PORTSRC=""
if have ss; then
  LTCP="$(ss -Hltn 2>/dev/null | awk '{print $4}')"
  LUDP="$(ss -Hlun 2>/dev/null | awk '{print $4}')"
  PORTSRC=ss
elif [ -r /proc/net/tcp ]; then
  LTCP="$(cat /proc/net/tcp /proc/net/tcp6 2>/dev/null \
    | awk '$4=="0A"{split($2,a,":"); print a[2]}' | sort -u \
    | while read -r h; do printf ':%d\n' "0x$h"; done)"
  LUDP="$(cat /proc/net/udp /proc/net/udp6 2>/dev/null \
    | awk 'NR>1{split($2,a,":"); print a[2]}' | sort -u \
    | while read -r h; do printf ':%d\n' "0x$h"; done)"
  PORTSRC=procfs
  warn "ss unavailable — checking via /proc/net fallback (no owner info; install iproute2)"
else
  fail "ss unavailable and /proc/net unreadable — port occupancy NOT verified (install iproute2)"
fi
if [ -n "$PORTSRC" ]; then
  for entry in $WANT; do
    p="${entry%%/*}"; proto="${entry##*/}"
    [ "$proto" = udp ] && LIST="$LUDP" || LIST="$LTCP"
    if echo "$LIST" | grep -qE "[:.]$p\$"; then
      ownr=""
      # only the users:(("proc",...)) field names a process; it is absent without root
      [ "$PORTSRC" = ss ] && [ "$proto" = tcp ] \
        && ownr="$(ss -Hltnp 2>/dev/null | awk -v P=":$p$" '$4 ~ P {for(i=1;i<=NF;i++) if ($i ~ /^users:/) print $i}' | head -1)"
      if [ "$STACK_UP" = 1 ]; then
        warn "port $p/$proto in use ${ownr:+by $ownr} (expected — stack is running)"
      else
        fail "port $p/$proto already LISTENING ${ownr:+by $ownr}"
      fi
    else
      ok "port $p/$proto free"
    fi
  done
fi
DUPES="$(printf '%s\n' "$WANT" | sort | uniq -d)"
[ -z "$DUPES" ] && ok "no port overlap between activated roles" \
  || fail "port overlap between roles: $(echo "$DUPES" | tr '\n' ' ')"

hdr "7. Folders, ownership & permissions (env paths)"
if [ "$ENGINE" = podman ] && [ "$ROOTLESS" = 1 ]; then EXP_OWNER="$(id -u)"; EXP_DESC="$(id -un) (keep-id)"; else EXP_OWNER="$SUID"; EXP_DESC="$SUID:$SGID (init-perms chown)"; fi
ok "expected host-file owner for this scenario: $EXP_DESC"
if [ ! -d "$BASE" ]; then
  if [ "$FIX_DIRS" = 1 ]; then mkdir -p "$BASE" && ok "created $BASE" || fail "cannot create $BASE"
  else fail "base path $BASE missing (rerun with --fix-dirs or create it)"; fi
else ok "base path $BASE exists"; fi
if [ -d "$BASE" ]; then
  BOWN="$(stat -c '%u' "$BASE" 2>/dev/null)"; BOWN_G="$(stat -c '%g' "$BASE" 2>/dev/null)"
  BOWN_N="$(stat -c '%U:%G' "$BASE" 2>/dev/null)"
  if [ "$ENGINE" = podman ] && [ "$ROOTLESS" = 1 ]; then
    [ "$BOWN" = "$EXP_OWNER" ] && ok "base owned by deploy user ($BOWN_N) — required for rootless" \
      || fail "base $BASE owned by $BOWN_N, not the deploy user — rootless cannot chown it: sudo chown -R $(id -un): $BASE"
  else
    if [ "$BOWN" = "$SUID" ] && [ "$BOWN_G" = "$SGID" ]; then ok "base already owned $BOWN_N (matches SERVICE_UID:GID)"
    else ok "base owned $BOWN_N — init-perms will chown to $SUID:$SGID on first up (rootful)"; fi
  fi
fi
for r in $ROLES; do
  d="$BASE/$r/data"
  if [ -d "$d" ]; then ok "node dir $d"
  elif [ "$FIX_DIRS" = 1 ] && mkdir -p "$d"/{cache/ignite/{chronicle,cmg,metastorage,partitions,raft},diagnostics,temp} 2>/dev/null; then ok "created $d tree"
  else warn "node dir $d missing (init-perms will create it on first up)"; fi
done
for r in $ROLES; do
  d="$BASE/$r/data"
  [ -d "$d" ] || continue
  P="$d/.preflight.$$"
  if touch "$P" 2>/dev/null; then rm -f "$P"; ok "role dir writable: $d"
  else
    if [ "$ENGINE" = podman ] && [ "$ROOTLESS" = 1 ]; then
      fail "role dir NOT writable by $(id -un): $d ($(stat -c '%u:%g %a' "$d" 2>/dev/null)) — rootless requires deploy-user ownership: sudo chown -R $(id -un): $BASE"
    else
      warn "role dir not writable by $(id -un): $d — OK on rootful (containers write as $SUID), but --fix-dirs and preflight probes need access"
    fi
  fi
  m="$(stat -c '%a' "$d" 2>/dev/null)"
  case "$m" in 2775|2770|2777) : ;; *) warn "role dir $d mode $m (expected setgid 2775 — init-perms fixes on next up)";; esac
done
PROBE="$BASE/.preflight.$$"
if touch "$PROBE" 2>/dev/null; then rm -f "$PROBE"; ok "base path writable by $(id -un)"
else
  o="$(stat -c '%u:%g %A' "$BASE" 2>/dev/null)"
  if [ "$ENGINE" = podman ] && [ "$ROOTLESS" = 1 ]; then
    fail "base NOT writable by $(id -un) (owner $o) — sudo chown -R $(id -un): $BASE"
  else
    warn "base not writable by $(id -un) (owner $o) — rootful init-perms handles container access; grant the deploy user access for probes/--fix-dirs"
  fi
fi
BFST="$(findmnt -no FSTYPE --target "$BASE" 2>/dev/null || echo '?')"
case "$BFST" in
  tmpfs|ramfs|overlay) fail "base $BASE is on $BFST — data would not survive reboot; use a real local disk";;
  *) ok "base $BASE on a persistent fs ($BFST)";;
esac
SEL=""
if have getenforce; then
  SEL="$(getenforce 2>/dev/null)"
  case "$SEL" in
    Enforcing) ok "SELinux Enforcing — compose applies :Z on /node/data binds";;
    Permissive|Disabled) ok "SELinux $SEL";;
  esac
fi

hdr "8. Storage layout & container mount mapping"
echo "   local  /node/data  <- $BASE/<role>/data   (roles: $ROLES)"
echo "   shared /home/data  <- $SHARED"
RB="$(readlink -f "$BASE" 2>/dev/null || echo "$BASE")"
RS="$(readlink -f "$SHARED" 2>/dev/null || echo "$SHARED")"
case "$RS" in
  "$RB"/home/data) ok "shared is <base>/home/data (single-tree layout)";;
  "$RB"|"$RB"/*)   warn "shared is inside base at a non-standard subpath ($RS) — allowed, keep it out of role dirs";;
  *)               ok "shared on separate path ($RS) — mountpoint layout";;
esac
for r in $ROLES; do
  case "$RS" in "$RB/$r"|"$RB/$r"/*) fail "shared path is INSIDE role dir $r — invalid";; esac
  case "$RB/$r" in "$RS"|"$RS"/*) fail "role dir $r is INSIDE the shared tree — node data must not live on shared/NFS";; esac
done
if [ -d "$SHARED" ]; then ok "shared path $SHARED exists"; else
  [ "$FIX_DIRS" = 1 ] && mkdir -p "$SHARED/extConf/log" 2>/dev/null && ok "created $SHARED" || fail "shared path $SHARED missing"
fi
FSTYPE="$(findmnt -no FSTYPE --target "$SHARED" 2>/dev/null || echo '?')"
if echo "$FSTYPE" | grep -qi '^nfs'; then
  ok "NFS-backed ($FSTYPE): $(findmnt -no SOURCE --target "$SHARED")"
  findmnt -no OPTIONS --target "$SHARED" | grep -qw hard && ok "mount option 'hard' set" || warn "NFS mounted without an explicit 'hard' option — add hard,noatime,_netdev"
  [ "$FSTYPE" = "nfs4" ] || warn "prefer NFSv4 (found $FSTYPE)"
  P="$SHARED/.preflight.$$"
  if touch "$P" 2>/dev/null; then
    ug="$(stat -c '%u:%g' "$P")"; rm -f "$P"
    ok "NFS write ok (files land as $ug)"
    if [ "$ENGINE" = podman ] && [ "$ROOTLESS" = 1 ]; then
      [ "$ug" = "$(id -u):$(id -g)" ] || warn "NFS squashes to $ug, expected $(id -u):$(id -g) (keep-id: your uid on the wire) — grant this uid on the export"
    else
      [ "$ug" = "$SUID:$SGID" ] || warn "NFS squashes to $ug, expected $SUID:$SGID — fix export (anonuid=$SUID,anongid=$SGID) or server-side ownership"
    fi
  else
    fail "cannot write on NFS share as $(id -un) (root_squash / export perms)"
  fi
  if [ "$SEL" = "Enforcing" ]; then
    getsebool virt_use_nfs 2>/dev/null | grep -q on && ok "virt_use_nfs=on" || fail "SELinux enforcing + NFS: run sudo setsebool -P virt_use_nfs 1"
  fi
else
  ok "shared path on local fs ($FSTYPE)"
fi
NODEFS="$(findmnt -no FSTYPE --target "$BASE" 2>/dev/null || echo '?')"
echo "$NODEFS" | grep -qi '^nfs' && fail "node data base $BASE is on NFS — must be local disk" || ok "node data on local fs ($NODEFS)"

hdr "9. Machine resources vs active profiles"
NEED_G=0; NEED_C=0; NROLES=0
for r in $ROLES; do
  NEED_G=$(awk -v a="$NEED_G" -v b="$(mem_gib_for_role "$r")" 'BEGIN{print a+b}')
  NEED_C=$(awk -v a="$NEED_C" -v b="$(cpu_for_role "$r")" 'BEGIN{print a+b}')
  NROLES=$((NROLES+1))
done
TOT_G="$(awk '/MemTotal/ {printf "%.1f", $2/1048576}' /proc/meminfo)"
NEED_TOT="$(awk -v n="$NEED_G" 'BEGIN{print n+2}')"
awk -v t="$TOT_G" -v n="$NEED_TOT" 'BEGIN{exit !(t>=n)}' \
  && ok "RAM: ${TOT_G}G total >= ${NEED_TOT}G (limits ${NEED_G}G + 2G OS)" \
  || fail "RAM: ${TOT_G}G total < ${NEED_TOT}G required (limits ${NEED_G}G + 2G OS)"
NCPU="$(nproc 2>/dev/null || echo 1)"
awk -v t="$NCPU" -v n="$NEED_C" 'BEGIN{exit !(t>=n)}' \
  && ok "CPU: $NCPU cores >= $NEED_C reserved" \
  || warn "CPU: $NCPU cores < $NEED_C reserved (will run, contended)"
FREE_G="$(df -BG --output=avail "$BASE" 2>/dev/null | tail -1 | tr -dc 0-9)"
[ "${FREE_G:-0}" -ge 50 ] && ok "disk: ${FREE_G}G free at $BASE" || warn "disk: only ${FREE_G:-?}G free at $BASE (>=50G recommended)"
MMC="$(sysctl -n vm.max_map_count 2>/dev/null || cat /proc/sys/vm/max_map_count 2>/dev/null || echo 0)"
if [ "${MMC:-0}" -ge 262144 ]; then ok "vm.max_map_count=$MMC (mmap-heavy: RocksDB+Chronicle+ZGC)"
else fail "vm.max_map_count=$MMC too low — set: echo 'vm.max_map_count=1048576' >/etc/sysctl.d/99-xplg.conf && sysctl --system"; fi
FMAX="$(sysctl -n fs.file-max 2>/dev/null || echo 0)"
[ "${FMAX:-0}" -ge 1048576 ] && ok "fs.file-max=$FMAX" || warn "fs.file-max=$FMAX (<1048576) — raise via sysctl for many mmap'd sst/queue files"
NOF="$(ulimit -n)"
if [ "$NOF" = unlimited ]; then ok "nofile ulimit unlimited"
elif [ "$NOF" -ge 65535 ] 2>/dev/null; then ok "nofile ulimit $NOF"
else warn "user nofile=$NOF (<65535) — engine sets per-container, but raise host limit for rootless"; fi
# each container gets its OWN tmpfs of shm_size, charged to host RAM — the
# host's /dev/shm free space is not the constraint, total RAM is.
SHM_NEED=$((4 * NROLES))
SHM_TOT="$(awk -v t="$TOT_G" -v g="$NEED_G" -v s="$SHM_NEED" 'BEGIN{print (g+s+2<=t)?"ok":"tight"}')"
[ "$SHM_TOT" = ok ] \
  && ok "/dev/shm: ${NROLES} containers x 4g shm cap fits in ${TOT_G}G RAM alongside ${NEED_G}G limits" \
  || warn "/dev/shm: ${NROLES} containers x 4g shm (${SHM_NEED}G) + ${NEED_G}G limits + 2G OS exceeds ${TOT_G}G RAM — lower shm_size or add RAM (shm is a cap, so this only bites under load)"
if have timedatectl; then
  timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -qi yes \
    && ok "clock NTP-synchronized" \
    || warn "clock NOT NTP-synchronized — enable chrony/systemd-timesyncd (cluster timestamps/joins drift)"
fi

hdr "10. Remote seed reachability (skipped for self)"
PEERS_TESTED=0
for h in $(echo "$HZ_MEMBERS" | tr ',' ' '); do
  hh="${h%%:*}"; n="${hh##*-}"
  [ "$hh" = "$SELF_ALIAS" ] && continue
  ip="$(ivar "XPLG_SEED_${n}_IP")"
  [ -z "$ip" ] && continue     # already FAILed in §2 as a missing IP
  PEERS_TESTED=$((PEERS_TESTED+1))
  hit=0; hitp=""
  for p in 11473 11474 11475 11476 11477; do
    if timeout 2 bash -c "exec 3<>/dev/tcp/$ip/$p" 2>/dev/null; then hit=1; hitp="$p"; break; fi
  done
  [ "$hit" = 1 ] && ok "hazelcast member $hh reachable ($ip:$hitp)" \
    || warn "hazelcast member $hh: no slot 11473-11477 reachable on $ip (peer down or firewall)"
done
for e in $(echo "$SEEDS" | tr ',' ' '); do
  h="${e%%:*}"; p="${e##*:}"; n="${h##*-}"
  [ "$h" = "$SELF_ALIAS" ] && continue
  [ "$e" = "$h" ] && continue
  ip="$(ivar "XPLG_SEED_${n}_IP")"
  [ -z "$ip" ] && continue
  PEERS_TESTED=$((PEERS_TESTED+1))
  if timeout 3 bash -c "exec 3<>/dev/tcp/$ip/$p" 2>/dev/null; then ok "seed $h ($ip:$p) reachable"
  else warn "seed $h ($ip:$p) not reachable (peer down or firewall — open before init)"; fi
done
[ "$PEERS_TESTED" = 0 ] && note "no remote peers tested (single-server, or seed IPs missing — see §2)"
# firewall: query each port individually; ranges only match if added as ranges
FW_PORTS="$(printf '%s\n' "$WANT" | cut -d/ -f1 | sort -un)"
if have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
  MISS=""
  for p in $FW_PORTS; do
    firewall-cmd --query-port="$p/tcp" >/dev/null 2>&1 || MISS="$MISS $p"
  done
  [ -z "$MISS" ] && ok "firewalld: all published ports open" \
    || warn "firewalld: not open:$MISS → firewall-cmd --permanent --add-port=<p>/tcp for each, then firewall-cmd --reload"
elif have ufw && ufw status 2>/dev/null | grep -q 'Status: active'; then
  UFW="$(ufw status 2>/dev/null)"
  if [ -z "$UFW" ]; then
    warn "ufw is active but 'ufw status' returned nothing (needs root) — re-run with sudo to verify the rules"
  else
    MISS=""
    for p in $FW_PORTS; do
      echo "$UFW" | grep -qE "(^|[^0-9])$p(/tcp|[^0-9]|$)" || MISS="$MISS $p"
    done
    [ -z "$MISS" ] && ok "ufw: all published ports appear allowed" \
      || warn "ufw active, no rule found for:$MISS → ufw allow proto tcp from <peer-subnet> to any port <p>"
  fi
fi

hdr "11. Compose validation (profiles resolved)"
if [ -n "$COMPOSE" ] && [ -n "$CF" ]; then
  EXTRA_F=""
  [ "$ENGINE" = podman ] && [ "$ROOTLESS" = 1 ] && [ -f compose.podman.yaml ] && EXTRA_F="-f $CF -f compose.podman.yaml"
  CFG_ERR="$(mktemp)"
  # shellcheck disable=SC2086
  if SVC="$(COMPOSE_PROFILES="$COMPOSE_PROFILES" $COMPOSE ${EXTRA_F:--f $CF} --env-file "$ENV_FILE" config --services 2>"$CFG_ERR")"; then
    ok "compose config valid ($CF${EXTRA_F:+ + compose.podman.yaml}); services: $(echo "$SVC" | tr '\n' ' ')"
    for r in $ROLES; do echo "$SVC" | grep -qx "$r" && ok "service '$r' activated" || fail "service '$r' expected but not activated by profiles"; done
  else
    fail "compose config failed: $(head -2 "$CFG_ERR" | tr '\n' ' ')"
  fi
  rm -f "$CFG_ERR"
elif [ -z "$CF" ]; then
  warn "no compose file (docker-compose.yml/compose.yaml) in $(pwd) — validation and the live port model were skipped (cd to the deploy dir)"
else
  warn "compose validation skipped (no working compose implementation)"
fi

# ── verdict + report file ───────────────────────────────────────────────────
printf '\n%s────────────────────────────────────────%s\n' "$B" "$N"
printf ' PASS=%d  WARN=%d  FAIL=%d\n' "$PASS" "$WARN" "$FAIL"
REPORT="preflight-report-${SELF_ALIAS}-$(date +%Y%m%d-%H%M%S).txt"
{
  echo "xplg-service preflight report"
  echo "server: $SELF_ALIAS  roles: $ROLES  engine: ${ENGINE:-none}$( [ "$ROOTLESS" = 1 ] && echo ' (rootless)')"
  echo "host: $(hostname)  user: $(id -un)  date: $(date -Is)"
  echo "env file: $ENV_FILE  base: $BASE  shared: $SHARED"
  echo "result: PASS=$PASS WARN=$WARN FAIL=$FAIL — $( [ "$FAIL" -eq 0 ] && echo READY || echo NOT-READY)"
  echo
  if [ "${#TODOS[@]}" -gt 0 ]; then
    echo "ACTION ITEMS (MUST = blocks deployment, SHOULD = recommended):"
    i=1; for t in "${TODOS[@]}"; do printf ' %2d. %s\n' "$i" "$t"; i=$((i+1)); done
  else
    echo "ACTION ITEMS: none — flight can take off."
  fi
} > "$REPORT" 2>/dev/null && printf ' report: %s\n' "$REPORT"
if [ "${#TODOS[@]}" -gt 0 ]; then
  printf '\n%sACTION ITEMS%s\n' "$B" "$N"
  i=1; for t in "${TODOS[@]}"; do printf ' %2d. %s\n' "$i" "$t"; i=$((i+1)); done
fi
if [ "$FAIL" -eq 0 ]; then
  printf '\n %s%sSERVER READY%s — %s roles: %s\n' "$B" "$G" "$N" "$SELF_ALIAS" "$ROLES"
  exit 0
else
  printf '\n %s%sNOT READY%s — fix the MUST items above and rerun.\n' "$B" "$R" "$N"
  exit 1
fi
