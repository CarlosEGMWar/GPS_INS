#!/bin/bash
# Publica una release.  Uso:
#
#     ./scripts/publicar.sh              propone la siguiente version
#     ./scripts/publicar.sh 1.2.0        publica esa
#     ./scripts/publicar.sh --ensayo     comprueba todo y no publica nada
#
# La etiqueta lleva las DOS versiones:
#
#     Rover-4.7.1-SBY-1.2.0
#     ^^^^^^^^^^^     ^^^^^
#     ArduPilot       tuya; la de aqui es la que tu das
#     (del arbol)
#
# La parte de ArduPilot no se escribe: sale de build/ardupilot al publicar. Asi
# la etiqueta dice por si sola contra que se construyo, sin abrir nada.
#
# Publicar NO es compilar. Compilar es cosa de cada dia (compilar.sh); publicar
# es decir "esto de aqui es estable y me lo llevo a la placa". Por eso hay que
# pedirlo a proposito: nada se publica solo.
#
# El binario NO se construye aqui. Este script comprueba, etiqueta y empuja la
# etiqueta; a partir de ahi GitHub Actions compila en una maquina limpia y sube
# la release. Es a proposito: un binario hecho en una maquina de desarrollo
# arrastra lo que esa maquina tenga instalado, y deja de ser reproducible.
# Compilando fuera, cualquiera puede reconstruir byte a byte lo publicado.

set -u
. "$(dirname "${BASH_SOURCE[0]}")/interno/comun.sh"

REPO_GH="CarlosEGMWar/GPS_INS"
RAMA="main"

ENSAYO=0
FORZAR=0
VER=""
for a in "$@"; do
    case "$a" in
        --ensayo|-n) ENSAYO=1 ;;
        --forzar)    FORZAR=1 ;;
        -h|--help)   sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        [0-9]*)      VER="$a" ;;
        Rover-*)     VER="${a##*-SBY-}" ;;   # admite la etiqueta entera
        *)           morir "no entiendo '$a'. Prueba: $0 --help" ;;
    esac
done

# ---------------------------------------------------------------------------
# El token.  Nunca se escribe en pantalla ni en la linea de ordenes: los
# argumentos de un proceso los ve cualquiera con 'ps', asi que el push va por
# GIT_ASKPASS y las llamadas a la API por la config de curl en la entrada.
# ---------------------------------------------------------------------------
TOKEN=""
leer_token() {
    if [ -n "${GITHUB_TOKEN:-}" ]; then TOKEN="$GITHUB_TOKEN"; return 0; fi

    local cfg
    for cfg in "$REPO/.publicar.env" "$HOME/.config/sby-gps-ins/github.env"; do
        [ -f "$cfg" ] || continue
        # token=...        el token directo
        # token_en=RUTA    donde esta, para no tener el secreto en dos sitios
        local ruta
        ruta=$(sed -nE 's/^[[:space:]]*token_en[[:space:]]*=[[:space:]]*//p' "$cfg" | head -1)
        if [ -n "$ruta" ] && [ -f "$ruta" ]; then
            TOKEN=$(sed -nE 's/^[[:space:]]*token[[:space:]]*=[[:space:]]*//p' "$ruta" | head -1)
        else
            TOKEN=$(sed -nE 's/^[[:space:]]*token[[:space:]]*=[[:space:]]*//p' "$cfg" | head -1)
        fi
        [ -n "$TOKEN" ] && return 0
    done
    return 1
}

if ! leer_token; then
    echo
    rojo "No encuentro el token de GitHub."
    cat <<FIN

Hace falta uno con permiso de escritura en $REPO_GH. Ponlo de una de estas
formas (la primera es la comoda: se hace una vez y ya):

  1) Crea  $REPO/.publicar.env  con UNA de estas dos lineas:

         token=ghp_tu_token_aqui

     o, si ya lo tienes en otro fichero y no quieres duplicarlo:

         token_en=/ruta/a/ese/fichero.env

  2) O exportalo antes de llamar:   export GITHUB_TOKEN=ghp_...

.publicar.env esta en el .gitignore: no se sube nunca.
FIN
    exit 1
fi

# Directorio temporal para el askpass. Se borra pase lo que pase.
TMPD=$(mktemp -d) || morir "no pude crear el temporal"
chmod 700 "$TMPD"
trap 'rm -rf "$TMPD"' EXIT
printf '%s' "$TOKEN" > "$TMPD/t"; chmod 600 "$TMPD/t"
# El usuario se averigua tras validar el token (paso 1). Un PAT clasico se
# autentica con USUARIO + token; 'x-access-token' solo sirve para tokens de
# GitHub App, y con un PAT GitHub responde "Invalid username or token".
: > "$TMPD/u"
cat > "$TMPD/askpass" <<FIN
#!/bin/sh
case "\$1" in
  *sername*|*serName*) cat "$TMPD/u" ;;
  *) cat "$TMPD/t" ;;
esac
FIN
chmod 700 "$TMPD/askpass"

# curl autenticado sin exponer el token: las cabeceras van por la entrada.
api() {
    local metodo=GET
    [ "${1:-}" = "-X" ] && { metodo="$2"; shift 2; }
    printf 'header = "Authorization: Bearer %s"\nheader = "Accept: application/vnd.github+json"\n' "$TOKEN" \
        | curl -s --config - -X "$metodo" "https://api.github.com/$1"
}

# ---------------------------------------------------------------------------
paso "1. comprobando que se puede publicar"

command -v curl >/dev/null   || morir "hace falta curl"
command -v python3 >/dev/null || morir "hace falta python3"

# --- el token sirve y tiene permiso de escritura ---
PERM=$(api "repos/$REPO_GH" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('NO_EXISTE') if 'permissions' not in d else print('si' if d['permissions'].get('push') else 'no')
" 2>/dev/null)
case "$PERM" in
    si) info "token valido, con permiso de escritura            ok" ;;
    no) morir "el token es valido pero no puede escribir en $REPO_GH" ;;
    *)  morir "el token no sirve para $REPO_GH (caducado, o sin permiso 'repo')" ;;
esac

api "user" | python3 -c "import json,sys;print(json.load(sys.stdin).get('login',''))" \
    > "$TMPD/u" 2>/dev/null
[ -s "$TMPD/u" ] || morir "no pude averiguar el usuario dueno del token"
info "autenticando como $(cat "$TMPD/u")"

# Comprobar que git puede empujar ANTES de crear ninguna etiqueta: que la API
# acepte el token no garantiza que git lo acepte. --dry-run autentica contra
# GitHub sin escribir nada.
if ! GIT_ASKPASS="$TMPD/askpass" GIT_TERMINAL_PROMPT=0 \
     git -C "$REPO" push -q --dry-run origin "$RAMA" 2>"$TMPD/err"; then
    sed 's/^/     /' "$TMPD/err"
    morir "el token vale para la API pero git no puede empujar con el"
fi
info "git puede empujar con ese token                    ok"

# --- rama ---
ACTUAL=$(git -C "$REPO" rev-parse --abbrev-ref HEAD)
if [ "$ACTUAL" != "$RAMA" ]; then
    [ "$FORZAR" = 1 ] || morir "estas en la rama '$ACTUAL', no en '$RAMA'. Si es a proposito: --forzar"
    info "rama '$ACTUAL' (forzado)"
else
    info "rama $RAMA                                          ok"
fi

# --- arbol limpio ---
# No es remilgo: publicar.yml rechaza el binario si el manifest dice que el
# repo estaba sucio, porque entonces nadie puede reconstruirlo. Mejor enterarse
# ahora que dentro de cuatro minutos.
SUCIOS=$(git -C "$REPO" status --porcelain | wc -l)
if [ "$SUCIOS" -ne 0 ]; then
    echo
    git -C "$REPO" status --short | sed 's/^/     /'
    morir "hay $SUCIOS cambios sin commitear. Commitear o descartar antes de publicar:
       lo que se publica tiene que poder reconstruirse desde un commit."
fi
info "arbol limpio                                       ok"

# --- HEAD ya esta en GitHub ---
git -C "$REPO" fetch -q --tags origin || morir "no pude hablar con GitHub"
HEAD_LOC=$(git -C "$REPO" rev-parse HEAD)
if ! git -C "$REPO" merge-base --is-ancestor "$HEAD_LOC" "origin/$RAMA" 2>/dev/null; then
    PEND=$(git -C "$REPO" rev-list --count "origin/$RAMA..HEAD" 2>/dev/null || echo "?")
    morir "tienes $PEND commit(s) sin subir. Una etiqueta que apunta a un commit
       que GitHub no conoce no se puede compilar. Sube primero la rama."
fi
info "HEAD ya esta en GitHub                             ok"

# --- el workflow existe ---
[ -f "$REPO/.github/workflows/publicar.yml" ] || morir "falta .github/workflows/publicar.yml"
info "publicar.yml presente                              ok"

# ---------------------------------------------------------------------------
paso "2. que version"

# La parte de ArduPilot sale del arbol, no de ningun archivo.
AP_TAG=$(version_ardupilot)
[ -n "$AP_TAG" ] || morir "no se contra que version de ArduPilot estas.
       Compila primero:  ./scripts/actualizar.sh"
info "ArduPilot en checkout: $AP_TAG"

# La ultima version SBY publicada, mirando solo la parte de detras del -SBY-.
ULTIMA=$(git -C "$REPO" tag -l '*-SBY-*' \
         | sed -E 's/.*-SBY-//' | sort -V | tail -1)

if [ -z "$VER" ]; then
    if [ -z "$ULTIMA" ]; then
        VER="1.0.0"
    else
        VER=$(echo "$ULTIMA" | python3 -c "
import sys,re
m=re.match(r'(\d+)\.(\d+)\.(\d+)$', sys.stdin.read().strip())
print('%s.%s.%d' % (m.group(1), m.group(2), int(m.group(3))+1) if m else '')
")
        [ -n "$VER" ] || morir "no se de que version partir. Dila tu: $0 X.Y.Z"
    fi
    info "no dijiste version: propongo SBY $VER"
fi

echo "$VER" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' \
    || morir "'$VER' no vale. El formato es X.Y.Z, por ejemplo 1.2.0
       (solo tu parte: la de ArduPilot la pone el script)"

ETIQUETA="${AP_TAG}-SBY-${VER}"

if git -C "$REPO" rev-parse -q --verify "refs/tags/$ETIQUETA" >/dev/null; then
    morir "la etiqueta $ETIQUETA ya existe.
       Una etiqueta publicada no se mueve: quien se bajo esos binarios espera
       que siga siendo lo mismo para siempre. Usa el numero siguiente."
fi
info "la etiqueta $ETIQUETA esta libre"

# ---------------------------------------------------------------------------
paso "3. esto es lo que se va a publicar"

echo
echo "   etiqueta       $ETIQUETA"
echo "   ArduPilot      $AP_TAG      (leido de build/ardupilot)"
echo "   version SBY    $VER"
echo "   commit         $(git -C "$REPO" rev-parse --short HEAD)  $(git -C "$REPO" log -1 --format=%s)"
echo "   se subiran     ardurover_with_bl.hex   (ST-LINK / SWD)"
echo "                  ardurover_with_bl.bin   (DFU y cable serie)"
echo "                  ardurover.apj           (Mission Planner o USART1)"
echo "                  y nada mas: las huellas SHA-256 van en las notas"

ETQ_ANT=$(git -C "$REPO" tag -l '*-SBY-*' --sort=-v:refname | head -1)
if [ -n "$ETQ_ANT" ]; then
    N=$(git -C "$REPO" rev-list --count "$ETQ_ANT..HEAD" 2>/dev/null || echo 0)
    echo
    echo "   $N commit(s) desde $ETQ_ANT:"
    git -C "$REPO" log --format='     %h %s' "$ETQ_ANT..HEAD" 2>/dev/null | head -20
    [ "$N" -gt 20 ] && echo "     ... y $((N-20)) mas"
fi

if [ "$ENSAYO" = 1 ]; then
    echo
    verde "ENSAYO: todo en orden. No se ha publicado nada."
    echo "Cuando quieras hacerlo de verdad:  $0 $VER"
    exit 0
fi

# ---------------------------------------------------------------------------
paso "4. confirmacion"

echo
echo "   Esto crea una release PUBLICA en github.com/$REPO_GH."
echo "   La etiqueta $ETIQUETA quedara fija para siempre."
echo
printf "   Escribe %s para seguir (o Enter para dejarlo): " "$VER"
read -r RESP
if [ "$RESP" != "$VER" ]; then
    echo
    info "no se ha publicado nada."
    exit 0
fi

# ---------------------------------------------------------------------------
paso "5. etiquetando y empujando"

git -C "$REPO" tag -a "$ETIQUETA" \
    -m "SBY $VER del firmware SBY_GPS_INS, sobre ArduPilot $AP_TAG" \
    || morir "no pude crear la etiqueta"
info "etiqueta $ETIQUETA creada en local"

if ! GIT_ASKPASS="$TMPD/askpass" GIT_TERMINAL_PROMPT=0 \
     git -C "$REPO" push -q origin "refs/tags/$ETIQUETA" 2>"$TMPD/err"; then
    git -C "$REPO" tag -d "$ETIQUETA" >/dev/null 2>&1   # que no quede a medias
    sed 's/^/     /' "$TMPD/err"
    morir "no pude subir la etiqueta (la he borrado en local para dejarlo como estaba)"
fi
verde "   etiqueta $ETIQUETA subida: GitHub ya esta compilando"

# ---------------------------------------------------------------------------
paso "6. esperando a que compile (unos 4 minutos)"

RUN=""
for i in $(seq 1 20); do
    sleep 6
    RUN=$(api "repos/$REPO_GH/actions/runs?event=push&per_page=15" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
for r in d.get('workflow_runs',[]):
    if r.get('head_branch')=='$ETIQUETA' or r.get('name','').startswith('publicar'):
        print(r['id']); break
" 2>/dev/null)
    [ -n "$RUN" ] && break
    printf '.'
done
echo

if [ -z "$RUN" ]; then
    echo
    info "el workflow aun no aparece. Consultarlo en:"
    info "https://github.com/$REPO_GH/actions"
    exit 0
fi

info "run $RUN  ->  https://github.com/$REPO_GH/actions/runs/$RUN"
ANT=""
for i in $(seq 1 90); do
    LINEA=$(api "repos/$REPO_GH/actions/runs/$RUN" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('%s|%s' % (d.get('status'), d.get('conclusion')))
" 2>/dev/null)
    EST=${LINEA%%|*}; CON=${LINEA##*|}
    [ "$EST" != "$ANT" ] && { echo; printf '   %s' "$EST"; ANT="$EST"; } || printf '.'
    [ "$EST" = "completed" ] && break
    sleep 10
done
echo

if [ "$CON" != "success" ]; then
    echo
    rojo "La compilacion fallo ($CON)."
    api "repos/$REPO_GH/actions/runs/$RUN/jobs" | python3 -c "
import json,sys
for j in json.load(sys.stdin).get('jobs',[]):
    for s in j.get('steps',[]):
        if s.get('conclusion') not in ('success','skipped',None):
            print('   fallo en el paso: %s' % s['name'])
" 2>/dev/null
    echo
    echo "   Registro completo: https://github.com/$REPO_GH/actions/runs/$RUN"
    echo
    echo "   La etiqueta $ETIQUETA se quedo puesta pero sin release. Cuando arregles"
    echo "   el problema, o la borras y reutilizas el numero:"
    echo "       git push origin :refs/tags/$ETIQUETA && git tag -d $ETIQUETA"
    echo "   o sigues con el siguiente numero."
    exit 1
fi

paso "7. listo"
api "repos/$REPO_GH/releases/tags/$ETIQUETA" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if 'html_url' not in d:
    print('   la release aun no aparece; mirala en https://github.com/$REPO_GH/releases')
    raise SystemExit
print('   %s' % d['html_url']); print()
for a in d.get('assets',[]):
    print('     %-34s %9d B' % (a['name'], a['size']))
" 2>/dev/null

echo
verde "Publicado $ETIQUETA"
echo
echo "Para comprobar que lo publicado es reproducible, cualquiera puede clonar"
echo "el repo en $ETIQUETA, ejecutar ./scripts/actualizar.sh y comparar los SHA-256"
echo "con los de manifest.json. Tienen que salir identicos."
