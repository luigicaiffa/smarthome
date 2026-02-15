#!/bin/bash

# Interrompe se errori
set -e

echo "🚀 Inizio Deploy dell'infrastruttura..."

# Definizioni
CONFIG_DIR="$HOME/.config/containers/systemd"
HA_DIR="$HOME/homeassistant"
SERVICES_SRC="$HOME/services"

# 1. Struttura Directory
echo "📂 Creazione struttura directory..."
mkdir -p "$CONFIG_DIR"
mkdir -p "$HA_DIR"
mkdir -p "$HA_DIR/config"
mkdir -p "$HA_DIR/caddy/data"
mkdir -p "$HA_DIR/caddy/config"

# 2. Controllo Caddyfile
# Ora controlliamo dove deve essere davvero (in HA_DIR)
if [ ! -f "$HA_DIR/Caddyfile" ]; then
    echo "⚠️  ATTENZIONE: Caddyfile non trovato in $HA_DIR!"
    echo "    Caddy potrebbe non partire correttamente."
else
    echo "✅ Caddyfile rilevato in posizione corretta."
fi

# 3. Installazione Servizi
echo "🐳 Installazione definizioni Container..."
if [ -d "$SERVICES_SRC" ]; then
    cp "$SERVICES_SRC"/*.container "$CONFIG_DIR/"
    COUNT=$(ls "$SERVICES_SRC"/*.container | wc -l)
    echo "   Copiati $COUNT servizi."
else
    echo "❌ ERRORE: Cartella $SERVICES_SRC non trovata!"
    exit 1
fi

# 4. Reload Systemd
echo "🔄 Ricaricamento Systemd User..."
systemctl --user daemon-reload

# 5. Riavvio Servizi
# Riavviamo usando i nomi dei FILE .container (senza estensione)
# Es. caddy.container -> caddy.service
# Es. duckdns.container -> duckdns.service
echo "▶️  Riavvio servizi..."
systemctl --user restart caddy
systemctl --user restart duckdns
systemctl --user restart homeassistant

# 5.1 Auto-Installazione HACS (Se mancante)
echo "🔍 Controllo presenza HACS..."

# Definiamo dove dovrebbe essere HACS
HACS_DIR="$HA_DIR/config/custom_components/hacs"

# Attendiamo che HA sia partito (diamo 10 secondi per sicurezza)
sleep 10

if [ ! -d "$HACS_DIR" ]; then
    echo "⚠️  HACS non trovato. Avvio installazione automatica..."
    
    # Eseguiamo l'installazione dentro il container
    if podman exec -it homeassistant bash -c "wget -O - https://get.hacs.xyz | bash"; then
        echo "✅ HACS installato con successo!"
        echo "♻️  Riavvio Home Assistant per attivarlo..."
        systemctl --user restart homeassistant
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
systemctl --user status caddy --no-pager | grep "Active:" || echo "❌ Caddy non attivo"
systemctl --user status duckdns --no-pager | grep "Active:" || echo "❌ DuckDNS non attivo"
systemctl --user status homeassistant --no-pager | grep "Active:" || echo "❌ Home Assistant non attivo"

echo ""
echo "✅ Deploy completato."
echo "   Per i log completi: journalctl --user -f"