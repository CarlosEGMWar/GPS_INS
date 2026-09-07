#!/bin/bash
# Funciones y rutas compartidas por los scripts. No se ejecuta suelto.

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AP="$REPO/build/ardupilot"
DIST="$REPO/dist"
PLACA="SBY_GPS_INS"
VEHICULO="rover"

# toolchain ARM dentro de WSL/Linux
TC=$(ls -d "$HOME"/opt/gcc-arm-none-eabi-*/bin 2>/dev/null | head -1)
[ -n "$TC" ] && export PATH="$TC:$HOME/.local/bin:$PATH"

rojo()  { printf '\033[31m%s\033[0m\n' "$*"; }
verde() { printf '\033[32m%s\033[0m\n' "$*"; }
paso()  { printf '\n== %s\n' "$*"; }
info()  { printf '   %s\n' "$*"; }

morir() { echo; rojo "ERROR: $*"; exit 1; }

comprobar_entorno() {
    [ -d "$AP/.git" ] || morir "no existe el arbol de ArduPilot en build/ardupilot
     Clonalo con:  git clone https://github.com/ArduPilot/ardupilot.git build/ardupilot"
    command -v arm-none-eabi-gcc >/dev/null || morir "no encuentro arm-none-eabi-gcc.
     Instala el toolchain (ver README) o corre esto dentro de WSL."
    command -v python3 >/dev/null || morir "falta python3"
}

# Los clones en Windows con core.autocrlf=true dejan los .py de Tools/scripts en
# CRLF. waf ejecuta make_intel_hex.py por su shebang y muere con
#   /usr/bin/env: 'python3\r': No such file or directory
# justo en la ULTIMA tarea, tras compilar las 999 anteriores.
# El blob commiteado es LF: lo rompe el checkout, no el repo. Y como
# 'git reset --hard' lo restaura, hay que normalizarlo en CADA pasada.
normalizar_crlf() {
    local f="$AP/Tools/scripts/make_intel_hex.py"
    if [ -f "$f" ] && grep -q $'\r' "$f" 2>/dev/null; then
        python3 -c "
import sys
p = sys.argv[1]
d = open(p,'rb').read()
open(p,'wb').write(d.replace(b'\r\n', b'\n'))
" "$f"
        info "make_intel_hex.py normalizado a LF (CRLF del checkout de Windows)"
    fi
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
    ( cd "$AP" && python3 ./waf "$VEHICULO" -j"$(nproc)" >/tmp/sby_bld.log 2>&1 ) \
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
