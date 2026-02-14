#!/bin/bash

# Definizioni
SERVICE_NAME="homeassistant"
CONTAINER_FILE="services/${SERVICE_NAME}.container"
SYSTEMD_DIR="$HOME/.config/containers/systemd"
CONFIG_DIR="$HOME/homeassistant/config"

# 1. Verifica di NON essere root (Sarebbe un errore fatale per Rootless Podman)
if [ "$EUID" -eq 0 ]; then
  echo "❌ ERRORE: Non eseguire questo script come root (sudo)!"
  echo "   Eseguilo come utente normale: ./deploy_app.sh"
  exit 1
fi

echo "🚀 Inizio Deploy di $SERVICE_NAME..."

# 2. Creazione cartelle (Se non esistono già grazie a Ignition)
# Il flag -p non dà errore se esistono già.
mkdir -p "$SYSTEMD_DIR"
mkdir -p "$CONFIG_DIR"

# 3. Copia del file Quadlet
echo "📂 Copia definizioni Systemd..."
cp "$CONTAINER_FILE" "$SYSTEMD_DIR/"

# 4. Reload di Systemd
echo "🔄 Ricaricamento Systemd User..."
systemctl --user daemon-reload

# 5. Restart del servizio
echo "▶️  Avvio/Restart Container..."
systemctl --user restart "$SERVICE_NAME"

# 6. Verifica stato
if systemctl --user is-active --quiet "$SERVICE_NAME"; then
    echo "✅ Successo! Il servizio è attivo."
    echo "   Log: journalctl --user -f -u $SERVICE_NAME"
else
    echo "⚠️  Attenzione: Il servizio non sembra attivo."
    echo "   Controlla: systemctl --user status $SERVICE_NAME"
fi