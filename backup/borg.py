import os
import re
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path

from loguru import logger

from .config import BorgConfig


@dataclass
class BorgStats:
    original_size: str = "N/A"
    compressed_size: str = "N/A"
    dedup_size: str = "N/A"
    nfiles: str = "N/A"


@dataclass
class BorgResult:
    success: bool
    duration: float
    archive_name: str
    stats: BorgStats = field(default_factory=BorgStats)
    error: str = ""


class BorgBackup:
    def __init__(self, config: BorgConfig) -> None:
        self.config = config
        self._env = {
            **os.environ,
            "BORG_REPO": config.repository,
            "BORG_PASSPHRASE": Path(config.password_file).read_text().strip(),
        }
        if config.rsh:
            self._env["BORG_RSH"] = config.rsh

    def _run(self, *args: str) -> subprocess.CompletedProcess:
        cmd = ["borg"]
        if self.config.remote_path:
            cmd += ["--remote-path", self.config.remote_path]
        cmd += [*args]
        logger.debug("Running: {}", " ".join(cmd))
        return subprocess.run(cmd, capture_output=True, text=True, env=self._env)

    def backup(self, archive_name: str) -> BorgResult:
        start = time.monotonic()

        excludes: list[str] = []
        for path in self.config.excludes:
            excludes += ["--exclude", path]

        proc = self._run(
            "create", "--stats",
            "--compression", self.config.compression,
            *excludes,
            f"::{archive_name}",
            "/",
        )

        duration = time.monotonic() - start

        if proc.returncode != 0:
            logger.error("borg create failed:\n{}", proc.stderr)
            return BorgResult(False, duration, archive_name, error=proc.stderr)

        logger.info("borg create succeeded in {:.0f}s", duration)
        return BorgResult(
            success=True,
            duration=duration,
            archive_name=archive_name,
            stats=self._parse_stats(proc.stdout + proc.stderr),
        )

    def prune(self) -> bool:
        r = self.config.retention
        proc = self._run(
            "prune",
            "--keep-daily", str(r.keep_daily),
            "--keep-weekly", str(r.keep_weekly),
            "--keep-monthly", str(r.keep_monthly),
        )
        if proc.returncode != 0:
            logger.warning("borg prune failed:\n{}", proc.stderr)
        return proc.returncode == 0

    def check(self) -> bool:
        proc = self._run("check")
        return proc.returncode == 0

    @staticmethod
    def _parse_stats(output: str) -> BorgStats:
        stats = BorgStats()
        lines = [l for l in output.splitlines() if "This archive:" in l]
        if lines:
            parts = lines[0].split()
            # Format: "This archive: X.XX MB X.XX MB X.XX MB N"
            nums = [p for p in parts if re.match(r"[\d.]+", p)]
            units = [p for p in parts if p in ("B", "kB", "MB", "GB", "TB")]
            if len(nums) >= 3 and len(units) >= 3:
                stats.original_size   = f"{nums[0]} {units[0]}"
                stats.compressed_size = f"{nums[1]} {units[1]}"
                stats.dedup_size      = f"{nums[2]} {units[2]}"

        nfiles = re.search(r"Number of files:\s+(\d+)", output)
        if nfiles:
            stats.nfiles = nfiles.group(1)

        return stats