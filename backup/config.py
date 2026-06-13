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


class Config(BaseModel):
    borg: BorgConfig
    slack: SlackConfig
    prometheus: PrometheusConfig

    @classmethod
    def from_yaml(cls, path: Path = Path("/appData/pi-backup/config.yaml")) -> "Config":
        with open(path) as f:
            data = yaml.safe_load(f)
        return cls(**data)