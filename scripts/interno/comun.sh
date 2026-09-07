#!/bin/bash
# Funciones y rutas compartidas por los scripts. No se ejecuta suelto.

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AP="$REPO/build/ardupilot"
DIST="$REPO/dist"
PLACA="SBY_GPS_INS"
VEHICULO="rover"

# ---------------------------------------------------------------------------
# Portabilidad: estos scripts corren en cualquier POSIX (Linux, WSL, macOS).
# No hay nada especifico de WSL. Windows nativo no sirve: waf necesita POSIX.
# ---------------------------------------------------------------------------

# Numero de nucleos. nproc es de GNU coreutils y no existe en macOS.
nucleos() {
    if command -v nproc >/dev/null 2>&1; then nproc
    elif command -v sysctl >/dev/null 2>&1 && sysctl -n hw.ncpu >/dev/null 2>&1; then sysctl -n hw.ncpu
    elif command -v getconf >/dev/null 2>&1; then getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4
    else echo 4
    fi
}

# Toolchain ARM, por orden de preferencia:
#   1. el que ya este en el PATH        (paquete del sistema, Nix, etc.)
#   2. la variable ARM_TOOLCHAIN         (apunta al directorio bin)
#   3. ~/opt/gcc-arm-none-eabi-*/bin     (la receta del README)
#   4. rutas habituales del sistema
if ! command -v arm-none-eabi-gcc >/dev/null 2>&1; then
    for d in "${ARM_TOOLCHAIN:-}" \
             $(ls -d "$HOME"/opt/gcc-arm-none-eabi-*/bin 2>/dev/null) \
             /opt/gcc-arm-none-eabi-*/bin \
             /usr/lib/arm-none-eabi/bin \
             /usr/local/opt/arm-none-eabi-gcc/bin; do
        if [ -n "$d" ] && [ -x "$d/arm-none-eabi-gcc" ]; then
            export PATH="$d:$PATH"
            break
        fi
    done
fi
[ -d "$HOME/.local/bin" ] && export PATH="$PATH:$HOME/.local/bin"

# ---------------------------------------------------------------------------
# La version de ArduPilot NO se guarda en ningun archivo: se le pregunta al
# arbol. Asi un checkout hecho a mano se respeta solo, sin nada que sincronizar.
#
# 'git describe' a secas no vale: hay commits con varios tags encima
# (Rover-4.7.1 y APMrover2-beta, por ejemplo) y elige uno cualquiera. Se filtra
# por Rover-* y se coge el mayor.
# ---------------------------------------------------------------------------
version_ardupilot() {
    local t
    [ -d "$AP/.git" ] || { echo ""; return; }
    t=$(git -C "$AP" tag --points-at HEAD 2>/dev/null \
        | grep -E '^Rover-[0-9]' | sort -V | tail -1)
    [ -n "$t" ] || t=$(git -C "$AP" describe --tags --abbrev=0 2>/dev/null)
    [ -n "$t" ] || t=$(git -C "$AP" rev-parse --short HEAD 2>/dev/null)
    echo "$t"
}

# Ultimo release de Rover publicado. Funciona sin tener ArduPilot descargado.
ultima_rover() {
    git ls-remote --tags --refs https://github.com/ArduPilot/ardupilot.git 'Rover-*' 2>/dev/null \
        | sed -E 's#.*refs/tags/##' | grep -E '^Rover-[0-9.]+$' | sort -V | tail -1
}

rojo()  { printf '\033[31m%s\033[0m\n' "$*"; }
verde() { printf '\033[32m%s\033[0m\n' "$*"; }
paso()  { printf '\n== %s\n' "$*"; }
info()  { printf '   %s\n' "$*"; }

morir() { echo; rojo "ERROR: $*"; exit 1; }

# ---------------------------------------------------------------------------
# La ruta no puede llevar espacios.
#
# No es cosa nuestra: la tarea modules/ChibiOS/include_dirs de ArduPilot arma
# una orden de shell sin comillas, la ruta se parte y falla con
#
#     /bin/sh: 1: gps: not found        (por .../test gps ins/...)
#
# Lo malo es cuando avisa: 'waf configure' pasa, los parches se aplican, y
# revienta en mitad de la compilacion con un mensaje que no menciona los
# espacios. Mejor cortar aqui, antes de descargar 2,4 GB.
# ---------------------------------------------------------------------------
comprobar_ruta() {
    case "$REPO" in
        *\ *) morir "la ruta del repositorio lleva espacios:

       $REPO

       ArduPilot no compila desde una ruta con espacios (su tarea
       modules/ChibiOS/include_dirs no entrecomilla la ruta). Mueve el
       repositorio a una ruta sin espacios, por ejemplo:

       $(echo "$REPO" | tr ' ' '_')" ;;
    esac
}
comprobar_ruta

# Si falta algo del entorno, lo prepara solo. No hay que instalar nada a mano.
comprobar_entorno() {
    if [ ! -d "$AP/.git" ]        || ! command -v arm-none-eabi-gcc >/dev/null 2>&1        || ! python3 -c "import em, pymavlink, intelhex" >/dev/null 2>&1        || [ "$(git -C "$AP" submodule status modules/ChibiOS 2>/dev/null | cut -c1)" = "-" ]; then
        paso "Falta parte del entorno: preparandolo"
        "$REPO/scripts/interno/preparar.sh" || morir "no se pudo preparar el entorno"
        # el compilador puede haberse instalado recien: rehacer el PATH
        if ! command -v arm-none-eabi-gcc >/dev/null 2>&1; then
            TC=$(ls -d "$HOME"/opt/gcc-arm-none-eabi-*/bin 2>/dev/null | head -1)
            [ -n "$TC" ] && export PATH="$TC:$PATH"
        fi
    fi
    command -v arm-none-eabi-gcc >/dev/null || morir "sigue sin haber arm-none-eabi-gcc"
}


# ---------------------------------------------------------------------------
# Finales de linea: la causa de la mayoria de los problemas raros en Windows.
#
# Si el arbol se clona con Git para Windows y core.autocrlf=true, queda escrito
# en CRLF. Entonces:
#   - git DESDE WSL ve los ~6000 archivos como modificados (no normaliza al
#     leer), y 'git apply' trabaja contra un arbol que considera entero sucio.
#   - waf ejecuta Tools/scripts/make_intel_hex.py por su shebang y muere con
#       /usr/bin/env: 'python3\r': No such file or directory
#     justo en la ULTIMA tarea, tras compilar las 999 anteriores.
#
# La solucion no es parchear ese archivo cada vez, sino que el arbol este en LF.
# Esto se asegura en cada pasada; es idempotente y no cuesta nada.
# ---------------------------------------------------------------------------
asegurar_eol() {
    git -C "$AP" config core.autocrlf false
    git -C "$AP" config core.eol lf
    git -C "$AP" config core.filemode false

    # si el arbol venia en CRLF, git lo ve como si todo estuviera modificado
    local sucios
    sucios=$(git -C "$AP" diff --name-only --ignore-submodules=dirty 2>/dev/null | wc -l)
    if [ "$sucios" -gt 200 ]; then
        info "el arbol venia en CRLF ($sucios archivos): reescribiendo en LF..."
        git -C "$AP" checkout -f -q .
        info "hecho"
    fi
}

# Devuelve el arbol a ArduPilot puro: quita TODO lo no versionado.
#
# Se usa 'git clean -fd' y no una lista derivada de overlay/, porque esa lista
# deja huerfanos: si un archivo del overlay se renombra o se quita, la copia
# vieja se queda en el arbol para siempre y el reset nunca da limpio.
#
# 'clean' SIN -x respeta el .gitignore de ArduPilot, donde 'build' esta
# listado. Asi que la cache de compilacion (~140 MB) sobrevive y los rebuilds
# siguen siendo incrementales. Con -x se la llevaria y cada ciclo costaria
# 10 minutos de recompilacion completa.
limpiar_overlay() {
    local n
    n=$(git -C "$AP" clean -nd | wc -l)
    git -C "$AP" clean -fdq
    info "$n archivos/carpetas no versionados retirados"
}

copiar_overlay() {
    local n=0
    while IFS= read -r -d '' f; do
        mkdir -p "$AP/$(dirname "$f")"
        cp "$REPO/overlay/$f" "$AP/$f"
        n=$((n+1))
    done < <(cd "$REPO/overlay" && find . -type f -print0)
    info "$n archivos del overlay copiados al arbol"
}

compilar() {
    ( cd "$AP" && python3 ./waf configure --board "$PLACA" >/tmp/sby_cfg.log 2>&1 ) \
        || { tail -25 /tmp/sby_cfg.log; morir "fallo 'waf configure'"; }
    info "configure ok"
    ( cd "$AP" && python3 ./waf "$VEHICULO" -j"$(nucleos)" >/tmp/sby_bld.log 2>&1 ) \
        || { grep -B3 -A8 -m3 "error:" /tmp/sby_bld.log || tail -25 /tmp/sby_bld.log
             morir "fallo la compilacion"; }
    grep -A4 "BUILD SUMMARY" /tmp/sby_bld.log | tail -2 | sed 's/^/   /'
}

# empaquetar [--avisar-si-sucio]
#   Sin el flag no avisa de cambios sin commitear: en desarrollo es lo normal
#   y seria ruido. Con el flag si avisa, porque un binario construido desde
#   un repo sucio NO se puede reproducir, y eso importa al publicar.
empaquetar() {
    mkdir -p "$DIST"
    local extra="--allow-dirty"
    [ "${1:-}" = "--avisar-si-sucio" ] && extra=""
    ( cd "$AP" && python3 Tools/scripts/sby_release.py --skip-build $extra -o "$DIST" ) \
        | grep -E "^ *(ardurover|apj|hex|bin|AVISO|Commitea|Este binario)" | sed 's/^/  /'
    info "binarios en dist/"
}
