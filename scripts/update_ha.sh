#!/bin/bash

# Interrompe subito se c'è un errore
set -e

# ==========================================
# ⬆️  UPDATE HOME ASSISTANT (immagine container)
# ==========================================
#
# Il quadlet usa il tag mobile ':stable' con AutoUpdate=registry, ma il timer
# podman-auto-update è disabilitato di proposito: un aggiornamento non presidiato
# di HA può rompere dashboard, card HACS e integrazioni custom senza preavviso.
# Questo script fa lo stesso lavoro in modo controllato e reversibile.
#
# Uso:
#   ./scripts/update_ha.sh                 pull + backup + riavvio + verifica
#   ./scripts/update_ha.sh -y              non chiede conferma
#   ./scripts/update_ha.sh --skip-backup   salta il backup (sconsigliato)
#   ./scripts/update_ha.sh --rollback      torna all'immagine precedente
#
# Il backup è quello nativo di HA (azione backup.create_automatic): usa le
# impostazioni dei backup automatici, quindi è cifrato e va sugli stessi
# archivi (locale e cloud). Serve un token di accesso a lunga vita:
#   HA_TOKEN=<token>  variabile d'ambiente, oppure riga HA_TOKEN=... nel file
#                     .ha_env alla radice del repo (ignorato da git; il percorso
#                     si cambia con HA_ENV_FILE). Abilita anche le verifiche
#                     finali (stato RUNNING e check_config).
# ------------------------------------------

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

HA_ENV_FILE="${HA_ENV_FILE:-$SCRIPT_DIR/../.ha_env}"
if [ -z "${HA_TOKEN:-}" ] && [ -f "$HA_ENV_FILE" ]; then
    # shellcheck source=/dev/null
    source "$HA_ENV_FILE"
fi

SERVER_HOST="fcos-ha"
REMOTE_USER="core"
HA_URL="${HA_URL:-http://192.168.68.100:8123}"
IMAGE="ghcr.io/home-assistant/home-assistant:stable"
HA_VERSION_FILE="/var/home/core/homeassistant/config/.HA_VERSION"
ROLLBACK_PTR="localhost/home-assistant:rollback-previous"
WAIT_TIMEOUT=420     # secondi massimi di attesa dell'avvio
BACKUP_TIMEOUT=1800  # secondi massimi per il backup (upload cloud compreso)

ASSUME_YES=0
SKIP_BACKUP=0
DO_ROLLBACK=0

for arg in "$@"; do
    case "$arg" in
        -y|--yes)      ASSUME_YES=1 ;;
        --skip-backup) SKIP_BACKUP=1 ;;
        --rollback)    DO_ROLLBACK=1 ;;
        -h|--help)     sed -n '7,27p' "$0"; exit 0 ;;
        *) echo "❌ Opzione sconosciuta: $arg (usa --help)"; exit 1 ;;
    esac
done

remote() { ssh "$REMOTE_USER@$SERVER_HOST" "$@"; }

conferma() {
    # $1 = domanda. Ritorna 0 se l'utente accetta.
    [ "$ASSUME_YES" -eq 1 ] && return 0
    local risposta
    read -r -p "$1 [s/N] " risposta
    [[ "$risposta" =~ ^[sSyY]$ ]]
}

# Attende che HA torni a rispondere. Con HA_TOKEN verifica lo stato reale
# ('RUNNING'), altrimenti si accontenta di un 200 sul frontend.
wait_for_ha() {
    local deadline=$(( SECONDS + WAIT_TIMEOUT ))
    echo -n "⏳ Attendo l'avvio di Home Assistant"
    while [ $SECONDS -lt $deadline ]; do
        if [ -n "$HA_TOKEN" ]; then
            if curl -s -m 5 -H "Authorization: Bearer $HA_TOKEN" "$HA_URL/api/config" 2>/dev/null \
                 | grep -q '"state": *"RUNNING"'; then
                echo " ✅"; return 0
            fi
        elif [ "$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$HA_URL/" 2>/dev/null)" = "200" ]; then
            echo " ✅"; return 0
        fi
        echo -n "."
        sleep 5
    done
    echo ""
    echo "⚠️  Timeout dopo ${WAIT_TIMEOUT}s: HA non risponde ancora."
    echo "    Log:  ssh $REMOTE_USER@$SERVER_HOST 'sudo podman logs -f homeassistant'"
    return 1
}

# Stato di un'entità via API REST; stringa vuota se non disponibile.
ha_state() {
    curl -s -m 10 -H "Authorization: Bearer $HA_TOKEN" "$HA_URL/api/states/$1" 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("state", ""))' 2>/dev/null \
        || true
}

# Backup nativo con le impostazioni automatiche (cifrato, stessi archivi del
# backup notturno). HA resta acceso. L'esito si legge dal sensore dell'ultimo
# backup riuscito: se non cambia, il backup è fallito.
backup_nativo() {
    local prima stato esito deadline dopo
    prima=$(ha_state sensor.backup_last_successful_automatic_backup)
    stato=$(ha_state sensor.backup_backup_manager_state)
    if [ "$stato" != "idle" ]; then
        echo "❌ Il gestore dei backup non è libero (stato: ${stato:-non leggibile})."
        echo "   C'è già un backup o un ripristino in corso, oppure il token non è valido."
        return 1
    fi

    echo "   Backup in corso (cifrato, locale + cloud): può volerci qualche minuto..."
    # L'azione risponde solo a backup finito, upload compresi.
    esito=$(curl -s -o /dev/null -w '%{http_code}' -m "$BACKUP_TIMEOUT" -X POST \
        -H "Authorization: Bearer $HA_TOKEN" -H "Content-Type: application/json" \
        -d '{}' "$HA_URL/api/services/backup/create_automatic" 2>/dev/null || true)

    # Se la richiesta è scaduta il backup può essere ancora in corso: attendo.
    deadline=$(( SECONDS + BACKUP_TIMEOUT ))
    while [ "$(ha_state sensor.backup_backup_manager_state)" != "idle" ] && [ $SECONDS -lt $deadline ]; do
        sleep 10
    done

    dopo=$(ha_state sensor.backup_last_successful_automatic_backup)
    if [ -z "$dopo" ] || [ "$dopo" = "$prima" ] || [ "$dopo" = "unknown" ]; then
        echo "❌ Backup non riuscito (risposta HTTP: ${esito:-nessuna})."
        echo "   Dettagli in Impostazioni > Sistema > Backup."
        return 1
    fi
    echo "✅ Backup completato: $dopo (UTC)"
}

# --- Verifica raggiungibilità ---
if ! remote "true" 2>/dev/null; then
    echo "❌ ERRORE: $SERVER_HOST non raggiungibile via SSH."
    exit 1
fi

CURRENT_VERSION=$(remote "sudo cat $HA_VERSION_FILE" 2>/dev/null || echo "sconosciuta")

# ==========================================
# ROLLBACK
# ==========================================
if [ "$DO_ROLLBACK" -eq 1 ]; then
    echo "↩️  Modalità ROLLBACK"
    echo "   Versione attualmente installata: $CURRENT_VERSION"

    # Di norma si usa il puntatore; in mancanza si accetta un tag 'rollback-*'
    # versionato, creato a mano o da una versione precedente dello script.
    if remote "sudo podman image exists '$ROLLBACK_PTR'"; then
        ROLLBACK_TARGET="$ROLLBACK_PTR"
    else
        ROLLBACK_TARGET=$(remote "sudo podman images --format '{{.Repository}}:{{.Tag}}' \
            | grep '^localhost/home-assistant:rollback-' | head -1" || true)
    fi

    if [ -z "$ROLLBACK_TARGET" ]; then
        echo "❌ Nessuna immagine di rollback disponibile."
        echo "   Viene creata da questo script solo quando applica un aggiornamento."
        exit 1
    fi

    TARGET_ID=$(remote "sudo podman inspect --format '{{.Id}}' '$ROLLBACK_TARGET'")
    RUNNING_ID=$(remote "sudo podman inspect --format '{{.Image}}' homeassistant")
    if [ "$TARGET_ID" = "$RUNNING_ID" ]; then
        echo "❌ L'immagine di rollback è quella già in esecuzione: non c'è nulla da ripristinare."
        exit 1
    fi

    # La versione sta nel nome del tag versionato che punta alla stessa immagine.
    PREV_VERSION=$(remote "sudo podman images --format '{{.Tag}}|{{.Id}}' localhost/home-assistant" \
        | grep "|$TARGET_ID" | grep -v '^rollback-previous' | head -1 \
        | cut -d'|' -f1 | sed 's/^rollback-//' || true)
    echo "   Immagine di rollback: $ROLLBACK_TARGET"
    echo "   Tornerei alla versione: ${PREV_VERSION:-sconosciuta}"

    conferma "   Procedo con il rollback?" || { echo "Annullato."; exit 0; }

    echo "🔄 Ripristino immagine e riavvio..."
    remote "sudo podman tag '$ROLLBACK_TARGET' '$IMAGE' && sudo systemctl restart homeassistant.service"
    wait_for_ha || true
    echo "✅ Rollback completato: $(remote "sudo cat $HA_VERSION_FILE")"
    echo ""
    echo "⚠️  ATTENZIONE: il database è già stato migrato alla versione più recente."
    echo "    Se HA si comporta male, ripristina anche il backup fatto prima"
    echo "    dell'aggiornamento: Impostazioni > Sistema > Backup > Ripristina"
    echo "    (serve la chiave di cifratura dei backup). Se HA non parte proprio,"
    echo "    vedi il README, sezione 'Backup & Disaster Recovery'."
    exit 0
fi

# ==========================================
# AGGIORNAMENTO
# ==========================================
echo "⬆️  Aggiornamento Home Assistant su $SERVER_HOST"
echo "   Versione attuale: $CURRENT_VERSION"

# Il backup preventivo passa dall'API: senza token meglio fermarsi subito,
# prima di scaricare l'immagine.
if [ "$SKIP_BACKUP" -eq 0 ] && [ -z "${HA_TOKEN:-}" ]; then
    echo "❌ Manca HA_TOKEN, necessario per il backup preventivo."
    echo "   Crea $HA_ENV_FILE con una riga HA_TOKEN=..., oppure usa --skip-backup."
    exit 1
fi

# --- 1. Pull (HA resta acceso: nessun downtime in questa fase) ---
echo ""
echo "--- ⬇️  Download immagine dal registry ---"
CURRENT_IMAGE_ID=$(remote "sudo podman inspect --format '{{.Image}}' homeassistant")
remote "sudo podman pull '$IMAGE'"
NEW_IMAGE_ID=$(remote "sudo podman inspect --format '{{.Id}}' '$IMAGE'")

if [ "$CURRENT_IMAGE_ID" = "$NEW_IMAGE_ID" ]; then
    echo ""
    echo "✅ Già all'ultima versione disponibile ($CURRENT_VERSION). Niente da fare."
    exit 0
fi

# --- 2. Che versione stiamo per installare? ---
NEW_VERSION=$(remote "sudo podman run --rm --entrypoint '' '$IMAGE' \
    grep -E '^(MAJOR|MINOR)_VERSION|^PATCH_VERSION' /usr/src/homeassistant/homeassistant/const.py" \
    | sed -E 's/.*= *//; s/"//g' | paste -sd. -)

echo ""
echo "══════════════════════════════════════════"
echo "  Aggiornamento:  $CURRENT_VERSION  →  $NEW_VERSION"
echo "══════════════════════════════════════════"
echo ""
echo "⚠️  Un salto di più release può rompere le integrazioni custom e le card HACS."
echo "    Dopo il riavvio controlla Impostazioni > Sistema > Log e Riparazioni."
echo ""

conferma "Procedo?" || {
    echo "Annullato. L'immagine resta scaricata: rilancia lo script per applicarla."
    exit 0
}

# --- 3. Tag di rollback sull'immagine VECCHIA (ancora presente per ID) ---
echo ""
echo "--- 🏷️  Tag di rollback ---"
remote "sudo podman tag '$CURRENT_IMAGE_ID' '$ROLLBACK_PTR' \
     && sudo podman tag '$CURRENT_IMAGE_ID' 'localhost/home-assistant:rollback-${CURRENT_VERSION}'"
echo "✅ Immagine $CURRENT_VERSION conservata (--rollback per tornare indietro)"

# --- 4. Backup preventivo (nativo, cifrato, con HA ancora sulla versione vecchia) ---
if [ "$SKIP_BACKUP" -eq 1 ]; then
    echo ""
    echo "⚠️  Backup SALTATO su richiesta esplicita."
else
    echo ""
    echo "--- 📦 Backup preventivo ---"
    # Il container gira ancora sull'immagine vecchia: il backup è fatto prima di
    # qualunque migrazione del database.
    if ! backup_nativo; then
        echo ""
        echo "Aggiornamento interrotto: HA non è stato riavviato e resta su $CURRENT_VERSION."
        echo "NB: la nuova immagine è già scaricata, quindi un riavvio del server la"
        echo "applicherebbe comunque. Rilancia lo script dopo aver risolto il problema."
        exit 1
    fi
fi

# --- 5. Riavvio controllato ---
echo ""
echo "--- 🔄 Riavvio del container ---"
remote "sudo systemctl restart homeassistant.service"
wait_for_ha || true

# --- 6. Verifica ---
echo ""
echo "--- 🔍 Verifica post-aggiornamento ---"
INSTALLED=$(remote "sudo cat $HA_VERSION_FILE" 2>/dev/null || echo "?")
echo "   Versione installata: $INSTALLED"

if [ -n "$HA_TOKEN" ]; then
    CHECK=$(curl -s -m 60 -X POST -H "Authorization: Bearer $HA_TOKEN" \
        -H "Content-Type: application/json" "$HA_URL/api/config/core/check_config" 2>/dev/null || echo "")
    ESITO=$(echo "$CHECK" | grep -o '"result": *"[a-z]*"' | cut -d'"' -f4 || true)
    echo "   check_config: ${ESITO:-non verificabile}"
fi

ERR_COUNT=$(remote "sudo podman logs homeassistant 2>&1 | grep -ac 'ERROR' || true")
echo "   Righe ERROR nel log di questo avvio: $ERR_COUNT"
if [ "$ERR_COUNT" != "0" ]; then
    echo "   Ultimi errori:"
    remote "sudo podman logs homeassistant 2>&1 | grep -a 'ERROR' | tail -5" | sed 's/^/     /'
fi

echo ""
echo "✅ Aggiornamento completato: $CURRENT_VERSION → $INSTALLED"
echo ""
echo "📌 Promemoria:"
echo "   • Svuota la cache del browser: il service worker continua a servire il"
echo "     frontend vecchio finché non chiudi tutte le schede di HA."
echo "   • Controlla le card HACS: le versioni recenti dei plugin possono"
echo "     richiedere una versione di HA più nuova (e viceversa)."
echo "   • In caso di problemi:  ./scripts/update_ha.sh --rollback"
