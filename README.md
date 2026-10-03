# builder

Repositorio de builds para:
- `audio.cpp`

Publica las releases con los binarios empaquetados y un script de instalación para Linux.

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

1. Consulta la **última release** de cada repositorio vía la API de GitHub.
2. Localiza el asset que coincide con el patrón configurado.
3. **Cachea** el archivo en `/tmp/` — si el SHA256 ya coincide, omite descarga y extracción.
4. **Verifica el SHA256** contra el digest publicado (si existe).
5. Extrae el contenido en el directorio de instalación.
6. Crea symlinks de los binarios en `~/.local/bin`.

> Asegúrate de que `~/.local/bin` esté en tu `PATH`.

### Uso

```bash
./install.sh              # Instala todos los repos configurados
./install.sh audiocpp     # Instala solo audiocpp
./install.sh llamacpp     # Instala solo llamacpp
./install.sh --list       # Lista repos configurados
./install.sh --help       # Muestra esta ayuda
```

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
