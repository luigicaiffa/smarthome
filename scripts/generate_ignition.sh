#!/bin/bash

# Ottieni la directory dello script per gestire i percorsi relativi
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$SCRIPT_DIR/.."
TEMPLATE_FILE="$PROJECT_ROOT/config.bu.template"
OUTPUT_FILE="$PROJECT_ROOT/config.ign"
REQUIRED_KEY="$HOME/.ssh/id_homeassistant.pub"

# --- 0. RILEVAMENTO CONTAINER ENGINE (DOCKER vs PODMAN) ---

if command -v podman &> /dev/null; then
    ENGINE="podman"
    echo "🐳 Engine rilevato: Podman"
elif command -v docker &> /dev/null; then
    ENGINE="docker"
    echo "🐳 Engine rilevato: Docker"
else
    echo "❌ ERRORE: Nessun container engine trovato."
    echo "   Devi avere installato 'docker' oppure 'podman' per generare il file."
    exit 1
fi

# --- 1. CONTROLLO RIGOROSO DELLA CHIAVE ---

if [ ! -f "$REQUIRED_KEY" ]; then
    echo "❌ ERRORE FATALE: Chiave mancante!"
    echo "   Questo progetto richiede una chiave SSH dedicata."
    echo ""
    echo "   Esegui questo comando per generarla:"
    echo "   ssh-keygen -t ed25519 -C \"admin@homeassistant\" -f ~/.ssh/id_homeassistant"
    echo ""
    exit 1
fi

# Leggiamo il contenuto e rimuoviamo spazi/newline
SSH_KEY_CONTENT=$(cat "$REQUIRED_KEY" | tr -d '\n')

echo "✅ Trovata chiave di progetto: id_homeassistant.pub"
echo "🔑 Fingerprint: ${SSH_KEY_CONTENT:0:30}..."

# --- 2. GENERAZIONE DEL FILE IGNITION ---

if [ ! -f "$TEMPLATE_FILE" ]; then
    echo "❌ ERRORE: Template $TEMPLATE_FILE non trovato."
    exit 1
fi

echo "⚙️  Generazione file Ignition in corso..."

# Sostituzione del placeholder e compilazione via Engine rilevato
# Nota: L'uso di --interactive (-i) è necessario per leggere da stdin
sed "s|%%SSH_PUB_KEY%%|$SSH_KEY_CONTENT|g" "$TEMPLATE_FILE" | \
$ENGINE run --interactive --rm quay.io/coreos/butane:release \
       --pretty --strict > "$OUTPUT_FILE"

if [ $? -eq 0 ]; then
    echo "🎉 SUCCESSO! File config.ign generato."
    echo "   Pronto per il flash: coreos-installer install /dev/sda --ignition-file config.ign"
else
    echo "❌ ERRORE: Generazione fallita (vedi output Butane sopra)."
    exit 1
fi