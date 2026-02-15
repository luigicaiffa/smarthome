#!/bin/bash

# Interrompe in caso di errori
set -e

# ==========================================
# 📦 REMOTE BACKUP (HA + SECRETS + DATA)
# ==========================================

# Configurazione
SERVER_HOST="fcos-ha"
REMOTE_USER="core"
REMOTE_DIR="homeassistant"        
LOCAL_BACKUP_DIR="./backups"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_FILENAME="ha_backup_${TIMESTAMP}.tar.gz"

# 1. Preparazione Locale
mkdir -p "$LOCAL_BACKUP_DIR"

echo "🚀 Inizio backup da $SERVER_HOST..."

# 2. Verifica Esistenza
if ! ssh "$REMOTE_USER@$SERVER_HOST" "[ -d $REMOTE_DIR ]"; then
    echo "❌ ERRORE: La cartella $REMOTE_DIR non esiste sul server!"
    exit 1
fi

# 3. Stop Servizi & Compressione
echo "⏸️  Arresto servizi e compressione..."
ssh "$REMOTE_USER@$SERVER_HOST" "bash -s" <<EOF
    # Stop solo di HA per consistenza DB (Caddy può restare attivo se vuoi, ma meglio spegnere)
    systemctl --user stop homeassistant
    systemctl --user stop caddy
    
    # Compressione
    # Usiamo tar ignorando eventuali warning di "file changed as we read it"
    tar -czf "$BACKUP_FILENAME" "$REMOTE_DIR" || [ \$? -eq 1 ]

    # Riavvio
    echo "▶️  Riavvio servizi..."
    systemctl --user start caddy
    systemctl --user start homeassistant
EOF

# 4. Download
echo "⬇️  Download backup..."
scp "$REMOTE_USER@$SERVER_HOST:~/$BACKUP_FILENAME" "$LOCAL_BACKUP_DIR/$BACKUP_FILENAME"

# 5. Pulizia Remota
echo "🧹 Pulizia file temporaneo..."
ssh "$REMOTE_USER@$SERVER_HOST" "rm ~/$BACKUP_FILENAME"

echo "✅ Backup salvato in: $LOCAL_BACKUP_DIR/$BACKUP_FILENAME"