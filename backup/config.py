from pathlib import Path

import yaml
from pydantic import BaseModel


class BorgRetention(BaseModel):
    keep_daily: int = 7
    keep_weekly: int = 4
    keep_monthly: int = 3


class BorgConfig(BaseModel):
    repository: str
    password_file: str
    compression: str = "lz4"
    excludes: list[str] = []
    retention: BorgRetention = BorgRetention()
    rsh: str | None = None
    remote_path: str | None = None


class SlackConfig(BaseModel):
    webhook_url: str


class PrometheusConfig(BaseModel):
    pushgateway_url: str
    job: str = "pi_backup"
    instance: str = "rpi5"


class NextcloudConfig(BaseModel):
    borg: BorgConfig                      # repo Borg dédié (≠ repo OS)
    data_dir: str                         # datadir Nextcloud sur le RAID
    db_password_file: str                 # fichier contenant le mot de passe DB
    db_container: str = "nextcloud-db"
    db_name: str = "nextcloud"
    db_user: str = "nextcloud"
    app_container: str = "nextcloud"
    dump_dir: str = "/appdata/pi-backup/.nextcloud-dump"
    prometheus_job: str = "nextcloud_backup"

class ResolveConfig(BaseModel):
    borg: BorgConfig                          # repo Borg dédié (≠ repo OS, ≠ repo nextcloud)
    postgres_container: str = "resolve-postgres"
    postgres_user: str = "postgres"
    db_password_file: str | None = None       # optionnel si pg_hba trust en local
    dump_dir: str = "/appdata/pi-backup/.resolve-dump"
    prometheus_job: str = "resolve_backup"

class Config(BaseModel):
    borg: BorgConfig
    slack: SlackConfig
    prometheus: PrometheusConfig
    nextcloud: NextcloudConfig | None = None
    resolve: ResolveConfig | None = None

    @classmethod
    def from_yaml(cls, path: Path = Path("/appdata/pi-backup/config.yaml")) -> "Config":
        with open(path) as f:
            data = yaml.safe_load(f)
        return cls(**data)