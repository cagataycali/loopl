#!/bin/bash
# Sync the bundled training script from cagataycali/loopl-train (train/loopl_sft.py) and pin the revision.
#   scripts/sync-train-script.sh            # latest main
#   scripts/sync-train-script.sh <sha>      # a specific loopl-train commit
#   scripts/sync-train-script.sh --check    # exit 1 if the bundle differs from the pinned revision (CI / TrainingScriptBundleTests)
# The app uploads App/Resources/train/loopl_sft.py into the user's dataset and runs it on HF Jobs (Train your own), so the
# bundle MUST equal loopl-train main — every learning there (mlx_vlm vision export, tokenizer normalisation, weight:0 masking,
# timeoutSeconds, --expect-vision) reaches the phone only through this file. App/Resources/train/VERSION records the pin.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEST="$ROOT/App/Resources/train/loopl_sft.py"
PIN="$ROOT/App/Resources/train/VERSION"
REPO=${LOOPL_TRAIN_REPO:-https://github.com/cagataycali/loopl-train}
sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }

if [ "${1:-}" = "--check" ]; then
  [ -f "$PIN" ] || { echo "no $PIN — run $0"; exit 1; }
  want=$(grep '^sha256=' "$PIN" | cut -d= -f2); have=$(sha256 "$DEST")
  if [ "$want" != "$have" ]; then echo "bundled loopl_sft.py ($have) != pinned $want — run scripts/sync-train-script.sh"; exit 1; fi
  echo "bundled loopl_sft.py matches VERSION ($(grep '^revision=' "$PIN"))"; exit 0
fi

REV=${1:-}
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
if [ -d "${LOOPL_TRAIN_DIR:-$HOME/loopl-train}/.git" ]; then
  git -C "${LOOPL_TRAIN_DIR:-$HOME/loopl-train}" fetch -q origin
  REV=${REV:-$(git -C "${LOOPL_TRAIN_DIR:-$HOME/loopl-train}" rev-parse origin/main)}
  git -C "${LOOPL_TRAIN_DIR:-$HOME/loopl-train}" show "$REV:train/loopl_sft.py" > "$TMP/loopl_sft.py"
else
  git clone -q --depth 50 "$REPO" "$TMP/repo"
  REV=${REV:-$(git -C "$TMP/repo" rev-parse HEAD)}
  git -C "$TMP/repo" show "$REV:train/loopl_sft.py" > "$TMP/loopl_sft.py"
fi
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$TMP/loopl_sft.py"
VERSION=$(grep -E '^SCRIPT_VERSION = ' "$TMP/loopl_sft.py" | sed -E 's/.*"([^"]+)".*/\1/')
cp "$TMP/loopl_sft.py" "$DEST"
cat > "$PIN" <<PIN
# App/Resources/train/loopl_sft.py == cagataycali/loopl-train train/loopl_sft.py at this revision. Written by scripts/sync-train-script.sh.
revision=$REV
script_version=$VERSION
sha256=$(sha256 "$DEST")
synced=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PIN
echo "synced loopl_sft.py $VERSION from loopl-train $REV"
cat "$PIN"
