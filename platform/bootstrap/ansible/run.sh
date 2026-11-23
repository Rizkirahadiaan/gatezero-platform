#!/usr/bin/env bash
# Wrapper: dekripsi secrets lalu jalankan playbook.
#
# Pemakaian:
#   ./run.sh site.yml
#   ./run.sh playbooks/90-verify.yml --limit k8s-cp-01
#
# Butuh: sops, ansible-playbook, dan koneksi SSH ke semua node.

set -euo pipefail

cd "$(dirname "$0")"

SECRETS="secrets.env.enc"

if [[ ! -f "$SECRETS" ]]; then
  echo "ERROR: $SECRETS tidak ditemukan."
  echo "Salin secrets.env.example, isi, lalu: sops -e secrets.env > secrets.env.enc"
  exit 1
fi

if [[ $# -eq 0 ]]; then
  echo "Pemakaian: ./run.sh <playbook> [opsi ansible-playbook...]"
  exit 1
fi

PLAYBOOK="$1"
shift

exec sops exec-env "$SECRETS" -- ansible-playbook "$PLAYBOOK" "$@"
