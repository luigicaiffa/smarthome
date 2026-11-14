#!/bin/bash

# Interrompe subito se c'è un errore
set -e

# ==========================================
# 🚀 PUSH UPDATE TO SERVER (MIRROR MODE)
# ==========================================

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Configurazione Server
SERVER_HOST="fcos-ha" 
REMOTE_USER="core"

echo "🚀 Inizio aggiornamento su: $SERVER_HOST"
echo "📂 Project Root rilevata: $PROJECT_ROOT"

echo ""
echo "--- 🧹 Pulizia cartelle remote ---"
# Prepariamo il server svuotando le cartelle di destinazione
ssh "$REMOTE_USER@$SERVER_HOST" "mkdir -p ~/services ~/scripts && rm -rf ~/services/* ~/scripts/*"
echo "✅ Cartelle remote ripulite."

echo ""
echo "--- 📦 Sincronizzazione File (Mirror) ---"

# 2.1 Services
if [ -d "$PROJECT_ROOT/services" ]; then
    echo "✅ Invio cartella 'services'..."
    scp -r "$PROJECT_ROOT/services/"* "$REMOTE_USER@$SERVER_HOST:~/services/"
else
    echo "⚠️  ATTENZIONE: Cartella 'services' non trovata in locale!"
fi

# 2.2 Scripts
if [ -d "$PROJECT_ROOT/scripts" ]; then
    echo "✅ Invio cartella 'scripts'..."
    scp -r "$PROJECT_ROOT/scripts/"* "$REMOTE_USER@$SERVER_HOST:~/scripts/"
else
    echo "⚠️  ATTENZIONE: Cartella 'scripts' non trovata in locale!"
fi

# 2.3 Secrets
# Arrivano in ~/incoming di core (700) e deploy_app.sh li passa all'utente
# cloudflared, poi distrugge la copia: core non tiene il token.
LOCAL_SECRETS="$PROJECT_ROOT/secrets.env"
if [ -f "$LOCAL_SECRETS" ]; then
    echo "✅ Invio secrets.env..."
    ssh "$REMOTE_USER@$SERVER_HOST" "mkdir -p -m 0700 ~/incoming"
    scp "$LOCAL_SECRETS" "$REMOTE_USER@$SERVER_HOST:~/incoming/secrets.env"
else
    echo "⚠️  ATTENZIONE: secrets.env non trovato in locale ($LOCAL_SECRETS)."
fi

echo ""
echo "--- ⚙️  Esecuzione Deploy Remoto ---"
ssh "$REMOTE_USER@$SERVER_HOST" "chmod +x ~/scripts/*.sh && ~/scripts/deploy_app.sh"

echo ""
echo "✅ Aggiornamento completato con successo!"