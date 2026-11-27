#!/usr/bin/env ksh
PATH=/usr/local/bin:${PATH}
IFS_DEFAULT="${IFS}"

#################################################################################
#
#  Variable Definition
# ---------------------
#
APP_NAME=${0##*/}
APP_DIR=${0%/*}
[[ ${APP_DIR} == "${0}" ]] && APP_DIR=.
APP_VER="1.1.0"
APP_WEB="http://www.sergiotocalini.com.ar/"
PID_FILE="/var/run/keepalived.pid"
DUMP_DATA="/tmp/keepalived.data"
DUMP_STATS="/tmp/keepalived.stats"
DUMP_WAIT=20                                      # x 0.1s to wait for a fresh dump
TIMESTAMP=$(date '+%s')
CACHE_DIR=${APP_DIR}/tmp
CACHE_TTL=10                                      # IN MINUTES
#
#################################################################################

#################################################################################
#
#  Load Configuration
# --------------------
#
# First existing of: $KEEPAX_CONF, <script dir>/keepax.conf, /etc/zabbix/keepax.conf
for CFG_FILE in "${KEEPAX_CONF:-}" "${APP_DIR}/${APP_NAME%.*}.conf" "/etc/zabbix/${APP_NAME%.*}.conf"; do
    [[ -n ${CFG_FILE} && -f ${CFG_FILE} ]] && { . "${CFG_FILE}"; break; }
done
CACHE_FILE="${CACHE_DIR%/}/data"
#
#################################################################################

#################################################################################
#
#  Function Definition
# ---------------------
#
usage() {
    echo "Usage: ${APP_NAME} [Options]"
    echo ""
    echo "Options:"
    echo "  -a ARG(str)   Query argument (repeatable, may be prefixed with 'p=')."
    echo "  -h            Displays this help message."
    echo "  -j ARG(str)   Jsonify output (LLD), ':'-separated macro names."
    echo "  -s ARG(str)   Section: service | vrrp."
    echo "  -v            Show the script version."
    echo ""
    echo "Examples:"
    echo "  ${APP_NAME} -s service -a uptime"
    echo "  ${APP_NAME} -s vrrp -j NAME -a list"
    echo "  ${APP_NAME} -s vrrp -a data -a VI_1 -a State"
    echo "  ${APP_NAME} -s vrrp -a stats -a VI_1 -a 'Became master'"
    exit 1
}

version() {
    echo "${APP_NAME%.*} ${APP_VER}"
    exit 1
}

zabbix_not_support() {
    echo "ZBX_NOTSUPPORTED"
    exit 1
}

file_mtime() {
    stat -c '%Y' "${1}" 2>/dev/null || stat -f '%m' "${1}" 2>/dev/null || echo 0
}

# Make sure ${CACHE_FILE} holds data not older than CACHE_TTL minutes.
# Runs in the current shell (no subshell) and only forks when a refresh is due.
refresh_cache() {
    typeset i

    if (( $(file_mtime "${CACHE_FILE}") + 60 * CACHE_TTL > TIMESTAMP )); then
        return 0
    fi

    [[ -d ${CACHE_DIR} ]] || mkdir -p "${CACHE_DIR}"
    # sudo is used only for fixed command lines (no wildcards needed in sudoers):
    #   pkill -USR1|-USR2 -F <PID_FILE>, cat <DUMP_DATA>, cat <DUMP_STATS>
    if [[ -f ${PID_FILE} ]] && : > "${CACHE_FILE}.tmp" && \
       sudo -n pkill -USR1 -F "${PID_FILE}" 2>/dev/null; then
        sudo -n pkill -USR2 -F "${PID_FILE}"
        # keepalived writes the dumps asynchronously: wait until both are at
        # least as new as the marker file, so we never cache the previous dump.
        i=0
        while (( i++ < DUMP_WAIT )); do
            [[ -f ${DUMP_DATA} && -f ${DUMP_STATS} && \
               ! ${DUMP_DATA} -ot ${CACHE_FILE}.tmp && \
               ! ${DUMP_STATS} -ot ${CACHE_FILE}.tmp ]] && break
            sleep 0.1
        done
        if [[ -f ${DUMP_DATA} && -f ${DUMP_STATS} ]]; then
            {
                echo "### START DATA ###"
                sudo -n cat "${DUMP_DATA}"
                echo "### END DATA ###"
                echo "### START STATS ###"
                sudo -n cat "${DUMP_STATS}"
                echo "### END STATS ###"
            } > "${CACHE_FILE}.tmp"
            mv -f "${CACHE_FILE}.tmp" "${CACHE_FILE}"
        fi
    fi
    # If keepalived is down (or the dump failed) keep serving the last known
    # data, so the VRRP State item still shows the state the node had before
    # the daemon stopped (used by the "was MASTER but not running" trigger).
    # The cache file is not touched here, so a refresh is retried on every call.
    [[ -s ${CACHE_FILE} ]]
}

service() {
    typeset resource="${1}" pid res

    if [[ ${resource} == 'uptime' ]] && [[ -f ${PID_FILE} ]] && read -r pid < "${PID_FILE}"; then
        res=$(ps -p "${pid}" -o etimes= 2>/dev/null)
    fi
    echo $(( ${res:-0} ))
    return 0
}

# Single awk pass over the cache file.
#   mode=list  : unique VRRP instance names
#   mode=data  : value of <attr> for <instance> from the data dump ("key = value")
#   mode=stats : value of <attr> for <instance> from the stats dump ("key: value")
vrrp_query() {
    typeset mode="${1}" instance="${2}" attr="${3}"

    refresh_cache || return 1

    awk -v mode="${mode}" -v inst="${instance}" -v attr="${attr}" '
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        /^### START DATA ###/  { sec = "data";  next }
        /^### START STATS ###/ { sec = "stats"; next }
        /^### END /            { sec = "";      next }
        /^-+</                 { in_inst = 0 }   # next dump section (keepalived 2.x)
        sec == "data" && /VRRP Instance = / {
            name = trim(substr($0, index($0, "=") + 1))
            if (mode == "list" && !(name in seen)) { seen[name]; print name }
            in_inst = (name == inst); next
        }
        sec == "stats" && /VRRP Instance: / {
            in_inst = (trim(substr($0, index($0, ":") + 1)) == inst); next
        }
        mode == "list" || mode != sec || !in_inst { next }
        {
            sep = (sec == "data") ? "=" : ":"
            if ((p = index($0, sep)) == 0) next
            if (index(trim(substr($0, 1, p - 1)), attr) == 0) next
            val = substr($0, p + 1)
            if ((q = index(val, sep)) > 0) val = substr(val, 1, q - 1)
            if (attr == "Last transition") sub(/\(.*\)/, "", val)
            print trim(val); found = 1; exit     # first match only (one value per item)
        }
        END { if (mode != "list" && !found) print 0 }
    ' "${CACHE_FILE}"
}

json_output() {
    typeset line out="" sep="" i
    typeset -a values

    set -f
    while IFS= read -r line; do
        [[ -z ${line} ]] && continue
        IFS='|'
        values=( ${line} )
        IFS="${IFS_DEFAULT}"
        out+="${sep}      { "
        for i in ${!values[*]}; do
            (( i > 0 )) && out+=", "
            out+="\"{#${JSON_ATTR[i]:-${i}}}\":\"${values[i]}\""
        done
        out+=" }"
        sep=$',\n'
    done <<< "${1}"
    set +f

    echo '{'
    echo '   "data":['
    [[ -n ${out} ]] && printf '%s\n' "${out}"
    echo '   ]'
    echo '}'
}
#
#################################################################################

#################################################################################
while getopts "s:a:j:hvupt:" OPTION; do
    case ${OPTION} in
        h)
            usage
            ;;
        s)
            SECTION="${OPTARG}"
            ;;
        j)
            JSON=1
            IFS=":"
            JSON_ATTR=( ${OPTARG} )
            IFS="${IFS_DEFAULT}"
            ;;
        a)
            # Zabbix passes empty trailing parameters (-a p=""): drop them.
            [[ -n ${OPTARG#p=} ]] && ARGS[${#ARGS[*]}]="${OPTARG#p=}"
            ;;
        v)
            version
            ;;
        \?)
            exit 1
            ;;
    esac
done

case "${SECTION}" in
    service)
        rval=$( service "${ARGS[@]}" )
        ;;
    vrrp)
        case "${ARGS[0]}" in
            list)       rval=$( vrrp_query list ) ;;
            data|stats) rval=$( vrrp_query "${ARGS[0]}" "${ARGS[1]}" "${ARGS[2]}" ) ;;
        esac
        ;;
    *)
        zabbix_not_support
        ;;
esac
rcode="${?}"

if (( JSON == 1 )); then
    json_output "${rval}"
else
    echo "${rval:-0}"
fi

exit ${rcode}
