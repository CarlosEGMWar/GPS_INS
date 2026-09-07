#!/bin/bash
# ============================================================================
#  verificar.sh  -  comprueba que el firmware generado esta completo
# ============================================================================
#
#  La comprobacion que importa es la de las cadenas: si el parche 0002 se
#  perdiera en una actualizacion, el firmware COMPILA Y ENLAZA IGUAL pero se
#  queda sin salida NMEA, sin $GO_BOOT y sin LEDs, en silencio. Buscar las
#  cadenas dentro del binario es la unica forma barata de detectarlo antes de
#  grabar una placa.
# ============================================================================
set -u
source "$(dirname "${BASH_SOURCE[0]}")/comun.sh"

BIN="$AP/build/$PLACA/bin/ardurover.bin"
fallos=0

chk() {
    printf "   %-50s " "$1"
    if eval "${*:2}" >/dev/null 2>&1; then echo "ok"; else echo "FALLA"; fallos=$((fallos+1)); fi
}

echo "verificando $PLACA"

if [ ! -f "$BIN" ]; then
    rojo "   no existe $BIN  -  compila primero"
    exit 1
fi

paso "la libreria propia entro en el binario"
for s in 'GNGGA' 'PASHR' 'GO_BOOT'; do
    chk "cadena \$$s presente" "strings -n 6 '$BIN' | grep -q '$s'"
done

paso "formato correcto de las sentencias"
chk "GGA con talker GN (no GP)"      "strings -n 6 '$BIN' | grep -q '^\\\$GNGGA,'"
chk "PASHR con 3 decimales (radianes)" "strings -n 6 '$BIN' | grep -q 'PASHR,%s,%.3f'"

paso "artefactos de programacion en dist/"
chk "ardurover_with_bl.hex  (ST-LINK / SWD)" "[ -s '$DIST/ardurover_with_bl.hex' ]"
chk "ardurover_with_bl.bin  (DFU y UART)"    "[ -s '$DIST/ardurover_with_bl.bin' ]"
chk "ardurover.apj          (ArduPilot/MP)"  "[ -s '$DIST/ardurover.apj' ]"
chk "manifest.json"                          "[ -s '$DIST/manifest.json' ]"

paso "ocupacion de flash"
if [ -f /tmp/sby_bld.log ]; then
    grep -A4 "BUILD SUMMARY" /tmp/sby_bld.log | tail -2 | sed 's/^/   /'
fi

echo
if [ "$fallos" -eq 0 ]; then
    verde "VERIFICACION OK  -  el firmware esta completo"
else
    rojo "VERIFICACION FALLIDA  -  $fallos comprobaciones no pasaron"
    rojo "NO GRABES ESTE FIRMWARE en una placa hasta resolverlo."
    exit 1
fi
