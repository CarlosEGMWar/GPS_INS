#!/bin/bash
# Funciones y rutas compartidas por los scripts. No se ejecuta suelto.

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

rojo()  { printf '\033[31m%s\033[0m\n' "$*"; }
verde() { printf '\033[32m%s\033[0m\n' "$*"; }
paso()  { printf '\n== %s\n' "$*"; }
info()  { printf '   %s\n' "$*"; }

morir() { echo; rojo "ERROR: $*"; exit 1; }

comprobar_entorno() {
    [ -d "$AP/.git" ] || morir "no existe el arbol de ArduPilot en build/ardupilot
     Clonalo con:  git clone https://github.com/ArduPilot/ardupilot.git build/ardupilot"
    command -v arm-none-eabi-gcc >/dev/null || morir "no encuentro arm-none-eabi-gcc.
     Instalalo (ver README), o indica donde esta:
         export ARM_TOOLCHAIN=/ruta/a/gcc-arm-none-eabi/bin
     En Windows: esto tiene que correr dentro de WSL, no en cmd/PowerShell."
    command -v python3 >/dev/null || morir "falta python3"
    command -v strings >/dev/null || morir "falta 'strings' (paquete binutils).
     Se usa para comprobar que la libreria propia entro en el binario."
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

# Retira del arbol exactamente los archivos que aporta overlay/, y las carpetas
# que queden vacias. Se deriva de overlay/ en vez de una lista fija, para que
# archivos nuevos se limpien solos sin tocar este script.
# Solo borra archivos NO versionados: nunca se lleva nada de ArduPilot.
limpiar_overlay() {
    local n=0 rel destino
    while IFS= read -r -d '' rel; do
        rel="${rel#./}"
        destino="$AP/$rel"
        [ -e "$destino" ] || continue
        if git -C "$AP" ls-files --error-unmatch "$rel" >/dev/null 2>&1; then
            continue            # es de ArduPilot: no tocar
        fi
        rm -f "$destino"
        rmdir -p "$(dirname "$destino")" 2>/dev/null   # solo si quedan vacias
        n=$((n+1))
    done < <(cd "$REPO/overlay" && find . -type f -print0)
    info "$n archivos del overlay retirados"
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

empaquetar() {
    mkdir -p "$DIST"
    ( cd "$AP" && python3 Tools/scripts/sby_release.py --skip-build --allow-dirty -o "$DIST" ) \
        | grep -E "^   (ardurover|manifest|apj|hex|bin)" | sed 's/^/  /'
    info "binarios en dist/"
}
