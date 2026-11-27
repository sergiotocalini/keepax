#!/usr/bin/env bash
#
# keepax deploy: installs keepax.sh + Zabbix agent UserParameters on a keepalived host.
#
#   sudo ./deploy.sh [options]
#
# What it does:
#   - checks/installs dependencies (ksh, procps)
#   - detects Zabbix agent (zabbix-agent2 or zabbix-agent) and its include directory
#   - installs keepax.sh, keepax.conf and the UserParameter file
#   - creates the cache directory owned by the zabbix user
#   - writes a validated sudoers drop-in with exact command lines (no wildcards)
#   - restarts the agent and runs a self-test as the zabbix user
#
set -euo pipefail

SOURCE_DIR=$(cd "$(dirname "$0")" && pwd)
ZABBIX_DIR=/etc/zabbix
PREFIX_DIR="${ZABBIX_DIR}/scripts/agentd/keepax"
CACHE_DIR=""
CACHE_TTL=5
PID_FILE=""
ZBX_USER=zabbix
AGENT=""                 # auto: zabbix-agent2 | zabbix-agent
SUDOERS_FILE=/etc/sudoers.d/zabbix-keepax
DUMP_DATA=/tmp/keepalived.data
DUMP_STATS=/tmp/keepalived.stats
RESTART=1
INSTALL_DEPS=1
UNINSTALL=0

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_yel=$'\e[33m'; c_off=$'\e[0m'
[[ -t 1 ]] || { c_red=""; c_grn=""; c_yel=""; c_off=""; }
info() { echo "${c_grn}[+]${c_off} $*"; }
warn() { echo "${c_yel}[!]${c_off} $*" >&2; }
die()  { echo "${c_red}[x]${c_off} $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: sudo $0 [options]

Options:
  -c DIR    cache directory           (default: ${PREFIX_DIR}/tmp)
  -t MIN    cache TTL in minutes      (default: ${CACHE_TTL})
  -p FILE   keepalived pid file       (default: auto, /run/keepalived.pid)
  -a NAME   agent: zabbix-agent2 | zabbix-agent (default: auto-detect)
  -u USER   zabbix agent user         (default: ${ZBX_USER})
  -d DIR    install prefix            (default: ${PREFIX_DIR})
  -n        do not restart the Zabbix agent
  -N        do not install missing packages
  -U        uninstall keepax
  -h        this help
EOF
    exit "${1:-0}"
}

while getopts "c:t:p:a:u:d:nNUh" opt; do
    case ${opt} in
        c) CACHE_DIR=${OPTARG} ;;
        t) CACHE_TTL=${OPTARG} ;;
        p) PID_FILE=${OPTARG} ;;
        a) AGENT=${OPTARG} ;;
        u) ZBX_USER=${OPTARG} ;;
        d) PREFIX_DIR=${OPTARG%/} ;;
        n) RESTART=0 ;;
        N) INSTALL_DEPS=0 ;;
        U) UNINSTALL=1 ;;
        h) usage 0 ;;
        *) usage 1 ;;
    esac
done
shift $((OPTIND - 1))
# backwards compatibility with deploy_zabbix.sh [CACHE_DIR] [CACHE_TTL]
[[ $# -ge 1 ]] && CACHE_DIR=$1
[[ $# -ge 2 ]] && CACHE_TTL=$2
CACHE_DIR=${CACHE_DIR:-${PREFIX_DIR}/tmp}
CACHE_DIR=${CACHE_DIR%/}

[[ ${EUID} -eq 0 ]] || die "run as root (sudo $0)"
[[ ${CACHE_TTL} =~ ^[0-9]+$ ]] || die "cache TTL must be a number of minutes: ${CACHE_TTL}"

#################################################################################
# Agent detection
#################################################################################
unit_exists() {
    command -v systemctl >/dev/null 2>&1 && \
        systemctl list-unit-files "${1}.service" 2>/dev/null | grep -q "^${1}.service"
}

detect_agent() {
    local a
    if [[ -z ${AGENT} ]]; then
        for a in zabbix-agent2 zabbix-agent; do
            if unit_exists "${a}"; then AGENT=${a}; break; fi
        done
        if [[ -z ${AGENT} && -d ${ZABBIX_DIR}/zabbix_agent2.d ]]; then
            AGENT=zabbix-agent2
        fi
        AGENT=${AGENT:-zabbix-agent}
    fi
    case ${AGENT} in
        zabbix-agent2) AGENT_INC_DIR=${ZABBIX_DIR}/zabbix_agent2.d ;;
        zabbix-agent)  AGENT_INC_DIR=${ZABBIX_DIR}/zabbix_agentd.d ;;
        *) die "unknown agent '${AGENT}' (use zabbix-agent2 or zabbix-agent)" ;;
    esac
    USERPARAM_FILE=${AGENT_INC_DIR}/keepax.conf
}

restart_agent() {
    [[ ${RESTART} -eq 1 ]] || { warn "skipping agent restart (-n): restart ${AGENT} yourself"; return 0; }
    if unit_exists "${AGENT}"; then
        if systemctl restart "${AGENT}"; then info "restarted ${AGENT}"; else warn "failed to restart ${AGENT}"; fi
    else
        warn "${AGENT} service not found: restart the Zabbix agent manually"
    fi
}

#################################################################################
# Uninstall
#################################################################################
if [[ ${UNINSTALL} -eq 1 ]]; then
    detect_agent
    rm -fv "${USERPARAM_FILE}" "${SUDOERS_FILE}"
    rm -rfv "${PREFIX_DIR}"
    restart_agent
    info "keepax removed"
    exit 0
fi

#################################################################################
# Dependencies
#################################################################################
pkg_install() {
    [[ ${INSTALL_DEPS} -eq 1 ]] || die "missing packages: $* (install them or drop -N)"
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "$@"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "$@"
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install "$@"
    else
        die "no supported package manager found, install manually: $*"
    fi
}

missing=()
command -v ksh   >/dev/null 2>&1 || missing+=(ksh)
command -v pkill >/dev/null 2>&1 || missing+=(procps)
command -v sudo  >/dev/null 2>&1 || missing+=(sudo)
if [[ ${#missing[@]} -gt 0 ]]; then
    info "installing: ${missing[*]}"
    pkg_install "${missing[@]}"
fi
for cmd in ksh awk pkill ps stat sudo; do
    command -v "${cmd}" >/dev/null 2>&1 || die "required command not found: ${cmd}"
done

id "${ZBX_USER}" >/dev/null 2>&1 || die "user '${ZBX_USER}' does not exist: is the Zabbix agent installed?"
detect_agent
[[ -d ${AGENT_INC_DIR} ]] || die "${AGENT_INC_DIR} not found: is ${AGENT} installed? (use -a to choose)"
info "agent: ${AGENT} (${AGENT_INC_DIR})"
if unit_exists "${AGENT}" && \
   [[ $(systemctl show "${AGENT}" -p NoNewPrivileges --value 2>/dev/null) == yes ]]; then
    warn "${AGENT}.service has NoNewPrivileges=yes: sudo will not work from the agent."
    warn "  fix: systemctl edit ${AGENT}  ->  [Service] NoNewPrivileges=no"
fi

#################################################################################
# keepalived checks
#################################################################################
if [[ -z ${PID_FILE} ]]; then
    for f in /run/keepalived.pid /var/run/keepalived.pid; do
        [[ -f ${f} ]] && { PID_FILE=${f}; break; }
    done
    PID_FILE=${PID_FILE:-/run/keepalived.pid}
fi
if [[ -f ${PID_FILE} ]]; then
    info "keepalived pid file: ${PID_FILE}"
else
    warn "keepalived pid file ${PID_FILE} not found (is keepalived running? use -p to override)"
fi
if command -v systemctl >/dev/null 2>&1 && \
   [[ $(systemctl show keepalived -p PrivateTmp --value 2>/dev/null) == yes ]]; then
    warn "keepalived.service has PrivateTmp=yes: its ${DUMP_DATA} is not visible to keepax."
    warn "  fix: systemctl edit keepalived  ->  [Service] PrivateTmp=no"
fi

#################################################################################
# Install files
#################################################################################
install -d -m 0755 "${PREFIX_DIR}"
install -m 0755 "${SOURCE_DIR}/keepax/keepax.sh" "${PREFIX_DIR}/keepax.sh"
info "installed ${PREFIX_DIR}/keepax.sh"

SCRIPT_CONFIG="${PREFIX_DIR}/keepax.conf"
if [[ -f ${SCRIPT_CONFIG} ]]; then
    SCRIPT_CONFIG="${SCRIPT_CONFIG}.new"
    warn "${PREFIX_DIR}/keepax.conf exists, writing ${SCRIPT_CONFIG} (compare and merge manually)"
fi
cat > "${SCRIPT_CONFIG}" <<EOF
# keepax configuration (generated by deploy.sh on $(date '+%F %T'))
CACHE_TTL="${CACHE_TTL}"
CACHE_DIR="${CACHE_DIR}/"
PID_FILE="${PID_FILE}"
EOF
chmod 0644 "${SCRIPT_CONFIG}"
info "wrote ${SCRIPT_CONFIG}"

install -d -m 0750 -o "${ZBX_USER}" -g "$(id -gn "${ZBX_USER}")" "${CACHE_DIR}"
info "cache dir ${CACHE_DIR} (owner ${ZBX_USER})"

sed "s|/etc/zabbix/scripts/agentd/keepax|${PREFIX_DIR}|g" \
    "${SOURCE_DIR}/keepax/zabbix_agentd.conf" > "${USERPARAM_FILE}"
chmod 0644 "${USERPARAM_FILE}"
info "installed ${USERPARAM_FILE}"

#################################################################################
# sudoers: exact command lines, every path variant of each binary (usrmerge)
#################################################################################
bin_paths() {
    local name=$1 p seen=""
    for p in "$(command -v "${name}")" "/usr/bin/${name}" "/bin/${name}"; do
        [[ -x ${p} && " ${seen} " != *" ${p} "* ]] && seen+=" ${p}"
    done
    echo ${seen}
}
cmds=()
for p in $(bin_paths pkill); do
    cmds+=("${p} -USR1 -F ${PID_FILE}" "${p} -USR2 -F ${PID_FILE}")
done
for p in $(bin_paths cat); do
    cmds+=("${p} ${DUMP_DATA}" "${p} ${DUMP_STATS}")
done
tmp_sudoers=$(mktemp)
{
    echo "# keepax: allow ${ZBX_USER} to trigger and read keepalived dumps (generated by deploy.sh)"
    echo "Cmnd_Alias KEEPAX = $(printf '%s, ' "${cmds[@]}" | sed 's/, $//')"
    echo "${ZBX_USER} ALL=(root) NOPASSWD: KEEPAX"
} > "${tmp_sudoers}"
if command -v visudo >/dev/null 2>&1; then
    visudo -cf "${tmp_sudoers}" >/dev/null || { rm -f "${tmp_sudoers}"; die "generated sudoers failed validation"; }
else
    warn "visudo not found, sudoers file not validated"
fi
install -m 0440 "${tmp_sudoers}" "${SUDOERS_FILE}"
rm -f "${tmp_sudoers}"
info "installed ${SUDOERS_FILE}"

#################################################################################
# Restart + self-test
#################################################################################
restart_agent

info "self-test as ${ZBX_USER}:"
as_zbx() { sudo -u "${ZBX_USER}" -- "${PREFIX_DIR}/keepax.sh" "$@" 2>&1 || true; }
echo "  version:   $(as_zbx -v)"
echo "  uptime:    $(as_zbx -s service -a uptime)"
disc=$(as_zbx -s vrrp -j NAME -a list)
names=$(grep -o '"{#NAME}":"[^"]*"' <<< "${disc}" | cut -d'"' -f4 || true)
if [[ -z ${names} ]]; then
    warn "no VRRP instances discovered (keepalived down, PrivateTmp, or sudo problem?)"
else
    for n in ${names}; do
        echo "  ${n}: $(as_zbx -s vrrp -a data -a "${n}" -a State)"
    done
fi

cat <<EOF

${c_grn}Done.${c_off} Next steps:
  1. Import zbx7.4_template_app_keepalived.yaml in Zabbix (Data collection -> Templates -> Import)
  2. Link "Template App Keepalived" to this host
  3. Check from the server/proxy:  zabbix_get -s <host> -k 'keepax.discovery[vrrp, NAME, list]'
EOF
