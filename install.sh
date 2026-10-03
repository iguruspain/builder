#!/usr/bin/env bash
##
## install.sh — Instalador unificado para repositorios de GitHub que
## publican releases con assets tar.gz. Soporta múltiples repos simultáneos
## mediante bloques de configuración.
##
## Uso:
##   ./install.sh [REPO1 REPO2 ...]
##       Instala solo los repos indicados por nombre.
##   ./install.sh --all
##       Instala todos los repos configurados.
##   ./install.sh
##       Instala todos los repos configurados (por defecto).
##

set -euo pipefail
# ============================================================================
# Funciones comunes
# ============================================================================

log() { printf '\033[1;34m[install]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

DEPENDENCIES_CHECKED=false
check_deps() {
    if [[ "$DEPENDENCIES_CHECKED" == "true" ]]; then return; fi
    for dep in curl jq tar sha256sum; do
        if ! command -v "${dep}" >/dev/null 2>&1; then
            err "Dependencia requerida no encontrada: ${dep}"
            exit 1
        fi
    done
    DEPENDENCIES_CHECKED=true
}

build_auth_args() {
    CURL_AUTH=()
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        CURL_AUTH=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    fi
}

# ============================================================================
# Verificación SHA256
# ============================================================================
verify_sha256() {
    local asset_name="$1" file="$2" digest="$3"
    if [[ -z "$digest" || "$digest" != sha256:* ]]; then
        log "  Aviso: no hay digest SHA256 disponible para '${asset_name}'; se omite verificación."
        return
    fi
    local expected="${digest#sha256:}"
    local actual
    actual="$(sha256sum "$file" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        err "SHA256 no coincide para ${asset_name}: esperado ${expected}, obtenido ${actual}"
        rm -f "$file"
        exit 1
    fi
    log "  SHA256 verificado para ${asset_name}: ${actual}"
}

cached_asset_ok() {
    local asset_name="$1" file="$2" digest="$3"
    [[ -f "$file" ]] || return 1
    if [[ -z "$digest" || "$digest" != sha256:* ]]; then
        return 1
    fi
    local expected="${digest#sha256:}"
    local actual
    actual="$(sha256sum "$file" | awk '{print $1}')"
    if [[ "$actual" == "$expected" ]]; then
        echo "$actual"
        return 0
    fi
    return 1
}

# ============================================================================
# Instalación — modo "search"
# (releases paginados, filtra por tag b<build>)
# ============================================================================
install_repo_search() {
    local name="$1" repo="$2" api_url="$3" asset_pattern="$4" install_dir="$5"

    log "Consultando las últimas releases de ${repo}..."

    local releases_json
    releases_json="$(curl -fsSL "${CURL_AUTH[@]}" "$api_url")"

    local asset asset_url asset_digest

    asset="$(jq -r --arg p "$asset_pattern" '
        [ .[]
          | select(.tag_name | test("^b[0-9]+$"))
          | .assets[]?
          | select(.name | test($p))
        ] | first | .name // empty
    ' <<<"$releases_json")"

    if [[ -z "$asset" ]]; then
        err "No se encontró '${asset_pattern}' en las últimas releases de ${repo}."
        exit 1
    fi

    asset_url="$(jq -r --arg n "$asset" '
        [ .[] | select(.tag_name | test("^b[0-9]+$")) | .assets[]?
          | select(.name == $n)
        ] | first | .browser_download_url
    ' <<<"$releases_json")"
    asset_digest="$(jq -r --arg n "$asset" '
        [ .[] | select(.tag_name | test("^b[0-9]+$")) | .assets[]?
          | select(.name == $n)
        ] | first | .digest // empty
    ' <<<"$releases_json")"

    log "  Asset: ${asset}"
    local dest_file="/tmp/$(basename "$asset")"
    local sha_hash
    if sha_hash="$(cached_asset_ok "$asset" "$dest_file" "$asset_digest")"; then
        log "  Caché: ${asset} (SHA256 ${sha_hash}, se omite descarga y extracción)"
    else
        log "  Descargando ..."
        curl -fL --progress-bar "${CURL_AUTH[@]}" -o "$dest_file" "$asset_url"
        verify_sha256 "$asset" "$dest_file" "$asset_digest"
        mkdir -p "$install_dir"
        log "  Extrayendo en ${install_dir} ..."
        tar -xzf "$dest_file" -C "$install_dir" --strip-components=1
    fi


    # Symlinks: todos los ejecutables regulares (excluye .so)
    local linked=0
    while IFS= read -r -d '' bin_path; do
        ln -sf "$bin_path" "${BIN_DIR}/$(basename "$bin_path")"
        log "  Enlazado $(basename "$bin_path")"
        linked=$((linked + 1))
    done < <(find "$install_dir" -maxdepth 1 -type f -perm -u+x ! -name '*.so*' -print0)

    if [[ "$linked" -eq 0 ]]; then
        err "No se encontraron binarios ejecutables en ${install_dir}."
        exit 1
    fi
    log "  Completado. ${linked} binarios en ${BIN_DIR}."
}

# ============================================================================
# Instalación — modo "latest"
# (releases/latest, binarios explícitos)
# ============================================================================
install_repo_latest() {
    local name="$1" repo="$2" api_url="$3" asset_pattern="$4" install_dir="$5"
    shift 5
    local bins=("$@")

    log "Consultando la última release de ${repo}..."

    local release_json asset asset_url asset_digest
    release_json="$(curl -fsSL "${CURL_AUTH[@]}" "$api_url")"

    asset="$(jq -r --arg p "$asset_pattern" '
        [.assets[] | select(.name | test($p))] | first | .name // empty
    ' <<<"$release_json")"

    if [[ -z "$asset" ]]; then
        err "No se encontró '${asset_pattern}' en la última release de ${repo}."
        exit 1
    fi

    asset_url="$(jq -r --arg n "$asset" \
        '.assets[] | select(.name == $n) | .browser_download_url' <<<"$release_json")"
    asset_digest="$(jq -r --arg n "$asset" \
        '.assets[] | select(.name == $n) | .digest // empty' <<<"$release_json")"

    log "  Asset: ${asset}"

    local dest_file="/tmp/$(basename "$asset")"
    local sha_hash
    if sha_hash="$(cached_asset_ok "$asset" "$dest_file" "$asset_digest")"; then
        log "  Caché: ${asset} (SHA256 ${sha_hash}, se omite descarga y extracción)"
    else
        log "  Descargando ..."
        curl -fL --progress-bar "${CURL_AUTH[@]}" -o "$dest_file" "$asset_url"
        verify_sha256 "$asset" "$dest_file" "$asset_digest"
        mkdir -p "$install_dir"
        log "  Extrayendo en ${install_dir} ..."
        tar -xzf "$dest_file" -C "$install_dir"
    fi

    mkdir -p "$install_dir"


    for bin in "${bins[@]}"; do
        if [[ ! -f "${install_dir}/${bin}" ]]; then
            err "El binario ${bin} no existe en ${install_dir}."
            exit 1
        fi
        ln -sf "${install_dir}/${bin}" "${BIN_DIR}/${bin}"
        log "  Enlazado ${bin}"
    done

    log "  Completado."
}

# ============================================================================
# Configuración de repositorios
# Índices paralelos — cada i referencia un repos.
# ============================================================================

# Nombres que se pasan en la CLI (--help lista estos)
declare -a CFG_NAME=( llamacpp audiocpp )

# Repositorio (usuario/nombre)
declare -a CFG_REPO=(
    "ggml-org/llama.cpp"
    "iguruspain/builder"
)

# URL de la API de GitHub
declare -a CFG_API=(
    "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=30"
    "https://api.github.com/repos/iguruspain/builder/releases/latest"
)

# Patrón regex del asset a buscar (shellopsible para jq test())
declare -a CFG_PATTERN=(
    "^llama-b[0-9]+-bin-ubuntu-cuda-13\.4-x64\.tar\.gz$"
    "audiocpp-.*\.tar\.gz$"
)
# Directorio de instalación (~/.local/share/...)
declare -a CFG_INSTALL_DIR=(
    "${HOME}/.local/share/llamacpp"
    "${HOME}/.local/share/audiocpp"
)

# Modo: "search" | "latest"
declare -a CFG_MODE=(
    search
    latest
)

# Lista de binarios (modo latest; vacío para search)
declare -a CFG_BINS=(
    ""
    "audiocpp_cli audiocpp_gguf audiocpp_server"
)

# ============================================================================
# Main
# ============================================================================

BIN_DIR="${HOME}/.local/bin"

# --- Parsea argumentos CLI --------------------------------------------------

TARGETS=()
if [[ $# -eq 0 ]] || [[ "${1:-}" == "--all" ]]; then
    for (( i=0; i<${#CFG_NAME[@]}; i++ )); do
        TARGETS+=("${CFG_NAME[$i]}")
    done
elif [[ "${1:-}" == "--list" ]]; then
    echo "Repositorios configurados:"
    for (( i=0; i<${#CFG_NAME[@]}; i++ )); do
        echo "  ${CFG_NAME[$i]}"
    done
    exit 0
elif [[ "${1:-}" == "--help" ]]; then
    echo "Uso: $0 [REPO1 REPO2 ...]"
    echo "  $0 --all           Instala todos (por defecto)"
    echo "  $0 --list          Lista repos configurados"
    echo "  $0 --help          Muestra esta ayuda"
    exit 0
else
    for arg in "$@"; do
        found=false
        for (( i=0; i<${#CFG_NAME[@]}; i++ )); do
            if [[ "$arg" == "${CFG_NAME[$i]}" ]]; then
                TARGETS+=("$arg")
                found=true
                break
            fi
        done
        if [[ "$found" == "false" ]]; then
            err "Repositorio '${arg}' desconocido."
            echo "  Disponibles: ${CFG_NAME[*]}"
            exit 1
        fi
    done
fi

# --- Resuelve índices por nombre -------------------------------------------

resolve_indices() {
    local name="$1"
    for (( i=0; i<${#CFG_NAME[@]}; i++ )); do
        if [[ "$name" == "${CFG_NAME[$i]}" ]]; then
            echo "$i"
            return
        fi
    done
    err "No encontrado: $name"
    exit 1
}

check_deps
build_auth_args

for target in "${TARGETS[@]}"; do
    idx="$(resolve_indices "$target")"

    name="${CFG_NAME[$idx]}"
    repo="${CFG_REPO[$idx]}"
    api_url="${CFG_API[$idx]}"
    pattern="${CFG_PATTERN[$idx]}"
    install_dir="${CFG_INSTALL_DIR[$idx]}"
    mode="${CFG_MODE[$idx]}"
    bins_str="${CFG_BINS[$idx]}"

    log ">>> Instalando: ${name} (${repo}) <<<"

    case "$mode" in
        search)
            install_repo_search "$name" "$repo" "$api_url" "$pattern" "$install_dir"
            ;;
        latest)
            if [[ -n "$bins_str" ]]; then
                bins=($bins_str)
                install_repo_latest "$name" "$repo" "$api_url" "$pattern" "$install_dir" "${bins[@]}"
            else
                err "Modo latest requiere CFG_BINS definido para ${name}."
                exit 1
            fi
            ;;
        *)
            err "Modo desconocido: ${mode}"
            exit 1
            ;;
    esac
done

log "Instalación completada."
