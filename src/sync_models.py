#!/usr/bin/env python3
"""
sync_models.py — download models from Hugging Face and mirror them into the
S3 model registry (huggingface-model-registry-<account>-<region>).

Responsibilities (and only these — infra lives in terraform/, automation
lives in .github/workflows/):
  1. Read models/registry.yaml
  2. Download each model from Hugging Face (HF_TOKEN from the environment)
  3. Validate the download (required files present, non-empty)
  4. Sync changed files up to s3://<bucket>/<type>/<model_id>/...

Usage:
  python src/sync_models.py --bucket huggingface-model-registry-123-us-east-1
  python src/sync_models.py --bucket ... --registry models/registry.yaml --dry-run
  python src/sync_models.py --bucket ... --only BAAI/bge-base-en-v1.5
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import logging
import mimetypes
import os
import sys
from dataclasses import dataclass, field
from pathlib import Path

import boto3
import yaml
from botocore.exceptions import ClientError
from huggingface_hub import snapshot_download

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("sync_models")

VALID_TYPES = {"inference", "embedding", "reranker", "classifier"}

# At least one of these must exist in a downloaded snapshot for it to count
# as a valid model rather than a partial/broken download.
REQUIRED_ANY = ("config.json", "tokenizer_config.json")


@dataclass
class ModelEntry:
    id: str
    type: str
    revision: str = "main"
    allow_patterns: list[str] | None = None
    ignore_patterns: list[str] | None = None

    @property
    def s3_prefix(self) -> str:
        return f"{self.type}/{self.id}"


@dataclass
class SyncStats:
    uploaded: int = 0
    skipped_unchanged: int = 0
    failed: list[str] = field(default_factory=list)


def load_registry(path: Path) -> list[ModelEntry]:
    data = yaml.safe_load(path.read_text())
    entries = []
    for raw in data.get("models", []):
        model_type = raw["type"]
        if model_type not in VALID_TYPES:
            raise ValueError(
                f"{raw['id']}: type '{model_type}' not in {sorted(VALID_TYPES)}"
            )
        entries.append(
            ModelEntry(
                id=raw["id"],
                type=model_type,
                revision=raw.get("revision", "main"),
                allow_patterns=raw.get("allow_patterns"),
                ignore_patterns=raw.get("ignore_patterns"),
            )
        )
    return entries


def download_model(entry: ModelEntry, cache_dir: Path, hf_token: str | None) -> Path:
    log.info("downloading %s (revision=%s)", entry.id, entry.revision)
    local_dir = snapshot_download(
        repo_id=entry.id,
        revision=entry.revision,
        token=hf_token,
        cache_dir=str(cache_dir),
        allow_patterns=entry.allow_patterns,
        ignore_patterns=entry.ignore_patterns,
    )
    return Path(local_dir)


def validate_snapshot(entry: ModelEntry, local_dir: Path) -> None:
    files = [p for p in local_dir.rglob("*") if p.is_file()]
    if not files:
        raise ValueError(f"{entry.id}: downloaded snapshot has no files")

    if not any((local_dir / name).exists() for name in REQUIRED_ANY):
        raise ValueError(
            f"{entry.id}: missing all of {REQUIRED_ANY} — likely a partial/wrong download"
        )

    empty = [p for p in files if p.stat().st_size == 0]
    if empty:
        raise ValueError(f"{entry.id}: {len(empty)} zero-byte file(s), e.g. {empty[0]}")

    log.info("%s: validated %d files", entry.id, len(files))


def _md5_hex(path: Path, chunk_size: int = 8 * 1024 * 1024) -> str:
    h = hashlib.md5()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(chunk_size), b""):
            h.update(chunk)
    return h.hexdigest()


def _needs_upload(s3, bucket: str, key: str, local_path: Path) -> bool:
    """Skip re-uploading a file whose size and md5 (as ETag) already match."""
    try:
        head = s3.head_object(Bucket=bucket, Key=key)
    except ClientError as exc:
        if exc.response["Error"]["Code"] in ("404", "NoSuchKey", "NotFound"):
            return True
        raise

    if head["ContentLength"] != local_path.stat().st_size:
        return True

    remote_etag = head["ETag"].strip('"')
    # Multipart uploads have a "-N" suffixed ETag that isn't a plain md5;
    # in that case we can't cheaply compare, so re-upload to be safe.
    if "-" in remote_etag:
        return True

    return remote_etag != _md5_hex(local_path)


def upload_model(
    entry: ModelEntry,
    local_dir: Path,
    s3,
    bucket: str,
    dry_run: bool,
    stats: SyncStats,
) -> None:
    for path in sorted(p for p in local_dir.rglob("*") if p.is_file()):
        rel = path.relative_to(local_dir).as_posix()
        key = f"{entry.s3_prefix}/{rel}"

        if not dry_run and not _needs_upload(s3, bucket, key, path):
            stats.skipped_unchanged += 1
            continue

        content_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"

        if dry_run:
            log.info("[dry-run] would upload s3://%s/%s", bucket, key)
            stats.uploaded += 1
            continue

        log.info("uploading s3://%s/%s", bucket, key)
        s3.upload_file(
            str(path),
            bucket,
            key,
            ExtraArgs={
                "ContentType": content_type,
                "Metadata": {
                    "hf-model-id": entry.id,
                    "hf-revision": entry.revision,
                },
            },
        )
        stats.uploaded += 1


def sync_one(entry: ModelEntry, args, s3, stats: SyncStats) -> None:
    try:
        local_dir = download_model(entry, Path(args.cache_dir), args.hf_token)
        validate_snapshot(entry, local_dir)
        upload_model(entry, local_dir, s3, args.bucket, args.dry_run, stats)
    except Exception as exc:  # noqa: BLE001 — we want to keep going and report at the end
        log.error("%s: FAILED — %s", entry.id, exc)
        stats.failed.append(entry.id)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bucket", required=True, help="Target S3 bucket (the model registry).")
    parser.add_argument(
        "--registry",
        default="models/registry.yaml",
        type=Path,
        help="Path to registry.yaml (default: models/registry.yaml)",
    )
    parser.add_argument(
        "--cache-dir",
        default=os.environ.get("HF_SYNC_CACHE_DIR", "/tmp/hf-cache"),
        help="Local directory used to stage downloads before upload.",
    )
    parser.add_argument(
        "--only",
        action="append",
        default=None,
        help="Limit the sync to this model id (repeatable). Default: all models in the registry.",
    )
    parser.add_argument(
        "--workers",
        type=int,
        default=int(os.environ.get("HF_SYNC_WORKERS", "2")),
        help="Number of models to download/upload concurrently.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Download and validate but don't write anything to S3.",
    )
    parser.add_argument(
        "--hf-token",
        default=os.environ.get("HF_TOKEN"),
        help="Hugging Face token. Defaults to the HF_TOKEN environment variable.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    if not args.hf_token:
        log.warning("HF_TOKEN not set — only public models will be downloadable")

    entries = load_registry(args.registry)
    if args.only:
        wanted = set(args.only)
        entries = [e for e in entries if e.id in wanted]
        missing = wanted - {e.id for e in entries}
        if missing:
            log.error("--only requested model(s) not in registry: %s", ", ".join(sorted(missing)))
            return 2

    if not entries:
        log.error("no models to sync (registry empty or --only matched nothing)")
        return 2

    Path(args.cache_dir).mkdir(parents=True, exist_ok=True)
    s3 = boto3.client("s3")
    stats = SyncStats()

    log.info("syncing %d model(s) to s3://%s", len(entries), args.bucket)
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        list(pool.map(lambda e: sync_one(e, args, s3, stats), entries))

    log.info(
        "done: %d uploaded, %d unchanged, %d failed",
        stats.uploaded,
        stats.skipped_unchanged,
        len(stats.failed),
    )
    if stats.failed:
        log.error("failed models: %s", ", ".join(stats.failed))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
