import sys
from datetime import datetime
from pathlib import Path

from loguru import logger

from .config import Config
from .borg import BorgBackup
from .notifiers.slack import SlackNotifier
from .notifiers.prometheus import PrometheusNotifier


CONFIG_PATH = Path("/appData/pi-backup/config.yaml")

logger.remove()
logger.add(sys.stdout, format="{time:YYYY-MM-DD HH:mm:ss} | {level:<8} | {message}")


def run_backup(config_path: Path = CONFIG_PATH) -> int:
    config = Config.from_yaml(config_path)

    borg  = BorgBackup(config.borg)
    slack = SlackNotifier(config.slack)
    prom  = PrometheusNotifier(config.prometheus)

    archive_name = f"os-{datetime.now():%Y%m%d-%H%M%S}"

    logger.info("Starting backup: {}", archive_name)
    slack.backup_started(archive_name)

    result = borg.backup(archive_name)

    if result.success:
        logger.info("Pruning old snapshots...")
        borg.prune()
        slack.backup_success(result)
        logger.info("Done in {:.0f}s", result.duration)
    else:
        slack.backup_failed(result)
        logger.error("Failed after {:.0f}s", result.duration)

    prom.push(result)

    return 0 if result.success else 1


def run_check(config_path: Path = CONFIG_PATH) -> int:
    config = Config.from_yaml(config_path)
    borg  = BorgBackup(config.borg)
    slack = SlackNotifier(config.slack)

    logger.info("Running integrity check...")
    ok = borg.check()

    if ok:
        logger.info("Repository integrity OK")
    else:
        logger.error("Integrity check FAILED")
        slack.check_failed()

    return 0 if ok else 1


def cli() -> None:
    import argparse

    parser = argparse.ArgumentParser(description="Pi backup manager")
    parser.add_argument("command", choices=["backup", "check"], default="backup", nargs="?")
    parser.add_argument("--config", type=Path, default=CONFIG_PATH)
    args = parser.parse_args()

    fn = run_backup if args.command == "backup" else run_check
    sys.exit(fn(args.config))


if __name__ == "__main__":
    cli()