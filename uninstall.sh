#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Tide Plugin Uninstaller
# ==============================================================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Keep these in lockstep with install.sh - both scripts must agree on ids.
PLUGIN_ID="io.github.elliotalien.tide"
LYRICS_PLUGIN_ID="io.github.elliotalien.tide-lyrics"
STOCK_PLUGIN_ID="omarchy.media"
BAR_SECTION="left"
BAR_ANCHOR_ID="omarchy.workspaces"
TARGET_DIR="${HOME}/.config/omarchy/plugins/${PLUGIN_ID}"
LYRICS_DIR="${HOME}/.config/omarchy/plugins/${LYRICS_PLUGIN_ID}"

echo -e "${YELLOW}==>${NC} Uninstalling ${RED}Tide${NC} [${PLUGIN_ID}]..."

# Back up the plugin directory instead of deleting it outright, in case this
# was run by mistake or the user wants their local edits back.
if [ -d "${TARGET_DIR}" ]; then
    BACKUP_DIR="$(dirname "${TARGET_DIR}")/.$(basename "${TARGET_DIR}").bak.$(date +%Y%m%d%H%M%S)"
    mv "${TARGET_DIR}" "${BACKUP_DIR}"
    echo -e "${BLUE}==>${NC} Removed plugin directory: ${TARGET_DIR}"
    echo -e "${BLUE}==>${NC} Backup saved to: ${BACKUP_DIR}"
fi
if [ -d "${LYRICS_DIR}" ] && [ ! -L "${LYRICS_DIR}" ]; then
    LYRICS_BACKUP_DIR="$(dirname "${LYRICS_DIR}")/.$(basename "${LYRICS_DIR}").bak.$(date +%Y%m%d%H%M%S)"
    mv "${LYRICS_DIR}" "${LYRICS_BACKUP_DIR}"
    echo -e "${BLUE}==>${NC} Lyrics companion backup saved to: ${LYRICS_BACKUP_DIR}"
fi

# Remove the terminal helper installed by install.sh, but only if it is ours.
CLI_HELPER="${HOME}/.local/bin/omarchy-flow"
if [ -f "${CLI_HELPER}" ] && grep -q "change the Tide bar visualizer" "${CLI_HELPER}" 2>/dev/null; then
    rm -f "${CLI_HELPER}"
    echo -e "${BLUE}==>${NC} Removed terminal helper: ${CLI_HELPER}"
fi

# Clean up configuration in shell.json
PLUGIN_ID="${PLUGIN_ID}" STOCK_PLUGIN_ID="${STOCK_PLUGIN_ID}" \
LYRICS_PLUGIN_ID="${LYRICS_PLUGIN_ID}" BAR_SECTION="${BAR_SECTION}" BAR_ANCHOR_ID="${BAR_ANCHOR_ID}" \
python3 "${SCRIPT_DIR}/scripts/configure_bar.py" --action disable

# Reload Omarchy Shell
if command -v omarchy >/dev/null 2>&1; then
    echo -e "${BLUE}==>${NC} Reloading Omarchy shell..."
    omarchy restart shell
    echo -e "${GREEN}✔ Uninstall complete! Restored default media widget.${NC}"
else
    echo -e "${YELLOW}==> Note: Please restart omarchy-shell manually to apply changes.${NC}"
fi
