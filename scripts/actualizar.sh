#!/bin/bash
# ============================================================================
#  actualizar.sh  -  CICLO LIMPIO: ArduPilot virgen + overlay + parches
# ============================================================================
#
#    ./scripts/actualizar.sh                reconstruye SOBRE LO QUE HAYA EN CHECKOUT
#    ./scripts/actualizar.sh Rover-4.7.2    cambia a esa version
#    ./scripts/actualizar.sh --buscar       mira que releases hay
#
#  No hay ningun archivo que fije la version de ArduPilot: la manda el arbol.
#  Si haces 'git checkout' a mano dentro de build/ardupilot, este script lo
#  respeta y compila contra eso. Solo cambia de version si se la pides.
#  Si todavia no hay ArduPilot descargado, coge el ultimo release de Rover.
#
#  OJO: este script hace 'git reset --hard' sobre build/ardupilot.
#  PIERDES cualquier cosa que tengas editada ahi sin guardar.
#  Para desarrollo del dia a dia usa  compilar.sh,  que no resetea.
#
#  Que hace, en orden:
#    1. deja build/ardupilot virgen en la version que toque
#    2. copia overlay/            -> tus archivos propios
#    3. aplica patches/ en orden  -> CORTA en el primero que falle
#    4. compila
#    5. genera dist/ (.hex .bin .apj) y verifica
#
#  Antes de todo eso fuerza core.autocrlf=false en el arbol: si se clono en
#  Windows viene en CRLF, y entonces git desde WSL ve los ~6000 archivos como
#  modificados y waf muere al generar el .hex.
# ============================================================================
set -u
source "$(dirname "${BASH_SOURCE[0]}")/interno/comun.sh"

NUEVA=""
case "${1:-}" in
    --buscar)
        actual=$(version_ardupilot)
        echo "version en checkout: ${actual:-(todavia no hay ArduPilot descargado)}"
        echo "consultando releases de Rover en ArduPilot..."
        git ls-remote --tags --refs https://github.com/ArduPilot/ardupilot.git 'Rover-*' 2>/dev/null \
            | sed -E 's#.*refs/tags/##' | grep -E '^Rover-[0-9.]+$' | sort -V | tail -5 | sed 's/^/   /'
        echo
        echo "para cambiar:  ./scripts/actualizar.sh Rover-X.Y.Z"
        exit 0 ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    "") ;;
    *) NUEVA="$1" ;;
esac

echo "actualizar.sh  -  ciclo limpio"

# Si no hay ArduPilot todavia, preparar.sh lo descarga. Se le pasa la version
# pedida; si no se pidio ninguna, el coge el ultimo release.
export SBY_VERSION_AP="$NUEVA"
comprobar_entorno
unset SBY_VERSION_AP

if [ -n "$NUEVA" ]; then
    VERSION="$NUEVA"
    info "objetivo: $VERSION  (pedido en la linea de ordenes)"
else
    VERSION=$(version_ardupilot)
    [ -n "$VERSION" ] || morir "no se en que version esta build/ardupilot"
    info "objetivo: $VERSION  (lo que hay en checkout; no se toca)"
fi

asegurar_eol

paso "1. dejando ArduPilot virgen en $VERSION"
# Solo se hace checkout si se pidio una version distinta. Sin argumento se
# resetea sobre el HEAD actual, sea un tag, una rama o un commit suelto: asi
# un checkout hecho a mano sobrevive al ciclo limpio.
if [ -n "$NUEVA" ]; then
    if ! git -C "$AP" rev-parse --verify "$VERSION" >/dev/null 2>&1; then
        info "la version $VERSION no esta en local, descargandola..."
        git -C "$AP" fetch origin --tags || morir "no pude traer $VERSION"
    fi
    git -C "$AP" checkout -q --detach "$VERSION" 2>/dev/null || morir "no existe la version $VERSION"
fi
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
empaquetar --avisar-si-sucio

paso "6. verificando"
"$REPO/scripts/interno/verificar.sh" || morir "la verificacion fallo: NO grabes este firmware"

echo
verde "LISTO.  Firmware en dist/  -  construido sobre $VERSION"
