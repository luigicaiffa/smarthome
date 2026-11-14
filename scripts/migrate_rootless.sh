#!/bin/bash

# ==========================================
# 🔀 MIGRAZIONE A SERVIZI ROOTLESS CON UTENTI DEDICATI (una tantum)
# ==========================================
#
# Gira sul server, come core, dopo che push_update.sh ha copiato la nuova
# versione di services/ e scripts/. Porta:
#   - Home Assistant da container di root (etichetta spc_t, SELinux spento)
#     a container rootless dell'utente homeassistant;
#   - cloudflared da rootless di core a rootless dell'utente cloudflared.
#
# Uso:
#   ~/scripts/migrate_rootless.sh             esegue la migrazione
#   ~/scripts/migrate_rootless.sh --rollback  torna esattamente a prima
#
# Fermo previsto: tunnel ~30 secondi, Home Assistant qualche minuto. I dati
# di HA si spostano con un mv sullo stesso disco: istantaneo. Le immagini
# vengono scaricate prima di fermare qualcosa.
#
# Le copie per il rollback (quadlet vecchi, timer, secrets.env) finiscono in
# ~/pre-rootless, con permessi 700. Si cancellano a mano quando tutto e'
# confermato.

set -euo pipefail

HA_USER=homeassistant
HA_HOME=/var/home/homeassistant
CF_USER=cloudflared
CF_HOME=/var/home/cloudflared

OLD_DIR="$HOME/homeassistant"
OLD_DATA="$OLD_DIR/config"
OLD_SECRETS="$OLD_DIR/secrets.env"
OLD_HA_QUADLET=/etc/containers/systemd/homeassistant.container
OLD_CF_QUADLET="$HOME/.config/containers/systemd/cloudflared.container"
OLD_CF_DROPIN="$HOME/.config/systemd/user/podman-auto-update.timer.d/nightly.conf"

NEW_DATA="$HA_HOME/config"
NEW_HA_QUADLET="$HA_HOME/.config/containers/systemd/homeassistant.container"
NEW_CF_QUADLET="$CF_HOME/.config/containers/systemd/cloudflared.container"

SALVA="$HOME/pre-rootless"

HA_IMAGE=ghcr.io/home-assistant/home-assistant:stable
CF_IMAGE=docker.io/cloudflare/cloudflared:latest

attendi_attivo() {
    # $1 = utente, $2 = unit, $3 = secondi
    local fine=$(( SECONDS + $3 ))
    while [ $SECONDS -lt $fine ]; do
        if svc-run "$1" systemctl --user is-active --quiet "$2"; then
            return 0
        fi
        sleep 2
    done
    return 1
}

attendi_ha() {
    local fine=$(( SECONDS + 420 ))
    echo -n "⏳ Attendo che Home Assistant risponda"
    while [ $SECONDS -lt $fine ]; do
        if [ "$(curl -s -o /dev/null -w '%{http_code}' -m 5 http://127.0.0.1:8123/ 2>/dev/null)" = "200" ]; then
            echo " ✅"
            return 0
        fi
        echo -n "."
        sleep 5
    done
    echo ""
    return 1
}

migra() {
    echo "🔎 Controlli preliminari..."
    [ -f "$OLD_HA_QUADLET" ] || { echo "❌ $OLD_HA_QUADLET non c'e': migrazione gia' fatta?"; exit 1; }
    [ -d "$OLD_DATA/.storage" ] || { echo "❌ $OLD_DATA non sembra la configurazione di HA."; exit 1; }
    if sudo test -e "$NEW_DATA" && [ -n "$(sudo ls -A "$NEW_DATA" 2>/dev/null)" ]; then
        echo "❌ $NEW_DATA esiste e non e' vuota: non sovrascrivo nulla."
        exit 1
    fi
    command -v svc-run >/dev/null || { echo "❌ svc-run mancante: lancia prima push_update.sh."; exit 1; }

    echo "💾 Copie per il rollback in $SALVA..."
    mkdir -p -m 0700 "$SALVA"
    sudo cp "$OLD_HA_QUADLET" "$SALVA/homeassistant.container.system"
    sudo chown "$(id -u):$(id -g)" "$SALVA/homeassistant.container.system"
    [ -f "$OLD_CF_QUADLET" ] && cp "$OLD_CF_QUADLET" "$SALVA/cloudflared.container.core"
    [ -f "$OLD_CF_DROPIN" ] && cp "$OLD_CF_DROPIN" "$SALVA/nightly.conf.core"
    [ -f "$OLD_SECRETS" ] && install -m 0600 "$OLD_SECRETS" "$SALVA/secrets.env"

    echo "🧰 Preparazione utenti e file..."
    "$HOME/scripts/deploy_app.sh" --prepare

    # Il token del tunnel: se push_update.sh non l'ha gia' messo, si usa quello
    # attuale di core.
    if ! sudo grep -q '^TUNNEL_TOKEN=..*' "$CF_HOME/secrets.env" 2>/dev/null \
       || sudo grep -q 'inserisci_qui' "$CF_HOME/secrets.env"; then
        sudo install -o "$CF_USER" -g "$CF_USER" -m 0600 "$OLD_SECRETS" "$CF_HOME/secrets.env"
    fi

    echo "⬇️  Scarico le immagini per i nuovi utenti (i servizi girano ancora)..."
    svc-run "$CF_USER" podman pull "$CF_IMAGE"
    svc-run "$HA_USER" podman pull "$HA_IMAGE"

    echo ""
    echo "--- 🌐 cloudflared ---"
    systemctl --user stop cloudflared.service || true
    systemctl --user disable --now podman-auto-update.timer 2>/dev/null || true
    rm -f "$OLD_CF_QUADLET" "$OLD_CF_DROPIN"
    systemctl --user daemon-reload
    svc-run "$CF_USER" systemctl --user daemon-reload
    svc-run "$CF_USER" systemctl --user start cloudflared.service
    if attendi_attivo "$CF_USER" cloudflared.service 60; then
        echo "✅ cloudflared attivo come $CF_USER"
    else
        echo "❌ cloudflared non parte: rollback con --rollback"
        exit 1
    fi
    svc-run "$CF_USER" systemctl --user enable --now podman-auto-update.timer

    echo ""
    echo "--- 🏠 Home Assistant ---"
    echo "⏹️  Fermo HA (rootful)..."
    sudo systemctl stop homeassistant.service
    sudo rm -f "$OLD_HA_QUADLET"
    sudo systemctl daemon-reload

    echo "📦 Sposto i dati in $NEW_DATA..."
    if sudo test -d "$NEW_DATA"; then
        sudo rmdir "$NEW_DATA"
    fi
    sudo mv "$OLD_DATA" "$NEW_DATA"
    sudo chown -R "$HA_USER:$HA_USER" "$NEW_DATA"
    sudo chmod 0750 "$NEW_DATA"

    echo "▶️  Avvio HA rootless..."
    svc-run "$HA_USER" systemctl --user daemon-reload
    svc-run "$HA_USER" systemctl --user start homeassistant.service
    if ! attendi_ha; then
        echo "❌ HA non risponde. Log:"
        echo "   journalctl _UID=$(id -u $HA_USER) --user-unit homeassistant.service -n 50"
        echo "   Per tornare indietro: $0 --rollback"
        exit 1
    fi

    # Il vecchio secrets.env di core non serve piu' (la copia sta in $SALVA).
    [ -f "$OLD_SECRETS" ] && shred -u "$OLD_SECRETS"
    rmdir "$OLD_DIR" 2>/dev/null || true

    # core non fa piu' girare servizi: niente linger.
    sudo loginctl disable-linger core || true

    echo ""
    echo "✅ Migrazione completata."
    echo "   Etichetta del processo HA:"
    ps -eZ | grep -E ' python3$' | head -1 || true
    echo "   Copie per il rollback: $SALVA (da cancellare quando tutto e' confermato)"
}

rollback() {
    echo "↩️  ROLLBACK alla configurazione precedente"
    [ -f "$SALVA/homeassistant.container.system" ] || { echo "❌ Copie in $SALVA mancanti."; exit 1; }

    echo "⏹️  Fermo i servizi rootless..."
    svc-run "$HA_USER" systemctl --user stop homeassistant.service 2>/dev/null || true
    svc-run "$CF_USER" systemctl --user stop cloudflared.service 2>/dev/null || true
    svc-run "$CF_USER" systemctl --user disable --now podman-auto-update.timer 2>/dev/null || true
    sudo rm -f "$NEW_HA_QUADLET" "$NEW_CF_QUADLET"
    svc-run "$HA_USER" systemctl --user daemon-reload 2>/dev/null || true
    svc-run "$CF_USER" systemctl --user daemon-reload 2>/dev/null || true

    echo "📦 Riporto i dati in $OLD_DATA..."
    mkdir -p "$OLD_DIR"
    if sudo test -d "$NEW_DATA/.storage" && [ ! -d "$OLD_DATA" ]; then
        sudo mv "$NEW_DATA" "$OLD_DATA"
    fi
    # HA rootful scrive come root; core deve poter fare rsync con deploy.sh.
    sudo chown -R core:core "$OLD_DATA"

    echo "🔒 Ripristino secrets.env e quadlet..."
    install -m 0600 "$SALVA/secrets.env" "$OLD_SECRETS"
    sudo install -m 0644 "$SALVA/homeassistant.container.system" "$OLD_HA_QUADLET"
    mkdir -p "$(dirname "$OLD_CF_QUADLET")" "$(dirname "$OLD_CF_DROPIN")"
    [ -f "$SALVA/cloudflared.container.core" ] && cp "$SALVA/cloudflared.container.core" "$OLD_CF_QUADLET"
    [ -f "$SALVA/nightly.conf.core" ] && cp "$SALVA/nightly.conf.core" "$OLD_CF_DROPIN"

    sudo loginctl enable-linger core
    sudo systemctl daemon-reload
    systemctl --user daemon-reload
    systemctl --user enable --now podman-auto-update.timer
    systemctl --user start cloudflared.service
    sudo systemctl start homeassistant.service
    attendi_ha || echo "⚠️  HA non risponde ancora: controlla con sudo journalctl -u homeassistant.service"

    echo ""
    echo "✅ Rollback completato. Prima del prossimo push_update.sh riporta il repo"
    echo "   smarthome alla versione precedente alla migrazione."
}

case "${1:-}" in
    "") migra ;;
    --rollback) rollback ;;
    *) echo "uso: $0 [--rollback]"; exit 2 ;;
esac
