#!/usr/bin/env bash
# Lance les tests dans alpine. Aucun outil a installer sur le poste : seul
# Docker est requis. Meme parti que deploy/tests/run.sh du depot monitoring.
#
#   ./tests/run.sh             tous les tests
#   ./tests/run.sh chart.bats  un seul fichier
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUITE="${1:-}"

docker run --rm \
  -v "$REPO:/repo" -w /repo \
  alpine:3.20 sh -c "
    apk add --no-cache --quiet bats bash helm python3 py3-yaml >/dev/null
    bats --print-output-on-failure tests/${SUITE:-*.bats}
  "
