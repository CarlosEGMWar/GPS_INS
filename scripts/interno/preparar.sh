#!/bin/bash
# ============================================================================
#  preparar.sh  -  deja el entorno listo para compilar, desde cero
# ============================================================================
#
#  No hace falta llamarlo a mano: compilar.sh y actualizar.sh lo invocan solos
#  cuando detectan que falta algo. Se puede correr tantas veces como quieras,
#  solo hace lo que falte.
#
#  Se encarga de:
#    1. descargar ArduPilot (la version que se le pase, o el ultimo Rover-*)
#    2. sus submodulos (ChibiOS, mavlink, ...)
#    3. las dependencias de Python
#    4. el compilador ARM, si no lo tienes ya
#
#  Descarga ~2,4 GB la primera vez. Despues no descarga nada.
# ============================================================================
set -u
source "$(dirname "${BASH_SOURCE[0]}")/comun.sh"

SUBMODULOS="modules/waf modules/mavlink modules/ChibiOS modules/lwip
            modules/littlefs modules/Micro-CDR modules/Micro-XRCE-DDS-Client
            modules/DroneCAN/DSDL modules/DroneCAN/dronecan_dsdlc
            modules/DroneCAN/libcanard modules/DroneCAN/pydronecan"

TC_VER="gcc-arm-none-eabi-10-2020-q4-major"
PY_DEPS='empy==3.3.4 pymavlink future intelhex pexpect'

falta_algo=0

# ------------------------------------------------------- 1. herramientas base
for h in git python3 tar; do
    command -v "$h" >/dev/null || morir "falta '$h'. Instalalo con el gestor de paquetes de tu sistema."
done
command -v strings >/dev/null || morir "falta 'strings' (paquete binutils).
     Debian/Ubuntu: sudo apt install binutils
     Fedora:        sudo dnf install binutils
     macOS:         viene con las Command Line Tools de Xcode"

# ------------------------------------------------------- 2. ArduPilot
if [ ! -d "$AP/.git" ]; then
    falta_algo=1
    # Que version. No hay ningun archivo que la fije: o la dice quien llama
    # (actualizar.sh la pasa en SBY_VERSION_AP) o se coge el ultimo release.
    VERSION="${SBY_VERSION_AP:-}"
    if [ -z "$VERSION" ]; then
        paso "Averiguando el ultimo release de Rover"
        VERSION=$(ultima_rover)
        [ -n "$VERSION" ] || morir "no pude consultar los releases de ArduPilot.
     Indica la version a mano:  ./scripts/actualizar.sh Rover-4.7.1"
        info "el mas reciente es $VERSION"
    fi
    paso "Descargando ArduPilot (~880 MB, solo esta vez)"
    info "version: $VERSION"
    mkdir -p "$(dirname "$AP")"
    git clone --progress https://github.com/ArduPilot/ardupilot.git "$AP" 2>&1 \
        | grep -E "Receiving|Resolving|Updating" | tail -3 | sed 's/^/   /'
    [ -d "$AP/.git" ] || morir "no se pudo descargar ArduPilot"
    git -C "$AP" checkout -q --detach "$VERSION" || morir "no existe la version $VERSION"
    info "ArduPilot en $VERSION"
fi

asegurar_eol

# ------------------------------------------------------- 3. submodulos
pendientes=$(git -C "$AP" submodule status $SUBMODULOS 2>/dev/null | grep -c '^-' || true)
if [ "${pendientes:-0}" -gt 0 ]; then
    falta_algo=1
    paso "Descargando $pendientes submodulos (~460 MB, ChibiOS es el grueso)"
    git -C "$AP" submodule update --init $SUBMODULOS 2>&1 \
        | grep -E "^Submodule path" | sed 's/^/   /' | tail -12
    pendientes=$(git -C "$AP" submodule status $SUBMODULOS 2>/dev/null | grep -c '^-' || true)
    [ "${pendientes:-0}" -eq 0 ] || morir "quedaron $pendientes submodulos sin descargar"
    info "submodulos listos"
fi

# ------------------------------------------------------- 4. dependencias Python
if ! python3 -c "import em, pymavlink, intelhex" >/dev/null 2>&1; then
    falta_algo=1
    paso "Instalando dependencias de Python (con pip --user)"
    info "$PY_DEPS"
    # shellcheck disable=SC2086
    python3 -m pip install --quiet --user $PY_DEPS 2>&1 | tail -3 | sed 's/^/   /'
    python3 -c "import em, pymavlink, intelhex" 2>/dev/null \
        || morir "no se pudieron instalar las dependencias de Python.
     Instalacion manual:  python3 -m pip install --user $PY_DEPS"
    info "dependencias listas"
fi

# ------------------------------------------------------- 5. compilador ARM
if ! command -v arm-none-eabi-gcc >/dev/null 2>&1; then
    falta_algo=1
    case "$(uname -s)/$(uname -m)" in
        Linux/x86_64)          PLAT=x86_64-linux ;;
        Linux/aarch64|Linux/arm64) PLAT=aarch64-linux ;;
        Darwin/*)              PLAT=mac ;;
        *) morir "no se para que plataforma bajar el compilador ($(uname -s)/$(uname -m)).
     Instalalo tu e indica donde esta:  export ARM_TOOLCHAIN=/ruta/a/bin" ;;
    esac
    paso "Descargando el compilador ARM (~150 MB, solo esta vez)"
    info "$TC_VER  para  $PLAT"
    mkdir -p "$HOME/opt" && cd "$HOME/opt" || morir "no puedo escribir en ~/opt"
    URL="https://firmware.ardupilot.org/Tools/STM32-tools/${TC_VER}-${PLAT}.tar.bz2"
    if command -v wget >/dev/null; then
        wget -c --tries=0 --timeout=30 --read-timeout=60 -q --show-progress "$URL" -O tc.tar.bz2 \
            || morir "fallo la descarga del compilador"
    else
        curl -fL --retry 5 -o tc.tar.bz2 "$URL" || morir "fallo la descarga del compilador"
    fi
    info "verificando el archivo"
    bzip2 -t tc.tar.bz2 || morir "el archivo descargado esta corrupto; borra ~/opt/tc.tar.bz2 y reintenta"
    info "extrayendo (tarda un par de minutos)"
    tar xjf tc.tar.bz2 && rm -f tc.tar.bz2
    export PATH="$HOME/opt/$TC_VER/bin:$PATH"
    cd - >/dev/null || true
    command -v arm-none-eabi-gcc >/dev/null || morir "el compilador no quedo utilizable"
    info "$(arm-none-eabi-gcc --version | head -1)"
fi

if [ "$falta_algo" -eq 1 ]; then
    echo
    verde "Entorno listo."
else
    info "entorno ya preparado, no habia nada que hacer"
fi
