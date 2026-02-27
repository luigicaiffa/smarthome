#!/bin/bash

# Interrompe se errori
set -e

echo "🚀 Inizio Deploy dell'infrastruttura..."

# Definizioni Percorsi
USER_CONFIG_DIR="$HOME/.config/containers/systemd"
SYS_CONFIG_DIR="/etc/containers/systemd"
HA_DIR="$HOME/homeassistant"
SERVICES_SRC="$HOME/services"

# 1. Struttura Directory
echo "📂 Creazione struttura directory..."
mkdir -p "$USER_CONFIG_DIR"
sudo mkdir -p "$SYS_CONFIG_DIR"
mkdir -p "$HA_DIR/config"

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

# 4. Reload Systemd (Utente + Sistema)
echo "🔄 Ricaricamento Systemd..."
systemctl --user daemon-reload
sudo systemctl daemon-reload

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

echo ""
echo "✅ Deploy completato."
echo "   Log Cloudflare: journalctl --user -u cloudflared.service -f"
echo "   Log Home Assistant: sudo journalctl -u homeassistant.service -f"