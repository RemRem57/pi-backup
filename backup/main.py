import sys
from datetime import datetime
from pathlib import Path

from loguru import logger

from .config import Config
from .borg import BorgBackup, BorgResult
from .nextcloud import NextcloudDumper
from .notifiers.slack import SlackNotifier
from .notifiers.prometheus import PrometheusNotifier


CONFIG_PATH = Path("/appdata/pi-backup/config.yaml")

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


def run_nextcloud(config_path: Path = CONFIG_PATH) -> int:
    config = Config.from_yaml(config_path)
    if config.nextcloud is None:
        logger.error("Section 'nextcloud' absente de la config")
        return 2

    nc    = config.nextcloud
    borg  = BorgBackup(nc.borg)
    slack = SlackNotifier(config.slack)
    # Même Pushgateway que l'OS, mais job distinct pour ne pas écraser ses métriques.
    prom  = PrometheusNotifier(config.prometheus.model_copy(update={"job": nc.prometheus_job}))
    dumper = NextcloudDumper(nc)

    archive_name = f"nextcloud-{datetime.now():%Y%m%d-%H%M%S}"

    logger.info("Starting Nextcloud backup: {}", archive_name)
    slack.backup_started(archive_name)

    try:
        paths = dumper.prepare()                       # dump SQL + config/
        result = borg.backup(archive_name, paths=paths)  # datadir + dump + config
        if result.success:
            logger.info("Pruning old snapshots...")
            borg.prune()
    except Exception as e:
        logger.error("Nextcloud backup error: {}", e)
        result = BorgResult(False, 0.0, archive_name, error=str(e))
    finally:
        dumper.cleanup()                               # supprime dump + config (secrets)

    if result.success:
        slack.backup_success(result)
        logger.info("Done in {:.0f}s", result.duration)
    else:
        slack.backup_failed(result)
        logger.error("Failed")

    prom.push(result)

    return 0 if result.success else 1


def run_notify(config_path: Path, title: str, body: str, *, error: bool) -> int:
    config = Config.from_yaml(config_path)
    slack = SlackNotifier(config.slack)
    slack.notify(title, body, error=error)
    return 0


def run_nextcloud_check(config_path: Path = CONFIG_PATH) -> int:
    config = Config.from_yaml(config_path)
    if config.nextcloud is None:
        logger.error("Section 'nextcloud' absente de la config")
        return 2

    borg  = BorgBackup(config.nextcloud.borg)
    slack = SlackNotifier(config.slack)

    logger.info("Running Nextcloud integrity check...")
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
    parser.add_argument(
        "command",
        choices=["backup", "check", "nextcloud", "nextcloud-check", "notify"],
        default="backup",
        nargs="?",
    )
    parser.add_argument("--config", type=Path, default=CONFIG_PATH)
    parser.add_argument("--title", default="")
    parser.add_argument("--body", default="")
    parser.add_argument("--error", action="store_true")
    args = parser.parse_args()

    if args.command == "notify":
        sys.exit(run_notify(args.config, args.title, args.body, error=args.error))

    dispatch = {
        "backup": run_backup,
        "check": run_check,
        "nextcloud": run_nextcloud,
        "nextcloud-check": run_nextcloud_check,
    }
    sys.exit(dispatch[args.command](args.config))


if __name__ == "__main__":
    cli()