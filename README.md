# builder

Repositorio de builds para:
- `audio.cpp` (Ubuntu x64 + CUDA 13.4 para Turing+, Ubuntu x64 + CUDA 12.8 para
  Maxwell/Pascal/Volta y Linux arm64 CPU, en una única release con los `tar.gz` correspondientes)

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

1. Deduce el **perfil** de la máquina con `uname -m` (ver [Perfiles](#perfiles)); con el perfil
   `cuda` además detecta la compute capability de la GPU con `nvidia-smi` y elige el asset CUDA (13.4 o 12.8).
2. Consulta la **última release** de cada repositorio vía la API de GitHub.
3. Localiza el asset que coincide con el patrón configurado **para ese perfil y ese asset CUDA**.
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

| `uname -m`        | Perfil  | Máquina                                              | llama.cpp                                  | audio.cpp                                  |
|-------------------|---------|------------------------------------------------------|--------------------------------------------|--------------------------------------------|
| `x86_64`          | `cuda`  | GPU NVIDIA Turing o superior (CC ≥ 8)                | `llama-bNNNN-bin-ubuntu-cuda-13.4-x64.tar.gz` | `audiocpp-<fecha>-bin-ubuntu-x64-cuda13.4-sm<arch>.tar.gz` |
| `x86_64`          | `cuda`  | GPU NVIDIA pre-Turing (CC ≤ 7.5, ej. GTX 10xx)       | `llama-bNNNN-bin-ubuntu-cuda-12.8-x64.tar.gz` | `audiocpp-<fecha>-bin-ubuntu-x64-cuda12.8-sm61.tar.gz` |
| `aarch64`/`arm64` | `arm64` | Raspberry Pi y otros arm64 (solo CPU)                | `llama-bNNNN-bin-ubuntu-arm64.tar.gz`      | `audiocpp-<fecha>-bin-linux-arm64.tar.gz`  |

Notas:

- El perfil `cuda` asume una GPU NVIDIA y el CUDA del sistema (`libcudart`, `libcublas`...).
  El asset 13.4 enlaza contra CUDA 13.x; el asset 12.8, contra CUDA 12.x (`libcudart.so.12`,
  `libcublas.so.12`...): si el sistema solo trae CUDA 13, instala además el toolkit 12.8
  (p. ej. `sudo apt install cuda-toolkit-12-8`) o extrae en un path de librerías el asset
  `cudart-...-cuda-12.8-x64.tar.gz` que llama.cpp publica al lado de los binarios.
- CUDA 13 eliminó la compilación offline para Maxwell/Pascal/Volta: las GPUs pre-Turing las cubre
  el asset 12.8, elegido automáticamente vía `nvidia-smi --query-gpu=compute_cap`
  (sin GPU detectada, por defecto 13.4).
- Builds de audio.cpp: el de 13.4 compila `sm<arch>` (`sm86` = RTX 30xx por defecto) y el de
  12.8, `sm61` (GTX 10xx); comprueba la arquitectura exacta en el nombre del asset.
- Si la release más reciente no trae el asset de tu perfil/asset CUDA, se usa la más reciente que sí lo tenga.
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
