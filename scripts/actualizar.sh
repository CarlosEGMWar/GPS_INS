#!/bin/bash
# ============================================================================
#  actualizar.sh  -  CICLO LIMPIO: ArduPilot virgen + overlay + parches
# ============================================================================
#
#    ./scripts/actualizar.sh                reconstruye con la version de UPSTREAM
#    ./scripts/actualizar.sh --buscar       mira si ArduPilot saco un release nuevo
#    ./scripts/actualizar.sh Rover-4.7.2    salta a esa version
#
#  OJO: este script hace 'git reset --hard' sobre build/ardupilot.
#  PIERDES cualquier cosa que tengas editada ahi sin guardar.
#  Para desarrollo del dia a dia usa  compilar.sh,  que no resetea.
#
#  Que hace, en orden:
#    1. deja build/ardupilot en la version de UPSTREAM, virgen
#    2. copia overlay/            -> tus archivos propios
#    3. aplica patches/ en orden  -> CORTA en el primero que falle
#    4. compila
#    5. genera dist/ (.hex .bin .apj) y verifica
#    6. si saltaste de version y todo fue bien, actualiza el archivo UPSTREAM
#
#  Antes de todo eso fuerza core.autocrlf=false en el arbol: si se clono en
#  Windows viene en CRLF, y entonces git desde WSL ve los ~6000 archivos como
#  modificados y waf muere al generar el .hex.
# ============================================================================
set -u
source "$(dirname "${BASH_SOURCE[0]}")/comun.sh"

NUEVA=""
case "${1:-}" in
    --buscar)
        comprobar_entorno
        actual=$(head -1 "$REPO/UPSTREAM")
        echo "version actual: $actual"
        echo "consultando releases de Rover en ArduPilot..."
        git -C "$AP" ls-remote --tags origin 2>/dev/null \
            | grep -oE 'Rover-[0-9.]+$' | sort -V | tail -5 | sed 's/^/   /'
        echo
        echo "para saltar:  ./scripts/actualizar.sh Rover-X.Y.Z"
        exit 0 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    "") ;;
    *) NUEVA="$1" ;;
esac

echo "actualizar.sh  -  ciclo limpio"
comprobar_entorno

VERSION=$(head -1 "$REPO/UPSTREAM")
[ -n "$NUEVA" ] && VERSION="$NUEVA"
info "objetivo: $VERSION"

asegurar_eol

paso "1. dejando ArduPilot virgen en $VERSION"
if ! git -C "$AP" rev-parse --verify "$VERSION" >/dev/null 2>&1; then
    info "la version $VERSION no esta en local, descargandola..."
    git -C "$AP" fetch origin --tags || morir "no pude traer $VERSION"
fi
git -C "$AP" checkout -q --detach "$VERSION" 2>/dev/null || morir "no existe la version $VERSION"
git -C "$AP" reset --hard -q HEAD
limpiar_overlay
sucio=$(git -C "$AP" status --porcelain --ignore-submodules=dirty | wc -l)
[ "$sucio" -eq 0 ] || morir "el arbol no quedo limpio ($sucio archivos)"
info "arbol virgen: $(git -C "$AP" log -1 --format='%h %s')"

info "sincronizando submodulos..."
git -C "$AP" submodule update --init --recursive \
    modules/waf modules/mavlink modules/ChibiOS modules/lwip modules/littlefs \
    modules/Micro-CDR modules/Micro-XRCE-DDS-Client modules/DroneCAN/DSDL \
    modules/DroneCAN/dronecan_dsdlc modules/DroneCAN/libcanard modules/DroneCAN/pydronecan \
    >/dev/null 2>&1 || info "aviso: algun submodulo no se pudo sincronizar"

paso "2. copiando overlay/"
copiar_overlay

paso "3. aplicando la cola de parches"
n=0
while read -r parche; do
    [ -z "$parche" ] && continue
    n=$((n+1))
    printf "   [%d] %-44s " "$n" "$parche"
    if git -C "$AP" apply --3way "$REPO/patches/$parche" >/tmp/sby_patch.err 2>&1; then
        echo "ok"
    else
        echo "FALLA"
        echo
        rojo "El parche '$parche' no aplica sobre $VERSION."
        echo
        sed 's/^/     /' /tmp/sby_patch.err | head -12
        echo
        info "Los $((n-1)) parches anteriores SI quedaron aplicados."
        info "Que hacer:"
        info "  1. abre patches/$parche  - su cabecera explica que hace y donde va"
        info "  2. aplica el cambio a mano sobre la version nueva del archivo"
        info "  3. regenera el parche:"
        info "       git -C build/ardupilot diff HEAD -- <archivos> > patches/$parche"
        info "     (conservando la cabecera de texto)"
        info "  4. vuelve a correr este script"
        exit 1
    fi
done < "$REPO/patches/series"
info "$n parches aplicados sin conflictos"

paso "4. compilando $PLACA"
compilar

paso "5. empaquetando en dist/"
empaquetar

paso "6. verificando"
"$REPO/scripts/verificar.sh" || morir "la verificacion fallo: NO grabes este firmware"

if [ -n "$NUEVA" ]; then
    paso "7. fijando la nueva version en UPSTREAM"
    sha=$(git -C "$AP" rev-parse HEAD)
    printf '%s\n%s\n' "$NUEVA" "$sha" > "$REPO/UPSTREAM"
    info "UPSTREAM -> $NUEVA ($sha)"
    info "acuerdate de commitear el cambio de UPSTREAM"
fi

echo
verde "LISTO.  Firmware en dist/  -  construido sobre $VERSION"
