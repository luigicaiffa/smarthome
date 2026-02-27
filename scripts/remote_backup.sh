#!/bin/bash

# Interrompe in caso di errori
set -e

# ==========================================
# 📦 REMOTE BACKUP (HA + SECRETS + DATA)
# ==========================================

SERVER_HOST="fcos-ha"
REMOTE_USER="core"
REMOTE_DIR="homeassistant"        
LOCAL_BACKUP_DIR="./backups"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_FILENAME="ha_backup_${TIMESTAMP}.tar.gz"

mkdir -p "$LOCAL_BACKUP_DIR"

echo "🚀 Inizio backup da $SERVER_HOST..."

if ! ssh "$REMOTE_USER@$SERVER_HOST" "[ -d $REMOTE_DIR ]"; then
    echo "❌ ERRORE: La cartella $REMOTE_DIR non esiste sul server!"
    exit 1
fi

echo "⏸️  Arresto servizi e compressione..."
ssh "$REMOTE_USER@$SERVER_HOST" "bash -s" <<EOF
    # Stop servizi
    sudo systemctl stop homeassistant.service
    systemctl --user stop cloudflared.service
    
    # Compressione (eseguita con SUDO per permessi)
    sudo tar -czf "$BACKUP_FILENAME" "$REMOTE_DIR" || [ \$? -eq 1 ]

    # Cambio proprietario per download
    sudo chown $REMOTE_USER:$REMOTE_USER "$BACKUP_FILENAME"

    # Riavvio
    echo "▶️  Riavvio servizi..."
    systemctl --user start cloudflared.service
    sudo systemctl start homeassistant.service
EOF

echo "⬇️  Download backup..."
scp "$REMOTE_USER@$SERVER_HOST:~/$BACKUP_FILENAME" "$LOCAL_BACKUP_DIR/$BACKUP_FILENAME"

echo "🧹 Pulizia file temporaneo..."
ssh "$REMOTE_USER@$SERVER_HOST" "rm ~/$BACKUP_FILENAME"

echo "✅ Backup salvato in: $LOCAL_BACKUP_DIR/$BACKUP_FILENAME"