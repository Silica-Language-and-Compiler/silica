#!/bin/bash

# Install the Silica syntax highlighting extension into VS Code with proper
# extension ID registration (publisher.name-version folder + extensions.json).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_JSON="${SCRIPT_DIR}/package.json"

if [[ ! -f "$PACKAGE_JSON" ]]; then
    echo "❌ Missing package.json in ${SCRIPT_DIR}"
    exit 1
fi

read -r PUBLISHER NAME VERSION < <(
    python3 - "$PACKAGE_JSON" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
print(data.get("publisher", "silica"), data["name"], data["version"])
PY
)

EXTENSION_ID="${PUBLISHER}.${NAME}"
FOLDER_NAME="${EXTENSION_ID}-${VERSION}"

if [[ "$OSTYPE" == "darwin"* || "$OSTYPE" == "linux-gnu"* ]]; then
    EXTENSIONS_ROOT="${HOME}/.vscode/extensions"
elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
    EXTENSIONS_ROOT="${USERPROFILE}/.vscode/extensions"
else
    echo "❌ Unsupported OS: $OSTYPE"
    exit 1
fi

TARGET_DIR="${EXTENSIONS_ROOT}/${FOLDER_NAME}"
REGISTRY="${EXTENSIONS_ROOT}/extensions.json"
OBSOLETE="${EXTENSIONS_ROOT}/.obsolete"

mkdir -p "$EXTENSIONS_ROOT"

echo "📦 Installing Silica extension into VS Code..."
echo "   From: ${SCRIPT_DIR}"
echo "   To:   ${TARGET_DIR}"
echo "   ID:   ${EXTENSION_ID}@${VERSION}"
echo ""

# Remove stale installs (old folder names / versions).
for old in \
    "${EXTENSIONS_ROOT}/silica-language" \
    "${EXTENSIONS_ROOT}/${EXTENSION_ID}" \
    "${EXTENSIONS_ROOT}/${EXTENSION_ID}-"*; do
    if [[ -e "$old" && "$old" != "$TARGET_DIR" ]]; then
        rm -rf "$old"
    fi
done

rm -rf "$TARGET_DIR"
mkdir -p "$TARGET_DIR"
cp "${SCRIPT_DIR}/package.json" "${TARGET_DIR}/package.json"
cp "${SCRIPT_DIR}/language-configuration.json" "${TARGET_DIR}/language-configuration.json"
mkdir -p "${TARGET_DIR}/syntaxes"
cp "${SCRIPT_DIR}/syntaxes/silica.tmLanguage.json" "${TARGET_DIR}/syntaxes/silica.tmLanguage.json"
if [[ -d "${SCRIPT_DIR}/themes" ]]; then
    mkdir -p "${TARGET_DIR}/themes"
    cp "${SCRIPT_DIR}/themes/"*.json "${TARGET_DIR}/themes/"
fi

python3 - "$REGISTRY" "$OBSOLETE" "$TARGET_DIR" "$EXTENSION_ID" "$VERSION" "$FOLDER_NAME" <<'PY'
import json, os, sys, time

registry_path, obsolete_path, target_dir, extension_id, version, folder_name = sys.argv[1:7]
stale_ids = {
    extension_id,
    "undefined_publisher.silica-language",
    "silica-language",
}

entries = []
if os.path.isfile(registry_path):
    with open(registry_path, encoding="utf-8") as f:
        entries = json.load(f)
    if not isinstance(entries, list):
        sys.exit(f"extensions.json is not a list: {registry_path}")

entries = [
    e for e in entries
    if e.get("identifier", {}).get("id") not in stale_ids
]

# Match the entry shape VS Code writes. It stores a file URI as path + scheme.
entries.append({
    "identifier": {"id": extension_id},
    "version": version,
    "location": {
        "$mid": 1,
        "path": target_dir,
        "scheme": "file",
    },
    "relativeLocation": folder_name,
    "metadata": {
        "installedTimestamp": int(time.time() * 1000),
        "pinned": True,
        "source": "vsix",
        "private": False,
        "isPreReleaseVersion": False,
        "hasPreReleaseVersion": False,
    },
})

with open(registry_path, "w", encoding="utf-8") as f:
    json.dump(entries, f, indent=2)
    f.write("\n")

if os.path.isfile(obsolete_path):
    with open(obsolete_path, encoding="utf-8") as f:
        obsolete = json.load(f)
    if isinstance(obsolete, dict):
        kept = {
            name: flag
            for name, flag in obsolete.items()
            if not (
                name == folder_name
                or name.startswith(extension_id + "-")
                or name.startswith("silica-language")
                or name.startswith("undefined_publisher.silica-language")
            )
        }
        if kept != obsolete:
            with open(obsolete_path, "w", encoding="utf-8") as f:
                json.dump(kept, f, indent=2)
                f.write("\n")
PY

echo "✅ Extension installed and registered."
echo ""
echo "📝 Next steps:"
echo "   1. Reload VS Code (Cmd+Shift+P → 'Developer: Reload Window')"
echo "   2. Color Theme → Silica Dark or Silica Light"
echo "   3. Open a .silica file — language mode should show 'Silica'"
echo "   4. If not, run: Developer: Show Running Extensions and confirm '${EXTENSION_ID}' is enabled"
