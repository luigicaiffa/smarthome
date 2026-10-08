#!/bin/bash

# Interrompe se errori
set -e

echo "🚀 Inizio Deploy dell'infrastruttura..."

# Definizioni Percorsi
USER_CONFIG_DIR="$HOME/.config/containers/systemd"
USER_TIMER_DROPIN_DIR="$HOME/.config/systemd/user/podman-auto-update.timer.d"
SYS_CONFIG_DIR="/etc/containers/systemd"
HA_DIR="$HOME/homeassistant"
SERVICES_SRC="$HOME/services"

# 1. Struttura Directory
echo "📂 Creazione struttura directory..."
mkdir -p "$USER_CONFIG_DIR"
sudo mkdir -p "$SYS_CONFIG_DIR"
mkdir -p "$HA_DIR/config"

# 1.1 Linger: indispensabile perche' i servizi ROOTLESS (cloudflared)
# partano al boot anche senza login interattivo dell'utente.
# Idempotente: auto-ripara installazioni precedenti senza linger.
echo "🔗 Verifica linger per l'utente '$USER'..."
if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" != "yes" ]; then
    echo "   -> Abilito il linger..."
    sudo loginctl enable-linger "$USER"
else
    echo "   -> Linger gia' attivo."
fi

# 1.2 Pulizia: rimuove un'eventuale copia di SISTEMA di cloudflared lasciata
# da provisioning precedenti (cloudflared deve girare SOLO rootless).
if [ -f "$SYS_CONFIG_DIR/cloudflared.container" ]; then
    echo "🧹 Rimuovo copia di sistema obsoleta di cloudflared.container..."
    sudo rm -f "$SYS_CONFIG_DIR/cloudflared.container"
fi

# 2. Gestione Permessi Secrets
if [ -f "$HA_DIR/secrets.env" ]; then
    echo "🔒 Configurazione permessi Secrets..."
    chmod 600 "$HA_DIR/secrets.env"
else
    echo "⚠️  ATTENZIONE: secrets.env non trovato in $HA_DIR!"
    echo "    Cloudflare Tunnel potrebbe non partire."
fi

# 3. Installazione Servizi
echo "🐳 Installazione definizioni Container..."
if [ -d "$SERVICES_SRC" ]; then
    for file in "$SERVICES_SRC"/*.container; do
        filename=$(basename "$file")
        if [ "$filename" == "homeassistant.container" ]; then
            echo "   -> Copia $filename (System/Rootful)"
            sudo cp "$file" "$SYS_CONFIG_DIR/"
        else
            echo "   -> Copia $filename (User/Rootless)"
            cp "$file" "$USER_CONFIG_DIR/"
        fi
    done
else
    echo "❌ ERRORE: Cartella $SERVICES_SRC non trovata!"
    exit 1
fi

# 3.1 Orario notturno per l'auto-update dei container rootless (cloudflared)
echo "🌙 Installazione orario notturno per podman-auto-update (utente)..."
mkdir -p "$USER_TIMER_DROPIN_DIR"
cp "$SERVICES_SRC/podman-auto-update-nightly.conf" "$USER_TIMER_DROPIN_DIR/nightly.conf"

# 4. Reload Systemd (Utente + Sistema)
echo "🔄 Ricaricamento Systemd..."
systemctl --user daemon-reload
sudo systemctl daemon-reload

# 4.1 Timer di auto-update: attivo SOLO quello utente (cloudflared).
# Quello di sistema toccherebbe Home Assistant, che si aggiorna a mano con
# update_ha.sh: lo teniamo esplicitamente spento.
echo "⏰ Abilitazione podman-auto-update.timer (utente)..."
systemctl --user enable --now podman-auto-update.timer
sudo systemctl disable --now podman-auto-update.timer 2>/dev/null || true

# 5. Riavvio Servizi
echo "▶️  Riavvio servizi..."
systemctl --user restart cloudflared.service || true
sudo systemctl restart homeassistant.service || true

# 5.1 Auto-Installazione HACS (Se mancante)
echo "🔍 Controllo presenza HACS..."

HACS_DIR="$HA_DIR/config/custom_components/hacs"
sleep 10

if [ ! -d "$HACS_DIR" ]; then
    echo "⚠️  HACS non trovato. Avvio installazione automatica..."
    if sudo podman exec -it homeassistant bash -c "wget -O - https://get.hacs.xyz | bash"; then
        echo "✅ HACS installato con successo!"
        echo "♻️  Riavvio Home Assistant per attivarlo..."
        sudo systemctl restart homeassistant.service
    else
        echo "❌ Errore durante l'installazione di HACS."
    fi
else
    echo "✅ HACS è già presente."
fi

# 6. Check Status
echo ""
echo "📊 Stato dei servizi:"
echo "---------------------"
systemctl --user status cloudflared.service --no-pager | grep "Active:" || echo "❌ Cloudflare non attivo"
sudo systemctl status homeassistant.service --no-pager | grep "Active:" || echo "❌ Home Assistant non attivo"
echo -n "Prossimo auto-update cloudflared: "
systemctl --user show podman-auto-update.timer -p NextElapseUSecRealtime --value || echo "❌ timer non attivo"

echo ""
echo "✅ Deploy completato."
echo "   Log Cloudflare: journalctl --user -u cloudflared.service -f"
echo "   Log auto-update: journalctl --user -u podman-auto-update.service"
echo "   Log Home Assistant: sudo journalctl -u homeassistant.service -f"