# builder

Repositorio de builds para:
- `audio.cpp` (Ubuntu x64 + CUDA 13 y Linux arm64 CPU, en una única release con los dos `tar.gz`)

Publica las releases con los binarios empaquetados y un script de instalación para Linux
que elige automáticamente el build adecuado para la máquina (ver [Perfiles](#perfiles)).

## Instalación

### Requisitos

- `curl`
- `jq`
- `tar`
- `sha256sum`

### Con el script

```bash
curl -fsSL https://raw.githubusercontent.com/iguruspain/builder/main/install.sh | bash
```

O descárgalo y ejecútalo localmente:

```bash
./install.sh
```

### Qué hace `install.sh`

El script instala todos los repos configurados de forma automática:

1. Deduce el **perfil** de la máquina con `uname -m` (ver [Perfiles](#perfiles)).
2. Consulta la **última release** de cada repositorio vía la API de GitHub.
3. Localiza el asset que coincide con el patrón configurado **para ese perfil**.
4. **Cachea** el archivo en `/tmp/` — si el SHA256 ya coincide, omite descarga y extracción.
5. **Verifica el SHA256** contra el digest publicado (si existe).
6. Extrae el contenido en el directorio de instalación.
7. Crea symlinks de los binarios en `~/.local/bin` (el directorio se crea si no existe).

> Asegúrate de que `~/.local/bin` esté en tu `PATH`.

### Uso

```bash
./install.sh              # Instala todos los repos configurados
./install.sh audiocpp     # Instala solo audiocpp
./install.sh llamacpp     # Instala solo llamacpp
./install.sh --list       # Lista repos configurados y el perfil detectado
./install.sh --profile arm64 audiocpp   # Fuerza el perfil (cuda | arm64)
./install.sh --help       # Muestra esta ayuda
```

### Perfiles

El perfil sale de `uname -m`; con `--profile` se puede forzar.

| `uname -m`        | Perfil  | Máquina                                  | llama.cpp                                  | audio.cpp                                  |
|-------------------|---------|------------------------------------------|--------------------------------------------|--------------------------------------------|
| `x86_64`          | `cuda`  | PC con GPU NVIDIA                        | `llama-bNNNN-bin-ubuntu-cuda-13.4-x64.tar.gz` | `audiocpp-<fecha>-bin-ubuntu-x64-cuda13.4-sm<arch>.tar.gz` |
| `aarch64`/`arm64` | `arm64` | Raspberry Pi y otros arm64 (solo CPU)    | `llama-bNNNN-bin-ubuntu-arm64.tar.gz`      | `audiocpp-<fecha>-bin-linux-arm64.tar.gz`  |

Notas:

- El perfil `cuda` asume una GPU NVIDIA y el CUDA del sistema (`libcudart`, `libcublas`...).
  El paquete de audio.cpp está compilado para unas arquitecturas concretas (`sm86` = RTX 30xx
  por defecto); compruébalo en el nombre del asset.
- Para llama.cpp, si la última release no trae el asset de tu perfil, se usa la más reciente que sí lo tenga.
- Los builds se compilan en Ubuntu 24.04 (glibc 2.39): en arm64 funcionan en Raspberry Pi OS **Trixie**
  y Ubuntu 24.04 o superior, no en Bookworm.
- Una x86_64 sin GPU NVIDIA no tiene build configurado; se puede forzar `--profile cuda`, pero no arrancará sin CUDA.

### Token de GitHub (opcional)

Si no usas credenciales, las descargas anónimas están sujetas a los límites de
la API de GitHub. Para evitarlo, exporta un token antes de ejecutar el script:

```bash
export GITHUB_TOKEN="ghp_..."
```

## Estructura

```
builder/
├── install.sh   # Script unificado de descarga, verificación e instalación
└── README.md
```
