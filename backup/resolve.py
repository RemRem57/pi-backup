import os
import shutil
import subprocess
from pathlib import Path

from loguru import logger

from .config import ResolveConfig


class ResolveDumper:
    """Dump Postgres pour le project server DaVinci Resolve.

    pg_dumpall (pas pg_dump ciblé) : Resolve crée une base par Project Library,
    un dump nommé raterait silencieusement toute nouvelle Library créée.
    """

    def __init__(self, config: ResolveConfig) -> None:
        self.config = config
        self.dump_dir = Path(config.dump_dir)
        self._db_password = (
            Path(config.db_password_file).read_text().strip()
            if config.db_password_file else None
        )

    def dump_database(self) -> Path:
        self.dump_dir.mkdir(parents=True, exist_ok=True)
        self.dump_dir.chmod(0o700)
        dump_file = self.dump_dir / "resolve-postgres-all.sql"

        env = {**os.environ}
        cmd = ["docker", "exec"]
        if self._db_password:
            env["PGPASSWORD"] = self._db_password
            cmd += ["-e", "PGPASSWORD"]
        cmd += [
            "-u", self.config.postgres_user,
            self.config.postgres_container,
            "pg_dumpall", "-U", self.config.postgres_user,
        ]

        logger.info("Dump pg_dumpall (toutes les Project Libraries)...")
        with open(dump_file, "wb") as fh:
            proc = subprocess.run(cmd, stdout=fh, stderr=subprocess.PIPE, env=env)
        if proc.returncode != 0:
            raise RuntimeError(
                f"pg_dumpall a échoué: {proc.stderr.decode(errors='replace').strip()}"
            )
        dump_file.chmod(0o600)
        logger.info("Dump SQL écrit ({} octets)", dump_file.stat().st_size)
        return dump_file

    def prepare(self) -> list[str]:
        """Renvoie les chemins à sauvegarder : juste le dump (pas de médias, cf. décision)."""
        dump_file = self.dump_database()
        return [str(dump_file)]

    def cleanup(self) -> None:
        if self.dump_dir.exists():
            shutil.rmtree(self.dump_dir, ignore_errors=True)
            logger.debug("Artefacts temporaires nettoyés: {}", self.dump_dir)