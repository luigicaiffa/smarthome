# 🏠 Smart Home Infrastructure (Fedora CoreOS + Podman)

Benvenuto nel repository **Infrastructure-as-Code (IaC)** per la tua Smart Home.
Questo progetto automatizza il deployment di **Home Assistant**, **Caddy** (Reverse Proxy con HTTPS automatico) e **DuckDNS** su un sistema operativo robusto e minimale: **Fedora CoreOS**.

### ✨ Filosofia del Progetto
*   🛡️ **Immutabile:** Sistema operativo gestito via `ostree`, aggiornamenti atomici.
*   🔒 **Rootless:** I container girano senza privilegi di root (Podman Quadlet) per la massima sicurezza.
*   🤖 **Zero-Touch:** Installazione tramite ISO autoconfigurante. Inserisci la chiavetta e fa tutto da solo.
*   🔄 **Smart Restore:** Ripristino intelligente che unisce i dati storici con la configurazione più recente.

---

## 📂 Struttura del Repository

```text
📂 .
├── 📂 backups/              # 📦 Backup scaricati dal server (ignorati da git)
├── 📂 services/             # ⚙️ Definizioni dei Container (Systemd/Quadlet .container)
├── 📂 scripts/              # 🛠️ Script di automazione (Build, Deploy, Backup)
├── 📄 config.bu.template    # 📄 Template Butane per la configurazione dell'OS
├── 📄 Caddyfile             # 🌐 Configurazione Reverse Proxy
├── 📄 secrets.env.template  # 📄 Template per le variabili d'ambiente
├── � secrets.env           # 🔑 Variabili sensibili (NON committare su Git!)
└── 📘 README.md             # 📖 Questo file
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
Se hai modificato un .container, il Caddyfile o secrets.env:
```bash
./scripts/push_update.sh
```

Questo script:
1.  Copia le configurazioni aggiornate (services/, scripts/, Caddyfile) sul server.
2.  Aggiorna il file dei segreti.
3.  Ricarica Systemd e riavvia i servizi necessari automaticamente.

============================================================

## 4. Backup & Disaster Recovery

### Eseguire Backup
Salva database, configurazioni storage e certificati SSL dal server al tuo PC.
```bash
./scripts/remote_backup.sh
```

Il file .tar.gz verrà salvato nella cartella locale backups/.

### Ripristinare (Restore)
Da usare dopo una reinstallazione o su un nuovo hardware.
```bash
./scripts/remote_restore.sh
```

Logica "Smart Restore":
1.  Carica ed estrae i DATI dal backup (Database, Storico, Certificati).
2.  Sovrascrive la CONFIGURAZIONE (Caddyfile, Secrets, Services) prendendola dal tuo PC attuale.
    Questo evita di ripristinare configurazioni obsolete che potrebbero rompere il sistema.

============================================================

## 5. Accesso Esterno & Troubleshooting

### URL di Accesso
* Esterno (HTTPS): https://tuosottodominio.duckdns.org
* Locale (HTTP): http://192.168.1.100:8123

### Problemi Comuni

#### Errore SSL / Sito non raggiungibile
1.  Verifica che Caddy abbia preso il certificato:
    ssh fcos-ha "podman logs caddy" | grep "certificate obtained"

2.  Se Caddy è OK ma non accedi, verifica di avere un IP Pubblico Reale.
    * Confronta l'IP WAN del modem con quello su mioip.it.
    * Se diversi -> Sei sotto CGNAT. Chiama il provider (es. TIM) per sbloccare l'IP pubblico.

#### Comandi Utili sul Server

# Stato dei servizi
```bash
systemctl --user status caddy homeassistant duckdns
```

# Log in tempo reale
```bash
journalctl --user -f -u homeassistant
podman logs -f caddy
podman logs -f duckdns-updater
```

# Aggiornamento manuale immagini
```bash
podman auto-update
```