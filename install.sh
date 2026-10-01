#!/usr/bin/env bash
#
# install.sh — Descarga el tar.gz de audio.cpp de la última release de
# iguruspain/builder, verifica su SHA256, lo extrae en
# ~/.local/share/audiocpp y crea los symlinks de los binarios en ~/.local/bin.
#
set -euo pipefail

REPO="iguruspain/builder"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"
DEST_DIR="/tmp/audiocpp"
INSTALL_DIR="${HOME}/.local/share/audiocpp"
BIN_DIR="${HOME}/.local/bin"
BINS=("audiocpp_cli" "audiocpp_gguf" "audiocpp_server")

log() { printf '\033[1;34m[install]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

# --- Dependencias -----------------------------------------------------------
for dep in curl jq tar sha256sum; do
    if ! command -v "${dep}" >/dev/null 2>&1; then
        err "Dependencia requerida no encontrada: ${dep}"
        exit 1
    fi
done

# --- Última release ---------------------------------------------------------
log "Consultando la última release de ${REPO}..."

CURL_AUTH=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    CURL_AUTH=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

release_json="$(curl -fsSL "${CURL_AUTH[@]}" "$API_URL")"

asset_name="$(jq -r '
    [.assets[] | select(.name | test("^audiocpp-.*\\.tar\\.gz$"))] | first | .name // empty
' <<<"$release_json")"

if [[ -z "${asset_name}" ]]; then
    err "No se encontró ningún asset 'audiocpp-*.tar.gz' en la última release."
    exit 1
fi

asset_url="$(jq -r --arg n "$asset_name" \
    '.assets[] | select(.name == $n) | .browser_download_url' <<<"$release_json")"
asset_digest="$(jq -r --arg n "$asset_name" \
    '.assets[] | select(.name == $n) | .digest // empty' <<<"$release_json")"

log "Asset: ${asset_name}"

# --- Descarga ----------------------------------------------------------------
mkdir -p "$DEST_DIR"
dest_file="${DEST_DIR}/${asset_name}"

log "Descargando ${asset_url} ..."
curl -fL --progress-bar "${CURL_AUTH[@]}" -o "$dest_file" "$asset_url"

# --- Verificación SHA256 -----------------------------------------------------
if [[ -n "$asset_digest" && "$asset_digest" == sha256:* ]]; then
    expected="${asset_digest#sha256:}"
    actual="$(sha256sum "$dest_file" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        err "SHA256 no coincide: esperado ${expected}, obtenido ${actual}"
        rm -f "$dest_file"
        exit 1
    fi
    log "SHA256 verificado: ${actual}"
else
    log "Aviso: no hay digest SHA256 disponible para este asset; se omite la verificación."
fi

# --- Extracción --------------------------------------------------------------
log "Extrayendo en ${INSTALL_DIR} ..."
mkdir -p "$INSTALL_DIR"
tar -xzf "$dest_file" -C "$INSTALL_DIR"

# --- Symlinks ----------------------------------------------------------------
mkdir -p "$BIN_DIR"
for bin in "${BINS[@]}"; do
    if [[ ! -f "${INSTALL_DIR}/${bin}" ]]; then
        err "El binario ${bin} no existe en ${INSTALL_DIR}."
        exit 1
    fi
    ln -sf "${INSTALL_DIR}/${bin}" "${BIN_DIR}/${bin}"
    log "Enlazado ${BIN_DIR}/${bin} -> ${INSTALL_DIR}/${bin}"
done

log "Completado. Instalado en ${INSTALL_DIR}; binarios disponibles en ${BIN_DIR}."
