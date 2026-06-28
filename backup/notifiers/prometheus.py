import time

from loguru import logger
from prometheus_client import CollectorRegistry, Gauge, push_to_gateway, pushadd_to_gateway

from ..config import PrometheusConfig
from ..borg import BorgResult


class PrometheusNotifier:
    def __init__(self, config: PrometheusConfig) -> None:
        self.config = config

    def push(self, result: BorgResult) -> None:
        registry = CollectorRegistry()

        Gauge("backup_success",          "1 if last backup succeeded",        registry=registry).set(int(result.success))
        Gauge("backup_duration_seconds", "Duration of last backup in seconds", registry=registry).set(result.duration)

        # backup_last_timestamp n'est mis à jour que sur succès : un échec ne doit pas
        # repousser le filet Grafana "backup trop ancien" et masquer des échecs répétés.
        # Sur succès : push (PUT) remplace tout le groupe. Sur échec : pushadd (POST)
        # met à jour uniquement les deux métriques ci-dessus sans toucher au timestamp.
        if result.success:
            Gauge("backup_last_timestamp", "Unix timestamp of last successful backup", registry=registry).set(time.time())
            push_fn = push_to_gateway
        else:
            push_fn = pushadd_to_gateway

        try:
            push_fn(
                self.config.pushgateway_url,
                job=self.config.job,
                grouping_key={"instance": self.config.instance},
                registry=registry,
            )
            logger.debug("Metrics pushed to Pushgateway")
        except Exception as e:
            logger.warning("Prometheus push failed: {}", e)