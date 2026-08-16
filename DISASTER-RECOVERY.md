# DISASTER-RECOVERY

Procédure de restauration du NAS (Raspberry Pi 5, hostname `stephane`).

> **Ce fichier vit dans ce dépôt volontairement.** Il décrit des chemins, des UUID et des
> commandes qui changent en même temps que le code. Toute modification de `backup-now.sh`,
> `config.yaml` ou des chemins de repo doit se refléter ici **dans le même commit**.
>
> Une copie de ce contenu existe dans 1Password (note « Restauration NAS », à côté de la clé
> Borg). C'est celle qui sert le jour J — elle est accessible sans réseau et sans le Pi.

---

## 0. Avant tout — les secrets

Aucun secret n'est dans ce dépôt. Tout est dans **1Password** :

| Élément | Sert à |
|---|---|
| Passphrase Borg OS (`.borg-password`) | ouvrir le repo `stephane-os` |
| Passphrase Borg Nextcloud (`.nextcloud-borg-password`) | ouvrir le repo `nextcloud-data` |
| Clés Borg exportées (`borg-key-backup.txt`, `nextcloud-borg-key-backup.txt`) | secours si l'en-tête du repo est endommagé |
| Mot de passe DB Nextcloud (`.nextcloud-db-password`) | réimporter le dump SQL |
| Credentials OVH `cold-admin` | accès complet au bucket d'archive froide |
| Credentials OMV, Grafana, Nextcloud admin | remonter les interfaces |
| Webhook Slack | présent dans `config.yaml`, hors git |

> **Sans la passphrase Borg, les backups sont définitivement irrécupérables.** Il n'existe
> aucun mécanisme de récupération. Vérifier périodiquement que les entrées 1Password sont
> à jour et lisibles.

---

## 1. Repères matériels

| Élément | Valeur |
|---|---|
| Hostname / user | `stephane` / `rzapp` |
| IP LAN | `192.168.50.59` |
| IP Tailscale | `100.118.178.103` |
| RAID 5 (4× SSD, ext4) | `/srv/dev-disk-by-uuid-c2939c2b-3899-4767-b3f0-b0505a98e397` |
| HDD USB (exFAT) | `/srv/dev-disk-by-uuid-686E-B978` — UUID `686E-B978` |

Repos Borg sur le HDD USB :

- `backups/stephane-os` — OS complet (`/`, hors volumes montés)
- `backups/nextcloud-data` — datadir Nextcloud + dump SQL + `config/`

Archive froide : bucket OVH `rzapp-nextcloud-cold`, région `eu-west-par`, classe
`DEEP_ARCHIVE` (restauration lente, jusqu'à 48h).

> Ces valeurs changent lors de la migration HDD exFAT → ext4. **Mettre ce tableau à jour
> dans le même commit que `config.yaml` et la règle udev.**

---

## 2. Scénario A — SD morte, RAID intact

Le cas le plus probable. Les données ne sont pas en jeu : seul l'OS est à reconstruire.

### A.1 — Préparer une machine

```bash
sudo apt install -y borgbackup
```

Monter le HDD USB (adapter le device) :

```bash
sudo mkdir -p /mnt/hdd
sudo mount /dev/sdX1 /mnt/hdd
```

### A.2 — Lister les snapshots

```bash
export BORG_PASSPHRASE='<depuis 1Password>'
borg list /mnt/hdd/backups/stephane-os
```

### A.3 — Restaurer

Sur une SD neuve flashée en Raspberry Pi OS Lite 64 bits, montée sur `/mnt/new-sd` :

```bash
borg extract --progress \
  /mnt/hdd/backups/stephane-os::<NOM_DU_SNAPSHOT> \
  --target /mnt/new-sd
```

Pour un seul fichier (chemin **relatif**, sans `/` initial) :

```bash
borg extract /mnt/hdd/backups/stephane-os::<SNAPSHOT> etc/ssh/sshd_config
```

### A.4 — Vérifier ce qui n'est dans aucun dépôt git

Ces fichiers sont dans l'archive (car sous `/`), mais leur absence est **silencieuse** —
rien ne signalera qu'ils manquent :

- `/etc/udev/rules.d/99-backup-hdd.rules`
- `/etc/systemd/system/backup-hdd.service`
- `/appdata/pi-backup/config.yaml` (contient le webhook Slack et les exclusions)
- `/appdata/loki/loki-config.yaml`
- `/appdata/alloy/config.alloy`
- `/appdata/rclone/rclone.conf` (chmod 600, root only)
- `/appdata/tapo-exporter/.env`
- `/docker-compose/nextcloud/.env`

Réactiver le déclenchement automatique :

```bash
sudo udevadm control --reload-rules
sudo systemctl daemon-reload
```

---

## 3. Scénario B — Perte des données Nextcloud

Repo `nextcloud-data` : datadir (RAID) + dump `mariadb-dump --single-transaction` +
dossier `config/`.

```bash
export BORG_PASSPHRASE='<passphrase Nextcloud, depuis 1Password>'
borg list /mnt/hdd/backups/nextcloud-data
borg extract --progress /mnt/hdd/backups/nextcloud-data::<SNAPSHOT>
```

Réimporter la base dans le conteneur MariaDB, puis remettre le datadir en place sur le RAID
et restaurer `config/`.

> ⚠️ Le volume Docker nommé `nextcloud_html` contient `config.php` et **n'est pas dans ce
> repo**. C'est ce qui avait été détruit par un `docker compose down -v`. Ne jamais utiliser
> `-v` sur cette stack.

Procédure validée par un test réel (extraction + import dans une base jetable).

---

## 4. Scénario C — Perte du Pi ET du HDD

L'archive froide OVH est alors la seule copie.

- Objets S3 **individuels**, pas un repo Borg → `rclone copy` en sens inverse, pas de
  `borg extract`.
- Pas de chiffrement côté client : les données sont lisibles telles quelles.
- Classe `DEEP_ARCHIVE` → restauration sur demande, jusqu'à 48h.
- Utiliser les credentials `cold-admin` (1Password). Ceux du Pi sont write-only.

> ⚠️ **Ce scénario n'a jamais été validé de bout en bout.** Tant que le drill n'est pas fait,
> l'archive froide ne doit pas être considérée comme une copie fiable.

---

## 5. Ordre de remontage des services

L'ordre compte : le réseau Docker externe doit exister avant les stacks.

```bash
# 1. Réseau partagé Caddy ↔ Grafana ↔ Loki
docker network create proxy

# 2. Nextcloud (db → redis → nextcloud → caddy)
cd /docker-compose/nextcloud && docker compose up -d

# 3. Exporters
cd /docker-compose/exporters && docker compose up -d

# 4. Monitoring
cd /docker-compose/monitoring && docker compose up -d
```

Points de vigilance :

- **Prometheus tourne en `network_mode: host`** — sa datasource Grafana doit pointer
  `http://192.168.50.59:9090`, pas `http://prometheus:9090`.
- **Bind mounts et ownership** — chaque nouveau bind mount exige un `chown` explicite vers
  l'UID du conteneur avant le premier démarrage : Grafana `472:472`, Pushgateway et
  Prometheus `65534:65534`, Loki `10001:10001`.
- **DNS Docker** — `/etc/docker/daemon.json` force `1.1.1.1` / `9.9.9.9`. Sans ça, les
  conteneurs ne résolvent rien (app store Nextcloud et ACME Caddy cassés).
- **`vm.overcommit_memory = 1`** (`/etc/sysctl.d/99-redis.conf`) — requis par le Redis de
  Nextcloud.

---

## 6. Vérification post-restauration

- [ ] `borg list` répond sur les deux repos
- [ ] Tous les targets Prometheus en `UP`
- [ ] Grafana affiche les dashboards, datasources Prometheus **et** Loki fonctionnelles
- [ ] `https://cloud.rzapp.fr` répond en HTTPS (certificat Let's Encrypt réémis)
- [ ] `https://grafana.rzapp.fr/public-dashboards/...` répond, et `/login` renvoie bien 403
- [ ] Tailscale connecté, `ssh stephane` fonctionne
- [ ] Branchement réel du HDD → séquence complète → ping Slack vert 🔌
- [ ] `{unit="backup-hdd.service"}` visible dans Loki
- [ ] `ls -l backup-now.sh` montre bien le bit exécutable

---

## 7. Pièges déjà rencontrés

| Symptôme | Cause | Fix |
|---|---|---|
| Branchement HDD ne déclenche rien | `backup-now.sh` a perdu son bit exécutable (opération git) | `chmod +x` — figé via `git update-index --chmod=+x` |
| Scrapes Prometheus en timeout | bridge Docker → hôte ne traverse pas iptables/UFW | `network_mode: host` |
| Alloy ne lit aucun log système | `SD_JOURNAL_LOCAL_ONLY` — échec silencieux | `path = "/run/log/journal"` explicite |
| Grafana repart vide après restauration | base en bind mount, pas en volume nommé | récupérer `/appdata/grafana/data`, `chown -R 472:472` |
| Mot de passe admin Grafana inchangé | `GF_SECURITY_ADMIN_PASSWORD` ne s'applique qu'à une base neuve | changer via l'UI |
| Backup Borg échoue par intermittence | Borg s'archive lui-même en sauvegardant `/` | exclure `/root/.config/borg` dans `config.yaml` |
| Alerte OVH ne se déclenche jamais | opérateur PromQL `>` sans `bool` filtre au lieu de renvoyer 0/1 | ajouter `bool` |
