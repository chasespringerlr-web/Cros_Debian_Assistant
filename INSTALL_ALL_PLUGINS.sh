#!/usr/bin/env bash
set -euo pipefail

RAW_BASE="https://raw.githubusercontent.com/chasespringerlr-web/Cros_Debian_Assistant/main/"

mkdir -p "$HOME/.cros-plugin-downloads"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FILES=(
  "plugins/cnc/cros_plugin_cnc_manufacturing_v2_6.sh"
  "plugins/logic/cros_plugin_logic_analyzer_datasheet_v1.sh"
  "plugins/pin/cros_plugin_pin_planner_v1.sh"
  "plugins/electronics/cros_plugin_electronics_calculator_bom_v1_2.sh"
  "plugins/kicad/cros_plugin_kicad_assistant_v1.sh"
)

echo "CROS: downloading five completed plugins..."
for file in "${FILES[@]}"; do
  name="${file##*/}"
  echo "  -> $name"
  curl -fsSL "${RAW_BASE}${file}" -o "${TMP_DIR}/${name}"
  chmod +x "${TMP_DIR}/${name}"
done

echo
echo "CROS: installing plugins..."
for file in "${FILES[@]}"; do
  bash "${TMP_DIR}/${file##*/}"
done

echo
echo "CROS: all five completed plugins installed."
echo "Restart CROS or use Plugins -> Reload Plugins."
