#!/bin/bash

# Interrompe subito se c'è un errore (es. ssh fallisce)
set -e

# ==========================================
# 🚀 PUSH UPDATE TO SERVER (ROBUST)
# ==========================================

# 1. Configurazione Percorsi (Indipendente da dove lanci lo script)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Configurazione Server
SERVER_HOST="fcos-ha"  # Verifica che corrisponda al tuo ~/.ssh/config
REMOTE_USER="core"

echo "🚀 Inizio aggiornamento su: $SERVER_HOST"
echo "📂 Project Root rilevata: $PROJECT_ROOT"

# 2. Copia dei file
echo ""
echo "--- 📦 Sincronizzazione File ---"

# 2.1 Services
if [ -d "$PROJECT_ROOT/services" ]; then
    echo "✅ Invio cartella 'services'..."
    scp -r "$PROJECT_ROOT/services/" "$REMOTE_USER@$SERVER_HOST:~/"
else
    echo "⚠️  ATTENZIONE: Cartella 'services' non trovata in locale!"
fi

# 2.2 Scripts
if [ -d "$PROJECT_ROOT/scripts" ]; then
    echo "✅ Invio cartella 'scripts'..."
    scp -r "$PROJECT_ROOT/scripts/" "$REMOTE_USER@$SERVER_HOST:~/"
else
    echo "⚠️  ATTENZIONE: Cartella 'scripts' non trovata in locale!"
fi

# 2.3 Caddyfile
LOCAL_CADDYFILE="$PROJECT_ROOT/Caddyfile"
if [ -f "$LOCAL_CADDYFILE" ]; then
    echo "✅ Invio Caddyfile..."
    scp "$LOCAL_CADDYFILE" "$REMOTE_USER@$SERVER_HOST:~/homeassistant/Caddyfile"
else
    echo "❌ ERRORE: Caddyfile non trovato in: $LOCAL_CADDYFILE"
fi

# 2.4 Secrets (NUOVA SEZIONE)
LOCAL_SECRETS="$PROJECT_ROOT/secrets.env"
if [ -f "$LOCAL_SECRETS" ]; then
    echo "✅ Invio secrets.env..."
    # Lo copiamo nella destinazione finale dove il deploy se lo aspetta
    scp "$LOCAL_SECRETS" "$REMOTE_USER@$SERVER_HOST:~/homeassistant/secrets.env"
else
    echo "⚠️  ATTENZIONE: secrets.env non trovato in locale ($LOCAL_SECRETS)."
    echo "    Se il server non lo ha già, il deploy fallirà."
fi

# 3. Deploy
echo ""
echo "--- ⚙️  Esecuzione Deploy Remoto ---"
# Eseguiamo il deploy. Nota: deploy_app.sh ricaricherà systemd e riavvierà i servizi necessari.
ssh "$REMOTE_USER@$SERVER_HOST" "chmod +x scripts/deploy_app.sh && ./scripts/deploy_app.sh"

echo ""
echo "✅ Aggiornamento completato con successo!"