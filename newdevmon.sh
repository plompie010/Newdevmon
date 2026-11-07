#!/bin/sh
###############################################################################
# newdevmon - sends an email when a new device joins your network
#
# For Asuswrt-Merlin. Uses the email settings from amtm (amtm > em).
# Periodically (cron) checks the DHCP leases and the ARP table of all LAN
# bridges: br0 = main network, br1/br2/... = guest networks.
# A device counts as "new" as long as its MAC address is not in the list of
# known devices. New devices found in one check are reported in a single email.
#
# Started without arguments in an SSH session (for example from amtm, option p)
# it opens a menu. For use in scripts/cron:
#   newdevmon.sh [menu|run|cron|install|uninstall|baseline|test|list|detail NR|MAC|log|forget MAC]
#   newdevmon.sh [update-check|update [-y]|rollback]
#
# Updates: once a day the script checks whether the GitHub repository
# plompie010/Newdevmon contains a newer VERSION. Raise the VERSION number below
# with every change you push to the repository, otherwise the script will not
# see the new version as newer.
#
# Copyright (C) 2026 plompie010
# This code was written with the help of Claude AI (Anthropic).
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
###############################################################################

VERSION="0.1.26"
SCRIPT_NAME="newdevmon"
SCRIPT_PATH="${NEWDEVMON_SCRIPT_PATH:-/jffs/scripts/newdevmon.sh}"
DATA_DIR="${NEWDEVMON_DIR:-/jffs/addons/newdevmon}"
KNOWN="$DATA_DIR/known_devices.txt"          # mac|first_seen|ip|name|network|last_seen_epoch
CONF="$DATA_DIR/newdevmon.conf"
LOGFILE="$DATA_DIR/newdevmon.log"
LEASES="${NEWDEVMON_LEASES:-/var/lib/misc/dnsmasq.leases}"
ARPFILE="${NEWDEVMON_ARP:-/proc/net/arp}"
EMAIL_DIR="${NEWDEVMON_EMAIL_DIR:-/jffs/addons/amtm/mail}"
AMTM_PW_KEY="ditbabot,isoi"                  # key amtm uses for emailpw.enc (see /jffs/addons/amtm/email.mod)
LOCKDIR="/tmp/${SCRIPT_NAME}.lock"
DRY_RUN="${NEWDEVMON_DRY_RUN:-0}"            # 1 = print the email instead of sending it
TMPBASE="/tmp/${SCRIPT_NAME}.$$"

OPT_DIR="${NEWDEVMON_OPT_DIR:-/opt}"          # Entware on the USB drive, if present
OUI_JFFS="$DATA_DIR/oui.txt"                 # vendor list (fallback location): AABBCC|Vendor name
OUI_USB="$OPT_DIR/share/newdevmon/oui.txt"   # preferred location: on the USB drive
OUI_UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/79.0.3945.79 Safari/537.36"  # IEEE blocks short/unknown user agents (HTTP 418)
OUI_URL_L="https://standards-oui.ieee.org/oui/oui.csv"      # MA-L (24-bit)
OUI_URL_M="https://standards-oui.ieee.org/oui28/mam.csv"    # MA-M (28-bit)
OUI_URL_S="https://standards-oui.ieee.org/oui36/oui36.csv"  # MA-S (36-bit)
SCAN_PORTS="21 22 23 25 53 80 81 110 111 135 139 143 443 445 465 515 548 554 587 631 873 993 995 1433 1723 1883 2049 3000 3306 3389 5000 5001 5432 5900 5985 8000 8008 8080 8081 8123 8443 8883 9000 9100 32400 49152 62078"

UPDATE_FLAG="$DATA_DIR/update_available"     # contains the number of a newer version, if found

# Settings (stored in $CONF through the menu)
INTERVAL=1                                   # minutes between checks
UPDATE_MAIL=0                                # 1 = email when a new version is available
[ -f "$CONF" ] && . "$CONF"

# Update source: fixed on purpose, not changeable through config or menu.
UPDATE_REPO="plompie010/Newdevmon"
UPDATE_BRANCH="main"
UPDATE_FILE="newdevmon.sh"
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=1 ;; esac
[ "$INTERVAL" -lt 1 ] && INTERVAL=1
[ "$INTERVAL" -gt 59 ] && INTERVAL=59

# Volatile state in RAM (/tmp), so the flash is not written every minute.
STATE_DIR="${NEWDEVMON_STATE_DIR:-/tmp}"
SEEN="$STATE_DIR/newdevmon.seen"             # mac|last_seen_epoch|ip|name|network
LASTRUN="$STATE_DIR/newdevmon.lastrun"       # epoch of the last check
MAILFAIL="$STATE_DIR/newdevmon.mailfail"      # epoch of the last failed new-device email
MAIL_RETRY_SECS=1800                         # pause after a failed email
PERSIST_TS="$STATE_DIR/newdevmon.persist"    # epoch of the last write to JFFS
NMP_FILE="${NEWDEVMON_NMP:-/jffs/nmp_cl_json.js}"                 # Asus client list (network map)
CLIENTLIST_FILE="${NEWDEVMON_CLIENTLIST:-/tmp/clientlist.json}"   # Asus per-band client list (signal)

# Colours only in a terminal (not in cron, logs or email).
USE_COLOR=0
if [ "$NEWDEVMON_FORCE_COLOR" = "1" ]; then
    USE_COLOR=1
elif [ -t 1 ] && [ -z "$NO_COLOR" ]; then
    USE_COLOR=1
fi
if [ "$USE_COLOR" = "1" ]; then
    C_G="$(printf '\033[32m')"; C_R="$(printf '\033[31m')"; C_Y="$(printf '\033[33m')"
    C_D="$(printf '\033[2m')";  C_B="$(printf '\033[1m')";  C_X="$(printf '\033[0m')"
else
    C_G=""; C_R=""; C_Y=""; C_D=""; C_B=""; C_X=""
fi

# awk helper functions used by several overviews.
AWK_FN='
function label(d) {
    if (d == "br0") return "Main network"
    if (d ~ /^br/) return "Guest network (" d ")"
    if (d == "") return "Unknown network"
    return "Network (" d ")"
}
function trunc(s, n) { return (length(s) > n) ? substr(s, 1, n - 1) "~" : s }
function ago(ep, now,   d) {
    if (ep <= 0) return "-"
    d = now - ep; if (d < 0) d = 0
    if (d < 3600) return int(d / 60) " min ago"
    if (d < 86400) return int(d / 3600) " h ago"
    return int(d / 86400) " d ago"
}
function bandshort(b) {
    if (b ~ /^2G/) return "2.4G"
    if (b ~ /^5G/) return "5G"
    if (b ~ /^6G/) return "6G"
    if (b ~ /^wired\?/) return "wired?"
    if (b ~ /^wired/) return "wired"
    return b
}
'

###############################################################################
# Helper functions
###############################################################################

now() { date '+%Y-%m-%d %H:%M:%S'; }

log() {
    mkdir -p "$DATA_DIR" 2>/dev/null
    echo "$(now) $*" >> "$LOGFILE"
    logger -t "$SCRIPT_NAME" "$*" 2>/dev/null
    [ -t 1 ] && echo "$*"
    if [ "$(wc -l < "$LOGFILE" 2>/dev/null || echo 0)" -gt 1000 ]; then
        tail -n 500 "$LOGFILE" > "$LOGFILE.tmp" && mv "$LOGFILE.tmp" "$LOGFILE"
    fi
}

cleanup() {
    rm -f "$TMPBASE".* 2>/dev/null
    if [ "$(cat "$LOCKDIR/pid" 2>/dev/null)" = "$$" ]; then
        rm -rf "$LOCKDIR"
    fi
}

lock() {
    if mkdir "$LOCKDIR" 2>/dev/null; then
        echo $$ > "$LOCKDIR/pid"
        return 0
    fi
    oldpid="$(cat "$LOCKDIR/pid" 2>/dev/null)"
    if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
        return 1
    fi
    rm -rf "$LOCKDIR"
    mkdir "$LOCKDIR" 2>/dev/null && echo $$ > "$LOCKDIR/pid"
}

# Asus network map data, one line per client:
# mac|name|vendor|vendorclass|online|wireless|mlo   (mac in lower case)
nmp_info() {
    [ -r "$NMP_FILE" ] || return 1
    tr -d '\r\n' < "$NMP_FILE" | sed 's/},"/}\n"/g' | awk '
        function jstr(l, k,   re, v) {
            re = "\"" k "\":\"[^\"]*\""
            if (match(l, re)) {
                v = substr(l, RSTART + length(k) + 4, RLENGTH - length(k) - 5)
                gsub(/\|/, "/", v)
                return v
            }
            return ""
        }
        function jnum(l, k,   re) {
            re = "\"" k "\":[0-9]+"
            if (match(l, re)) return substr(l, RSTART + length(k) + 3, RLENGTH - length(k) - 3)
            return ""
        }
        {
            m = jstr($0, "mac")
            if (m == "") next
            print tolower(m) "|" jstr($0, "name") "|" jstr($0, "vendor") "|" jstr($0, "vendorclass") "|" jnum($0, "online") "|" jnum($0, "wireless") "|" jstr($0, "mlo")
        }'
}

# Live connection data per client from the Asus per-band client list:
# mac|node_mac|band|rssi|ip   (band: 2G_1, 5G_1, wired_mac, ...)
link_info() {
    [ -r "$CLIENTLIST_FILE" ] || return 1
    rmacs=""
    for v in lan_hwaddr et0macaddr label_mac; do
        rmacs="$rmacs $(nvram get "$v" 2>/dev/null | tr 'A-F' 'a-f')"
    done
    tr -d '\r\n' < "$CLIENTLIST_FILE" | awk -v all="$1" -v routers="$rmacs" '
        BEGIN { nr = split(routers, ra, " "); for (i = 1; i <= nr; i++) isr[ra[i]] = 1 }
        function leaf(k, v,   mac, p, kk) {
            if (depth < 3 || (k != "ip" && k != "rssi")) return
            mac = tolower(stack[depth])
            p = stack[depth - 2] "/" stack[depth - 1]
            kk = mac SUBSEP p
            if (!(mac in ent)) { ent[mac] = 1; order[++n] = mac }
            if (!(kk in pseen)) {
                pseen[kk] = 1; np[mac]++; pl[mac, np[mac]] = p
                bnd[kk] = stack[depth - 1]; nd[kk] = tolower(stack[depth - 2])
            }
            if (k == "ip") ip[kk] = v; else rssi[kk] = v
        }
        {
            s = $0; depth = 0; after = 0; last = ""; key = ""
            while (length(s) > 0) {
                c = substr(s, 1, 1)
                if (c ~ /[[:space:]]/) { s = substr(s, 2); continue }
                if (c == "\"") {
                    if (!match(s, /^"[^"]*"/)) break
                    tok = substr(s, 2, RLENGTH - 2); s = substr(s, RLENGTH + 1)
                    if (after) { leaf(key, tok); after = 0 } else last = tok
                    continue
                }
                if (c == "{" || c == "[") { depth++; stack[depth] = after ? key : ""; after = 0; s = substr(s, 2); continue }
                if (c == "}" || c == "]") { depth--; after = 0; s = substr(s, 2); continue }
                if (c == ":") { key = last; after = 1; s = substr(s, 2); continue }
                if (c == ",") { after = 0; s = substr(s, 2); continue }
                if (match(s, /^[^],}[:space:]]+/)) {
                    tok = substr(s, 1, RLENGTH); s = substr(s, RLENGTH + 1)
                    if (after) { leaf(key, tok); after = 0 }
                    continue
                }
                s = substr(s, 2)
            }
        }
        END {
            for (i = 1; i <= n; i++) {
                m = order[i]
                if (!(m ~ /^[0-9a-f:]+$/ && length(m) == 17)) continue
                best = ""; bs = -1
                for (j = 1; j <= np[m]; j++) {
                    kk = m SUBSEP pl[m, j]
                    if (all == "all") print m "|" nd[kk] "|" bnd[kk] "|" rssi[kk] "|" ip[kk]
                    sc = ((rssi[kk] != "" && rssi[kk] != "0") ? 4 : 0) + ((bnd[kk] !~ /^wired/) ? 2 : 0) + ((nd[kk] in isr) ? 0 : 1)
                    if (sc > bs) { bs = sc; best = kk }
                }
                # Behind an AiMesh node, "wired" is unreliable: nodes often do not report
                # Wi-Fi clients (for example sleeping cameras), so these show up as wired.
                b = bnd[best]
                if (b ~ /^wired/ && !(nd[best] in isr)) b = "wired?"
                if (all != "all") print m "|" nd[best] "|" b "|" rssi[best] "|" ip[best]
            }
        }'
}

# node_labels: mac|label for the router and the AiMesh nodes (lower case MACs).
node_labels() {
    for v in lan_hwaddr et0macaddr label_mac; do
        m="$(nvram get "$v" 2>/dev/null | tr 'A-F' 'a-f')"
        [ -n "$m" ] && echo "$m|Router"
    done
    nmp_info 2>/dev/null | awk -F'|' '$2 != "" { print $1 "|" $2 }'
}

# Devices currently visible, one line per device: mac|ip|name|interface
# Sources: DHCP leases + ARP table (which devices exist) and the Asus client list (names).
scan() {
    {
        [ -r "$LEASES" ] && awk 'NF >= 4 { h = $4; if (h == "*") h = ""; print "D|" tolower($2) "|" $3 "|" h "||||" }' "$LEASES"
        [ -r "$ARPFILE" ] && awk 'NR > 1 && ($3 == "0x2" || $3 == "0x6") && $4 != "00:00:00:00:00:00" && $6 ~ /^br/ { print "D|" tolower($4) "|" $1 "||" $6 "|||" }' "$ARPFILE"
        nmp_info 2>/dev/null | awk -F'|' '{ print "A|" $1 "||||" $2 "|" $3 "|" $4 }'
    } | awk -F'|' '
        $2 !~ /^[0-9a-f:]+$/ || length($2) != 17 { next }
        $1 == "D" {
            m = $2
            if (!(m in seen)) { seen[m] = 1; order[++n] = m }
            if ($3 != "") ip[m] = $3
            if ($4 != "") host[m] = $4
            if ($5 != "") dev[m] = $5
            next
        }
        $1 == "A" { an[$2] = $6; av[$2] = $7; avc[$2] = $8 }
        END {
            for (i = 1; i <= n; i++) {
                m = order[i]
                name = host[m]; a = an[m]
                # Prefer the Asus name, unless it is just the vendor (class) string.
                if (a != "" && a != av[m] && a != avc[m]) name = a
                else if (name == "") name = a
                print m "|" ip[m] "|" name "|" dev[m]
            }
        }'
}

# Same as scan, but with the interface filled in and sorted by network
# (main network first, then guest networks) and by IP address within a network.
scan_sorted() {
    scan | while IFS='|' read -r mac ip host dev; do
        [ -z "$dev" ] && [ -n "$ip" ] && dev="$(iface_for_ip "$ip")"
        echo "${mac}|${ip}|${host}|${dev}"
    done | awk -F'|' '{
        split($2, o, ".")
        g = ($4 == "br0") ? 0 : (($4 ~ /^br/) ? 1 : 2)
        printf "%d|%s|%03d%03d%03d%03d|%s|%s|%s|%s\n", g, $4, o[1], o[2], o[3], o[4], $1, $2, $3, $4
    }' | sort -t'|' -k1,1n -k2,2 -k3,3 | cut -d'|' -f4-7
}

iface_for_ip() {
    ip -4 route get "$1" 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i+1); exit } }'
}

label_for_iface() {
    case "$1" in
        br0) echo "Main network" ;;
        br*) echo "Guest network ($1)" ;;
        "")  echo "Unknown network" ;;
        *)   echo "Network ($1)" ;;
    esac
}

# Private/random MAC (iPhone, Android, Windows): the second hex digit is 2, 6, a or e.
is_random_mac() {
    case "$(echo "$1" | cut -c2)" in
        2|6|a|e) return 0 ;;
        *) return 1 ;;
    esac
}

known_count() { if [ -f "$KNOWN" ]; then wc -l < "$KNOWN"; else echo 0; fi; }

is_known() { grep -qi "^${1}|" "$KNOWN" 2>/dev/null; }

cron_active() { cru l 2>/dev/null | grep -q "$SCRIPT_NAME"; }

mail_configured() { [ -f "$EMAIL_DIR/email.conf" ]; }

# Devices that Asus itself sees as online (network map), in lower case.
# Prints nothing and returns 1 if the file is missing.
online_macs() {
    [ -r "$NMP_FILE" ] || return 1
    grep -Eo '"mac":"[0-9A-Fa-f:]{17}"[^{}]*"online":[01]' "$NMP_FILE" \
        | sed -n 's/^"mac":"\([^"]*\)".*"online":1$/\1/p' | tr 'A-F' 'a-f'
    return 0
}

# update_seen SCANFILE: records per device when it was last online.
# Source for "online": the Asus client list. If that is missing, everything in
# the leases or ARP table counts as seen (less accurate).
update_seen() {
    ts="$(date +%s)"
    [ -f "$SEEN" ] || : > "$SEEN"
    have_online=0
    if online_macs > "$TMPBASE.online" 2>/dev/null && [ -r "$NMP_FILE" ]; then
        have_online=1
    else
        : > "$TMPBASE.online"
    fi
    awk -F'|' -v ts="$ts" -v have="$have_online" "$AWK_FN"'
        FILENAME == ARGV[1] {
            if ($1 != "") { m[$1] = 1; ep[$1] = $2; ip[$1] = $3; nm[$1] = $4; lb[$1] = $5; ord[++n] = $1 }
            next
        }
        FILENAME == ARGV[2] {
            if ($1 == "") next
            if (!($1 in m)) { m[$1] = 1; ord[++n] = $1 }
            insc[$1] = 1
            if ($2 != "") ip[$1] = $2
            if ($3 != "") nm[$1] = $3
            l = label($4)
            if (l != "Unknown network" || lb[$1] == "") lb[$1] = l
            next
        }
        {
            if ($1 == "") next
            if (!($1 in m)) { m[$1] = 1; ord[++n] = $1 }
            on[$1] = 1
        }
        END {
            for (i = 1; i <= n; i++) {
                k = ord[i]
                if (have == 1) { if (k in on) ep[k] = ts } else { if (k in insc) ep[k] = ts }
                print k "|" ep[k] "|" ip[k] "|" nm[k] "|" lb[k]
            }
        }
    ' "$SEEN" "$1" "$TMPBASE.online" > "$SEEN.tmp" && mv "$SEEN.tmp" "$SEEN"
    echo "$ts" > "$LASTRUN"
}

# Writes the last-seen data from RAM back to the file with known devices.
# Only if something changed, to spare the flash.
persist_seen() {
    [ -s "$SEEN" ] && [ -s "$KNOWN" ] || return 0
    awk -F'|' -v OFS='|' '
        FILENAME == ARGV[1] { ep[$1] = $2; ip[$1] = $3; nm[$1] = $4; lb[$1] = $5; next }
        {
            m = $1
            if (m in ep) {
                if (ip[m] != "") $3 = ip[m]
                if (nm[m] != "") $4 = nm[m]
                if (lb[m] != "") $5 = lb[m]
                if (ep[m] + 0 > 0) $6 = ep[m]
            }
            print
        }
    ' "$SEEN" "$KNOWN" > "$TMPBASE.persist"
    if ! cmp -s "$TMPBASE.persist" "$KNOWN" 2>/dev/null; then
        cat "$TMPBASE.persist" > "$KNOWN"
    fi
    rm -f "$TMPBASE.persist"
}

persist_seen_if_due() {
    ts="$(date +%s)"
    last="$(cat "$PERSIST_TS" 2>/dev/null)"
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    if [ $((ts - last)) -ge 3600 ]; then
        persist_seen
        echo "$ts" > "$PERSIST_TS"
    fi
}

# seen_epoch MAC: last-seen epoch from RAM, or 0.
seen_epoch() {
    e="$(grep -i "^${1}|" "$SEEN" 2>/dev/null | head -n 1 | cut -d'|' -f2)"
    case "$e" in ''|*[!0-9]*) e=0 ;; esac
    echo "$e"
}

# similar_known MAC NAME: known devices (other MAC) with the same name.
# Helps to recognise a device that returns with a new private MAC address.
# Generic names are skipped because they match unrelated devices.
similar_known() {
    case "$2" in
        ""|unknown|iPhone|iPad|"MSFT 5.0"|localhost|[Aa]ndroid*) return 0 ;;
    esac
    joined_known | awk -F'|' -v m="$1" -v n="$2" -v now="$(date +%s)" "$AWK_FN"'
        tolower($8) == tolower(n) && $5 != m {
            printf "%s (%s, %s)\n", $8, $5, ($11 == 1) ? "online now" : (($10 + 0 > 0) ? "last seen " ago($10, now) : "never seen online")
        }' | head -n 3
}

# Known devices combined with the last-seen data from RAM.
# Fields: g|network|ipkey|lineno|mac|first|ip|name|network|last_epoch|online
joined_known() {
    [ -f "$SEEN" ] || : > "$SEEN"
    awk -F'|' -v now="$(date +%s)" -v win="$((INTERVAL * 120 + 30))" "$AWK_FN"'
        FILENAME == ARGV[1] { sep[$1] = $2; sip[$1] = $3; snm[$1] = $4; slb[$1] = $5; next }
        {
            m = $1; ip = $3; nm = $4; lb = $5; ls = $6 + 0
            if (m in sep) {
                if (sep[m] + 0 > ls) ls = sep[m] + 0
                if (sip[m] != "") ip = sip[m]
                if (snm[m] != "") nm = snm[m]
                if (slb[m] != "") lb = slb[m]
            }
            online = (ls > 0 && now - ls <= win) ? 1 : 0
            split(ip, o, ".")
            g = (lb ~ /^Main/) ? 0 : ((lb ~ /^Guest/) ? 1 : 2)
            printf "%d|%s|%03d%03d%03d%03d|%d|%s|%s|%s|%s|%s|%d|%d\n", g, lb, o[1], o[2], o[3], o[4], FNR, m, $2, ip, nm, lb, ls, online
        }
    ' "$SEEN" "$KNOWN"
}

###############################################################################
# Email through the amtm settings
###############################################################################

# send_mail "subject" "file with the body"
send_mail() {
    subject="$1"
    bodyfile="$2"

    if [ "$DRY_RUN" = "1" ]; then
        echo "----- DRY RUN: subject: $subject -----"
        cat "$bodyfile"
        echo "----- end -----"
        return 0
    fi

    if ! mail_configured; then
        log "amtm email settings are missing ($EMAIL_DIR/email.conf). Set them up in amtm > em."
        return 1
    fi

    # shellcheck disable=SC1090
    . "$EMAIL_DIR/email.conf"

    pw="$(/usr/sbin/openssl aes-256-cbc $emailPwEnc -d -in "$EMAIL_DIR/emailpw.enc" -pass "pass:$AMTM_PW_KEY" 2>/dev/null)"
    if [ -z "$pw" ]; then
        log "Could not read the email password from amtm."
        return 1
    fi

    routername="${FRIENDLY_ROUTER_NAME:-$(nvram get model 2>/dev/null)}"
    [ -z "$routername" ] && routername="Router"

    msg="$TMPBASE.mail"
    {
        printf 'From: "%s" <%s>\r\n' "$routername" "$FROM_ADDRESS"
        printf 'To: "%s" <%s>\r\n' "${TO_NAME:-$TO_ADDRESS}" "$TO_ADDRESS"
        printf 'Subject: %s\r\n' "$subject"
        printf 'Date: %s\r\n' "$(date -R)"
        printf 'MIME-Version: 1.0\r\n'
        printf 'Content-Type: text/plain; charset=UTF-8\r\n'
        printf 'Content-Transfer-Encoding: 8bit\r\n'
        printf '\r\n'
        sed 's/$/\r/' "$bodyfile"
    } > "$msg"

    # Same curl call as amtm itself uses (--user). The password is therefore
    # briefly visible in the process list, just like with amtm.
    CURL_BIN="curl"
    [ -x /usr/sbin/curl ] && CURL_BIN="/usr/sbin/curl"

    "$CURL_BIN" -s -S --max-time 60 \
        --url "${PROTOCOL}://${SMTP}:${PORT}" \
        --mail-from "$FROM_ADDRESS" \
        --mail-rcpt "$TO_ADDRESS" \
        --upload-file "$msg" \
        --ssl-reqd \
        --user "${USERNAME}:${pw}" $SSL_FLAG 2>"$TMPBASE.curlerr"
    rc=$?
    unset pw

    if [ $rc -ne 0 ]; then
        log "Sending failed (curl exit $rc): $(tr '\n' ' ' < "$TMPBASE.curlerr")"
    fi
    return $rc
}

###############################################################################
# Core functions
###############################################################################

# One check. Sets NEW_COUNT and SENT_OK for the menu.
cmd_run() {
    NEW_COUNT=0
    SENT_OK=1
    lock || return 0
    trap cleanup EXIT INT TERM
    mkdir -p "$DATA_DIR"
    [ -f "$KNOWN" ] || : > "$KNOWN"

    scanfile="$TMPBASE.scan"
    pending="$TMPBASE.pending"
    body="$TMPBASE.body"
    : > "$pending"
    : > "$body"
    count=0

    scan_sorted > "$scanfile"
    update_seen "$scanfile"

    while IFS='|' read -r mac ip host dev; do
        [ -z "$mac" ] && continue
        is_known "$mac" && continue

        iface="$dev"
        if [ -z "$iface" ] && [ -n "$ip" ]; then
            iface="$(iface_for_ip "$ip")"
        fi
        label="$(label_for_iface "$iface")"
        name="${host:-unknown}"
        seen="$(now)"

        echo "${mac}|${seen}|${ip}|${name}|${label}|$(seen_epoch "$mac")" >> "$pending"

        {
            echo "Name:       $name"
            if is_random_mac "$mac"; then
                echo "MAC:        $mac (private/random address)"
            else
                echo "MAC:        $mac"
            fi
            vnd="$(vendor_for "$mac")"
            [ -n "$vnd" ] && echo "Vendor:     $vnd"
            echo "IP:         ${ip:-unknown}"
            echo "Network:    $label"
            if is_random_mac "$mac"; then
                sim="$(similar_known "$mac" "$name")"
                [ -n "$sim" ] && printf '%s\n' "$sim" | sed 's/^/Similar to: /'
            fi
            echo "Seen at:    $seen"
            echo
        } >> "$body"
        count=$((count + 1))
    done < "$scanfile"

    NEW_COUNT=$count
    if [ "$count" -gt 0 ]; then
        {
            if [ "$count" -eq 1 ]; then
                echo "1 new device connected to your network:"
            else
                echo "$count new devices connected to your network:"
            fi
            echo
            cat "$body"
            echo "Unknown device? Check it in the router or change the wifi password."
            echo "A device in this list counts as known after this message."
        } > "$TMPBASE.final"

        # After a failed email, wait before trying again (a manual check ignores the pause).
        paused=0
        if [ "$IGNORE_MAIL_PAUSE" != "1" ] && [ -f "$MAILFAIL" ]; then
            lf="$(cat "$MAILFAIL" 2>/dev/null)"
            case "$lf" in ''|*[!0-9]*) lf=0 ;; esac
            [ $(( $(date +%s) - lf )) -lt "$MAIL_RETRY_SECS" ] && paused=1
        fi

        if [ "$paused" = "1" ]; then
            SENT_OK=0
        elif send_mail "[Router] New device on the network ($count)" "$TMPBASE.final"; then
            rm -f "$MAILFAIL"
            cat "$pending" >> "$KNOWN"
            log "Reported $count new device(s): $(cut -d'|' -f1,4 "$pending" | tr '\n' ' ')"
        else
            SENT_OK=0
            date +%s > "$MAILFAIL"
            log "Message not sent; $count device(s) stay 'new'. Next attempt in $((MAIL_RETRY_SECS / 60)) min."
        fi
    fi

    persist_seen_if_due

    cleanup
    trap - EXIT INT TERM
}

cmd_baseline() {
    mkdir -p "$DATA_DIR"
    [ -f "$KNOWN" ] || : > "$KNOWN"
    n=0
    scan_sorted > "$TMPBASE.scan"
    update_seen "$TMPBASE.scan"
    while IFS='|' read -r mac ip host dev; do
        [ -z "$mac" ] && continue
        is_known "$mac" && continue
        iface="$dev"
        [ -z "$iface" ] && [ -n "$ip" ] && iface="$(iface_for_ip "$ip")"
        echo "${mac}|$(now)|${ip}|${host:-unknown}|$(label_for_iface "$iface")|$(seen_epoch "$mac")" >> "$KNOWN"
        n=$((n + 1))
    done < "$TMPBASE.scan"
    log "Baseline: added $n device(s) as known."
    echo "Total known: $(wc -l < "$KNOWN")."
    rm -f "$TMPBASE".*
}

cmd_test() {
    printf 'This is a test message from %s.\nIf you can read this, the amtm email settings work.\n' "$SCRIPT_NAME" > "$TMPBASE.test"
    if send_mail "[Router] Test message from newdevmon" "$TMPBASE.test"; then
        log "Test email sent."
        rc=0
    else
        echo "Test email failed. See the log for the reason."
        rc=1
    fi
    rm -f "$TMPBASE".*
    return $rc
}

cmd_list() {
    if [ ! -s "$KNOWN" ]; then
        echo "No known devices yet."
        return
    fi
    # Grouped by network (main network first), by IP address within a network.
    # The number (#) stays the line number in the file.
    link_info 2>/dev/null > "$TMPBASE.link" || : > "$TMPBASE.link"
    node_labels > "$TMPBASE.nodes"
    joined_known | sort -t'|' -k1,1n -k2,2 -k3,3 | awk -F'|' \
        -v now="$(date +%s)" -v G="$C_G" -v D="$C_D" -v B="$C_B" -v X="$C_X" "$AWK_FN"'
        FILENAME == ARGV[1] { lk[$1] = bandshort($3) ($4 != "" ? " " $4 : ""); nk[$1] = $2; next }
        FILENAME == ARGV[2] { if (!($1 in nl)) nl[$1] = $2; next }
        {
            n++; L[n] = $0
            lab = $9; tot[lab]++
            if ($11 == 1) on[lab]++
        }
        END {
            prev = ""
            for (i = 1; i <= n; i++) {
                split(L[i], f, "|")
                lab = f[9]
                if (lab != prev) {
                    if (i > 1) print ""
                    printf "%s== %s ==%s  %d devices, %d online\n", B, lab, X, tot[lab], on[lab] + 0
                    printf "%s%-3s %-16s %-15s %-9s %-12s %-10s %s%s\n", D, "#", "Name", "IP", "Link", "Node", "First", "Last seen", X
                    prev = lab
                }
                if (f[11] == 1) last = G "online" X
                else if (f[10] + 0 <= 0) last = "never online"
                else last = ago(f[10], now)
                lt = (f[11] == 1 && (f[5] in lk)) ? lk[f[5]] : "-"
                nd = "-"
                if (f[11] == 1 && (f[5] in nk) && nk[f[5]] != "") {
                    nd = (nk[f[5]] in nl) ? nl[nk[f[5]]] : "node " substr(nk[f[5]], 13)
                }
                printf "%-3d %-16s %-15s %-9s %-12s %-10s %s\n", f[4], trunc(f[8], 16), f[7], lt, trunc(nd, 12), substr(f[6], 1, 10), last
            }
        }' "$TMPBASE.link" "$TMPBASE.nodes" -
    rm -f "$TMPBASE.link" "$TMPBASE.nodes"
}

# resolve_device NR_OR_MAC: returns the MAC address for a number from the list (or the MAC itself).
resolve_device() {
    case "$1" in
        '') return 0 ;;
        *[!0-9]*) echo "$1" | tr 'A-F' 'a-f' ;;
        *) [ "$1" -ge 1 ] && sed -n "${1}p" "$KNOWN" | cut -d'|' -f1 ;;
    esac
}

# All known details of one device.
cmd_detail() {
    dmac="$(resolve_device "$1")"
    if [ -z "$dmac" ] || ! is_known "$dmac"; then
        echo "Device not found: ${1:-(no input)}"
        return 1
    fi
    joined_known | awk -F'|' -v m="$dmac" -v now="$(date +%s)" \
        -v G="$C_G" -v R="$C_R" -v D="$C_D" -v B="$C_B" -v X="$C_X" "$AWK_FN"'
        $5 == m {
            nm = ($8 == "") ? "unknown" : $8
            priv = (substr($5, 2, 1) ~ /[26ae]/)
            printf "%s== %s ==%s\n\n", B, nm, X
            printf "  %-15s %s\n", "Name:", nm
            printf "  %-15s %s%s\n", "MAC address:", $5, (priv ? "  (private/random address)" : "")
            printf "  %-15s %s\n", "IP address:", ($7 == "" ? "unknown" : $7)
            printf "  %-15s %s\n", "Network:", $9
            if ($11 == 1) st = G "online" X; else st = R "offline" X
            printf "  %-15s %s\n", "Status:", st
            if ($10 + 0 > 0) ls = ($11 == 1) ? "now" : ago($10, now); else ls = "not seen online yet"
            printf "  %-15s %s\n", "Last seen:", ls
            printf "  %-15s %s\n", "Known since:", $6
            printf "  %-15s %d\n", "List no.:", $4
        }'

    # Extra data from the router (Asus client lists).
    dnmp="$(nmp_info 2>/dev/null | awk -F'|' -v m="$dmac" '$1 == m { print; exit }')"
    dlink="$(link_info 2>/dev/null | awk -F'|' -v m="$dmac" '$1 == m { print; exit }')"
    IFS='|' read -r _m an av avc aon awl amlo <<EOF
$dnmp
EOF
    IFS='|' read -r _l lnode lband lrssi lip <<EOF
$dlink
EOF

    conn=""
    case "$lband" in
        2G*) conn="Wi-Fi 2.4 GHz" ;;
        5G*) conn="Wi-Fi 5 GHz" ;;
        6G*) conn="Wi-Fi 6 GHz" ;;
        "wired?") conn="Wired? (the node does not report Wi-Fi; may be wireless)" ;;
        wired*) conn="Wired" ;;
        "") ;;
        *) conn="$lband" ;;
    esac
    if [ -z "$conn" ] && [ "$aon" = "1" ]; then
        case "$awl" in
            0) conn="Wired" ;;
            1) conn="Wi-Fi 2.4 GHz" ;;
            2) conn="Wi-Fi 5 GHz" ;;
            ?*) conn="Wi-Fi" ;;
        esac
    fi

    sig=""
    case "$lrssi" in
        -[0-9]*|[0-9]*)
            if   [ "$lrssi" -ge -50 ]; then q="excellent"
            elif [ "$lrssi" -ge -60 ]; then q="good"
            elif [ "$lrssi" -ge -70 ]; then q="fair"
            else q="weak"; fi
            sig="$lrssi dBm ($q)" ;;
    esac

    via=""
    if [ -n "$lnode" ]; then
        rmacs=""
        for v in lan_hwaddr et0macaddr label_mac; do
            rmacs="$rmacs $(nvram get "$v" 2>/dev/null | tr 'A-F' 'a-f')"
        done
        case " $rmacs " in
            *" $lnode "*) via="Router (this device)" ;;
            *)
                nname="$(nmp_info 2>/dev/null | awk -F'|' -v m="$lnode" '$1 == m { print $2; exit }')"
                via="AiMesh node ${nname:+$nname }($lnode)" ;;
        esac
    fi

    vend=""; vsrc=""
    if ! is_random_mac "$dmac"; then
        vend="$(oui_lookup "$dmac")"
        [ -n "$vend" ] && vsrc="IEEE list"
    fi
    if [ -z "$vend" ] && [ -n "$av" ]; then vend="$av"; vsrc="Asus"; fi
    if [ -z "$vend" ] && ! is_random_mac "$dmac" && ! oui_exists; then
        vend="unknown (download the vendor list: Settings > o)"
    fi

    if [ -n "$conn$sig$via$vend$an" ]; then
        echo
        [ -n "$conn" ] && printf '  %-15s %s\n' "Connection:" "$conn"
        [ -n "$sig" ]  && printf '  %-15s %s\n' "Signal:" "$sig"
        [ -n "$via" ]  && printf '  %-15s %s\n' "Connected to:" "$via"
        [ -n "$vend" ] && printf '  %-15s %s%s\n' "Vendor:" "$vend" "${vsrc:+  ($vsrc)}"
        [ -n "$an" ]   && printf '  %-15s %s\n' "Asus name:" "$an"
        [ "$amlo" = "1" ] && printf '  %-15s %s\n' "MLO:" "yes"
    fi

    dname="$(joined_known | awk -F'|' -v m="$dmac" '$5 == m { print $8; exit }')"
    sim="$(similar_known "$dmac" "$dname")"
    if [ -n "$sim" ]; then
        echo
        printf '  %-15s %s\n' "Same name as:" "$(printf '%s\n' "$sim" | head -n 1)"
        printf '%s\n' "$sim" | tail -n +2 | sed 's/^/                  /'
    fi

    if is_random_mac "$dmac"; then
        printf '\n  %sA private address can change per network or after a reset.\n  The same device then shows up again as new.%s\n' "$C_D" "$C_X"
    fi
}

# Shows the raw router data about one device (to find out why Link/Node is wrong).
cmd_debug() {
    dmac="$(resolve_device "$1")"
    [ -z "$dmac" ] && { echo "Usage: $0 debug NR|MAC"; return 1; }
    echo "== Debug for $dmac (newdevmon $VERSION) =="
    echo
    echo "-- Asus per-band list ($CLIENTLIST_FILE): every place where this MAC occurs"
    echo "   format: mac|node|band|rssi|ip"
    if [ -r "$CLIENTLIST_FILE" ]; then
        link_info all 2>/dev/null | awk -F'|' -v m="$dmac" '$1 == m'
        echo "   (raw, around the MAC:)"
        tr -d '\r\n' < "$CLIENTLIST_FILE" | grep -oi ".\{0,120\}$dmac.\{0,160\}" | head -n 6
    else
        echo "   file not found"
    fi
    echo
    echo "-- Asus network map ($NMP_FILE)"
    if [ -r "$NMP_FILE" ]; then
        tr -d '\r\n' < "$NMP_FILE" | sed 's/},"/}\n"/g' | grep -i "\"mac\":\"$dmac\"" | head -n 2
    else
        echo "   file not found"
    fi
    echo
    echo "-- Router and node names"
    node_labels
}

# oui_compact FILE: turns an IEEE registry CSV (MA-L, MA-M or MA-S) into lines
# "HEXPREFIX|Vendor name" (6, 7 or 9 hex digits). Placeholder entries are dropped.
oui_compact() {
    awk '
        NR == 1 { next }
        {
            gsub(/\r/, "")
            i = index($0, ","); if (i == 0) next
            rest = substr($0, i + 1)
            i = index(rest, ","); if (i == 0) next
            asg = substr(rest, 1, i - 1)
            name = substr(rest, i + 1)
            if (asg !~ /^[0-9A-Fa-f]+$/) next
            if (length(asg) != 6 && length(asg) != 7 && length(asg) != 9) next
            if (substr(name, 1, 1) == "\"") {
                name = substr(name, 2)
                i = index(name, "\",")
                if (i > 0) name = substr(name, 1, i - 1); else sub(/"$/, "", name)
                gsub(/""/, "\"", name)
            } else {
                i = index(name, ","); if (i > 0) name = substr(name, 1, i - 1)
            }
            gsub(/\|/, "/", name)
            sub(/^[ \t]+/, "", name); sub(/[ \t]+$/, "", name)
            if (name == "" || name == "IEEE Registration Authority" || name == "Private") next
            print toupper(asg) "|" name
        }' "$1"
}

# oui_path: the vendor list that exists (USB first), nothing if there is none.
oui_path() {
    if [ -s "$OUI_USB" ]; then echo "$OUI_USB"
    elif [ -s "$OUI_JFFS" ]; then echo "$OUI_JFFS"
    fi
}
oui_exists() { [ -n "$(oui_path)" ]; }

# oui_target: where a new vendor list is written: the USB drive (Entware) if usable, else JFFS.
oui_target() {
    if [ -d "$OPT_DIR" ] && [ -w "$OPT_DIR" ] && mkdir -p "$OPT_DIR/share/newdevmon" 2>/dev/null; then
        echo "$OUI_USB"
    else
        echo "$OUI_JFFS"
    fi
}

# oui_lookup MAC: prints the vendor from the local list (nothing if unknown).
oui_lookup() {
    OUI_FILE="$(oui_path)"
    [ -n "$OUI_FILE" ] || return 0
    full="$(echo "$1" | tr -d ':' | tr 'a-f' 'A-F')"
    # Longest match first: MA-S (9 digits), MA-M (7 digits), MA-L (6 digits).
    for n in 9 7 6; do
        pfx="$(echo "$full" | cut -c1-$n)"
        v="$(grep "^${pfx}|" "$OUI_FILE" | head -n 1 | cut -d'|' -f2)"
        [ -n "$v" ] && { echo "$v"; return 0; }
    done
    return 0
}

# Downloads the IEEE vendor list and stores it compactly (Settings > o).
cmd_oui_update() {
    mkdir -p "$DATA_DIR"
    CURL_BIN="curl"
    [ -x /usr/sbin/curl ] && CURL_BIN="/usr/sbin/curl"
    echo "Downloading the IEEE vendor lists (about 6 MB in total)..."
    : > "$TMPBASE.ouic"
    for part in L M S; do
        case "$part" in L) url="$OUI_URL_L" ;; M) url="$OUI_URL_M" ;; S) url="$OUI_URL_S" ;; esac
        if "$CURL_BIN" -fsSL --max-time 120 --retry 2 -A "$OUI_UA" "$url" -o "$TMPBASE.csv" 2>"$TMPBASE.ouierr"; then
            oui_compact "$TMPBASE.csv" >> "$TMPBASE.ouic"
        elif [ "$part" = "L" ]; then
            log "Vendor list download failed: $(tr '\n' ' ' < "$TMPBASE.ouierr")"
            echo "Download failed (see the log)."
            rm -f "$TMPBASE".*
            return 1
        else
            echo "Note: the MA-$part list could not be downloaded; small vendors may be missing."
        fi
    done
    n="$(wc -l < "$TMPBASE.ouic")"
    if [ "$n" -lt 10000 ]; then
        log "Vendor list looks wrong ($n entries); not used."
        echo "The downloaded list looks wrong ($n entries); the old list is kept."
        rm -f "$TMPBASE".*
        return 1
    fi
    target="$(oui_target)"
    if cp "$TMPBASE.ouic" "$target.new" && mv "$target.new" "$target"; then
        # Remove an older copy on the flash if the list now lives on the USB drive.
        [ "$target" = "$OUI_USB" ] && rm -f "$OUI_JFFS"
        log "Vendor list updated: $n entries, stored in $target."
        echo "Vendor list updated: $n entries ($(wc -c < "$target") bytes)."
        echo "Stored in: $target"
    else
        rm -f "$target.new"
        log "Could not write the vendor list to $target."
        echo "Could not write the vendor list to $target."
        rm -f "$TMPBASE".*
        return 1
    fi
    rm -f "$TMPBASE".*
}

# vendor_for MAC: vendor from the local IEEE list, else from the Asus network map.
# Prints nothing for private/random addresses or when nothing is known.
vendor_for() {
    is_random_mac "$1" && return 0
    v="$(oui_lookup "$1")"
    if [ -z "$v" ]; then
        v="$(nmp_info 2>/dev/null | awk -F'|' -v m="$1" '$1 == m { print $3; exit }')"
    fi
    [ -n "$v" ] && echo "$v"
    return 0
}

# port_name PORT: common service name.
port_name() {
    case "$1" in
        21) echo ftp ;; 22) echo ssh ;; 23) echo telnet ;; 25|465|587) echo smtp ;;
        53) echo dns ;; 80|81|8000|8008|8080|8081) echo http ;; 110|995) echo pop3 ;;
        111) echo rpcbind ;; 135) echo msrpc ;; 139|445) echo smb ;; 143|993) echo imap ;;
        443|8443) echo https ;; 515) echo lpd-printer ;; 548) echo afp ;; 554) echo rtsp ;;
        631) echo ipp-printer ;; 873) echo rsync ;; 1433) echo mssql ;; 1723) echo pptp ;;
        1883|8883) echo mqtt ;; 2049) echo nfs ;; 3000) echo web-app ;; 3306) echo mysql ;;
        3389) echo rdp ;; 5000|5001) echo synology/upnp ;; 5432) echo postgres ;; 5900) echo vnc ;;
        5985) echo winrm ;; 8123) echo home-assistant ;; 9000) echo web-app ;; 9100) echo jetdirect-printer ;;
        32400) echo plex ;; 49152) echo upnp ;; 62078) echo ios-lockdown ;; *) echo "" ;;
    esac
}

# cmd_portscan NR|MAC: TCP connect scan of common ports on one known device (private addresses only).
cmd_portscan() {
    dmac="$(resolve_device "$1")"
    if [ -z "$dmac" ] || ! is_known "$dmac"; then
        echo "Device not found: ${1:-(no input)}"
        return 1
    fi
    ip="$(joined_known | awk -F'|' -v m="$dmac" '$5 == m { print $7; exit }')"
    case "$ip" in
        10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) ;;
        *) echo "No private IP address known for this device; not scanning."; return 1 ;;
    esac
    if ! command -v nc >/dev/null 2>&1; then
        echo "The nc command is not available on this router."
        return 1
    fi
    np=0; for p in $SCAN_PORTS; do np=$((np + 1)); done
    echo "Scanning $ip: $np common TCP ports (takes a few seconds)..."
    : > "$TMPBASE.open"
    k=0
    for p in $SCAN_PORTS; do
        ( nc -w 1 "$ip" "$p" </dev/null >/dev/null 2>&1 && echo "$p" >> "$TMPBASE.open" ) &
        k=$((k + 1))
        [ $((k % 12)) -eq 0 ] && wait
    done
    wait
    echo
    if [ -s "$TMPBASE.open" ]; then
        printf '%s  %-7s %s%s\n' "$C_D" "Port" "Service" "$C_X"
        sort -n "$TMPBASE.open" | while read -r p; do
            printf '  %-7s %s\n' "$p" "$(port_name "$p")"
        done
    else
        echo "No open ports found among the common ports."
    fi
    printf '\n  %sTCP only. A device that silently drops packets looks the same as one with closed ports.%s\n' "$C_D" "$C_X"
    log "Port scan of $dmac ($ip): $(sort -n "$TMPBASE.open" | tr '\n' ' ')"
    rm -f "$TMPBASE".*
}

cmd_log() {
    n="${1:-40}"
    if [ -s "$LOGFILE" ]; then
        tail -n "$n" "$LOGFILE"
    else
        echo "The log is still empty."
    fi
}

cmd_forget() {
    mac="$(echo "$1" | tr 'A-F' 'a-f')"
    [ -z "$mac" ] && { echo "Usage: $0 forget MAC-ADDRESS"; return 1; }
    if ! is_known "$mac"; then
        echo "$mac is not in the list."
        return 1
    fi
    grep -vi "^${mac}|" "$KNOWN" > "$TMPBASE.known"
    cat "$TMPBASE.known" > "$KNOWN"
    rm -f "$TMPBASE".*
    log "Forgot $mac (it will be reported again at the next check if it is connected)."
}

# Sets the cron jobs according to the configured interval (also called by services-start).
cmd_cron() {
    if [ "$INTERVAL" -le 1 ]; then
        expr="* * * * *"
    else
        expr="*/$INTERVAL * * * *"
    fi
    cru d "$SCRIPT_NAME" 2>/dev/null
    cru a "$SCRIPT_NAME" "$expr $SCRIPT_PATH run"

    # Daily update check.
    cru d "${SCRIPT_NAME}-update" 2>/dev/null
    cru a "${SCRIPT_NAME}-update" "23 5 * * * $SCRIPT_PATH update-check"
}

cmd_install() {
    mkdir -p "$DATA_DIR" /jffs/scripts
    self="$(readlink -f "$0" 2>/dev/null)"
    if [ "$self" != "$SCRIPT_PATH" ]; then
        cp "$0" "$SCRIPT_PATH" || { echo "Copying to $SCRIPT_PATH failed."; return 1; }
    fi
    chmod 755 "$SCRIPT_PATH"

    cmd_cron

    hook="/jffs/scripts/services-start"
    [ -f "$hook" ] || printf '#!/bin/sh\n' > "$hook"
    chmod 755 "$hook"
    # Replace old lines, including those of an earlier file name.
    sed -i "/$SCRIPT_NAME/d" "$hook"
    printf '%s cron # %s\n' "$SCRIPT_PATH" "$SCRIPT_NAME" >> "$hook"

    log "Installed: cron job (every $INTERVAL min) + startup hook in $hook."
}

cmd_uninstall() {
    cru d "$SCRIPT_NAME" 2>/dev/null
    cru d "${SCRIPT_NAME}-update" 2>/dev/null
    [ -f /jffs/scripts/services-start ] && sed -i "/$SCRIPT_NAME/d" /jffs/scripts/services-start
    log "Cron jobs and startup hook removed. Data remains in $DATA_DIR."
}

###############################################################################
# Updates through GitHub
###############################################################################

save_conf() {
    mkdir -p "$DATA_DIR"
    {
        echo "INTERVAL=$INTERVAL"
        echo "UPDATE_MAIL=$UPDATE_MAIL"
    } > "$CONF"
}

update_url() {
    echo "https://raw.githubusercontent.com/${UPDATE_REPO}/${UPDATE_BRANCH}/${UPDATE_FILE}"
}

# ver_gt A B: succeeds (0) if version A is newer than version B (format x.y.z)
ver_gt() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        na = split(a, x, "."); nb = split(b, y, ".")
        n = (na > nb) ? na : nb
        for (i = 1; i <= n; i++) {
            xi = x[i] + 0; yi = y[i] + 0
            if (xi > yi) exit 0
            if (xi < yi) exit 1
        }
        exit 1
    }'
}

remote_version() {
    sed -n 's/^VERSION="\([0-9][0-9.]*\)".*/\1/p' "$1" | head -n 1
}

# fetch_remote FILE: downloads the script from the repository to FILE.
fetch_remote() {
    CURL_BIN="curl"
    [ -x /usr/sbin/curl ] && CURL_BIN="/usr/sbin/curl"
    if ! "$CURL_BIN" -fsSL --max-time 30 --retry 2 "$(update_url)" -o "$1" 2>"$TMPBASE.fetcherr"; then
        log "Update check failed: $(tr '\n' ' ' < "$TMPBASE.fetcherr")"
        echo "Download failed (see the log). Check the router's internet connection."
        return 1
    fi
    return 0
}

# validate_remote FILE: checks that the downloaded file really is this script.
validate_remote() {
    head -n 1 "$1" | grep -q '^#!/bin/sh' || { echo "The downloaded file does not look like a shell script."; return 1; }
    grep -q "^SCRIPT_NAME=\"$SCRIPT_NAME\"" "$1" || { echo "The downloaded file is not $SCRIPT_NAME."; return 1; }
    sh -n "$1" 2>/dev/null || { echo "The downloaded script has a syntax error."; return 1; }
    [ -n "$(remote_version "$1")" ] || { echo "No version number found in the downloaded file."; return 1; }
    return 0
}

# Runs daily through cron. Sets a flag and notifies (optionally by email) about a new version.
cmd_update_check() {
    mkdir -p "$DATA_DIR"
    fetch_remote "$TMPBASE.remote" || { rm -f "$TMPBASE".*; return 1; }
    if ! validate_remote "$TMPBASE.remote"; then
        log "Update check: invalid file in the repository, not used."
        rm -f "$TMPBASE".*
        return 1
    fi
    rv="$(remote_version "$TMPBASE.remote")"
    if ver_gt "$rv" "$VERSION"; then
        [ "$(cat "$UPDATE_FLAG" 2>/dev/null)" = "$rv" ] || echo "$rv" > "$UPDATE_FLAG"
        echo "New version available: $rv (you have $VERSION)."
        if [ "$(cat "$DATA_DIR/update_notified" 2>/dev/null)" != "$rv" ]; then
            log "New version available: $rv (current $VERSION)."
            if [ "$UPDATE_MAIL" = "1" ]; then
                {
                    echo "A new version of $SCRIPT_NAME is available: $rv (installed: $VERSION)."
                    echo
                    echo "To install: open the script through amtm (p), then Settings > u, or run:"
                    echo "  $SCRIPT_PATH update"
                } > "$TMPBASE.updmail"
                send_mail "[Router] $SCRIPT_NAME update available ($rv)" "$TMPBASE.updmail" && echo "$rv" > "$DATA_DIR/update_notified"
            else
                echo "$rv" > "$DATA_DIR/update_notified"
            fi
        fi
    else
        rm -f "$UPDATE_FLAG"
        echo "You have the latest version ($VERSION)."
    fi
    rm -f "$TMPBASE".*
}

# Prints the changelog entries newer than the installed version, taken from
# README.md in the repository. Prints nothing if the README cannot be fetched.
show_changelog() {
    CURL_BIN="curl"
    [ -x /usr/sbin/curl ] && CURL_BIN="/usr/sbin/curl"
    u="$(update_url)"
    ru="${u%/*}/README.md"
    "$CURL_BIN" -fsSL --max-time 30 "$ru" -o "$TMPBASE.readme" 2>/dev/null || return 0
    sc=0
    first=1
    while IFS= read -r line; do
        case "$line" in
            "### "[0-9]*)
                v="${line#\#\#\# }"
                if ver_gt "$v" "$VERSION"; then
                    sc=1
                    [ "$first" = "1" ] && { echo; echo "What's new:"; first=0; }
                    echo "  $v"
                else
                    sc=0
                fi ;;
            "## "*) sc=0 ;;
            *) [ "$sc" = "1" ] && [ -n "$line" ] && echo "  $line" ;;
        esac
    done < "$TMPBASE.readme"
    [ "$first" = "0" ] && echo
    return 0
}

# Checks for a newer version and installs it after confirmation (or with -y).
cmd_update() {
    UPDATED=0
    mkdir -p "$DATA_DIR"
    fetch_remote "$TMPBASE.remote" || { rm -f "$TMPBASE".*; return 1; }
    validate_remote "$TMPBASE.remote" || { rm -f "$TMPBASE".*; return 1; }
    rv="$(remote_version "$TMPBASE.remote")"

    if ! ver_gt "$rv" "$VERSION"; then
        echo "You have the latest version ($VERSION); the repository has $rv."
        rm -f "$UPDATE_FLAG"
        rm -f "$TMPBASE".*
        return 0
    fi

    echo "Update available: $VERSION -> $rv"
    show_changelog
    echo "Source: $(update_url)"
    if [ "$1" != "-y" ]; then
        if [ -t 0 ] && [ -t 1 ]; then
            menu_confirm "Install now?" || { echo "Cancelled."; rm -f "$TMPBASE".*; return 0; }
        else
            echo "Not interactive: use 'update -y' to install."
            rm -f "$TMPBASE".*
            return 1
        fi
    fi

    mkdir -p "$DATA_DIR/backup"
    bk="$DATA_DIR/backup/${SCRIPT_NAME}-v${VERSION}-$(date +%Y%m%d%H%M%S)"
    cp "$SCRIPT_PATH" "$bk" || { log "Update aborted: could not make a backup."; rm -f "$TMPBASE".*; return 1; }
    # Keep the 3 newest backups.
    ls -1t "$DATA_DIR/backup" | tail -n +4 | while read -r old; do rm -f "$DATA_DIR/backup/$old"; done

    # Through a temporary file + mv, so the running script is not overwritten in place.
    if cp "$TMPBASE.remote" "$SCRIPT_PATH.new" && chmod 755 "$SCRIPT_PATH.new" && mv "$SCRIPT_PATH.new" "$SCRIPT_PATH"; then
        rm -f "$UPDATE_FLAG" "$DATA_DIR/update_notified"
        log "Updated from $VERSION to $rv. Backup: $bk"
        echo "Updated to $rv. Start the script again to use the new version."
        UPDATED=1
    else
        rm -f "$SCRIPT_PATH.new"
        log "Update failed while replacing $SCRIPT_PATH; the current version is unchanged."
        echo "Update failed; the current version is unchanged."
    fi
    rm -f "$TMPBASE".*
}

cmd_rollback() {
    UPDATED=0
    latest="$(ls -1t "$DATA_DIR/backup" 2>/dev/null | head -n 1)"
    if [ -z "$latest" ]; then
        echo "No backups found."
        return 1
    fi
    echo "Restoring backup: $latest"
    if [ -t 0 ] && [ -t 1 ]; then
        menu_confirm "Continue?" || { echo "Cancelled."; return 0; }
    fi
    if cp "$DATA_DIR/backup/$latest" "$SCRIPT_PATH.new" && chmod 755 "$SCRIPT_PATH.new" && mv "$SCRIPT_PATH.new" "$SCRIPT_PATH"; then
        log "Restored backup $latest."
        echo "Restored. Start the script again."
        UPDATED=1
    else
        rm -f "$SCRIPT_PATH.new"
        echo "Restore failed."
        return 1
    fi
}

cmd_status() {
    echo "newdevmon $VERSION - notifies you about new devices"
    if [ -f "$UPDATE_FLAG" ]; then
        echo "Update:            version $(cat "$UPDATE_FLAG") available (run: $SCRIPT_PATH update)"
    fi
    if cron_active; then
        echo "Cron job:          active (every $INTERVAL min)"
    else
        echo "Cron job:          NOT active (run: $SCRIPT_PATH install)"
    fi
    if mail_configured; then
        echo "amtm email:        configured"
    else
        echo "amtm email:        NOT configured (amtm > em)"
    fi
    echo "Known devices:     $(known_count)"
    [ "$DRY_RUN" = "1" ] && echo "Mode:              DRY RUN (nothing is sent)"
    echo
    echo "Commands: menu | run | cron | install | uninstall | baseline | test | list | detail NR|MAC | debug NR|MAC | portscan NR|MAC | oui-update | log | forget MAC"
    echo "          update-check | update [-y] | rollback"
}

###############################################################################
# Menu
###############################################################################

pause_enter() { printf '\nPress Enter to continue... '; read -r _dummy || true; }

# Compact overview at the top of the menu.
menu_dashboard() {
    if [ -s "$KNOWN" ]; then
        joined_known | sort -t'|' -k1,1n -k2,2 | awk -F'|' -v G="$C_G" -v D="$C_D" -v X="$C_X" '
            { lab = $9; if (!(lab in t)) ord[++n] = lab; t[lab]++; if ($11 == 1) o[lab]++ }
            END {
                for (i = 1; i <= n; i++) {
                    lab = ord[i]
                    c = (o[lab] > 0) ? G : D
                    printf "  %-20s %3d known, %s%3d online%s\n", lab, t[lab], c, o[lab] + 0, X
                }
            }'
        tail -n 1 "$KNOWN" | awk -F'|' -v D="$C_D" -v X="$C_X" '
            { nm = ($4 == "") ? "unknown" : $4
              printf "  %sNewest:%s     %s, %s\n", D, X, nm, substr($2, 1, 16) }'
    else
        echo "  No known devices yet."
    fi

    now_ep="$(date +%s)"
    last="$(cat "$LASTRUN" 2>/dev/null)"
    case "$last" in ''|*[!0-9]*) last="" ;; esac
    if cron_active; then
        if [ -z "$last" ]; then
            ctl="${C_G}active${C_X}, every $INTERVAL min; not run yet"
        else
            age=$(( (now_ep - last) / 60 ))
            limit=$(( INTERVAL * 3 )); [ "$limit" -lt 5 ] && limit=5
            if [ "$age" -gt "$limit" ]; then
                ctl="${C_R}last check $age min ago${C_X}"
            else
                ctl="${C_G}active${C_X}, every $INTERVAL min; last $age min ago"
            fi
        fi
    else
        ctl="${C_R}NOT active${C_X} (Settings > i)"
    fi
    if mail_configured; then mail_txt="${C_G}configured${C_X}"; else mail_txt="${C_R}NOT configured${C_X} (amtm > em)"; fi
    printf '  %sChecking:%s   %s\n' "$C_D" "$C_X" "$ctl"
    printf '  %samtm mail:%s  %s\n' "$C_D" "$C_X" "$mail_txt"
    if [ -f "$MAILFAIL" ]; then
        lf="$(cat "$MAILFAIL" 2>/dev/null)"
        case "$lf" in ''|*[!0-9]*) lf=0 ;; esac
        left=$(( (MAIL_RETRY_SECS - (now_ep - lf) + 59) / 60 ))
        [ "$left" -gt 0 ] && printf '  %samtm mail:%s  %slast send FAILED, retrying in %d min%s\n' "$C_D" "$C_X" "$C_R" "$left" "$C_X"
    fi
    [ "$DRY_RUN" = "1" ] && printf '  %sMode:%s       DRY RUN\n' "$C_D" "$C_X"
    if [ -f "$UPDATE_FLAG" ]; then
        printf '  %s** UPDATE AVAILABLE: %s (Settings > u) **%s\n' "$C_Y" "$(cat "$UPDATE_FLAG")" "$C_X"
    fi
}

# Clears the screen and prints a clearly visible bar, so a new screen is easy
# to find when scrolling back (some terminals keep the old output).
new_screen() {
    clear 2>/dev/null
    printf '\n\n%s%s%s\n\n' "$C_Y" "$(printf '%66s' '' | tr ' ' '=')" "$C_X"
}

hdr_line() {
    # No %*s here: busybox awk does not support it.
    awk -v t="$1" 'BEGIN {
        l = length(t); p = int((62 - l) / 2); q = 62 - l - p
        sp = ""; for (i = 0; i < p; i++) sp = sp " "
        sq = ""; for (i = 0; i < q; i++) sq = sq " "
        print "##" sp t sq "##"
    }'
}

# banner LINE1 LINE2: the boxed ASCII header, used for the menu and the exit screen.
banner() {
    model="$(nvram get model 2>/dev/null)"
    [ -z "$model" ] && model="router"
    bar="$(printf '%66s' '' | tr ' ' '#')"
    printf '%s%s\n' "$C_B" "$bar"
    cat <<'ART' | awk '{ printf "## %-59s  ##\n", $0 }'
                        _                                  
 _ __   _____      ____| | _____   ___ __ ___   ___  _ __  
| '_ \ / _ \ \ /\ / / _` |/ _ \ \ / / '_ ` _ \ / _ \| '_ \ 
| | | |  __/\ V  V / (_| |  __/\ V /| | | | | | (_) | | | |
|_| |_|\___| \_/\_/ \__,_|\___| \_/ |_| |_| |_|\___/|_| |_|
ART
    hdr_line ""
    hdr_line "$1"
    hdr_line "$2"
    hdr_line ""
    hdr_line "https://github.com/$UPDATE_REPO"
    hdr_line ""
    printf '%s%s\n' "$bar" "$C_X"
}

menu_header() {
    new_screen
    model="$(nvram get model 2>/dev/null)"
    [ -z "$model" ] && model="router"
    banner "New Device Monitor" "v$VERSION on $model"
    echo
    menu_dashboard
    echo "------------------------------------------------------------------"
}

mi() { printf '  %s) %s\n' "$1" "$2"; }

menu_confirm() {
    printf '%s (y/N): ' "$1"
    read -r a || return 1
    case "$a" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

menu_forget() {
    printf '\nNumber or MAC address to forget (Enter = cancel): '
    read -r sel || return
    [ -z "$sel" ] && return
    mac="$(resolve_device "$sel")"
    if [ -z "$mac" ] || ! is_known "$mac"; then echo "Invalid choice."; pause_enter; return; fi
    if menu_confirm "Forget this device (it will be reported again)?"; then
        cmd_forget "$mac"
        pause_enter
    fi
}

# Detail screen of one device, with actions.
menu_device_detail() {
    new_screen
    cmd_detail "$1" || { pause_enter; return; }
    mac="$(resolve_device "$1")"
    echo
    printf '  s) Scan common ports\n  f) Forget this device (report it again)\n  Enter) Back\n\n  Choice: '
    read -r act || return
    case "$act" in
        s|S)
            echo
            cmd_portscan "$mac"
            pause_enter ;;
        f|F)
            if menu_confirm "Forget this device?"; then
                cmd_forget "$mac"
                pause_enter
            fi ;;
    esac
}

# List of known devices, with details and forget at the bottom.
menu_devices() {
    msg=""
    while true; do
        new_screen
        cmd_list
        [ -n "$msg" ] && printf '\n  %s\n' "$msg"
        msg=""
        [ -s "$KNOWN" ] || { pause_enter; return; }
        printf '\n  Number or MAC address = details\n  c) Check for new devices now (refreshes the list)\n  f) Forget a device\n  Enter) Back\n\n  Choice: '
        read -r sel || return
        case "$sel" in
            "") return ;;
            c|C)
                IGNORE_MAIL_PAUSE=1
                cmd_run >/dev/null 2>&1
                IGNORE_MAIL_PAUSE=0
                if [ "$NEW_COUNT" -eq 0 ]; then
                    msg="Check done: no new devices."
                elif [ "$SENT_OK" -eq 1 ]; then
                    msg="Check done: reported $NEW_COUNT new device(s)."
                else
                    msg="Check done: $NEW_COUNT new, but the email was not sent (see the log)."
                fi ;;
            f|F) menu_forget ;;
            *) menu_device_detail "$sel" ;;
        esac
    done
}

menu_interval() {
    echo "Current interval: $INTERVAL min"
    printf 'New interval in minutes (1-59, empty = cancel): '
    read -r n || return
    [ -z "$n" ] && return
    case "$n" in
        *[!0-9]*) echo "Not a valid number."; return ;;
    esac
    if [ "$n" -lt 1 ] || [ "$n" -gt 59 ]; then
        echo "Choose a value between 1 and 59."
        return
    fi
    INTERVAL="$n"
    save_conf
    log "Interval set to $INTERVAL min."
    if cron_active; then
        cmd_cron
        echo "Cron job updated."
    else
        echo "Saved. The cron job is not active yet; use Settings > i to install it."
    fi
}

menu_update_mail() {
    if [ "$UPDATE_MAIL" = "1" ]; then UPDATE_MAIL=0; txt="off"; else UPDATE_MAIL=1; txt="on"; fi
    save_conf
    log "Email for new versions: $txt."
    echo "Email for new versions is now $txt."
}

menu_settings() {
    EXIT_MENU=0
    while true; do
        menu_header
        printf '  %sSettings and maintenance%s\n\n' "$C_B" "$C_X"
        if [ "$UPDATE_MAIL" = "1" ]; then um="on"; else um="off"; fi
        ouip="$(oui_path)"
        if [ -n "$ouip" ]; then
            case "$ouip" in "$OUI_USB") where="USB" ;; *) where="flash" ;; esac
            oui_state="$(wc -l < "$ouip") entries, on $where"
        else
            oui_state="not downloaded"
        fi
        mi f "Check frequency (now: every $INTERVAL min)"
        mi n "Notify me by email about new versions (now: $um)"
        mi m "Mark all connected devices as known (no email is sent)"
        mi o "Download the vendor list ($oui_state)"
        mi l "Read the log"
        mi t "Send a test email"
        mi u "Update (check and install)"
        mi p "Restore the previous version"
        mi i "Install cron jobs and startup hook"
        mi r "Remove cron jobs and startup hook"
        printf '  Enter) Back\n'
        echo
        printf '  Choice: '
        read -r sc || return
        case "$sc" in ""|b|B) ;; *) new_screen ;; esac
        case "$sc" in
            f|F) menu_interval; pause_enter ;;
            n|N) menu_update_mail; pause_enter ;;
            m|M)
                if menu_confirm "Mark all currently connected devices as known without a notification?"; then
                    cmd_baseline
                fi
                pause_enter ;;
            o|O) cmd_oui_update; pause_enter ;;
            l|L) cmd_log 40; pause_enter ;;
            t|T)
                echo "Sending test email..."
                cmd_test && echo "Test email sent. Check your inbox."
                pause_enter ;;
            u|U)
                UPDATED=0
                cmd_update
                pause_enter
                [ "$UPDATED" = "1" ] && EXIT_MENU=1 && return ;;
            p|P)
                cmd_rollback
                pause_enter
                [ "$UPDATED" = "1" ] && EXIT_MENU=1 && return ;;
            i|I) cmd_install; pause_enter ;;
            r|R)
                if menu_confirm "Remove the cron jobs and the startup hook?"; then
                    cmd_uninstall
                fi
                pause_enter ;;
            b|B|"") return ;;
            *) echo "Unknown choice."; pause_enter ;;
        esac
    done
}

cmd_menu() {
    mkdir -p "$DATA_DIR"
    [ -f "$KNOWN" ] || : > "$KNOWN"
    while true; do
        menu_header
        mi 1 "Check for new devices now"
        mi 2 "Devices (list, check, details, forget)"
        mi s "Settings and maintenance"
        mi e "Exit (back to amtm)"
        echo
        printf '  Choice: '
        read -r choice || break
        case "$choice" in 2|s|S|e|E|q|Q|0|"") ;; *) new_screen ;; esac
        case "$choice" in
            1)
                IGNORE_MAIL_PAUSE=1
                cmd_run
                IGNORE_MAIL_PAUSE=0
                if [ "$NEW_COUNT" -eq 0 ]; then
                    echo "Check done: no new devices."
                elif [ "$SENT_OK" -eq 1 ]; then
                    echo "Check done: reported $NEW_COUNT new device(s)."
                else
                    echo "Check done: $NEW_COUNT new, but the email was not sent (see the log)."
                fi
                pause_enter ;;
            2) menu_devices ;;
            s|S) menu_settings; [ "$EXIT_MENU" = "1" ] && break ;;
            e|E|q|Q|0) break ;;
            "") ;;
            *) echo "Unknown choice."; pause_enter ;;
        esac
    done
    clear 2>/dev/null
    printf '\n\n'
    banner "Thanks for using New Device Monitor" "v$VERSION - see you next time!"
    printf '\n'
    # Short pause so the screen is visible before amtm redraws (interactive only).
    [ -t 1 ] && sleep 2
}

###############################################################################
case "$1" in
    run)       cmd_run ;;
    cron)      cmd_cron ;;
    baseline)  cmd_baseline ;;
    test)      cmd_test ;;
    list)      cmd_list ;;
    detail)    cmd_detail "$2" ;;
    debug)     cmd_debug "$2" ;;
    portscan)  cmd_portscan "$2" ;;
    oui-update) cmd_oui_update ;;
    log)       cmd_log "$2" ;;
    forget)    cmd_forget "$2" ;;
    install)   cmd_install ;;
    uninstall) cmd_uninstall ;;
    update-check) cmd_update_check ;;
    update)    cmd_update "$2" ;;
    rollback)  cmd_rollback ;;
    menu)      cmd_menu ;;
    "")
        if [ -t 0 ] && [ -t 1 ]; then cmd_menu; else cmd_status; fi ;;
    status|help|-h|--help) cmd_status ;;
    *)         echo "Unknown command: $1"; cmd_status; exit 1 ;;
esac
