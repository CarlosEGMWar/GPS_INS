#!/bin/bash
# ============================================================================
#  compilar.sh  -  DESARROLLO: compila lo que hay AHORA, sin resetear nada
# ============================================================================
#
#  Usalo mientras estas probando cosas. NO resetea el arbol, NO aplica parches:
#  respeta lo que tengas editado en build/ardupilot.
#
#  Flujo tipico de desarrollo:
#    1. editas overlay/...            (tus archivos)  -> este script los sincroniza
#       o editas build/ardupilot/...  (de ArduPilot)  -> este script los respeta
#    2. ./scripts/compilar.sh
#    3. cuando quede bien, si tocaste un archivo de ArduPilot:
#       regenera su .patch  (ver patches/README.md)
#
#  Opciones:
#    --sin-overlay   no copiar overlay/ (util si estas editando esos archivos
#                    directamente en el arbol y no quieres que te los pise)
#    --sin-dist      no generar los binarios en dist/, solo compilar
#
#  Para el ciclo limpio desde cero usa  actualizar.sh  en su lugar.
# ============================================================================
set -u
source "$(dirname "${BASH_SOURCE[0]}")/interno/comun.sh"

SIN_OVERLAY=0; SIN_DIST=0
for a in "$@"; do
    case "$a" in
        --sin-overlay) SIN_OVERLAY=1 ;;
        --sin-dist)    SIN_DIST=1 ;;
        -h|--help)     sed -n '2,25p' "$0"; exit 0 ;;
        *)             morir "opcion desconocida: $a" ;;
    esac
done

echo "compilar.sh  -  desarrollo (sin reset)"
comprobar_entorno

paso "1. preparando el arbol"
asegurar_eol
if [ "$SIN_OVERLAY" -eq 1 ]; then
    info "overlay NO sincronizado (--sin-overlay)"
else
    copiar_overlay
fi

# aviso si hay archivos de ArduPilot modificados que aun no estan en patches/
paso "2. estado del arbol"
mods=$(cd "$AP" && git status --porcelain --ignore-submodules=dirty \
       | grep '^ M' | awk '{print $2}')
if [ -n "$mods" ]; then
    info "archivos de ArduPilot modificados (deberian acabar en un .patch):"
    echo "$mods" | sed 's/^/      /'
else
    info "sin modificaciones a archivos de ArduPilot"
fi

paso "3. compilando $PLACA"
compilar

if [ "$SIN_DIST" -eq 0 ]; then
    paso "4. empaquetando"
    empaquetar
    paso "5. verificando"
    "$REPO/scripts/interno/verificar.sh" || morir "la verificacion fallo"
else
    info "dist/ omitido (--sin-dist)"
fi

echo
verde "LISTO."
