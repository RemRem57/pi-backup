import time

from loguru import logger
from prometheus_client import CollectorRegistry, Gauge, push_to_gateway

from ..config import PrometheusConfig
from ..borg import BorgResult


class PrometheusNotifier:
    def __init__(self, config: PrometheusConfig) -> None:
        self.config = config

    def push(self, result: BorgResult) -> None:
        registry = CollectorRegistry()

        Gauge("backup_success",          "1 if last backup succeeded",        registry=registry).set(int(result.success))
        Gauge("backup_duration_seconds", "Duration of last backup in seconds", registry=registry).set(result.duration)
        Gauge("backup_last_timestamp",   "Unix timestamp of last backup run",  registry=registry).set(time.time())

        try:
            push_to_gateway(
                self.config.pushgateway_url,
                job=self.config.job,
                grouping_key={"instance": self.config.instance},
                registry=registry,
            )
            logger.debug("Metrics pushed to Pushgateway")
        except Exception as e:
            logger.warning("Prometheus push failed: {}", e)