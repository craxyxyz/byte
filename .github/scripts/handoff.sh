#!/usr/bin/env bash
# © 2026 Apurba Laskar
# Hands the built files to Byte's build helper: one AES-256 encrypted tar,
# split into parts on a temporary host that deletes them after 60 minutes.
# Without the DIST_KEY secret nothing is uploaded.
set -euo pipefail
[ -n "${DIST_KEY:-}" ] || { echo "no DIST_KEY secret, skipping"; exit 0; }
tar -cf handoff.tar -C dist .
openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass env:DIST_KEY -in handoff.tar -out handoff.bin
rm -f handoff.tar
split -b 90m -d handoff.bin part.
ls -la handoff.bin part.*
for f in part.*; do
  U=$(curl -fsS --retry 4 --retry-all-errors -F "file=@$f" https://tmpfiles.org/api/v1/upload | jq -r .data.url)
  echo "::notice title=handoff $f::$U $(sha256sum "$f" | cut -c1-64)"
done
echo "::notice title=handoff total::$(sha256sum handoff.bin | cut -c1-64) $(stat -c%s handoff.bin)"
rm -f handoff.bin part.*
