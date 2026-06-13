import socket
import time

from loguru import logger
from slack_sdk.webhook import WebhookClient
from slack_sdk.errors import SlackApiError

from ..config import SlackConfig
from ..borg import BorgResult


COLORS = {
    "info":    "#439FE0",
    "success": "#2EB67D",
    "error":   "#E01E5A",
}

HOSTNAME = socket.gethostname()


class SlackNotifier:
    def __init__(self, config: SlackConfig) -> None:
        self.client = WebhookClient(config.webhook_url)

    def _send(self, color: str, title: str, fields: list[dict]) -> None:
        try:
            response = self.client.send(
                attachments=[{
                    "color": color,
                    "title": title,
                    "fields": fields,
                    "footer": HOSTNAME,
                    "ts": int(time.time()),
                }]
            )
            if response.status_code != 200:
                logger.warning("Slack {}: {}", response.status_code, response.body)
        except SlackApiError as e:
            logger.warning("Slack send failed: {}", e)

    def backup_started(self, archive_name: str) -> None:
        self._send(COLORS["info"], "🔄 Backup démarré", [
            {"title": "Archive", "value": archive_name, "short": True},
        ])

    def backup_success(self, result: BorgResult) -> None:
        self._send(COLORS["success"], "✅ Backup terminé", [
            {"title": "Archive",    "value": result.archive_name,        "short": True},
            {"title": "Durée",      "value": f"{result.duration:.0f}s",  "short": True},
            {"title": "Original",   "value": result.stats.original_size, "short": True},
            {"title": "Dédupliqué", "value": result.stats.dedup_size,    "short": True},
            {"title": "Fichiers",   "value": result.stats.nfiles,        "short": True},
        ])

    def backup_failed(self, result: BorgResult) -> None:
        self._send(COLORS["error"], "❌ Backup échoué", [
            {"title": "Archive", "value": result.archive_name,              "short": True},
            {"title": "Durée",   "value": f"{result.duration:.0f}s",        "short": True},
            {"title": "Erreur",  "value": f"```{result.error[-400:]}```",   "short": False},
        ])

    def check_failed(self) -> None:
        self._send(COLORS["error"], "🚨 Intégrité repository compromise", [
            {"title": "Action", "value": "Vérifier le repo Borg manuellement", "short": False},
        ])