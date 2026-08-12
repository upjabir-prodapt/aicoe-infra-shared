#!/usr/bin/env bash
set -euo pipefail
for d in $(find . -name '*.tf' -printf '%h\n' | sort -u); do
  echo "── $d"
  terraform -chdir="$d" init -backend=false -upgrade >/dev/null
  terraform -chdir="$d" validate
done
