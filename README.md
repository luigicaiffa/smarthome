# Home Assistant su Fedora CoreOS (Podman + Quadlet)

Questo repository contiene l'Infrastructure-as-Code (IaC) per il deployment di **Home Assistant** su **Fedora CoreOS (FCOS)** in modalità "Bare Metal".

Il progetto garantisce un ambiente immutabile, sicuro (Rootless) e persistente.

## ⚠️ Prerequisiti (Strict Mode)

L'accesso al server avviene **esclusivamente via chiavi SSH**.

1.  **Genera la chiave del progetto** (sul tuo PC):
    ```bash
    ssh-keygen -t ed25519 -C "admin@homeassistant" -f ~/.ssh/id_homeassistant
    ```

2.  **Configura il client SSH** (`~/.ssh/config`):
    ```text
    Host fcos-ha
        User core
        Hostname <IP-DEL-SERVER>
        IdentityFile ~/.ssh/id_homeassistant
    ```

## 🛠️ Fase 1: Generazione Configurazione (Ignition)

Lo script inietta la tua chiave pubblica e prepara le direttive per la creazione automatica di cartelle e permessi.

1.  Entra nella cartella scripts:
    ```bash
    cd scripts
    chmod +x generate_ignition.sh
    ```
2.  Genera il file `.ign`:
    ```bash
    ./generate_ignition.sh
    ```
    *Verrà creato il file `config.ign` nella root del progetto.*

## 💿 Fase 2: Installazione OS (Metodo Server Python)

Poiché SCP non funziona facilmente sulla Live ISO, usiamo un server web temporaneo.

1.  **Sul tuo PC di sviluppo:**
    Avvia il server nella cartella dove hai generato `config.ign`:
    ```bash
    python3 -m http.server 8000
    ```
    *Prendi nota dell'IP del tuo PC (es. 192.168.1.50).*

2.  **Sul Mini PC (Tastiera e Monitor collegati):**
    Avvia la Live ISO di Fedora CoreOS. Dalla shell:

    **A. Pulizia del disco (Cruciale se provieni da Ubuntu/LVM)**
    Rimuovi vecchie partizioni che potrebbero bloccare l'installer:
    ```bash
    sudo swapoff -a
    sudo vgchange -an
    sudo dmsetup remove_all
    sudo wipefs --all --force /dev/sda
    ```
    *(Verifica con `lsblk` se il tuo disco è `/dev/sda` o `/dev/nvme0n1`)*.

    **B. Download e Flash**
    ```bash
    # Scarica il file dal tuo PC
    curl -O http://<IP-TUO-PC>:8000/config.ign

    # Installa
    sudo coreos-installer install /dev/sda --ignition-file config.ign
    ```

3.  **Riavvio:**
    Spegni, rimuovi la chiavetta USB e riaccendi.

## 📦 Fase 3: Primo Avvio e Deploy

Ora puoi staccare monitor e tastiera. 
Grazie al file `config.ign` aggiornato, il sistema ha già creato le cartelle e abilitato il Linger (persistenza).

1.  **Collegati via SSH:**
    ```bash
    ssh fcos-ha
    ```
    *(Se ricevi errori "Host Key Verification", dai `ssh-keygen -R <IP-SERVER>`)*.

2.  **Copia i file del progetto sul server:**
    Dal tuo PC (nuovo terminale):
    ```bash
    scp -r scripts/ services/ fcos-ha:~
    ```

3.  **Esegui il Deploy:**
    Dal terminale SSH del server:
    ```bash
    chmod +x scripts/deploy_app.sh
    ./scripts/deploy_app.sh
    ```

    *Questo script installerà il servizio Systemd e avvierà il container.*

## 🔧 Manutenzione

**Controllare lo stato:**
```bash
systemctl --user status homeassistant
```

**Vedere i log:**
```bash
journalctl --user -f -u homeassistant
```

**Aggiornare Home Assistant:**
Il sistema controlla automaticamente gli aggiornamenti. Per forzarlo:
```bash
podman auto-update
```

**Struttura Cartelle:**
* Configurazione HA: `~/homeassistant/config`
* File Systemd: `~/.config/containers/systemd`