# 🏠 Smart Home Infrastructure (Fedora CoreOS + Podman)

Benvenuto nel repository **Infrastructure-as-Code (IaC)** per la tua Smart Home.
Questo progetto automatizza il deployment di **Home Assistant** e **Cloudflare Tunnel** (Accesso Remoto Sicuro) su un sistema operativo robusto e minimale: **Fedora CoreOS**.

### ✨ Filosofia del Progetto
*   🛡️ **Immutabile:** Sistema operativo gestito via `ostree`, aggiornamenti atomici.
*   🔐 **Tutto rootless, un utente per servizio:** Home Assistant e Cloudflare Tunnel girano in container **rootless**, ognuno con il proprio utente senza shell né sudo, confinati da SELinux. `core` serve solo ad amministrare (vedi [Utenti e permessi](#utenti-e-permessi)).
*   🤖 **Zero-Touch:** Installazione tramite ISO autoconfigurante. Inserisci la chiavetta e fa tutto da solo.
*   🔄 **Backup cifrati:** Backup nativi di Home Assistant, cifrati, ogni notte sul server e nel cloud; il server si ricrea dal repository.

---

## 📂 Struttura del Repository

```text
📂 .
├── 📂 services/             # ⚙️ Definizioni dei Container (Systemd/Quadlet .container)
├── 📂 scripts/              # 🛠️ Script di automazione (Build, Deploy, Aggiornamento)
├── 📄 config.bu.template    # 📄 Template Butane per la configurazione dell'OS
├── 📄 secrets.env.template  # 📄 Template per le variabili d'ambiente
├── 📄 secrets.env           # 🔑 Variabili sensibili (NON committare su Git!)
├── 📄 .ha_env               # 🔑 Token di HA per update_ha.sh (NON committare su Git!)
└── 📘 README.md             # 📖 Questo file
```

## Utenti e permessi

| Utente | Ruolo | Privilegi |
|---|---|---|
| `core` | amministrazione: SSH con chiave, `push_update.sh`, `update_ha.sh` | sudo; non fa girare servizi |
| `homeassistant` (uid 1001) | solo il container di Home Assistant, dati in `/var/home/homeassistant/config` | nessuno: niente shell, chiavi o sudo |
| `cloudflared` (uid 1002) | solo il tunnel, token in `/var/home/cloudflared/secrets.env` | nessuno: niente shell, chiavi o sudo |

I container sono **rootless** e girano con l'etichetta SELinux standard (`container_t`),
senza capability aggiuntive. Chi compromettesse un'integrazione di HA resterebbe chiuso
nel container; se anche ne uscisse, troverebbe un utente che non può fare nulla e non
potrebbe leggere il token del tunnel. Solo `core` può entrare via SSH (`AllowUsers`).

Niente Bluetooth: richiedeva HA come root con SELinux spento. Se servirà, la strada è
un proxy Bluetooth ESPHome in rete, che non chiede permessi al server.

Per agire come utente di servizio c'è `svc-run`, installato sul server:
```bash
svc-run homeassistant systemctl --user restart homeassistant.service
svc-run homeassistant podman exec -it homeassistant bash
svc-run cloudflared systemctl --user status cloudflared.service
```

## 1. Prerequisiti (Setup Locale)

Esegui queste operazioni sul tuo PC di sviluppo prima di iniziare.

### A. Configurazione SSH
L'accesso al server avviene esclusivamente tramite chiavi SSH.

1.  Genera la chiave dedicata:
    ssh-keygen -t ed25519 -C "admin@smarthome" -f ~/.ssh/id_homeassistant

2.  Configura il client SSH:
    Aggiungi al tuo ~/.ssh/config:

    ```text
    Host fcos-ha
        User core
        Hostname 192.168.1.100  # Sostituisci con l'IP statico del server
        IdentityFile ~/.ssh/id_homeassistant
    ```

### B. Gestione Segreti
Crea il file dei segreti partendo dal template fornito. Questo ti assicura di avere già i nomi delle variabili corretti.

```bash
cp secrets.env.template secrets.env
```

## 2. Installazione (Metodo ISO Automatica)

Questa procedura crea una chiavetta USB che formatta, installa e configura il server automaticamente senza bisogno di tastiera o monitor.

1.  Genera Configurazione (Ignition):
    Prepara il file iniettando la tua chiave SSH pubblica.
    ```bash
    ./scripts/generate_ignition.sh
    ```

2.  Crea ISO Custom:
    Scarica FCOS e inietta la configurazione nell'immagine.
    ```bash
    ./scripts/build_custom_iso.sh
    ```

3.  Scrivi su USB:
    Inserisci una chiavetta e lancia lo script (rileva i dischi sicuri):
    ```bash
    ./scripts/flash_usb.sh
    ```

4.  Boot & Installazione:
    * Inserisci la USB nel Mini PC (collegato via Ethernet).
    * Avvia il PC e assicurati che la **priorità di boot** sia impostata sulla chiavetta USB (premi F12, F2 o DEL se necessario).
    * Attendi lo spegnimento/riavvio automatico.
    * Rimuovi la USB e riaccendi.


## 3. Workflow Quotidiano (Push & Deploy)

Regola d'oro: Non modificare mai i file direttamente sul server. Modifica sul PC, poi fai "Push".

### Applicare Modifiche
Se hai modificato un file `.container` o `secrets.env`:
```bash
./scripts/push_update.sh
```

Questo script:
1.  Copia le configurazioni aggiornate (`services/`, `scripts/`) sul server.
2.  Consegna `secrets.env` all'utente `cloudflared` (la copia di `core` viene distrutta).
3.  Lancia `deploy_app.sh`, che installa ogni quadlet nella home del suo utente,
    ricarica systemd e riavvia i servizi.

### Migrazione dalla vecchia installazione (una tantum)
Fino a novembre 2026 HA girava come root sotto `core`. Su un server installato con la
versione precedente, dopo `push_update.sh` va lanciato una volta:
```bash
ssh fcos-ha ~/scripts/migrate_rootless.sh             # migra (HA fermo qualche minuto)
ssh fcos-ha ~/scripts/migrate_rootless.sh --rollback  # torna com'era
```
Finché la migrazione non è fatta, `deploy_app.sh` prepara utenti e file ma non tocca i servizi.

============================================================

## 4. Aggiornamenti

| Componente | Come si aggiorna |
|---|---|
| Fedora CoreOS | Automatico, tramite **Zincati**, con riavvio **solo tra le 03:00 e le 03:45** (ora italiana) |
| Cloudflare Tunnel (`cloudflared`) | Automatico, **ogni notte alle 04:00** (ora italiana) |
| Home Assistant | Manuale, con `./scripts/update_ha.sh` |

### Fedora CoreOS (automatico)

Zincati scarica e prepara le nuove release in qualunque momento, ma per applicarle
deve riavviare l'host, e quindi spegnere Home Assistant per qualche minuto. Il default
di FCOS riavvia appena l'aggiornamento è pronto, a qualunque ora: per questo
`services/zincati-updates-strategy.toml` imposta la strategia `periodic` con una
finestra notturna, prima dei lavori delle 04:00.

```bash
# Strategia attiva e prossima finestra
ssh fcos-ha "journalctl -u zincati -b | grep -i strategy"
# Aggiornamenti in attesa del riavvio
ssh fcos-ha "rpm-ostree status"
```

### Cloudflare Tunnel (automatico)

`cloudflared` non ha stato né integrazioni da rompere, mentre le versioni troppo
vecchie smettono di essere supportate da Cloudflare: conviene tenerlo sempre aggiornato.

Il quadlet ha `AutoUpdate=registry` ed è abilitato il timer `podman-auto-update.timer`
**dell'utente `cloudflared`**, che verifica il registry ogni notte alle 04:00 (± 15 min)
e, se c'è una nuova immagine, la scarica e riavvia il servizio. Se il servizio non
riparte, podman ripristina da solo l'immagine precedente. Se il server era spento
all'ora prevista, il controllo salta alla notte successiva.

Il timer di un utente vede solo i suoi container, quindi Home Assistant (utente
`homeassistant`, senza timer né `AutoUpdate`) non viene mai toccato. Il timer di
**sistema** resta disabilitato (`deploy_app.sh` lo forza spento).

```bash
# Prossima esecuzione
ssh fcos-ha "svc-run cloudflared systemctl --user list-timers podman-auto-update.timer"
# Esito delle ultime esecuzioni
ssh fcos-ha "journalctl _UID=1002 --user-unit podman-auto-update.service"
# Cosa verrebbe aggiornato adesso (senza applicare nulla)
ssh fcos-ha "svc-run cloudflared podman auto-update --dry-run"
# Forzare subito l'aggiornamento
ssh fcos-ha "svc-run cloudflared systemctl --user start podman-auto-update.service"
```

### Home Assistant (manuale)

Il quadlet usa il tag mobile `:stable` **senza** `AutoUpdate`, e l'utente `homeassistant`
non ha il timer di aggiornamento, **di proposito**: un aggiornamento non
presidiato può rompere dashboard, card HACS e integrazioni custom senza preavviso.
L'aggiornamento si fa quindi a mano, in modo controllato:

```bash
./scripts/update_ha.sh
```

Lo script:
1.  Scarica l'immagine dal registry **senza fermare HA** (nessun downtime in questa fase).
2.  Si ferma subito se sei già all'ultima versione.
3.  Mostra `versione attuale → versione nuova` e chiede conferma.
4.  Conserva l'immagine attuale come tag di rollback.
5.  Esegue un backup nativo di HA (azione `backup.create_automatic`) **senza fermare HA**
    e prima di qualunque migrazione del database. Usa le impostazioni dei backup
    automatici: è cifrato e finisce sugli stessi archivi del backup notturno. Se il
    backup fallisce lo script si ferma e HA resta sulla versione vecchia.
6.  Riavvia il container e attende che HA risponda.
7.  Verifica versione installata, `check_config` ed errori nel log.

Opzioni: `-y` (nessuna conferma), `--skip-backup`, `--rollback`.

Il backup passa dall'API, quindi serve un token di accesso a lunga vita (profilo utente >
Sicurezza). Lo script lo legge dalla variabile `HA_TOKEN` oppure dal file `.ha_env` alla
radice del repo (ignorato da git, permessi 600):
```bash
HA_TOKEN=xxxx
```

### Tornare indietro
```bash
./scripts/update_ha.sh --rollback
```
Ripristina l'immagine precedente e riavvia. **Attenzione**: il database viene migrato
al primo avvio della versione nuova e la migrazione non è reversibile. Se dopo il
rollback HA si comporta male, ripristina anche il backup fatto prima dell'aggiornamento
(vedi la sezione 5).

### Dopo l'aggiornamento
-   **Svuota la cache del browser.** Il service worker continua a servire il frontend
    vecchio finché non chiudi *tutte* le schede di HA: è cache lato client, il server
    non può invalidarla.
-   **Controlla le card HACS.** Le versioni recenti dei plugin possono richiedere una
    versione di HA più nuova, e viceversa: un plugin troppo avanti rispetto al core
    fa apparire "Errore di configurazione" su tutte le card che lo usano.
-   Controlla *Impostazioni > Sistema > Log* e la sezione *Riparazioni*.

============================================================

## 5. Backup & Disaster Recovery

Cosa serve per ricostruire tutto, e dove sta:

| Cosa | Dove |
|---|---|
| Sistema operativo, container, servizi | Questo repository (Ignition + `push_update.sh`) |
| Token del tunnel (`secrets.env`) | Si rigenera dal pannello Cloudflare Zero Trust |
| Dati e configurazione di Home Assistant | **Backup nativi di HA**, cifrati |
| Chiave di cifratura dei backup | Kit di emergenza, da conservare in un gestore di password |

### Backup
Si configurano da *Impostazioni > Sistema > Backup* (le impostazioni stanno in
`.storage`, quindi viaggiano con il backup stesso):
-   backup automatico ogni notte, cifrato, cronologia compresa;
-   copie sul server (`/var/home/homeassistant/config/backups/`) e su un archivio cloud
    (es. integrazione Google Drive), ognuna con la sua conservazione;
-   `update_ha.sh` ne fa uno in più subito prima di ogni aggiornamento.

Backup manuale: *Impostazioni > Sistema > Backup > Esegui backup ora*.

### Ripristinare
**HA funziona** (es. dopo un aggiornamento andato male): *Impostazioni > Sistema >
Backup*, scegli il backup, *Ripristina* e inserisci la chiave di cifratura.

**HA non parte, o server reinstallato:**
1.  Se serve, reinstalla il server (sezione 2) e lancia `./scripts/push_update.sh`.
2.  Se la vecchia configurazione è ancora lì ma rotta, mettila da parte così HA riparte da zero:
    ```bash
    ssh fcos-ha 'svc-run homeassistant systemctl --user stop homeassistant.service \
      && sudo -u homeassistant mv /var/home/homeassistant/config /var/home/homeassistant/config.rotta \
      && sudo -u homeassistant mkdir -m 0750 /var/home/homeassistant/config \
      && svc-run homeassistant systemctl --user start homeassistant.service'
    ```
3.  Apri `http://<ip-del-server>:8123`: nella procedura iniziale scegli
    **Ripristina da backup** e carica il file `.tar` (dall'archivio cloud, oppure da
    `/var/home/homeassistant/config.rotta/backups/`).
4.  Inserisci la chiave di cifratura e attendi il riavvio.

============================================================

## 6. Accesso Esterno & Troubleshooting

### URL di Accesso
*   **Esterno (HTTPS):** `https://<tuo-hostname-cloudflare>` (configurato nel file `secrets.env`)
*   **Locale (HTTP):** `http://192.168.1.100:8123`

### Problemi Comuni

#### Tunnel Cloudflare non raggiungibile
Cloudflare Tunnel non richiede IP pubblico statico né apertura di porte sul router. I problemi sono quasi sempre legati al servizio `cloudflared` sul server.

1.  **Verifica lo stato del servizio:**
    ```bash
    ssh fcos-ha "svc-run cloudflared systemctl --user status cloudflared.service"
    ```
    Se non è `active (running)`, prova a riavviarlo:
    ```bash
    ssh fcos-ha "svc-run cloudflared systemctl --user restart cloudflared.service"
    ```

2.  **Controlla i log in tempo reale:**
    ```bash
    ssh fcos-ha "journalctl _UID=1002 --user-unit cloudflared.service -f"
    ```
    Cerca messaggi di errore relativi alla connessione con i server di Cloudflare o al token di autenticazione.

### Comandi Utili sul Server

**Stato dei servizi:**
```bash
# Home Assistant (utente homeassistant)
svc-run homeassistant systemctl --user status homeassistant.service

# Cloudflare Tunnel (utente cloudflared)
svc-run cloudflared systemctl --user status cloudflared.service
```

**Log in tempo reale** (core è nel gruppo `systemd-journal`, non serve sudo):
```bash
# Home Assistant
journalctl _UID=1001 --user-unit homeassistant.service -f

# Cloudflare Tunnel
journalctl _UID=1002 --user-unit cloudflared.service -f
```

**Aggiornamento manuale delle immagini container:**
```bash
# cloudflared: forza subito il controllo notturno
svc-run cloudflared systemctl --user start podman-auto-update.service

# Home Assistant: dal PC, con backup e rollback
./scripts/update_ha.sh
```