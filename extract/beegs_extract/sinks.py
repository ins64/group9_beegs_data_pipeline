"""Where the extract job writes: a Snowflake internal stage in the cloud, a local folder in development.

Both sinks expose the same methods, so the extraction code never knows where it runs.
  put_bytes / put_file   land one file under landing/<source>/dt=YYYY-MM-DD/...
  put_tree               land a whole folder at once (backfill: one PUT per source, parallel uploads)
  get_state / set_state  watermarks of the incremental API pulls (last day successfully extracted)
  notify_pipe            tell Snowpipe that new files are there (internal stages have no cloud event:
                         the producer triggers the pipe right after the upload)
"""
from __future__ import annotations

import json
import logging
import os
import shutil
import tempfile
from pathlib import Path

log = logging.getLogger("beegs.extract.sinks")


class LocalSink:
    def __init__(self, root: str = "data"):
        self.root = Path(root)

    def put_bytes(self, data: bytes, key: str):
        p = self.root / key
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)

    def put_file(self, path: Path, key: str):
        self.put_bytes(Path(path).read_bytes(), key)

    def put_tree(self, folder: Path, prefix: str = "landing"):
        for f in Path(folder).rglob("*"):
            if f.is_file():
                self.put_file(f, f"{prefix}/{f.relative_to(folder).as_posix()}")

    def get_state(self, name: str) -> dict:
        p = self.root / "state" / f"{name}.json"
        return json.loads(p.read_text()) if p.exists() else {}

    def set_state(self, name: str, value: dict):
        self.put_bytes(json.dumps(value).encode(), f"state/{name}.json")

    def notify_pipe(self, pipe: str, staged_paths: list[str]):
        log.info(json.dumps({"local": True, "pipe": pipe, "files": len(staged_paths)}))


class SnowflakeStageSink:
    """Snowflake internal stages: @BEEGS.OPS.LANDING (data, = the landing zone) and @BEEGS.OPS.EXTRACT_STATE (watermarks).
    Authentication: key pair of the service user BEEGS_PIPELINE_SVC (role BEEGS_PIPELINE). The private key comes
    from the environment (a GitHub Actions secret), never from a file in the image or the repository."""

    STAGE = "@BEEGS.OPS.LANDING"
    STATE_STAGE = "@BEEGS.OPS.EXTRACT_STATE"

    def __init__(self):
        import snowflake.connector
        from cryptography.hazmat.primitives import serialization

        import re
        import textwrap

        raw = os.environ["SNOWFLAKE_PRIVATE_KEY"].replace("\r", "").strip()   # KeyError = loud failure
        body = re.sub(r"\s+", "", re.sub(r"-----(BEGIN|END) PRIVATE KEY-----", "", raw))   # tolerate copy/paste damage
        pem = ("-----BEGIN PRIVATE KEY-----\n" + "\n".join(textwrap.wrap(body, 64)) + "\n-----END PRIVATE KEY-----\n").encode()
        key = serialization.load_pem_private_key(pem, password=None)
        self.account = os.environ.get("SNOWFLAKE_ACCOUNT", "ZEFQCKT-WL69349")
        self.user = os.environ.get("SNOWFLAKE_USER", "BEEGS_PIPELINE_SVC")
        self.con = snowflake.connector.connect(
            account=self.account, user=self.user,
            private_key=key.private_bytes(serialization.Encoding.DER, serialization.PrivateFormat.PKCS8,
                                          serialization.NoEncryption()),
            role=os.environ.get("SNOWFLAKE_ROLE", "BEEGS_PIPELINE"),
            warehouse=os.environ.get("SNOWFLAKE_WAREHOUSE", "BEEGS_PIPELINE_WH"),
            database="BEEGS", schema="OPS", session_parameters={"QUERY_TAG": "beegs_extract"})

    @staticmethod
    def _split(key: str) -> tuple[str, str]:
        rel = key.removeprefix("landing/")
        return (rel.rsplit("/", 1) if "/" in rel else ("", rel))

    def _put(self, local: Path, stage_dir: str, stage=None):
        # OVERWRITE=TRUE: re-running the same day replaces the same object (no 2nd file for COPY to load twice)
        sql = (f"PUT 'file://{local.as_posix()}' '{stage or self.STAGE}/{stage_dir}' "
               f"AUTO_COMPRESS=FALSE OVERWRITE=TRUE PARALLEL=8")
        self.con.cursor().execute(sql)

    def put_bytes(self, data: bytes, key: str):
        folder, name = self._split(key)
        with tempfile.TemporaryDirectory() as tmp:
            f = Path(tmp) / name
            f.write_bytes(data)
            self._put(f, folder)

    def put_file(self, path: Path, key: str):
        folder, name = self._split(key)
        if Path(path).name == name:
            self._put(Path(path), folder)
        else:
            self.put_bytes(Path(path).read_bytes(), key)

    def put_tree(self, folder: Path, prefix: str = "landing"):
        """Backfill: one wildcard PUT per source (uploads in parallel). Files land in <source>/backfill/
        (the file names carry the date), and are loaded once by CALL SP_LOAD_BATCH(NULL)."""
        for src in sorted(p for p in Path(folder).iterdir() if p.is_dir()):
            with tempfile.TemporaryDirectory() as tmp:
                for f in src.rglob("*"):
                    if f.is_file():
                        shutil.copy(f, Path(tmp) / f.name)
                self._put(Path(tmp) / "*", f"{src.name}/backfill/")
                log.info(json.dumps({"backfill_source": src.name, "files": len(list(Path(tmp).iterdir()))}))

    def get_state(self, name: str) -> dict:
        # first run of a source: no watermark yet (GET on a missing file raises, so LIST first)
        if not self.con.cursor().execute(f"LIST '{self.STATE_STAGE}/{name}.json'").fetchall():
            return {}
        with tempfile.TemporaryDirectory() as tmp:
            self.con.cursor().execute(f"GET '{self.STATE_STAGE}/{name}.json' 'file://{Path(tmp).as_posix()}/'")
            f = Path(tmp) / f"{name}.json"
            return json.loads(f.read_text()) if f.exists() else {}

    def set_state(self, name: str, value: dict):
        with tempfile.TemporaryDirectory() as tmp:
            f = Path(tmp) / f"{name}.json"
            f.write_text(json.dumps(value))
            self._put(f, "", stage=self.STATE_STAGE)

    def notify_pipe(self, pipe: str, staged_paths: list[str]):
        """Hand the new files to Snowpipe (serverless, loaded within ~1 minute). An internal stage emits no cloud
        event, so the producer triggers the pipe itself, limited to the folder it just wrote (PREFIX).
        Files already loaded by the pipe are skipped by Snowpipe's own load history: calling it twice is harmless."""
        for prefix in sorted({p.rsplit("/", 1)[0] + "/" for p in staged_paths}):
            sub = prefix.split("/", 1)[1] if "/" in prefix.rstrip("/") else ""
            self.con.cursor().execute(f"ALTER PIPE {pipe} REFRESH PREFIX = '{sub}'")
        log.info(json.dumps({"pipe": pipe, "files_notified": len(staged_paths)}))


def make_sink(target: str):
    if target == "local":
        return LocalSink(os.getenv("BEEGS_LOCAL_ROOT", "data"))
    return SnowflakeStageSink()
