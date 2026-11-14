#!/bin/bash

# ==========================================
# 🚀 DEPLOY DELL'INFRASTRUTTURA (gira sul server, come core)
# ==========================================
#
# Lo lancia push_update.sh dopo aver copiato services/ e scripts/ nella home
# di core. E' idempotente: a regime scrive solo cio' che e' cambiato e
# riavvia i due servizi.
#
# TRE UTENTI, TRE RUOLI (vedi config.bu.template)
#   core           amministra e lancia questo script; non fa girare servizi
#   homeassistant  container di Home Assistant, rootless (uid 1001)
#   cloudflared    container del tunnel, rootless (uid 1002)
#
# Uso:
#   deploy_app.sh             deploy completo con riavvio dei servizi
#   deploy_app.sh --prepare   tutto tranne i riavvii (lo usa migrate_rootless.sh)
#
# Se trova ancora la vecchia installazione (HA rootful sotto core) prepara
# utenti e file ma non riavvia nulla: la migrazione va fatta una volta con
# scripts/migrate_rootless.sh.

set -euo pipefail

SERVICES_SRC="$HOME/services"
INCOMING="$HOME/incoming"

HA_USER=homeassistant
HA_UID=1001
HA_HOME=/var/home/homeassistant
CF_USER=cloudflared
CF_UID=1002
CF_HOME=/var/home/cloudflared

# Tracce della vecchia installazione, prima della migrazione rootless.
OLD_HA_QUADLET=/etc/containers/systemd/homeassistant.container
OLD_HA_DATA="$HOME/homeassistant/config"

PREPARE_ONLY=0
[ "${1:-}" = "--prepare" ] && PREPARE_ONLY=1

MIGRAZIONE_DA_FARE=0
if [ -f "$OLD_HA_QUADLET" ] || [ -d "$OLD_HA_DATA" ]; then
    MIGRAZIONE_DA_FARE=1
fi

echo "🚀 Inizio Deploy dell'infrastruttura..."

if [ ! -d "$SERVICES_SRC" ]; then
    echo "❌ ERRORE: Cartella $SERVICES_SRC non trovata!"
    exit 1
fi

# 0. Comando per agire come utente di servizio
echo "🧰 Installazione di svc-run..."
sudo install -D -m 0755 "$SERVICES_SRC/svc-run" /usr/local/bin/svc-run

# 1. Utenti di servizio
#
# Primo uid/gid libero dopo gli intervalli subordinati gia' assegnati.
prossimo_subid() {
    awk -F: -v minimo=524288 '{ fine = $2 + $3; if (fine > minimo) minimo = fine } END { print minimo }' "$1"
}

prepara_utente() {
    local nome="$1" uid="$2" home="$3"

    if ! id "$nome" &>/dev/null; then
        echo "👤 Creo l'utente di servizio $nome (uid $uid)..."
        sudo useradd --uid "$uid" --home-dir "$home" --create-home \
            --shell /usr/sbin/nologin "$nome"
    fi

    # Intervalli subordinati per i container rootless. useradd di solito li
    # assegna da solo; se mancano si aggiungono dopo l'ultimo esistente.
    if ! grep -q "^$nome:" /etc/subuid; then
        local s; s=$(prossimo_subid /etc/subuid)
        sudo usermod --add-subuids "$s-$((s + 65535))" "$nome"
    fi
    if ! grep -q "^$nome:" /etc/subgid; then
        local g; g=$(prossimo_subid /etc/subgid)
        sudo usermod --add-subgids "$g-$((g + 65535))" "$nome"
    fi

    # Linger: l'istanza systemd dell'utente parte al boot, senza login.
    if [ "$(loginctl show-user "$nome" -p Linger --value 2>/dev/null)" != "yes" ]; then
        sudo loginctl enable-linger "$nome"
    fi
    # Si aspetta che il gestore utente sia su, altrimenti systemctl --user fallisce.
    for _ in $(seq 1 30); do
        [ -S "/run/user/$uid/bus" ] && break
        sleep 1
    done

    sudo -u "$nome" mkdir -p -m 0700 "$home/.config/containers/systemd"
}

echo "👤 Verifica utenti di servizio..."
prepara_utente "$HA_USER" "$HA_UID" "$HA_HOME"
prepara_utente "$CF_USER" "$CF_UID" "$CF_HOME"

# La cartella dati di HA nasce vuota solo su un'installazione nuova: con la
# migrazione in sospeso ci arriva quella vecchia, spostata intera.
if [ "$MIGRAZIONE_DA_FARE" -eq 0 ]; then
    sudo -u "$HA_USER" mkdir -p -m 0750 "$HA_HOME/config"
fi

# 2. Quadlet, ognuno nella home del suo utente
echo "🐳 Installazione definizioni Container..."
sudo install -o "$HA_USER" -g "$HA_USER" -m 0644 \
    "$SERVICES_SRC/homeassistant.container" \
    "$HA_HOME/.config/containers/systemd/homeassistant.container"
sudo install -o "$CF_USER" -g "$CF_USER" -m 0644 \
    "$SERVICES_SRC/cloudflared.container" \
    "$CF_HOME/.config/containers/systemd/cloudflared.container"

# 3. Segreti di cloudflared
# push_update.sh li deposita in ~/incoming: qui passano a cloudflared e la
# copia di core viene distrutta.
if [ -f "$INCOMING/secrets.env" ]; then
    echo "🔒 Installazione secrets.env per $CF_USER..."
    sudo install -o "$CF_USER" -g "$CF_USER" -m 0600 \
        "$INCOMING/secrets.env" "$CF_HOME/secrets.env"
    shred -u "$INCOMING/secrets.env"
fi
if ! sudo test -s "$CF_HOME/secrets.env"; then
    echo "⚠️  ATTENZIONE: $CF_HOME/secrets.env mancante: il tunnel non partira'."
fi

# 4. Timer notturno di podman-auto-update, solo per cloudflared
echo "🌙 Timer notturno di aggiornamento per cloudflared..."
sudo -u "$CF_USER" mkdir -p -m 0700 "$CF_HOME/.config/systemd/user/podman-auto-update.timer.d"
sudo install -o "$CF_USER" -g "$CF_USER" -m 0644 \
    "$SERVICES_SRC/podman-auto-update-nightly.conf" \
    "$CF_HOME/.config/systemd/user/podman-auto-update.timer.d/nightly.conf"

# 5. Configurazione di sistema
# 5.1 Finestra notturna per i riavvii di Zincati (aggiornamenti dell'OS).
# Riavviare zincati rilegge la configurazione e basta: non provoca reboot.
echo "🌙 Installazione finestra di riavvio di Zincati..."
sudo mkdir -p /etc/zincati/config.d
sudo cp "$SERVICES_SRC/zincati-updates-strategy.toml" /etc/zincati/config.d/55-updates-strategy.toml
sudo systemctl restart zincati.service

# 5.2 LLMNR spento: niente risposte di risoluzione nomi in LAN sulla 5355.
echo "🔇 Disattivazione LLMNR..."
sudo mkdir -p /etc/systemd/resolved.conf.d
sudo cp "$SERVICES_SRC/resolved-no-llmnr.conf" /etc/systemd/resolved.conf.d/90-no-llmnr.conf
sudo systemctl restart systemd-resolved.service

# 5.3 Irrobustimento di sshd. Prima si valida la configurazione: un errore
# qui chiuderebbe fuori dal server, quindi se sshd -t fallisce il file viene
# tolto e si prosegue senza. Il reload non chiude le sessioni aperte.
echo "🔐 Configurazione sshd..."
SSHD_DROPIN=/etc/ssh/sshd_config.d/40-hardening.conf
sudo cp "$SERVICES_SRC/sshd-hardening.conf" "$SSHD_DROPIN"
if sudo sshd -t; then
    sudo systemctl reload sshd.service
else
    echo "❌ Configurazione sshd non valida: rimuovo $SSHD_DROPIN"
    sudo rm -f "$SSHD_DROPIN"
fi

# 5.4 Niente Bluetooth: HA non lo usa piu' e non ha i permessi per farlo.
# Il pacchetto bluez si toglie a parte (rpm-ostree uninstall + riavvio).
if [ -f /etc/systemd/system/install-bluez.service ]; then
    echo "🧹 Rimozione di install-bluez.service..."
    sudo systemctl disable install-bluez.service 2>/dev/null || true
    sudo rm -f /etc/systemd/system/install-bluez.service
fi
if systemctl is-enabled bluetooth.service &>/dev/null; then
    sudo systemctl disable --now bluetooth.service || true
fi

# 6. Ricaricamento di systemd (sistema e utenti di servizio)
echo "🔄 Ricaricamento Systemd..."
sudo systemctl daemon-reload
svc-run "$HA_USER" systemctl --user daemon-reload
svc-run "$CF_USER" systemctl --user daemon-reload

# Il timer di sistema toccherebbe container di root: resta spento.
sudo systemctl disable --now podman-auto-update.timer 2>/dev/null || true

if [ "$MIGRAZIONE_DA_FARE" -eq 1 ]; then
    echo ""
    echo "⚠️  Trovata la vecchia installazione (HA rootful sotto core)."
    echo "    Utenti e file sono pronti, ma i servizi non sono stati toccati."
    echo "    Esegui una volta: ~/scripts/migrate_rootless.sh"
    exit 0
fi

svc-run "$CF_USER" systemctl --user enable --now podman-auto-update.timer

if [ "$PREPARE_ONLY" -eq 1 ]; then
    echo "✅ Preparazione completata (servizi non riavviati)."
    exit 0
fi

# 7. Riavvio Servizi
echo "▶️  Riavvio servizi..."
svc-run "$CF_USER" systemctl --user restart cloudflared.service || true
svc-run "$HA_USER" systemctl --user restart homeassistant.service || true

# 8. Stato
echo ""
echo "📊 Stato dei servizi:"
echo "---------------------"
svc-run "$CF_USER" systemctl --user status cloudflared.service --no-pager | grep "Active:" || echo "❌ Cloudflare non attivo"
svc-run "$HA_USER" systemctl --user status homeassistant.service --no-pager | grep "Active:" || echo "❌ Home Assistant non attivo"
echo -n "Prossimo auto-update cloudflared: "
svc-run "$CF_USER" systemctl --user show podman-auto-update.timer -p NextElapseUSecRealtime --value || echo "❌ timer non attivo"

echo ""
echo "✅ Deploy completato."
echo "   Log Home Assistant: journalctl _UID=$HA_UID --user-unit homeassistant.service -f"
echo "   Log Cloudflare:     journalctl _UID=$CF_UID --user-unit cloudflared.service -f"
echo "   Comandi come utente di servizio: svc-run <utente> <comando>"
