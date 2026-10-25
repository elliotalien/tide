#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Tide Plugin Updater
# ==============================================================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Single source of truth for every id this script and the config-writer below
# touch, so the plugin id never has to be duplicated (and drift) across files.
PLUGIN_ID="io.github.elliotalien.tide"
LYRICS_PLUGIN_ID="io.github.elliotalien.tide-lyrics"
STOCK_PLUGIN_ID="omarchy.media"
BAR_SECTION="left"
BAR_ANCHOR_ID="omarchy.workspaces"
TARGET_DIR="${HOME}/.config/omarchy/plugins/${PLUGIN_ID}"
# Tide was forked from a plugin that used a per-user id (${USER_NAME}.media).
# Derive the legacy id from the actual account running this script, not a
# hardcoded name - it only ever matched one specific developer's own machine
# otherwise.
CURRENT_USER="$(id -un)"
LEGACY_DIR="${HOME}/.config/omarchy/plugins/${CURRENT_USER}.media"

MPV_MPRIS_CANDIDATES=(
    "/usr/lib/mpv-mpris/mpris.so"
    "/etc/mpv/scripts/mpris.so"
)

echo -e "${BLUE}==>${NC} Synchronizing ${GREEN}Tide${NC} [${PLUGIN_ID}]..."

# 1. Ensure target plugin directory exists
mkdir -p "${TARGET_DIR}"

# 2. Clean legacy plugin folder if it exists
#
# -L guards against a same-user process having swapped LEGACY_DIR for a
# symlink between the -d check and this running: mv/rm never traverse
# through a symlink to reach its target anyway (they act on the directory
# entry itself), so that swap was never able to reach outside this path -
# but backing up instead of an unconditional rm -rf, matching uninstall.sh's
# TARGET_DIR handling below, means a legitimate directory here is never
# destroyed outright, just moved aside.
if [ -d "${LEGACY_DIR}" ] && [ ! -L "${LEGACY_DIR}" ]; then
    LEGACY_BACKUP_DIR="$(dirname "${LEGACY_DIR}")/.$(basename "${LEGACY_DIR}").bak.$(date +%Y%m%d%H%M%S)"
    mv "${LEGACY_DIR}" "${LEGACY_BACKUP_DIR}"
    echo -e "${BLUE}==>${NC} Moved legacy plugin directory to: ${LEGACY_BACKUP_DIR}"
fi

# 3. Copy updated plugin files
#
# Routed through a fresh mktemp name + mv instead of `cp -f src dest`
# directly: `cp -f` follows a symlink at the destination and overwrites
# whatever it points to (verified), so a same-user process that plants one
# at e.g. TARGET_DIR/BarWidget.qml once would get it silently and
# deterministically corrupted, no race required, on every update. `mv`
# (rename) never follows a symlink at the destination - it replaces the
# directory entry itself - so landing the new content there first and
# swapping it into place closes this off.
PLUGIN_TMP_FILES=()
cleanup_plugin_tmp_files() {
    local f
    for f in "${PLUGIN_TMP_FILES[@]:-}"; do
        [ -n "${f}" ] && rm -f "${f}"
    done
}
trap cleanup_plugin_tmp_files EXIT

install_plugin_file() {
    local src="$1" name="$2" tmp
    tmp=$(mktemp -p "${TARGET_DIR}" ".${name}.XXXXXX")
    PLUGIN_TMP_FILES+=("${tmp}")
    cp -f "${src}" "${tmp}"
    chmod --reference="${src}" "${tmp}"
    mv -f "${tmp}" "${TARGET_DIR}/${name}"
}
install_plugin_file "${SCRIPT_DIR}/BarWidget.qml" "BarWidget.qml"
install_plugin_file "${SCRIPT_DIR}/Service.qml" "Service.qml"
install_plugin_file "${SCRIPT_DIR}/MediaModel.js" "MediaModel.js"
install_plugin_file "${SCRIPT_DIR}/manifest.json" "manifest.json"

echo -e "${BLUE}==>${NC} Plugin files synchronized to: ${TARGET_DIR}"

LYRICS_DIR="${HOME}/.config/omarchy/plugins/${LYRICS_PLUGIN_ID}"
mkdir -p "${LYRICS_DIR}"
for spec in "BarWidget.qml:BarWidget.qml" "manifest.json.in:manifest.json"; do
    src_name="${spec%%:*}"
    dest_name="${spec#*:}"
    tmp=$(mktemp -p "${LYRICS_DIR}" ".${dest_name}.XXXXXX")
    PLUGIN_TMP_FILES+=("${tmp}")
    cp -f "${SCRIPT_DIR}/companions/synced-lyrics/${src_name}" "${tmp}"
    chmod 0644 "${tmp}"
    mv -f "${tmp}" "${LYRICS_DIR}/${dest_name}"
done

# 4. Catch manifest/schema problems before they get wired into the bar
if command -v omarchy >/dev/null 2>&1; then
    if ! omarchy plugin validate "${TARGET_DIR}"; then
        echo -e "${RED}==> Error:${NC} updated plugin failed validation, aborting before touching your bar config." >&2
        exit 1
    fi
    if ! omarchy plugin validate "${LYRICS_DIR}"; then
        echo -e "${RED}==> Error:${NC} lyrics companion failed validation, aborting before touching your bar config." >&2
        exit 1
    fi
fi

# 5. Enable MPV MPRIS script if mpv is installed
if command -v mpv >/dev/null 2>&1; then
    mkdir -p "${HOME}/.config/mpv/scripts"
    for candidate in "${MPV_MPRIS_CANDIDATES[@]}"; do
        if [ -f "${candidate}" ]; then
            mpris_link="${HOME}/.config/mpv/scripts/mpris.so"
            if [ -e "${mpris_link}" ] || [ -L "${mpris_link}" ]; then
                if [ "$(readlink -f "${mpris_link}" 2>/dev/null || true)" = "$(readlink -f "${candidate}")" ]; then
                    echo -e "${BLUE}==>${NC} Verified MPV MPRIS integration."
                else
                    echo -e "${YELLOW}==> Note:${NC} Preserving existing ${mpris_link}; MPV MPRIS integration was not changed."
                fi
            else
                ln -s "${candidate}" "${mpris_link}"
                echo -e "${BLUE}==>${NC} Enabled MPV MPRIS integration."
            fi
            break
        fi
    done
fi

# 6. Verify and update status bar layout in ~/.config/omarchy/shell.json
echo -e "${BLUE}==>${NC} Verifying status bar configuration in ~/.config/omarchy/shell.json..."
PLUGIN_ID="${PLUGIN_ID}" STOCK_PLUGIN_ID="${STOCK_PLUGIN_ID}" \
LYRICS_PLUGIN_ID="${LYRICS_PLUGIN_ID}" BAR_SECTION="${BAR_SECTION}" BAR_ANCHOR_ID="${BAR_ANCHOR_ID}" \
python3 "${SCRIPT_DIR}/scripts/configure_bar.py" --action enable

# 7. Restart Omarchy Shell to apply updates
if command -v omarchy >/dev/null 2>&1; then
    echo -e "${BLUE}==>${NC} Reloading Omarchy shell with updated plugin..."
    omarchy restart shell
    echo -e "${GREEN}✔ Update complete! Tide is up to date and running.${NC}"
else
    echo -e "${YELLOW}==> Note: Please restart omarchy-shell manually to apply changes.${NC}"
fi
