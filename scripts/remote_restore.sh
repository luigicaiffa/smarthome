#!/bin/bash

# Interrompe subito se c'è un errore
set -e

# ==========================================
# ♻️ REMOTE RESTORE (SMART MERGE & MIRROR)
# ==========================================

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

SERVER_HOST="fcos-ha"
REMOTE_USER="core"
LOCAL_BACKUP_DIR="$PROJECT_ROOT/backups"
LOCAL_SECRETS="$PROJECT_ROOT/secrets.env"

if [ -n "$1" ]; then
    BACKUP_FILE="$1"
else
    BACKUP_FILE=$(ls -t "$LOCAL_BACKUP_DIR"/ha_backup_*.tar.gz 2>/dev/null | head -n 1)
fi

if [ -z "$BACKUP_FILE" ] || [ ! -f "$BACKUP_FILE" ]; then
    echo "❌ Errore: Nessun backup trovato in $LOCAL_BACKUP_DIR."
    exit 1
fi

FILENAME=$(basename "$BACKUP_FILE")

echo "🚀 Inizio procedura di ripristino su $SERVER_HOST..."
echo "📂 Backup selezionato: $FILENAME"
echo "⚠️  ATTENZIONE: Verranno ripristinati i DATI dal backup, ma la CONFIGURAZIONE verrà forzata dal PC locale."

echo "⬆️  Caricamento backup..."
scp "$BACKUP_FILE" "$REMOTE_USER@$SERVER_HOST:~/$FILENAME"

echo "📦 Estrazione archivio e pulizia..."
ssh "$REMOTE_USER@$SERVER_HOST" "bash -s" <<EOF
    # Stop servizi
    sudo systemctl stop homeassistant.service 2>/dev/null || true
    systemctl --user stop cloudflared.service 2>/dev/null || true
    
    sudo rm -rf homeassistant/

    tar -xzf "$FILENAME"
    rm "$FILENAME"
    
    if command -v restorecon &> /dev/null; then
        sudo restorecon -R homeassistant/
    fi
EOF

echo ""
echo "--- 🔧 Allineamento Configurazione (Local -> Remote) ---"

if [ -f "$LOCAL_SECRETS" ]; then
    echo "✅ Aggiorno secrets.env..."
    scp "$LOCAL_SECRETS" "$REMOTE_USER@$SERVER_HOST:~/homeassistant/secrets.env"
else
    echo "❌ ERRORE: secrets.env locale mancante! Il tunnel non partirà."
fi

echo "🧹 Svuoto servizi e script obsoleti sul server..."
ssh "$REMOTE_USER@$SERVER_HOST" "mkdir -p ~/services ~/scripts && rm -rf ~/services/* ~/scripts/*"

echo "✅ Aggiorno Services e Scripts..."
scp -r "$PROJECT_ROOT/services/"* "$REMOTE_USER@$SERVER_HOST:~/services/"
scp -r "$PROJECT_ROOT/scripts/"* "$REMOTE_USER@$SERVER_HOST:~/scripts/"

echo ""
echo "🚀 Avvio Deploy..."
ssh "$REMOTE_USER@$SERVER_HOST" "chmod +x ~/scripts/deploy_app.sh && ~/scripts/deploy_app.sh"

echo "✅ Ripristino completato con successo!"