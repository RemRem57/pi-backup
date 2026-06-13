# pi-backup

Système de backup automatisé de la carte SD (OS) du Raspberry Pi 5 vers le HDD USB.
Notifications Slack, métriques Prometheus/Grafana, rotation automatique des snapshots.

---

## Sommaire

- [Architecture](#architecture)
- [Prérequis](#prérequis)
- [Installation](#installation)
- [Configuration](#configuration)
- [Utilisation manuelle](#utilisation-manuelle)
- [Planification via OMV](#planification-via-omv)
- [Grafana](#grafana)
- [Restauration](#restauration)
- [Maintenance](#maintenance)
- [Troubleshooting](#troubleshooting)

---

## Architecture

```
Raspberry Pi 5 (SD Card — OS)
         │
         │  borgbackup — incrémental + chiffré
         ▼
HDD USB 4To (/srv/dev-disk-by-uuid-686E-B978/backups/rpi-os)
         │
         ├── Notifications  → Slack
         └── Métriques      → Pushgateway → Prometheus → Grafana
```

**Philosophie** : Python orchestre uniquement. Borgbackup fait le vrai travail (backup, déduplication, chiffrement, rotation). Les mises à jour de l'un n'impactent pas l'autre.

**Ce qui est sauvegardé** : tout `/` sauf les dossiers système régénérés au boot (`/proc`, `/sys`, `/dev`, `/tmp`, `/run`) et les volumes montés (RAID, HDD).

**Ce qui n'est PAS sauvegardé** (inutile) :
- Le RAID 5 — données NAS (photos, vidéos)
- Le HDD USB lui-même — c'est la destination du backup

---

## Prérequis

- Raspberry Pi OS Lite 64 bits
- borgbackup : `sudo apt install -y borgbackup`
- uv (gestionnaire de dépendances Python) : `curl -LsSf https://astral.sh/uv/install.sh | sh`
- HDD USB monté et accessible
- Webhook Slack configuré
- Stack Docker avec Prometheus + Pushgateway

---

## Installation

### 1. Cloner le projet

```bash
mkdir -p /appData/pi-backup
cd /appData/pi-backup
# Copier les fichiers du projet ici
```

### 2. Installer les dépendances

```bash
cd /appData/pi-backup
uv venv
uv pip install -e .
```

### 3. Créer le fichier mot de passe Borg

```bash
echo "ton-mot-de-passe-fort" > /appData/pi-backup/.borg-password
chmod 600 /appData/pi-backup/.borg-password
```

> ⚠️ **IMPORTANT** : Sauvegarder ce mot de passe en dehors du Pi (gestionnaire de mots de passe, etc.). Sans lui, les backups sont irrécupérables.

### 4. Initialiser le repo Borg

```bash
BORG_PASSPHRASE=$(cat /appData/pi-backup/.borg-password) \
  borg init --encryption=repokey /srv/dev-disk-by-uuid-686E-B978/backups/rpi-os
```

### 5. Exporter et sauvegarder la clé Borg

```bash
BORG_PASSPHRASE=$(cat /appData/pi-backup/.borg-password) \
  borg key export \
  /srv/dev-disk-by-uuid-686E-B978/backups/rpi-os \
  /appData/pi-backup/borg-key-backup.txt
```

> Stocker `borg-key-backup.txt` en lieu sûr hors du Pi.

---

## Configuration

Fichier : `/appData/pi-backup/config.yaml`

```yaml
borg:
  repository: /srv/dev-disk-by-uuid-686E-B978/backups/rpi-os
  password_file: /appData/pi-backup/.borg-password
  compression: lz4          # lz4 = rapide | zstd = meilleur ratio
  excludes:
    - /proc
    - /sys
    - /dev
    - /tmp
    - /run
    - /mnt
    - /lost+found
    - /srv/dev-disk-by-uuid-c2939c2b-3899-4767-b3f0-b0505a98e397  # RAID
    - /srv/dev-disk-by-uuid-686E-B978                              # HDD (destination)
  retention:
    keep_daily: 7     # 7 derniers jours
    keep_weekly: 4    # 4 dernières semaines
    keep_monthly: 3   # 3 derniers mois

slack:
  webhook_url: "https://hooks.slack.com/services/XXX/YYY/ZZZ"

prometheus:
  pushgateway_url: "http://localhost:9091"
  job: "pi_backup"
  instance: "rpi5"
```

### Rétention des snapshots

Avec la config par défaut, Borg conserve :
- 1 snapshot par jour pendant 7 jours
- 1 snapshot par semaine pendant 4 semaines
- 1 snapshot par mois pendant 3 mois

Les anciens snapshots sont supprimés automatiquement après chaque backup (`borg prune`).

---

## Utilisation manuelle

Le CLI s'appelle via `sudo` (nécessaire pour lire tous les fichiers système).

### Lancer un backup

```bash
sudo /appData/pi-backup/.venv/bin/pi-backup backup --config /appData/pi-backup/config.yaml
```

### Lancer un check d'intégrité

Vérifie que tous les snapshots sont intacts et restaurables.

```bash
sudo /appData/pi-backup/.venv/bin/pi-backup check --config /appData/pi-backup/config.yaml
```

### Lister les snapshots existants

```bash
BORG_PASSPHRASE=$(cat /appData/pi-backup/.borg-password) \
  borg list /srv/dev-disk-by-uuid-686E-B978/backups/rpi-os
```

---

## Planification via OMV

Deux tâches à créer dans OMV : **System → Scheduled Tasks**.

### Tâche 1 — Backup quotidien (3h00)

| Champ | Valeur |
|---|---|
| Enabled | ✅ |
| Minute | `0` |
| Hour | `3` |
| Day of month | `*` |
| Month | `*` |
| Day of week | `*` |
| Command | `/appData/pi-backup/.venv/bin/pi-backup backup --config /appData/pi-backup/config.yaml` |
| Run as | `root` |

### Tâche 2 — Check d'intégrité hebdomadaire (dimanche 4h00)

| Champ | Valeur |
|---|---|
| Enabled | ✅ |
| Minute | `0` |
| Hour | `4` |
| Day of month | `*` |
| Month | `*` |
| Day of week | `0` (dimanche) |
| Command | `/appData/pi-backup/.venv/bin/pi-backup check --config /appData/pi-backup/config.yaml` |
| Run as | `root` |

> Les résultats apparaîtront dans Slack et dans Grafana automatiquement.

---

## Grafana

Le dashboard **Pi Backup** (`pi-backup-grafana-dashboard.json`) expose 6 panels :

| Panel | Description | Alerte |
|---|---|---|
| Statut dernier backup | Vert = OK, Rouge = échec | Rouge si échec |
| Durée dernier backup | En secondes | Jaune > 5min, Rouge > 10min |
| Depuis dernier backup | Temps écoulé | Rouge si > 25h |
| Jauge durée | Visuel rapide | — |
| Historique durée | Time series 7 jours | — |
| Historique statut | Time series succès/échec | — |

### Import

1. Grafana → **Dashboards → Import**
2. Upload `pi-backup-grafana-dashboard.json`
3. Sélectionner la datasource Prometheus

---

## Restauration

> À faire depuis une autre machine Linux ou depuis une nouvelle SD.

### 1. Installer borgbackup

```bash
sudo apt install -y borgbackup
```

### 2. Brancher le HDD USB et le monter

```bash
sudo mkdir -p /mnt/hdd
sudo mount /dev/sdX1 /mnt/hdd  # adapter le device
```

### 3. Lister les snapshots disponibles

```bash
BORG_PASSPHRASE="ton-mot-de-passe" \
  borg list /mnt/hdd/backups/rpi-os
```

### 4. Restaurer le dernier snapshot

```bash
# Monter la nouvelle SD
sudo mkdir -p /mnt/new-sd
sudo mount /dev/mmcblkX /mnt/new-sd

# Restaurer
BORG_PASSPHRASE="ton-mot-de-passe" \
  borg extract \
  /mnt/hdd/backups/rpi-os::NOM_DU_SNAPSHOT \
  --target /mnt/new-sd
```

### 5. Restaurer uniquement un fichier/dossier

```bash
BORG_PASSPHRASE="ton-mot-de-passe" \
  borg extract \
  /mnt/hdd/backups/rpi-os::NOM_DU_SNAPSHOT \
  etc/ssh/sshd_config    # chemin relatif sans /
```

---

## Maintenance

### Mettre à jour les dépendances Python

```bash
cd /appData/pi-backup
uv lock --upgrade
uv pip install -e .
```

### Mettre à jour borgbackup

```bash
sudo apt update && sudo apt upgrade -y borgbackup
```

### Ajouter une exclusion

Éditer `/appData/pi-backup/config.yaml`, ajouter une ligne sous `excludes`. Aucun redémarrage nécessaire, pris en compte au prochain backup.

### Changer la rétention

Éditer `/appData/pi-backup/config.yaml`, modifier `retention`. Pris en compte au prochain backup.

### Ajouter une 2e destination (cloud / VPS)

Dans `config.yaml`, dupliquer le bloc `borg` et ajouter un 2e repository SSH :

```yaml
borg:
  repository: ssh://user@vps-ip/backups/rpi-os
```

Borgmatic supporte nativement plusieurs destinations — évolution possible si besoin.

---

## Troubleshooting

### Slack ne reçoit pas les notifications

Vérifier le webhook dans `config.yaml`. Tester manuellement :

```bash
curl -X POST "TON_WEBHOOK_URL" \
  -H 'Content-type: application/json' \
  --data '{"text":"Test"}'
```

### Prometheus ne reçoit pas les métriques

Vérifier que le Pushgateway tourne :

```bash
curl -s http://localhost:9091/metrics | head -3
```

Vérifier les containers Docker :

```bash
docker ps | grep pushgateway
```

### Borg demande la passphrase interactivement

Vérifier que le fichier `.borg-password` est lisible et contient la bonne valeur :

```bash
sudo cat /appData/pi-backup/.borg-password
BORG_PASSPHRASE=$(cat /appData/pi-backup/.borg-password) \
  borg list /srv/dev-disk-by-uuid-686E-B978/backups/rpi-os
```

### Le backup inclut le RAID ou le HDD

Vérifier les exclusions dans `config.yaml`. Lister les points de montage :

```bash
df -h
```

S'assurer que chaque point de montage est bien dans la liste `excludes`.

### Nettoyer une archive partielle (après un ctrl+C)

```bash
BORG_PASSPHRASE=$(cat /appData/pi-backup/.borg-password) \
  borg delete --glob-archives '*' \
  /srv/dev-disk-by-uuid-686E-B978/backups/rpi-os
```

---

## Structure du projet

```
/appData/pi-backup/
├── pyproject.toml              # Dépendances Python (uv)
├── config.yaml                 # Configuration principale
├── .borg-password              # Passphrase Borg (chmod 600)
├── borg-key-backup.txt         # Export clé Borg (à stocker ailleurs)
├── .venv/                      # Environnement virtuel Python
├── backup/
│   ├── __init__.py
│   ├── config.py               # Modèles Pydantic
│   ├── borg.py                 # Wrapper borgbackup
│   ├── main.py                 # CLI (backup | check)
│   └── notifiers/
│       ├── slack.py            # Notifications Slack
│       └── prometheus.py       # Métriques Pushgateway
└── grafana/
    └── pi-backup-dashboard.json
```