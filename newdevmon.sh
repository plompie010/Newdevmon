#!/bin/sh
###############################################################################
# newdevmon - meldt per e-mail wanneer een nieuw apparaat het netwerk op komt
#
# Voor Asuswrt-Merlin. Gebruikt de e-mailinstellingen van amtm (amtm > em).
# Controleert periodiek (cron) de DHCP-leases en de ARP-tabel van alle
# LAN-bridges: br0 = hoofdnetwerk, br1/br2/... = gastnetwerken.
# Een apparaat telt als "nieuw" zolang het MAC-adres niet in de lijst met
# bekende apparaten staat. Nieuwe apparaten uit een controle komen samen in
# één e-mail.
#
# Zonder argumenten in een SSH-sessie (bijvoorbeeld vanuit amtm, optie p)
# opent het menu. Voor gebruik in scripts/cron:
#   newdevmon.sh [menu|run|cron|install|uninstall|baseline|test|list|detail NR|MAC|log|forget MAC]
#   newdevmon.sh [update-check|update [-y]|rollback]
#
# Updates: het script controleert dagelijks of er in de GitHub-repo
# plompie010/Newdevmon een nieuwere VERSION staat. Verhoog bij elke wijziging
# die je in de repo zet het VERSION-nummer hieronder, anders ziet het script de
# nieuwe versie niet als nieuwer.
#
# Copyright (C) 2026 plompie010
#
# Dit programma is vrije software: je mag het verspreiden en/of aanpassen onder
# de voorwaarden van de GNU General Public License, zoals gepubliceerd door de
# Free Software Foundation, versie 3 van de licentie of (naar keuze) een latere
# versie.
#
# Dit programma wordt verspreid in de hoop dat het nuttig is, maar ZONDER ENIGE
# GARANTIE; zelfs zonder de impliciete garantie van VERKOOPBAARHEID of
# GESCHIKTHEID VOOR EEN BEPAALD DOEL. Zie de GNU General Public License voor
# meer details. Je hoort een kopie van de GPL te hebben ontvangen bij dit
# programma; zo niet, zie <https://www.gnu.org/licenses/>.
###############################################################################

VERSION="0.1.2"
SCRIPT_NAME="newdevmon"
SCRIPT_PATH="${NEWDEVMON_SCRIPT_PATH:-/jffs/scripts/newdevmon.sh}"
DATA_DIR="${NEWDEVMON_DIR:-/jffs/addons/newdevmon}"
KNOWN="$DATA_DIR/known_devices.txt"          # mac|eerste_keer|ip|naam|netwerk
CONF="$DATA_DIR/newdevmon.conf"
LOGFILE="$DATA_DIR/newdevmon.log"
LEASES="${NEWDEVMON_LEASES:-/var/lib/misc/dnsmasq.leases}"
ARPFILE="${NEWDEVMON_ARP:-/proc/net/arp}"
EMAIL_DIR="${NEWDEVMON_EMAIL_DIR:-/jffs/addons/amtm/mail}"
AMTM_PW_KEY="ditbabot,isoi"                  # sleutel waarmee amtm emailpw.enc versleutelt (zie /jffs/addons/amtm/email.mod)
LOCKDIR="/tmp/${SCRIPT_NAME}.lock"
DRY_RUN="${NEWDEVMON_DRY_RUN:-0}"            # 1 = mail op scherm tonen, niet versturen
TMPBASE="/tmp/${SCRIPT_NAME}.$$"

UPDATE_FLAG="$DATA_DIR/update_available"     # bevat het nummer van een gevonden nieuwere versie

# Instellingen (worden via het menu in $CONF bewaard)
INTERVAL=1                                   # minuten tussen controles
UPDATE_MAIL=0                                # 1 = mail bij nieuwe versie
[ -f "$CONF" ] && . "$CONF"

# Update-bron: vast ingesteld en bewust niet via config of menu te wijzigen.
UPDATE_REPO="plompie010/Newdevmon"
UPDATE_BRANCH="main"
UPDATE_FILE="newdevmon.sh"
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=1 ;; esac
[ "$INTERVAL" -lt 1 ] && INTERVAL=1
[ "$INTERVAL" -gt 59 ] && INTERVAL=59

# Vluchtige status in het RAM (/tmp), zodat de flash niet elke minuut beschreven wordt.
STATE_DIR="${NEWDEVMON_STATE_DIR:-/tmp}"
SEEN="$STATE_DIR/newdevmon.seen"             # mac|laatst_gezien_epoch|ip|naam|netwerk
LASTRUN="$STATE_DIR/newdevmon.lastrun"       # epoch van de laatste controle
PERSIST_TS="$STATE_DIR/newdevmon.persist"    # epoch van de laatste opslag naar JFFS
NMP_FILE="${NEWDEVMON_NMP:-/jffs/nmp_cl_json.js}"   # clientlijst van Asus (netwerkoverzicht)

# Kleuren alleen in een terminal (niet in cron, logs of mail).
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

# awk-hulpfuncties die in meerdere overzichten gebruikt worden.
AWK_FN='
function label(d) {
    if (d == "br0") return "Hoofdnetwerk"
    if (d ~ /^br/) return "Gastnetwerk (" d ")"
    if (d == "") return "Onbekend netwerk"
    return "Netwerk (" d ")"
}
function trunc(s, n) { return (length(s) > n) ? substr(s, 1, n - 1) "~" : s }
function ago(ep, now,   d) {
    if (ep <= 0) return "-"
    d = now - ep; if (d < 0) d = 0
    if (d < 3600) return int(d / 60) " min geleden"
    if (d < 86400) return int(d / 3600) " u geleden"
    return int(d / 86400) " d geleden"
}
'

###############################################################################
# Hulpfuncties
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

# Geeft regels "mac|ip|naam|interface" voor alle nu bekende apparaten.
scan() {
    {
        [ -r "$LEASES" ] && awk 'NF>=4 { h=$4; if (h=="*") h=""; print tolower($2) "|" $3 "|" h "|" }' "$LEASES"
        [ -r "$ARPFILE" ] && awk 'NR>1 && ($3=="0x2" || $3=="0x6") && $4!="00:00:00:00:00:00" && $6 ~ /^br/ { print tolower($4) "|" $1 "||" $6 }' "$ARPFILE"
    } | awk -F'|' '
        $1 ~ /^[0-9a-f:]+$/ && length($1)==17 {
            m = $1
            if (!(m in seen)) { seen[m] = 1; order[++n] = m }
            if ($2 != "") ip[m]   = $2
            if ($3 != "") host[m] = $3
            if ($4 != "") dev[m]  = $4
        }
        END { for (i = 1; i <= n; i++) { m = order[i]; print m "|" ip[m] "|" host[m] "|" dev[m] } }'
}

# Zelfde als scan, maar met de interface ingevuld en gesorteerd op netwerk
# (hoofdnetwerk eerst, daarna gastnetwerken) en daarbinnen op IP-adres.
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
        br0) echo "Hoofdnetwerk" ;;
        br*) echo "Gastnetwerk ($1)" ;;
        "")  echo "Onbekend netwerk" ;;
        *)   echo "Netwerk ($1)" ;;
    esac
}

# Prive/willekeurige MAC (iPhone, Android, Windows): tweede hexcijfer is 2, 6, a of e.
is_random_mac() {
    case "$(echo "$1" | cut -c2)" in
        2|6|a|e) return 0 ;;
        *) return 1 ;;
    esac
}

known_count() { if [ -f "$KNOWN" ]; then wc -l < "$KNOWN"; else echo 0; fi; }

is_known() { grep -qi "^${1}|" "$KNOWN" 2>/dev/null; }

# Apparaten die Asus zelf als online ziet (netwerkoverzicht), als kleine letters.
# Geeft niets en returncode 1 als het bestand ontbreekt.
online_macs() {
    [ -r "$NMP_FILE" ] || return 1
    grep -Eo '"mac":"[0-9A-Fa-f:]{17}"[^{}]*"online":[01]' "$NMP_FILE" \
        | sed -n 's/^"mac":"\([^"]*\)".*"online":1$/\1/p' | tr 'A-F' 'a-f'
    return 0
}

# update_seen SCANBESTAND: bewaart per apparaat wanneer het voor het laatst online was.
# Bron voor "online": de clientlijst van Asus. Ontbreekt die, dan geldt alles wat in
# de leases of ARP-tabel staat als gezien (minder nauwkeurig).
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
            if (l != "Onbekend netwerk" || lb[$1] == "") lb[$1] = l
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

# Schrijft de laatst-gezien-gegevens uit het RAM terug naar het bestand met bekende
# apparaten. Alleen als er iets veranderd is, om de flash te sparen.
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

# seen_epoch MAC: laatst-gezien-epoch uit het RAM, of 0.
seen_epoch() {
    e="$(grep -i "^${1}|" "$SEEN" 2>/dev/null | head -n 1 | cut -d'|' -f2)"
    case "$e" in ''|*[!0-9]*) e=0 ;; esac
    echo "$e"
}

# Bekende apparaten gecombineerd met de laatst-gezien-gegevens uit het RAM.
# Velden: g|netwerk|ipsleutel|regelnr|mac|eerst|ip|naam|netwerk|laatst_epoch|online
joined_known() {
    [ -f "$SEEN" ] || : > "$SEEN"
    awk -F'|' -v now="$(date +%s)" -v win="$((INTERVAL * 120 + 30))" '
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
            g = (lb ~ /^Hoofd/) ? 0 : ((lb ~ /^Gast/) ? 1 : 2)
            printf "%d|%s|%03d%03d%03d%03d|%d|%s|%s|%s|%s|%s|%d|%d\n", g, lb, o[1], o[2], o[3], o[4], FNR, m, $2, ip, nm, lb, ls, online
        }
    ' "$SEEN" "$KNOWN"
}

cron_active() { cru l 2>/dev/null | grep -q "$SCRIPT_NAME"; }

mail_configured() { [ -f "$EMAIL_DIR/email.conf" ]; }

###############################################################################
# E-mail via de amtm-instellingen
###############################################################################

# send_mail "onderwerp" "bestand met tekst"
send_mail() {
    subject="$1"
    bodyfile="$2"

    if [ "$DRY_RUN" = "1" ]; then
        echo "----- DRY RUN: onderwerp: $subject -----"
        cat "$bodyfile"
        echo "----- einde -----"
        return 0
    fi

    if ! mail_configured; then
        log "amtm e-mailinstellingen ontbreken ($EMAIL_DIR/email.conf). Stel ze in via amtm > em."
        return 1
    fi

    # shellcheck disable=SC1090
    . "$EMAIL_DIR/email.conf"

    pw="$(/usr/sbin/openssl aes-256-cbc $emailPwEnc -d -in "$EMAIL_DIR/emailpw.enc" -pass "pass:$AMTM_PW_KEY" 2>/dev/null)"
    if [ -z "$pw" ]; then
        log "Kon het e-mailwachtwoord uit amtm niet lezen."
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

    # Zelfde curl-aanroep als amtm zelf gebruikt (--user). Het wachtwoord staat
    # daardoor kort in de proceslijst, net als bij amtm.
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
        log "Versturen mislukt (curl exit $rc): $(tr '\n' ' ' < "$TMPBASE.curlerr")"
    fi
    return $rc
}

###############################################################################
# Kernfuncties
###############################################################################

# Eén controle. Zet NEW_COUNT en SENT_OK voor het menu.
cmd_run() {
    NEW_COUNT=0
    SENT_OK=1
    lock || return 0
    trap cleanup EXIT INT TERM
    mkdir -p "$DATA_DIR"
    touch "$KNOWN"

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
        name="${host:-onbekend}"
        seen="$(now)"

        echo "${mac}|${seen}|${ip}|${name}|${label}|$(seen_epoch "$mac")" >> "$pending"

        {
            echo "Naam:      $name"
            if is_random_mac "$mac"; then
                echo "MAC:       $mac (privé/willekeurig adres)"
            else
                echo "MAC:       $mac"
            fi
            echo "IP:        ${ip:-onbekend}"
            echo "Netwerk:   $label"
            echo "Gezien op: $seen"
            echo
        } >> "$body"
        count=$((count + 1))
    done < "$scanfile"

    NEW_COUNT=$count
    if [ "$count" -gt 0 ]; then
        {
            if [ "$count" -eq 1 ]; then
                echo "Er is 1 nieuw apparaat verbonden met je netwerk:"
            else
                echo "Er zijn $count nieuwe apparaten verbonden met je netwerk:"
            fi
            echo
            cat "$body"
            echo "Onbekend apparaat? Controleer het in de router of verander het wifi-wachtwoord."
            echo "Een apparaat uit deze lijst wordt na deze melding als bekend beschouwd."
        } > "$TMPBASE.final"

        if send_mail "[Router] Nieuw apparaat op het netwerk ($count)" "$TMPBASE.final"; then
            cat "$pending" >> "$KNOWN"
            log "$count nieuw(e) apparaat/apparaten gemeld: $(cut -d'|' -f1,4 "$pending" | tr '\n' ' ')"
        else
            SENT_OK=0
            log "Melding niet verstuurd; $count apparaat/apparaten blijven 'nieuw' en worden de volgende run opnieuw geprobeerd."
        fi
    fi

    persist_seen_if_due

    cleanup
    trap - EXIT INT TERM
}

cmd_baseline() {
    mkdir -p "$DATA_DIR"
    touch "$KNOWN"
    n=0
    scan_sorted > "$TMPBASE.scan"
    update_seen "$TMPBASE.scan"
    while IFS='|' read -r mac ip host dev; do
        [ -z "$mac" ] && continue
        is_known "$mac" && continue
        iface="$dev"
        [ -z "$iface" ] && [ -n "$ip" ] && iface="$(iface_for_ip "$ip")"
        echo "${mac}|$(now)|${ip}|${host:-onbekend}|$(label_for_iface "$iface")|$(seen_epoch "$mac")" >> "$KNOWN"
        n=$((n + 1))
    done < "$TMPBASE.scan"
    log "Baseline: $n apparaat/apparaten als bekend toegevoegd."
    echo "Totaal bekend: $(wc -l < "$KNOWN")."
    rm -f "$TMPBASE".*
}

cmd_test() {
    printf 'Dit is een testmelding van %s.\nAls je dit leest, werken de amtm e-mailinstellingen.\n' "$SCRIPT_NAME" > "$TMPBASE.test"
    if send_mail "[Router] Testmelding newdevmon" "$TMPBASE.test"; then
        log "Testmail verstuurd."
        rc=0
    else
        echo "Testmail mislukt. Zie het log voor de reden."
        rc=1
    fi
    rm -f "$TMPBASE".*
    return $rc
}

cmd_list() {
    if [ ! -s "$KNOWN" ]; then
        echo "Nog geen bekende apparaten."
        return
    fi
    # Per netwerk gegroepeerd (hoofdnetwerk eerst), binnen een netwerk op IP-adres.
    # Het nummer (#) blijft het regelnummer in het bestand.
    joined_known | sort -t'|' -k1,1n -k2,2 -k3,3 | awk -F'|' \
        -v now="$(date +%s)" -v G="$C_G" -v D="$C_D" -v B="$C_B" -v X="$C_X" "$AWK_FN"'
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
                    printf "%s== %s ==%s  %d apparaten, %d online\n", B, lab, X, tot[lab], on[lab] + 0
                    printf "%s%-3s %-16s %-15s %-17s %-10s %s%s\n", D, "#", "Naam", "IP", "MAC", "Eerst", "Laatst gezien", X
                    prev = lab
                }
                if (f[11] == 1) last = G "online" X
                else last = ago(f[10], now)
                printf "%-3d %-16s %-15s %-17s %-10s %s\n", f[4], trunc(f[8], 16), f[7], f[5], substr(f[6], 1, 10), last
            }
        }'
}

cmd_connected() {
    scan_sorted > "$TMPBASE.scan"
    if [ ! -s "$TMPBASE.scan" ]; then
        echo "Geen verbonden apparaten gevonden."
        rm -f "$TMPBASE".*
        return
    fi
    [ -f "$KNOWN" ] || : > "$KNOWN"
    awk -F'|' -v R="$C_R" -v D="$C_D" -v B="$C_B" -v X="$C_X" "$AWK_FN"'
        FILENAME == ARGV[1] { fs[$1] = substr($2, 1, 10); next }
        {
            lab = label($4)
            if (lab != prev) {
                if (prev != "") print ""
                printf "%s== %s ==%s\n", B, lab, X
                printf "%s%-16s %-15s %-17s %s%s\n", D, "Naam", "IP", "MAC", "Eerst gezien", X
                prev = lab
            }
            if ($1 in fs) st = fs[$1]; else { st = R "NIEUW" X; nn++ }
            nm = ($3 == "") ? "onbekend" : $3
            printf "%-16s %-15s %-17s %s\n", trunc(nm, 16), ($2 == "" ? "-" : $2), $1, st
            n++
        }
        END { printf "\n%d apparaten in de leases/ARP-tabel, %d nieuw\n", n, nn + 0 }
    ' "$KNOWN" "$TMPBASE.scan"
    rm -f "$TMPBASE".*
}

# resolve_device NR_OF_MAC: geeft het MAC-adres bij een nummer uit de lijst (of het MAC zelf).
resolve_device() {
    case "$1" in
        '') return 0 ;;
        *[!0-9]*) echo "$1" | tr 'A-F' 'a-f' ;;
        *) [ "$1" -ge 1 ] && sed -n "${1}p" "$KNOWN" | cut -d'|' -f1 ;;
    esac
}

# Alle bekende gegevens van één apparaat.
cmd_detail() {
    dmac="$(resolve_device "$1")"
    if [ -z "$dmac" ] || ! is_known "$dmac"; then
        echo "Apparaat niet gevonden: ${1:-(geen invoer)}"
        return 1
    fi
    joined_known | awk -F'|' -v m="$dmac" -v now="$(date +%s)" \
        -v G="$C_G" -v R="$C_R" -v D="$C_D" -v B="$C_B" -v X="$C_X" "$AWK_FN"'
        $5 == m {
            nm = ($8 == "") ? "onbekend" : $8
            priv = (substr($5, 2, 1) ~ /[26ae]/)
            printf "%s== %s ==%s\n\n", B, nm, X
            printf "  %-15s %s\n", "Naam:", nm
            printf "  %-15s %s%s\n", "MAC-adres:", $5, (priv ? "  (privé/willekeurig adres)" : "")
            printf "  %-15s %s\n", "IP-adres:", ($7 == "" ? "onbekend" : $7)
            printf "  %-15s %s\n", "Netwerk:", $9
            if ($11 == 1) st = G "online" X; else st = R "offline" X
            printf "  %-15s %s\n", "Status:", st
            if ($10 + 0 > 0) ls = ($11 == 1) ? "nu" : ago($10, now); else ls = "nog niet online gezien"
            printf "  %-15s %s\n", "Laatst gezien:", ls
            printf "  %-15s %s\n", "Bekend sinds:", $6
            printf "  %-15s %d\n", "Nr. in lijst:", $4
            if (priv) printf "\n  %sEen privé-adres kan per netwerk of na een reset veranderen.\n  Hetzelfde apparaat verschijnt dan opnieuw als nieuw.%s\n", D, X
        }'
}

cmd_log() {
    n="${1:-40}"
    if [ -s "$LOGFILE" ]; then
        tail -n "$n" "$LOGFILE"
    else
        echo "Het log is nog leeg."
    fi
}

cmd_forget() {
    mac="$(echo "$1" | tr 'A-F' 'a-f')"
    [ -z "$mac" ] && { echo "Gebruik: $0 forget MAC-adres"; return 1; }
    if ! is_known "$mac"; then
        echo "$mac staat niet in de lijst."
        return 1
    fi
    grep -vi "^${mac}|" "$KNOWN" > "$TMPBASE.known"
    cat "$TMPBASE.known" > "$KNOWN"
    rm -f "$TMPBASE".*
    log "Vergeten: $mac (wordt bij de volgende controle opnieuw gemeld als hij verbonden is)."
}

# Zet de cronjob volgens het ingestelde interval (ook aangeroepen door services-start).
cmd_cron() {
    if [ "$INTERVAL" -le 1 ]; then
        expr="* * * * *"
    else
        expr="*/$INTERVAL * * * *"
    fi
    cru d "$SCRIPT_NAME" 2>/dev/null
    cru a "$SCRIPT_NAME" "$expr $SCRIPT_PATH run"

    # Dagelijkse update-check.
    cru d "${SCRIPT_NAME}-update" 2>/dev/null
    cru a "${SCRIPT_NAME}-update" "23 5 * * * $SCRIPT_PATH update-check"
}

cmd_install() {
    mkdir -p "$DATA_DIR" /jffs/scripts
    self="$(readlink -f "$0" 2>/dev/null)"
    if [ "$self" != "$SCRIPT_PATH" ]; then
        cp "$0" "$SCRIPT_PATH" || { echo "Kopiëren naar $SCRIPT_PATH mislukt."; return 1; }
    fi
    chmod 755 "$SCRIPT_PATH"

    cmd_cron

    hook="/jffs/scripts/services-start"
    [ -f "$hook" ] || printf '#!/bin/sh\n' > "$hook"
    chmod 755 "$hook"
    # Oude regels vervangen, ook die van een eerdere bestandsnaam (bijv. newdevmon.sh).
    sed -i "/$SCRIPT_NAME/d" "$hook"
    printf '%s cron # %s\n' "$SCRIPT_PATH" "$SCRIPT_NAME" >> "$hook"

    log "Geïnstalleerd: cronjob (elke $INTERVAL min) + opstarthook in $hook."
}

cmd_uninstall() {
    cru d "$SCRIPT_NAME" 2>/dev/null
    cru d "${SCRIPT_NAME}-update" 2>/dev/null
    [ -f /jffs/scripts/services-start ] && sed -i "/$SCRIPT_NAME/d" /jffs/scripts/services-start
    log "Cronjob en opstarthook verwijderd. Data blijft staan in $DATA_DIR."
}

###############################################################################
# Updates via GitHub
###############################################################################

save_conf() {
    mkdir -p "$DATA_DIR"
    {
        echo "INTERVAL=$INTERVAL"
        echo "UPDATE_MAIL=$UPDATE_MAIL"
    } > "$CONF"
}

update_url() {
    # NEWDEVMON_TEST_UPDATE_URL is alleen bedoeld voor tests (bijv. file://...).
    echo "${NEWDEVMON_TEST_UPDATE_URL:-https://raw.githubusercontent.com/${UPDATE_REPO}/${UPDATE_BRANCH}/${UPDATE_FILE}}"
}

# ver_gt A B: geslaagd (0) als versie A nieuwer is dan versie B (formaat x.y.z)
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

# fetch_remote BESTAND: download het script uit de repo naar BESTAND.
fetch_remote() {
    CURL_BIN="curl"
    [ -x /usr/sbin/curl ] && CURL_BIN="/usr/sbin/curl"
    if ! "$CURL_BIN" -fsSL --max-time 30 --retry 2 "$(update_url)" -o "$1" 2>"$TMPBASE.fetcherr"; then
        log "Update-check mislukt: $(tr '\n' ' ' < "$TMPBASE.fetcherr")"
        echo "Downloaden mislukt (zie log). Controleer de internetverbinding van de router."
        return 1
    fi
    return 0
}

# validate_remote BESTAND: controleert of het gedownloade bestand echt dit script is.
validate_remote() {
    head -n 1 "$1" | grep -q '^#!/bin/sh' || { echo "Het gedownloade bestand lijkt geen shellscript."; return 1; }
    grep -q "^SCRIPT_NAME=\"$SCRIPT_NAME\"" "$1" || { echo "Het gedownloade bestand is niet $SCRIPT_NAME."; return 1; }
    sh -n "$1" 2>/dev/null || { echo "Het gedownloade script heeft een syntaxfout."; return 1; }
    [ -n "$(remote_version "$1")" ] || { echo "Geen versienummer gevonden in het gedownloade bestand."; return 1; }
    return 0
}

# Draait dagelijks via cron. Zet een vlag en meldt (optioneel per mail) bij een nieuwe versie.
cmd_update_check() {
    mkdir -p "$DATA_DIR"
    fetch_remote "$TMPBASE.remote" || { rm -f "$TMPBASE".*; return 1; }
    if ! validate_remote "$TMPBASE.remote"; then
        log "Update-check: ongeldig bestand in de repo, niet gebruikt."
        rm -f "$TMPBASE".*
        return 1
    fi
    rv="$(remote_version "$TMPBASE.remote")"
    if ver_gt "$rv" "$VERSION"; then
        echo "$rv" > "$UPDATE_FLAG"
        echo "Nieuwe versie beschikbaar: $rv (jij hebt $VERSION)."
        if [ "$(cat "$DATA_DIR/update_notified" 2>/dev/null)" != "$rv" ]; then
            log "Nieuwe versie beschikbaar: $rv (huidig $VERSION)."
            if [ "$UPDATE_MAIL" = "1" ]; then
                {
                    echo "Er is een nieuwe versie van $SCRIPT_NAME beschikbaar: $rv (geïnstalleerd: $VERSION)."
                    echo
                    echo "Installeren: open het script via amtm (p) en kies 9, of draai:"
                    echo "  $SCRIPT_PATH update"
                } > "$TMPBASE.updmail"
                send_mail "[Router] $SCRIPT_NAME update beschikbaar ($rv)" "$TMPBASE.updmail" && echo "$rv" > "$DATA_DIR/update_notified"
            else
                echo "$rv" > "$DATA_DIR/update_notified"
            fi
        fi
    else
        rm -f "$UPDATE_FLAG"
        echo "Je hebt de nieuwste versie ($VERSION)."
    fi
    rm -f "$TMPBASE".*
}

# Controleert op een nieuwere versie en installeert die na bevestiging (of met -y).
cmd_update() {
    UPDATED=0
    mkdir -p "$DATA_DIR"
    fetch_remote "$TMPBASE.remote" || { rm -f "$TMPBASE".*; return 1; }
    validate_remote "$TMPBASE.remote" || { rm -f "$TMPBASE".*; return 1; }
    rv="$(remote_version "$TMPBASE.remote")"

    if ! ver_gt "$rv" "$VERSION"; then
        echo "Je hebt de nieuwste versie ($VERSION); in de repo staat $rv."
        rm -f "$UPDATE_FLAG"
        rm -f "$TMPBASE".*
        return 0
    fi

    changed="$(diff "$SCRIPT_PATH" "$TMPBASE.remote" 2>/dev/null | grep -c '^[<>]')"
    echo "Update beschikbaar: $VERSION -> $rv (${changed:-0} regels gewijzigd)"
    echo "Bron: $(update_url)"
    if [ "$1" != "-y" ]; then
        if [ -t 0 ] && [ -t 1 ]; then
            menu_confirm "Nu installeren?" || { echo "Geannuleerd."; rm -f "$TMPBASE".*; return 0; }
        else
            echo "Niet-interactief: gebruik 'update -y' om te installeren."
            rm -f "$TMPBASE".*
            return 1
        fi
    fi

    mkdir -p "$DATA_DIR/backup"
    bk="$DATA_DIR/backup/${SCRIPT_NAME}-v${VERSION}-$(date +%Y%m%d%H%M%S)"
    cp "$SCRIPT_PATH" "$bk" || { log "Update afgebroken: backup maken mislukt."; rm -f "$TMPBASE".*; return 1; }
    # Houd de 3 nieuwste backups.
    ls -1t "$DATA_DIR/backup" | tail -n +4 | while read -r old; do rm -f "$DATA_DIR/backup/$old"; done

    # Via tijdelijk bestand + mv, zodat het draaiende script niet wordt overschreven.
    if cp "$TMPBASE.remote" "$SCRIPT_PATH.new" && chmod 755 "$SCRIPT_PATH.new" && mv "$SCRIPT_PATH.new" "$SCRIPT_PATH"; then
        rm -f "$UPDATE_FLAG" "$DATA_DIR/update_notified"
        log "Bijgewerkt van $VERSION naar $rv. Backup: $bk"
        echo "Bijgewerkt naar $rv. Start het script opnieuw om de nieuwe versie te gebruiken."
        UPDATED=1
    else
        rm -f "$SCRIPT_PATH.new"
        log "Update mislukt bij het vervangen van $SCRIPT_PATH; huidige versie is ongewijzigd."
        echo "Update mislukt; de huidige versie is ongewijzigd."
    fi
    rm -f "$TMPBASE".*
}

cmd_rollback() {
    latest="$(ls -1t "$DATA_DIR/backup" 2>/dev/null | head -n 1)"
    if [ -z "$latest" ]; then
        echo "Geen backups gevonden."
        return 1
    fi
    echo "Terugzetten naar backup: $latest"
    if [ -t 0 ] && [ -t 1 ]; then
        menu_confirm "Doorgaan?" || { echo "Geannuleerd."; return 0; }
    fi
    if cp "$DATA_DIR/backup/$latest" "$SCRIPT_PATH.new" && chmod 755 "$SCRIPT_PATH.new" && mv "$SCRIPT_PATH.new" "$SCRIPT_PATH"; then
        log "Teruggezet naar backup $latest."
        echo "Teruggezet. Start het script opnieuw."
        UPDATED=1
    else
        rm -f "$SCRIPT_PATH.new"
        echo "Terugzetten mislukt."
        return 1
    fi
}

cmd_status() {
    echo "newdevmon $VERSION - melding bij nieuwe apparaten"
    if [ -f "$UPDATE_FLAG" ]; then
        echo "Update:            versie $(cat "$UPDATE_FLAG") beschikbaar (draai: $SCRIPT_PATH update)"
    fi
    if cron_active; then
        echo "Cronjob:           actief (elke $INTERVAL min)"
    else
        echo "Cronjob:           NIET actief (draai: $SCRIPT_PATH install)"
    fi
    if mail_configured; then
        echo "amtm e-mail:       ingesteld"
    else
        echo "amtm e-mail:       NIET ingesteld (amtm > em)"
    fi
    echo "Bekende apparaten: $(known_count)"
    [ "$DRY_RUN" = "1" ] && echo "Modus:             DRY RUN (er wordt niets verstuurd)"
    echo
    echo "Opdrachten: menu | run | cron | install | uninstall | baseline | test | list | detail NR|MAC | log | forget MAC"
    echo "            update-check | update [-y] | rollback"
}

###############################################################################
# Menu
###############################################################################

pause_enter() { printf '\nDruk op Enter om verder te gaan... '; read -r _dummy || true; }

# Compact overzicht bovenaan het menu.
menu_dashboard() {
    if [ -s "$KNOWN" ]; then
        joined_known | sort -t'|' -k1,1n -k2,2 | awk -F'|' -v G="$C_G" -v D="$C_D" -v X="$C_X" '
            { lab = $9; if (!(lab in t)) ord[++n] = lab; t[lab]++; if ($11 == 1) o[lab]++ }
            END {
                for (i = 1; i <= n; i++) {
                    lab = ord[i]
                    c = (o[lab] > 0) ? G : D
                    printf "  %-20s %3d bekend, %s%3d online%s\n", lab, t[lab], c, o[lab] + 0, X
                }
            }'
        tail -n 1 "$KNOWN" | awk -F'|' -v D="$C_D" -v X="$C_X" '
            { nm = ($4 == "") ? "onbekend" : $4
              printf "  %sNieuwste:%s  %s (%s), %s\n", D, X, nm, $5, substr($2, 1, 16) }'
    else
        echo "  Nog geen bekende apparaten."
    fi

    now_ep="$(date +%s)"
    last="$(cat "$LASTRUN" 2>/dev/null)"
    case "$last" in ''|*[!0-9]*) last="" ;; esac
    if cron_active; then
        if [ -z "$last" ]; then
            ctl="${C_G}actief${C_X}, elke $INTERVAL min; nog niet gedraaid"
        else
            age=$(( (now_ep - last) / 60 ))
            limit=$(( INTERVAL * 3 )); [ "$limit" -lt 5 ] && limit=5
            if [ "$age" -gt "$limit" ]; then
                ctl="${C_R}laatste controle $age min geleden${C_X}"
            else
                ctl="${C_G}actief${C_X}, elke $INTERVAL min; laatste $age min geleden"
            fi
        fi
    else
        ctl="${C_R}NIET actief${C_X} (kies i)"
    fi
    if mail_configured; then mail_txt="${C_G}ingesteld${C_X}"; else mail_txt="${C_R}NIET ingesteld${C_X} (amtm > em)"; fi
    printf '  %sControle:%s  %s\n' "$C_D" "$C_X" "$ctl"
    printf '  %sAmtm mail:%s %s\n' "$C_D" "$C_X" "$mail_txt"
    [ "$DRY_RUN" = "1" ] && printf '  %sModus:%s     DRY RUN\n' "$C_D" "$C_X"
    if [ -f "$UPDATE_FLAG" ]; then
        printf '  %s** UPDATE BESCHIKBAAR: %s (kies 9) **%s\n' "$C_Y" "$(cat "$UPDATE_FLAG")" "$C_X"
    fi
}

menu_header() {
    clear 2>/dev/null
    echo "=============================================================="
    printf '  %snewdevmon %s%s - nieuwe apparaten melden\n' "$C_B" "$VERSION" "$C_X"
    echo "=============================================================="
    menu_dashboard
    echo "--------------------------------------------------------------"
}

menu_update_mail() {
    if [ "$UPDATE_MAIL" = "1" ]; then UPDATE_MAIL=0; txt="uit"; else UPDATE_MAIL=1; txt="aan"; fi
    save_conf
    log "Mail bij nieuwe versie: $txt."
    echo "Mail bij nieuwe versie staat nu $txt."
}

# Detailscherm van één apparaat met acties.
menu_device_detail() {
    clear 2>/dev/null
    cmd_detail "$1" || { pause_enter; return; }
    mac="$(resolve_device "$1")"
    echo
    printf '  v) Vergeten (opnieuw laten melden)    Enter) terug: '
    read -r act || return
    case "$act" in
        v|V)
            if menu_confirm "Dit apparaat vergeten?"; then
                cmd_forget "$mac"
                pause_enter
            fi ;;
    esac
}

# Lijst met bekende apparaten, met keuze voor details.
menu_devices() {
    while true; do
        clear 2>/dev/null
        cmd_list
        [ -s "$KNOWN" ] || { pause_enter; return; }
        printf '\nNummer of MAC-adres voor details (Enter = terug): '
        read -r sel || return
        [ -z "$sel" ] && return
        menu_device_detail "$sel"
    done
}

menu_forget() {
    cmd_list
    [ -s "$KNOWN" ] || return
    printf '\nNummer of MAC-adres om te vergeten (leeg = annuleren): '
    read -r sel || return
    [ -z "$sel" ] && return
    mac="$(resolve_device "$sel")"
    [ -z "$mac" ] && { echo "Ongeldige keuze."; return; }
    cmd_forget "$mac"
}

menu_interval() {
    echo "Huidig interval: $INTERVAL min"
    printf 'Nieuw interval in minuten (1-59, leeg = annuleren): '
    read -r n || return
    [ -z "$n" ] && return
    case "$n" in
        *[!0-9]*) echo "Geen geldig getal."; return ;;
    esac
    if [ "$n" -lt 1 ] || [ "$n" -gt 59 ]; then
        echo "Kies een waarde tussen 1 en 59."
        return
    fi
    INTERVAL="$n"
    save_conf
    log "Interval ingesteld op $INTERVAL min."
    if cron_active; then
        cmd_cron
        echo "Cronjob bijgewerkt."
    else
        echo "Opgeslagen. De cronjob is nog niet actief; kies 'i' om te installeren."
    fi
}

menu_confirm() {
    printf '%s (j/N): ' "$1"
    read -r a || return 1
    case "$a" in j|J|y|Y) return 0 ;; *) return 1 ;; esac
}

cmd_menu() {
    mkdir -p "$DATA_DIR"
    touch "$KNOWN"
    while true; do
        menu_header
        if [ "$UPDATE_MAIL" = "1" ]; then um="aan"; else um="uit"; fi
        printf '  %-38s %s\n' "1) Controle nu uitvoeren"          "9) Controleren op updates"
        printf '  %-38s %s\n' "2) Verbonden apparaten tonen"      "g) Mail bij update aan/uit (nu: $um)"
        printf '  %-38s %s\n' "3) Bekende apparaten en details"   "r) Vorige versie terugzetten"
        printf '  %-38s %s\n' "4) Log lezen"                      "i) Installeren (cron + opstarthook)"
        printf '  %-38s %s\n' "5) Testmail versturen"             "u) Verwijderen (cron + opstarthook)"
        printf '  %-38s %s\n' "6) Alles nu verbonden als bekend"  "e) Afsluiten (terug naar amtm)"
        printf '  %-38s\n'    "7) Apparaat vergeten"
        printf '  %-38s\n'    "8) Controle-interval ($INTERVAL min)"
        echo
        printf '  Keuze: '
        read -r choice || break
        echo
        case "$choice" in
            1)
                cmd_run
                if [ "$NEW_COUNT" -eq 0 ]; then
                    echo "Controle klaar: geen nieuwe apparaten."
                elif [ "$SENT_OK" -eq 1 ]; then
                    echo "Controle klaar: $NEW_COUNT nieuw(e) apparaat/apparaten gemeld."
                else
                    echo "Controle klaar: $NEW_COUNT nieuw, maar de mail is niet verstuurd (zie log)."
                fi
                pause_enter ;;
            2) cmd_connected; pause_enter ;;
            3) menu_devices ;;
            4) cmd_log 40; pause_enter ;;
            5)
                echo "Testmail versturen..."
                cmd_test && echo "Testmail verstuurd. Controleer je inbox."
                pause_enter ;;
            6)
                if menu_confirm "Alle nu verbonden apparaten stil als bekend markeren?"; then
                    cmd_baseline
                fi
                pause_enter ;;
            7) menu_forget; pause_enter ;;
            8) menu_interval; pause_enter ;;
            9)
                UPDATED=0
                cmd_update
                pause_enter
                [ "$UPDATED" = "1" ] && break ;;
            g|G) menu_update_mail; pause_enter ;;
            r|R)
                UPDATED=0
                cmd_rollback
                pause_enter
                [ "$UPDATED" = "1" ] && break ;;
            i|I) cmd_install; pause_enter ;;
            u|U)
                if menu_confirm "Cronjob en opstarthook verwijderen?"; then
                    cmd_uninstall
                fi
                pause_enter ;;
            e|E|q|Q|0) break ;;
            "") ;;
            *) echo "Onbekende keuze."; pause_enter ;;
        esac
    done
    clear 2>/dev/null
}

###############################################################################
case "$1" in
    run)       cmd_run ;;
    cron)      cmd_cron ;;
    baseline)  cmd_baseline ;;
    test)      cmd_test ;;
    list)      cmd_list ;;
    detail)    cmd_detail "$2" ;;
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
    *)         echo "Onbekende opdracht: $1"; cmd_status; exit 1 ;;
esac
