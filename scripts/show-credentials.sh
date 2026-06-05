#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: ./scripts/show-credentials.sh [--decrypt]

Show all credential-related YAML keys from this repo as a table.

Options:
  --decrypt   Attempt to decrypt Ansible Vault files using ansible-vault.
  -h, --help  Show this help message and exit.
EOF
}

DECRYPT=false
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
    --decrypt)
      DECRYPT=true
      ;;
    *)
      echo "Unknown option: $arg" >&2
      usage
      exit 1
      ;;
  esac
done

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required." >&2
  exit 1
fi

python3 - "$DECRYPT" "$ROOT" <<'PY'
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("Error: PyYAML is required. Install it with 'pip install pyyaml'.", file=sys.stderr)
    sys.exit(1)

if hasattr(yaml, 'SafeLoader'):
    def vault_constructor(loader, node):
        return loader.construct_scalar(node)
    yaml.SafeLoader.add_constructor('!vault', vault_constructor)

decrypt = sys.argv[1].lower() == "true"
root = Path(sys.argv[2])

paths = [root / "ansible/group_vars/all.yml"]
paths += sorted(root.glob("ansible/host_vars/*/vars.yml"))
paths += sorted(root.glob("ansible/host_vars/*/vault.yml"))

pattern = re.compile(r"(user(name)?|pass(word)?|secret|token|auth|credential)", re.I)

records = []

for path in paths:
    if not path.exists():
        continue

    raw_text = path.read_text(encoding="utf-8")
    parsed_text = raw_text
    vault_decrypted = False

    if decrypt and "ANSIBLE_VAULT" in raw_text:
        if shutil.which("ansible-vault"):
            try:
                result = subprocess.run(
                    ["ansible-vault", "view", str(path)],
                    capture_output=True,
                    text=True,
                    check=True,
                    env=os.environ,
                )
                parsed_text = result.stdout
                vault_decrypted = True
            except subprocess.CalledProcessError as exc:
                print(
                    f"Warning: unable to decrypt {path}: {exc}. Parsing as raw YAML.",
                    file=sys.stderr,
                )
        else:
            print(
                f"Warning: ansible-vault not found. Cannot decrypt {path}.",
                file=sys.stderr,
            )

    try:
        docs = list(yaml.safe_load_all(parsed_text))
    except Exception as exc:
        print(f"Warning: failed to parse YAML for {path}: {exc}", file=sys.stderr)
        continue

    def flatten(key_path, value):
        if isinstance(value, dict):
            for key, sub in value.items():
                flatten(key_path + [str(key)], sub)
        elif isinstance(value, list):
            for index, item in enumerate(value):
                flatten(key_path + [str(index)], item)
        else:
            key_name = key_path[-1] if key_path else ""
            if pattern.search(key_name) or pattern.search(".".join(key_path)):
                value_str = ""
                if isinstance(value, str) and value.startswith("$ANSIBLE_VAULT;"):
                    value_str = "<encrypted>"
                elif isinstance(value, str) and "{{" in value and "}}" in value:
                    value_str = value.strip()
                else:
                    try:
                        value_str = json.dumps(value, ensure_ascii=False)
                    except TypeError:
                        value_str = str(value)
                if value_str == "null":
                    value_str = ""
                records.append((str(path.relative_to(root)), ".".join(key_path), value_str, vault_decrypted))

    for doc in docs:
        if doc is None:
            continue
        flatten([], doc)

if not records:
    print("Keine credential-relevanten Variablen gefunden.")
    sys.exit(0)

# Determine column widths
headers = ["Datei", "Variablenname", "Wert"]
rows = []
for file_name, key_name, value_str, decrypted in records:
    display = value_str
    if decrypted and value_str == "<encrypted>":
        display = "<decrypted>"
    rows.append((file_name, key_name, display))

widths = [max(len(cell) for cell in col) for col in zip(headers, *rows)]
format_str = f"{{:<{widths[0]}}}  {{:<{widths[1]}}}  {{:<{widths[2]}}}"
print(format_str.format(*headers))
print("-" * (widths[0] + widths[1] + widths[2] + 4))
for row in rows:
    print(format_str.format(*row))
PY
