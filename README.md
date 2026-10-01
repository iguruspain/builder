# builder

Repositorio de builds de **audio.cpp**. Publica las releases con los binarios
empaquetados en `audio-*.tar.gz` y un script de instalación para Linux.

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

1. Consulta la **última release** de [`iguruspain/builder`](https://github.com/iguruspain/builder) vía la API de GitHub.
2. Localiza el asset `audio-*.tar.gz`.
3. Lo descarga a `/tmp/audiocpp`.
4. **Verifica el SHA256** contra el digest publicado en la release (si existe).
5. Extrae el contenido en `~/.local/share/audiocpp`.
6. Crea symlinks de los binarios en `~/.local/bin`:
   - `audiocpp_cli`
   - `audiocpp_gguf`
   - `audiocpp_server`

> Asegúrate de que `~/.local/bin` esté en tu `PATH`.

### Token de GitHub (opcional)

Si no usas credenciales, las descargas anónimas están sujetas a los límites de
la API de GitHub. Para evitarlo, exporta un token antes de ejecutar el script:

```bash
export GITHUB_TOKEN="ghp_..."
```

## Estructura

```
builder/
├── install.sh   # Script de descarga, verificación e instalación
└── README.md
```
