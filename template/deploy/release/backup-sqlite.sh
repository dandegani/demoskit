#!/usr/bin/env bash
# Back up a product's data/ directory on its host: every SQLite database through the online
# backup API (consistent while the app is writing), everything else as files, in one
# timestamped .tar.gz; optionally copied to S3. deploy.sh runs it as BACKUP_CMD.
#
#   bash backup-sqlite.sh <data dir> [product]     # product default: name of the data dir's parent
#
# Output: /home/ubuntu/backups/<product>/<product>-<UTC timestamp>.tar.gz (BACKUP_DIR overrides
# the directory). With S3_URI set (e.g. s3://bucket/prefix) it is also copied there with
# `aws s3 cp`. The last line is "wrote <path>" (the contract with deploy.sh); exit 0 only then.
# Restore: stop the app, untar into data/ (the .db files in the archive are complete copies).
set -euo pipefail
DATA="${1:?data dir}"
DATA=$(cd "$DATA" && pwd)
PRODUCT="${2:-$(basename "$(dirname "$DATA")")}"
OUT_DIR="${BACKUP_DIR:-/home/ubuntu/backups/$PRODUCT}"
command -v sqlite3 >/dev/null || { echo "backup-sqlite: sqlite3 not installed on this host (apt install sqlite3)" >&2; exit 1; }
mkdir -p "$OUT_DIR"
ts=$(date -u +%Y%m%dT%H%M%SZ)
out="$OUT_DIR/$PRODUCT-$ts.tar.gz"
stage=$(mktemp -d); tarball="$OUT_DIR/.$PRODUCT-$ts.tar"
trap 'rm -rf "$stage" "$tarball" "$tarball.gz"' EXIT

# 1. The databases, each copied with sqlite3 .backup to the same relative path in the stage.
n=0
while IFS= read -r -d '' db; do
  rel="${db#"$DATA"/}"
  mkdir -p "$stage/$(dirname "$rel")"
  sqlite3 -cmd ".timeout 15000" "$db" ".backup '$stage/$rel'"
  n=$((n + 1))
done < <(find "$DATA" -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) -print0)

# 2. One tar: the database copies, then the rest of data/ without the live database files.
tar -cf "$tarball" -C "$stage" .
tar -rf "$tarball" -C "$DATA" \
  --exclude='*.db' --exclude='*.db-wal' --exclude='*.db-shm' --exclude='*.db-journal' \
  --exclude='*.sqlite' --exclude='*.sqlite-wal' --exclude='*.sqlite-shm' \
  --exclude='*.sqlite3' --exclude='*.sqlite3-wal' --exclude='*.sqlite3-shm' .
gzip -q "$tarball"
mv "$tarball.gz" "$out"
echo "backup-sqlite: $n database(s) + files of $DATA, $(du -h "$out" | cut -f1)"

if [ -n "${S3_URI:-}" ]; then
  aws s3 cp --only-show-errors "$out" "${S3_URI%/}/$(basename "$out")"
  echo "backup-sqlite: copied to ${S3_URI%/}/$(basename "$out")"
fi
echo "wrote $out"
