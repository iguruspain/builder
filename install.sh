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
##   ./install.sh --profile cuda|arm64 [...]
##       Fuerza el perfil en vez de deducirlo de `uname -m`.
##
## Perfil (según `uname -m`):
##   x86_64          -> cuda   (PC con GPU NVIDIA)
##   aarch64/arm64   -> arm64  (Raspberry Pi y otros arm64, solo CPU)
##
## Assets CUDA: 13.4 para Turing+ (CC >= 8) y 12.8 para Maxwell/Pascal/Volta
## (CC < 8, ej. GTX 10xx); se detecta con `nvidia-smi --query-gpu=compute_cap`.
## Runtime CUDA: si el sistema no trae el runtime (libcudart.so.NN), se descarga
## el asset 'cudart-<asset principal>' de la misma release y se extrae junto al
## binario (RUNPATH $ORIGIN): sin sudo ni variables de entorno.
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

# Muestra la versión del binario actualmente instalado (si existe)
show_current_version() {
    local bin="$1"
    if command -v "$bin" >/dev/null 2>&1; then
        log "Versión actual de ${bin} ($(command -v "$bin")):"
        "$bin" --version 2>&1 | head -n 1
    else
        log "Versión actual de ${bin}: no instalado"
    fi
}

# --- Assets CUDA: 12.8 o 13.4 según la GPU --------------------------------
# CUDA 13 (y sus binarios oficiales de llama.cpp) eliminaron Maxwell/Pascal/
# Volta: las GPUs pre-Turing (CC < 8) usan los assets 12.8.
CUDA_ASSET=""
detect_cuda_asset() {
    local cc=""
    if command -v nvidia-smi >/dev/null 2>&1; then
        cc="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -n 1 || true)"
    fi
    if [[ -z "$cc" ]]; then
        CUDA_ASSET="13.4"
        log "GPU NVIDIA no detectada: assets CUDA 13.4 por defecto"
        return
    fi
    local major="${cc%%.*}"
    if (( major < 8 )); then
        CUDA_ASSET="12.8"
        log "GPU con compute capability ${cc} (pre-Turing): assets CUDA 12.8"
        # El asset 12.8 enlaza contra el runtime CUDA 12.x; si no está en el
        # sistema, install_cudart_runtime descarga el asset 'cudart-...' de la
        # misma release y lo extrae junto al binario (RUNPATH $ORIGIN).
        if ! ldconfig -p 2>/dev/null | grep -q 'libcudart\.so\.12'; then
            log "Aviso: no hay runtime CUDA 12.x en el sistema; se descargará el asset cudart-...-cuda-12.8-x64."
        fi
    else
        CUDA_ASSET="13.4"
        log "GPU con compute capability ${cc}: assets CUDA 13.4"
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
# Runtime CUDA — el build cuda de llama.cpp enlaza contra libcudart.so.NN y
# libcublas.so.NN. Si el sistema no trae ese runtime, se descarga el asset
# 'cudart-<asset principal>' de la MISMA release (mismo build) y se extrae
# junto al binario: RUNPATH $ORIGIN lo resuelve sin sudo ni variables.
# ============================================================================
install_cudart_runtime() {
    local main_asset="$1" releases_json="$2" install_dir="$3"
    local soname_major="${CUDA_ASSET%%.*}"
    local soname="libcudart.so.${soname_major}"

    if ldconfig -p 2>/dev/null | grep -q "${soname}"; then
        log "  Runtime CUDA: ${soname} ya presente en el sistema; se omite el asset cudart."
        return
    fi
    if [[ -f "${install_dir}/${soname}" ]]; then
        log "  Runtime CUDA: ${soname} ya instalado junto al binario; se omite."
        return
    fi

    local cudart_asset="cudart-${main_asset}"
    local tab=$'\t'
    local lookup cudart_url cudart_digest
    lookup="$(jq -r --arg main "$main_asset" --arg cud "$cudart_asset" '
        [ .[]
          | select(.tag_name | test("^b[0-9]+$"))
          | select((.assets[]? | select(.name == $main)) | length > 0)
          | .assets[]?
          | select(.name == $cud)
        ] | first | [.browser_download_url // "", .digest // ""] | @tsv
    ' <<<"$releases_json")"
    cudart_url="${lookup%%${tab}*}"
    cudart_digest="${lookup#*${tab}}"

    if [[ -z "$cudart_url" ]]; then
        err "El sistema no tiene ${soname} y la release no publica '${cudart_asset}'."
        err "Instala el runtime manualmente (p. ej. 'sudo apt install cuda-toolkit-12-8')."
        exit 1
    fi

    log "  Runtime CUDA: asset ${cudart_asset} ..."
    local dest_file="/tmp/$(basename "$cudart_asset")"
    local sha_hash
    if sha_hash="$(cached_asset_ok "$cudart_asset" "$dest_file" "$cudart_digest")"; then
        log "  Runtime CUDA: caché OK (SHA256 ${sha_hash})"
    else
        log "  Runtime CUDA: descargando ..."
        curl -fL --progress-bar "${CURL_AUTH[@]}" -o "$dest_file" "$cudart_url"
        verify_sha256 "$cudart_asset" "$dest_file" "$cudart_digest"
    fi
    log "  Runtime CUDA: extrayendo en ${install_dir} ..."
    mkdir -p "$install_dir"
    tar -xzf "$dest_file" -C "$install_dir" --strip-components=1
    if [[ ! -f "${install_dir}/${soname}" ]]; then
        err "El asset cudart no produjo ${install_dir}/${soname}."
        exit 1
    fi
    log "  Runtime CUDA: listo (runtime ${soname_major}.x junto al binario, RUNPATH \$ORIGIN)."
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

    # Runtime CUDA (solo builds cuda): las .so del mismo build junto al binario.
    if [[ "$PROFILE" == "cuda" ]]; then
        install_cudart_runtime "$asset" "$releases_json" "$install_dir"
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
# (releases paginados, retrocede hasta la release más reciente con el asset)
# ============================================================================
install_repo_latest() {
    local name="$1" repo="$2" api_url="$3" asset_pattern="$4" install_dir="$5"
    shift 5
    local bins=("$@")

    log "Consultando la última release de ${repo}..."

    local release_json asset asset_url asset_digest
    release_json="$(curl -fsSL "${CURL_AUTH[@]}" "$api_url")"

    asset="$(jq -r --arg p "$asset_pattern" '
        [ .[] | .assets[]? | select(.name | test($p)) ] | first | .name // empty
    ' <<<"$release_json")"

    if [[ -z "$asset" ]]; then
        err "No se encontró '${asset_pattern}' en las últimas releases de ${repo}."
        exit 1
    fi

    asset_url="$(jq -r --arg n "$asset" '
        [ .[] | .assets[]? | select(.name == $n) | .browser_download_url ]
        | first // empty
    ' <<<"$release_json")"
    asset_digest="$(jq -r --arg n "$asset" '
        [ .[] | .assets[]? | select(.name == $n) | .digest // empty ]
        | first // empty
    ' <<<"$release_json")"

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
    "https://api.github.com/repos/iguruspain/builder/releases?per_page=30"
)

# Patrón regex del asset a buscar, por "<nombre>:<perfil>[:<asset cuda>]" (shellopsible para jq test())
declare -A CFG_PATTERN=(
    ['llamacpp:cuda:13.4']='^llama-b[0-9]+-bin-ubuntu-cuda-13\.4-x64\.tar\.gz$'
    ['llamacpp:cuda:12.8']='^llama-b[0-9]+-bin-ubuntu-cuda-12\.8-x64\.tar\.gz$'
    ['llamacpp:arm64']='^llama-b[0-9]+-bin-ubuntu-arm64\.tar\.gz$'
    ['audiocpp:cuda:13.4']='^audiocpp-[0-9]+-bin-ubuntu-x64-cuda13\.4-sm[^/]*\.tar\.gz$'
    ['audiocpp:cuda:12.8']='^audiocpp-[0-9]+-bin-ubuntu-x64-cuda12\.8-sm[^/]*\.tar\.gz$'
    ['audiocpp:arm64']='^audiocpp-[0-9]+-bin-linux-arm64\.tar\.gz$'
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

# Binarios cuya versión se muestra antes de instalar (vacío = ninguno)
declare -a CFG_VERSION_BINS=(
    "llama-server"
    "audiocpp_server"
)

# ============================================================================
# Main
# ============================================================================

BIN_DIR="${HOME}/.local/bin"

# --- Parsea argumentos CLI --------------------------------------------------

usage() {
    echo "Uso: $0 [--profile cuda|arm64] [REPO1 REPO2 ...]"
    echo "  $0 --all           Instala todos (por defecto)"
    echo "  $0 --list          Lista repos configurados y el perfil detectado"
    echo "  $0 --profile P     Fuerza el perfil (cuda | arm64); por defecto se deduce de uname -m"
    echo "  $0 --help          Muestra esta ayuda"
}

TARGETS=()
PROFILE=""
LIST=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)       shift ;;
        --list)      LIST=true; shift ;;
        --help|-h)   usage; exit 0 ;;
        --profile)
            [[ $# -ge 2 ]] || { err "--profile requiere un valor (cuda|arm64)"; exit 1; }
            PROFILE="$2"; shift 2 ;;
        --profile=*) PROFILE="${1#--profile=}"; shift ;;
        -*)          err "Opción desconocida: $1"; usage; exit 1 ;;
        *)
            found=false
            for (( i=0; i<${#CFG_NAME[@]}; i++ )); do
                if [[ "$1" == "${CFG_NAME[$i]}" ]]; then found=true; break; fi
            done
            if [[ "$found" == "false" ]]; then
                err "Repositorio '$1' desconocido."
                echo "  Disponibles: ${CFG_NAME[*]}"
                exit 1
            fi
            TARGETS+=("$1"); shift ;;
    esac
done

# --- Perfil: uname -m -------------------------------------------------------

if [[ -z "$PROFILE" ]]; then
    case "$(uname -m)" in
        x86_64)         PROFILE="cuda" ;;
        aarch64|arm64)  PROFILE="arm64" ;;
        *) err "Arquitectura no soportada: $(uname -m) (usa --profile cuda|arm64)"; exit 1 ;;
    esac
fi
case "$PROFILE" in
    cuda|arm64) ;;
    *) err "Perfil inválido: '${PROFILE}' (usa cuda o arm64)"; exit 1 ;;
esac

if [[ "$PROFILE" == "cuda" ]]; then
    detect_cuda_asset
fi

if [[ "$LIST" == "true" ]]; then
    if [[ "$PROFILE" == "cuda" ]]; then
        echo "Perfil: ${PROFILE} ($(uname -m)) · assets CUDA ${CUDA_ASSET}"
    else
        echo "Perfil: ${PROFILE} ($(uname -m))"
    fi
    echo "Repositorios configurados:"
    for (( i=0; i<${#CFG_NAME[@]}; i++ )); do
        echo "  ${CFG_NAME[$i]}"
    done
    exit 0
fi

if [[ ${#TARGETS[@]} -eq 0 ]]; then
    for (( i=0; i<${#CFG_NAME[@]}; i++ )); do
        TARGETS+=("${CFG_NAME[$i]}")
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
mkdir -p "$BIN_DIR"
if [[ "$PROFILE" == "cuda" ]]; then
    log "Perfil: ${PROFILE} ($(uname -m)) · assets CUDA ${CUDA_ASSET}"
else
    log "Perfil: ${PROFILE} ($(uname -m))"
fi

for target in "${TARGETS[@]}"; do
    idx="$(resolve_indices "$target")"

    name="${CFG_NAME[$idx]}"
    repo="${CFG_REPO[$idx]}"
    api_url="${CFG_API[$idx]}"
    pkey="${name}:${PROFILE}"
    if [[ "$PROFILE" == "cuda" ]]; then
        pkey="${pkey}:${CUDA_ASSET}"
    fi
    pattern="${CFG_PATTERN[${pkey}]:-}"
    if [[ -z "$pattern" ]]; then
        err "No hay build de ${name} para el perfil '${PROFILE}'."
        exit 1
    fi
    install_dir="${CFG_INSTALL_DIR[$idx]}"
    mode="${CFG_MODE[$idx]}"
    bins_str="${CFG_BINS[$idx]}"

    log ">>> Instalando: ${name} (${repo}) <<<"

    for vbin in ${CFG_VERSION_BINS[$idx]:-}; do
        show_current_version "$vbin"
    done

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
