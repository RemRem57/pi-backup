import os
import shutil
import subprocess
from pathlib import Path

from loguru import logger

from .config import NextcloudConfig


class NextcloudDumper:
    """Prépare les artefacts Nextcloud à sauvegarder.

    Produit un dump SQL cohérent (mariadb-dump --single-transaction) et une copie
    du dossier de config (config.php + éventuels *.config.php), puis renvoie la
    liste des chemins à confier à Borg : datadir + dump + config.

    Le dump et la config contiennent des secrets : ils sont écrits en 0600/0700
    dans un dossier temporaire local, puis supprimés après le backup (cleanup()).
    """

    def __init__(self, config: NextcloudConfig) -> None:
        self.config = config
        self.dump_dir = Path(config.dump_dir)
        self._db_password = Path(config.db_password_file).read_text().strip()

    def dump_database(self) -> Path:
        self.dump_dir.mkdir(parents=True, exist_ok=True)
        self.dump_dir.chmod(0o700)
        dump_file = self.dump_dir / f"{self.config.db_name}.sql"

        # MYSQL_PWD passé via l'env du client docker (option -e sans valeur) :
        # le mot de passe n'apparaît jamais dans argv, donc pas visible en `ps`.
        env = {**os.environ, "MYSQL_PWD": self._db_password}
        cmd = [
            "docker", "exec", "-e", "MYSQL_PWD", self.config.db_container,
            "mariadb-dump",
            "--single-transaction",   # snapshot cohérent InnoDB sans verrou
            "--no-tablespaces",       # évite d'exiger le privilège PROCESS
            "--default-character-set=utf8mb4",
            "-u", self.config.db_user,
            self.config.db_name,
        ]
        logger.info("Dump de la base '{}'...", self.config.db_name)
        with open(dump_file, "wb") as fh:
            proc = subprocess.run(cmd, stdout=fh, stderr=subprocess.PIPE, env=env)
        if proc.returncode != 0:
            raise RuntimeError(
                f"mariadb-dump a échoué: {proc.stderr.decode(errors='replace').strip()}"
            )
        dump_file.chmod(0o600)
        logger.info("Dump SQL écrit ({} octets)", dump_file.stat().st_size)
        return dump_file

    def copy_config(self) -> Path:
        # On copie tout le dossier config/ (config.php + éventuels *.config.php).
        dest = self.dump_dir / "config"
        if dest.exists():
            shutil.rmtree(dest, ignore_errors=True)
        proc = subprocess.run(
            ["docker", "cp",
             f"{self.config.app_container}:/var/www/html/config",
             str(dest)],
            capture_output=True, text=True,
        )
        if proc.returncode != 0:
            raise RuntimeError(f"docker cp config a échoué: {proc.stderr.strip()}")
        dest.chmod(0o700)
        logger.info("config/ copié")
        return dest

    def prepare(self) -> list[str]:
        """Renvoie les chemins à sauvegarder : datadir + dump + config."""
        dump_file = self.dump_database()
        config_dir = self.copy_config()
        return [self.config.data_dir, str(dump_file), str(config_dir)]

    def cleanup(self) -> None:
        if self.dump_dir.exists():
            shutil.rmtree(self.dump_dir, ignore_errors=True)
            logger.debug("Artefacts temporaires nettoyés: {}", self.dump_dir)