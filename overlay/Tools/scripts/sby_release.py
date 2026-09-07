#!/usr/bin/env python3
"""
sby_release.py - genera de una sola pasada los TRES ficheros de programacion
de la placa SBY_GPS_INS, y comprueba que los tres contengan el mismo firmware.

    ardurover_with_bl.hex   ->  ST-LINK / SWD   (STM32CubeProgrammer)
    ardurover_with_bl.bin   ->  DFU            (dfu-util, BOOT0 alto)
    ardurover.apj           ->  ArduPilot      (uploader.py / Mission Planner)

Deliberadamente NO se copia la app cruda (ardurover.bin): seria un segundo .bin de
nombre casi igual pero que va en 0x08010000 en vez de 0x08000000, y grabarlo por
error por DFU deja la placa sin bootloader.

waf NO genera el .bin combinado para DFU: aqui se construye igual que lo hace
Tools/scripts/make_intel_hex.py, o sea bootloader + relleno 0xFF hasta
FLASH_RESERVE_START_KB, y a continuacion la aplicacion.

Un solo comando, tambien desde Windows: detecta que waf necesita Linux y delega
la compilacion en WSL sin que tengas que entrar ahi. Como waf es incremental,
si no cambiaste nada no recompila; si tocaste codigo o el hwdef, si.

    python  Tools\\scripts\\sby_release.py            # Windows: compila (via WSL) y empaqueta
    python3 Tools/scripts/sby_release.py            # Linux/WSL: igual, sin intermediario
    python3 Tools/scripts/sby_release.py --skip-build   # no compilar, solo empaquetar
    python3 Tools/scripts/sby_release.py --bootloader   # recompilar tambien el bootloader
    python3 Tools/scripts/sby_release.py -o "D:/ruta/dist"

Opciones utiles: --no-wsl (no delegar), --distro NOMBRE (elegir distro WSL).
Se puede lanzar desde cualquier directorio: localiza la raiz del repo por su cuenta.
Solo depende de la libreria estandar de Python 3.
"""

import argparse
import base64
import hashlib
import io
import json
import os
import platform
import shutil
import subprocess
import sys
import zlib
from datetime import datetime, timezone

BOARD = "SBY_GPS_INS"
VEHICLE = "rover"
BINARY = "ardurover"

def find_repo_root():
    """sube desde este fichero hasta encontrar la raiz del repo ArduPilot.
    Asi el script sigue funcionando si se mueve de sitio."""
    d = os.path.dirname(os.path.abspath(__file__))
    while True:
        if (os.path.exists(os.path.join(d, "wscript")) and
                os.path.isdir(os.path.join(d, "Tools", "ardupilotwaf"))):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            raise RuntimeError("no encuentro la raiz del repo ArduPilot "
                               "(busco un wscript junto a Tools/ardupilotwaf/)")
        d = parent


ROOT = find_repo_root()
BUILD_BIN_DIR = os.path.join(ROOT, "build", BOARD, "bin")
BOOTLOADER_BIN = os.path.join(ROOT, "Tools", "bootloaders", "%s_bl.bin" % BOARD)

FLASH_BASE = 0x08000000


# ---------------------------------------------------------------- utilidades

class Fail(Exception):
    pass


def info(msg):
    print("   %s" % msg)


def step(msg):
    print("\n== %s" % msg)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def read(path):
    with open(path, "rb") as f:
        return f.read()


def human(n):
    return "%s bytes (%.1f KiB)" % ("{:,}".format(n).replace(",", "."), n / 1024.0)


def datos_git(repo):
    """devuelve (commit, tag, sucio) de un repo git, o (None, None, None)"""
    def correr(*args):
        try:
            r = subprocess.run(["git", "-C", repo] + list(args),
                               capture_output=True, text=True, timeout=30)
            return r.stdout.strip() if r.returncode == 0 else ""
        except Exception:
            return ""
    if not os.path.isdir(os.path.join(repo, ".git")):
        return None, None, None
    commit = correr("rev-parse", "--short", "HEAD") or None
    tag = (correr("describe", "--tags", "--exact-match", "HEAD")
           or correr("describe", "--tags", "--abbrev=0") or None)
    sucio = bool(correr("status", "--porcelain", "--ignore-submodules=dirty"))
    return commit, tag, sucio


def hwdef_value(key, default=None):
    """lee un valor escalar del hwdef.dat de la placa"""
    hwdef = os.path.join(ROOT, "libraries", "AP_HAL_ChibiOS", "hwdef", BOARD, "hwdef.dat")
    with open(hwdef, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            parts = line.split("#")[0].split()
            if len(parts) >= 2 and parts[0] == key:
                return parts[1]
    if default is None:
        raise Fail("no encuentro '%s' en %s" % (key, hwdef))
    return default


def parse_intel_hex(text):
    """parser minimo de Intel HEX -> dict {direccion_absoluta: byte}.
    Soporta los tipos 00 (datos), 01 (fin) y 04 (direccion lineal extendida),
    que son los unicos que emite intelhex.bin2hex()."""
    mem = {}
    upper = 0
    for lineno, raw in enumerate(text.splitlines(), 1):
        rec = raw.strip()
        if not rec:
            continue
        if not rec.startswith(":"):
            raise Fail("hex: linea %d no empieza con ':'" % lineno)
        try:
            body = bytes.fromhex(rec[1:])
        except ValueError:
            raise Fail("hex: linea %d no es hexadecimal valido" % lineno)
        if len(body) < 5:
            raise Fail("hex: linea %d demasiado corta" % lineno)
        count, addr_hi, addr_lo, rtype = body[0], body[1], body[2], body[3]
        data = body[4:4 + count]
        if len(data) != count:
            raise Fail("hex: linea %d con longitud declarada incorrecta" % lineno)
        if (sum(body) & 0xFF) != 0:
            raise Fail("hex: checksum incorrecto en la linea %d" % lineno)
        if rtype == 0x00:
            base = upper + (addr_hi << 8) + addr_lo
            for i, b in enumerate(data):
                mem[base + i] = b
        elif rtype == 0x04:
            upper = ((data[0] << 8) | data[1]) << 16
        elif rtype == 0x01:
            break
        else:
            raise Fail("hex: tipo de registro 0x%02X no soportado (linea %d)" % (rtype, lineno))
    return mem


def hex_region(mem, start, length):
    """extrae [start, start+length) del mapa; error si hay huecos"""
    out = bytearray()
    for a in range(start, start + length):
        if a not in mem:
            raise Fail("hex: falta el byte 0x%08X (imagen incompleta)" % a)
        out.append(mem[a])
    return bytes(out)


def run(cmd, cwd=ROOT):
    info("$ " + " ".join(cmd))
    res = subprocess.run(cmd, cwd=cwd)
    if res.returncode != 0:
        raise Fail("el comando fallo con codigo %d" % res.returncode)


# -------------------------------------------------------------- compilacion
#
# waf solo corre en POSIX. Desde Windows este script se apoya en WSL de forma
# transparente: manda alli los comandos de waf y sigue empaquetando en Windows.
# No hay que "entrar" a WSL ni compilar aparte.
#
# Deteccion de cambios: la hace waf, que es incremental (si no tocaste nada, no
# recompila ningun fichero). Ojo con un detalle que no es obvio: "waf rover" NO
# recoge cambios de hwdef.dat -- comprobado: editas un pin, recompila y te da un
# binario que lo ignora. Por eso se lanza SIEMPRE "waf configure" antes: cuesta
# ~5 s y no invalida los objetos ya compilados (comprobado: 0 recompilaciones).

def to_wsl_path(win_path):
    """C:\\Users\\x\\y  ->  /mnt/c/Users/x/y"""
    q = os.path.abspath(win_path)
    drive, rest = os.path.splitdrive(q)
    if not drive:
        return q.replace("\\", "/")
    return "/mnt/" + drive[0].lower() + rest.replace("\\", "/")


def find_wsl_distro():
    """nombre de la primera distro WSL instalada, o None"""
    if shutil.which("wsl") is None:
        return None
    try:
        out = subprocess.run(["wsl", "-l", "-q"], capture_output=True, timeout=60)
    except Exception:
        return None
    raw = out.stdout
    text = raw.decode("utf-16-le", errors="ignore") if b"\x00" in raw[:20] \
        else raw.decode("utf-8", errors="ignore")
    names = [l.strip() for l in text.replace("\x00", "").splitlines() if l.strip()]
    return names[0] if names else None


class Builder:
    """lanza waf: directo si estamos en Linux, via WSL si estamos en Windows"""

    # donde se busca el toolchain dentro de WSL (asi lo instala el README)
    TOOLCHAIN_GLOB = "$HOME/opt/gcc-arm-none-eabi-*/bin"

    def __init__(self, distro=None):
        self.distro = distro            # None = ejecucion local

    @classmethod
    def create(cls, allow_wsl, distro):
        if platform.system() == "Linux":
            if shutil.which("arm-none-eabi-gcc") is None:
                raise Fail("no encuentro arm-none-eabi-gcc en el PATH.\n"
                           "     Anade el toolchain al PATH o usa --skip-build.")
            return cls()
        if not allow_wsl:
            raise Fail("waf necesita Linux y se paso --no-wsl.\n"
                       "     Usa --skip-build para empaquetar un build ya hecho.")
        d = distro or find_wsl_distro()
        if d is None:
            raise Fail("no hay WSL disponible y waf no corre en %s.\n"
                       "     Instala WSL, o compila en Linux y usa --skip-build."
                       % platform.system())
        b = cls(d)
        b.check_toolchain()
        return b

    def check_toolchain(self):
        r = self._wsl("ls -d %s 2>/dev/null | head -1" % self.TOOLCHAIN_GLOB, capture=True)
        found = (r.stdout or "").strip()
        if not found:
            raise Fail(
                "en WSL (%s) no encuentro el toolchain en %s\n"
                "     Instalalo (README de la placa, seccion 6) o usa --skip-build."
                % (self.distro, self.TOOLCHAIN_GLOB))
        info("WSL: %s    toolchain: %s" % (self.distro, found))

    def _wsl(self, inner, capture=False):
        cmd = ["wsl", "-d", self.distro, "-e", "bash", "-c", inner]
        if capture:
            return subprocess.run(cmd, capture_output=True, text=True)
        return subprocess.run(cmd)

    def waf(self, *args):
        """ejecuta './waf <args>' donde corresponda"""
        if self.distro is None:
            run([sys.executable, "./waf"] + list(args))
            return
        inner = ('set -e; '
                 'TC=$(ls -d %s 2>/dev/null | head -1); '
                 'export PATH="$TC:$HOME/.local/bin:$PATH"; '
                 'cd %s; '
                 'python3 ./waf %s') % (self.TOOLCHAIN_GLOB, to_wsl_path(ROOT),
                                        " ".join(args))
        info("$ [wsl:%s] ./waf %s" % (self.distro, " ".join(args)))
        res = self._wsl(inner)
        if res.returncode != 0:
            raise Fail("'waf %s' fallo en WSL (codigo %d)" % (args[0], res.returncode))


def build_bootloader(builder):
    step("Compilando el bootloader")
    builder.waf("configure", "--board", BOARD, "--bootloader")
    builder.waf("bootloader")
    src = os.path.join(ROOT, "build", BOARD, "bootloader", "AP_Bootloader.bin")
    if not os.path.exists(src):
        raise Fail("no se genero %s" % src)
    shutil.copyfile(src, BOOTLOADER_BIN)
    info("bootloader copiado a Tools/bootloaders/%s_bl.bin (%s)"
         % (BOARD, human(os.path.getsize(BOOTLOADER_BIN))))


def build_app(builder):
    step("Compilando el firmware (%s)" % VEHICLE)
    # configure SIEMPRE: es lo unico que recoge cambios de hwdef.dat / defaults.parm
    builder.waf("configure", "--board", BOARD)
    jobs = "-j$(nproc)" if builder.distro else "-j%d" % (os.cpu_count() or 4)
    builder.waf(VEHICLE, jobs)


# ------------------------------------------------------------ empaquetado

def package(outdir, allow_dirty):
    step("Recogiendo los ficheros del build")

    app_bin_path = os.path.join(BUILD_BIN_DIR, BINARY + ".bin")
    apj_path = os.path.join(BUILD_BIN_DIR, BINARY + ".apj")
    hex_path = os.path.join(BUILD_BIN_DIR, BINARY + "_with_bl.hex")

    for p in (app_bin_path, apj_path, hex_path):
        if not os.path.exists(p):
            raise Fail("falta %s\n     (compila primero, o quita --skip-build)" % p)
    if not os.path.exists(BOOTLOADER_BIN):
        raise Fail("falta el bootloader %s" % BOOTLOADER_BIN)

    reserve_kb = int(hwdef_value("FLASH_RESERVE_START_KB"))
    app = read(app_bin_path)
    bl = read(BOOTLOADER_BIN)
    info("app         %s  sha256 %s" % (human(len(app)), sha256(app)[:16]))
    info("bootloader  %s  sha256 %s" % (human(len(bl)), sha256(bl)[:16]))
    info("reserva de flash para el bootloader: %d KiB" % reserve_kb)

    if len(bl) > reserve_kb * 1024:
        raise Fail("el bootloader (%d B) no cabe en los %d KiB reservados"
                   % (len(bl), reserve_kb))

    # --- imagen combinada, identica a la que arma make_intel_hex.py ---
    bl_padded = bl + b"\xFF" * (reserve_kb * 1024 - len(bl))
    combined = bl_padded + app

    # ---------------------------------------------------------- validaciones
    step("Comprobando que los tres ficheros lleven el MISMO firmware")

    # 1) el .apj descomprimido debe ser byte a byte la aplicacion
    apj = json.loads(open(apj_path, "r", encoding="utf-8").read())
    apj_img = zlib.decompress(base64.b64decode(apj["image"]))
    if apj_img != app:
        raise Fail("el .apj NO coincide con %s.bin" % BINARY)
    if apj.get("image_size") != len(app):
        raise Fail("image_size del .apj (%s) != tamano real (%d)"
                   % (apj.get("image_size"), len(app)))
    info("apj  -> coincide con la app  (board_id %s, git %s)"
         % (apj.get("board_id"), apj.get("git_identity")))

    # 2) el .hex debe contener bootloader + app en las posiciones correctas
    mem = parse_intel_hex(open(hex_path, "r", encoding="utf-8").read())
    lo, hi = min(mem), max(mem)
    if lo != FLASH_BASE:
        raise Fail("el .hex empieza en 0x%08X, se esperaba 0x%08X" % (lo, FLASH_BASE))
    hex_bl = hex_region(mem, FLASH_BASE, reserve_kb * 1024)
    hex_app = hex_region(mem, FLASH_BASE + reserve_kb * 1024, len(app))
    if hex_bl != bl_padded:
        raise Fail("la zona de bootloader del .hex no coincide con %s" % BOOTLOADER_BIN)
    if hex_app != app:
        raise Fail("la zona de aplicacion del .hex no coincide con %s.bin" % BINARY)
    if hi != FLASH_BASE + len(combined) - 1:
        raise Fail("el .hex termina en 0x%08X, se esperaba 0x%08X"
                   % (hi, FLASH_BASE + len(combined) - 1))
    info("hex  -> bootloader en 0x%08X y app en 0x%08X, ambos correctos"
         % (FLASH_BASE, FLASH_BASE + reserve_kb * 1024))

    # 3) el .bin de DFU se deriva de los mismos bytes que el .hex
    if combined != hex_bl + hex_app:
        raise Fail("inconsistencia interna al armar la imagen combinada")
    info("bin  -> imagen combinada de %s, identica al contenido del .hex" % human(len(combined)))

    flash_total = int(hwdef_value("FLASH_SIZE_KB")) * 1024
    libre = flash_total - len(combined)
    if libre < 0:
        raise Fail("la imagen combinada (%d B) no entra en %d KiB de flash"
                   % (len(combined), flash_total // 1024))
    info("ocupacion: %s de %s  (%.1f%%, quedan %s)"
         % (human(len(combined)), human(flash_total),
            100.0 * len(combined) / flash_total, human(libre)))

    # ------------------------------------------------------------- escritura
    step("Escribiendo en %s" % outdir)
    os.makedirs(outdir, exist_ok=True)

    combined_name = BINARY + "_with_bl.bin"
    salidas = []

    def emit(name, data, para):
        path = os.path.join(outdir, name)
        with open(path, "wb") as f:
            f.write(data)
        salidas.append((name, len(data), sha256(data), para))
        info("%-26s %-24s %s" % (name, human(len(data)), para))

    # A PROPOSITO no se copia aqui la app cruda (build/.../ardurover.bin):
    # tendria un nombre .bin casi identico al combinado pero se graba en OTRA
    # direccion (0x08010000 en vez de 0x08000000). Confundirlos al grabar por DFU
    # deja la placa sin bootloader y solo se recupera por SWD. Es el mismo motivo
    # por el que make_intel_hex.py de ArduPilot emite un unico .hex.
    # Si alguna vez hace falta, sigue estando en build/SBY_GPS_INS/bin/.
    emit(BINARY + "_with_bl.hex", read(hex_path), "ST-LINK / SWD")
    emit(combined_name, combined, "DFU")
    emit(BINARY + ".apj", read(apj_path), "ArduPilot / Mission Planner")

    # ---------------------------------------------------------- manifiesto
    # Un firmware queda identificado por DOS cosas, no una:
    #   - la version de ArduPilot sobre la que se construyo  (arbol ROOT)
    #   - la version de los cambios de SBY que se le aplicaron (repo de la cola)
    # Sin la segunda no se puede reproducir el binario: cambiar el hwdef.dat y
    # recompilar sobre el mismo release daria un manifest identico.
    git, tag_ap, dirty = datos_git(ROOT)
    git = git or ""

    # El repo de la cola de parches: ROOT suele ser <cola>/build/ardupilot
    cola = os.path.abspath(os.path.join(ROOT, "..", ".."))
    sby_commit, sby_tag, sby_sucio = datos_git(cola)

    # La version de ArduPilot la dice el archivo UPSTREAM, que es la fuente
    # autoritativa. 'git describe' no sirve: hay varios tags en el mismo commit
    # (Rover-4.7.1 y APMrover2-beta, por ejemplo) y elige uno cualquiera.
    ruta_upstream = os.path.join(cola, "UPSTREAM")
    if os.path.exists(ruta_upstream):
        try:
            primera = io.open(ruta_upstream, encoding="utf-8").readline().strip()
            if primera:
                tag_ap = primera
        except Exception:
            pass

    # El arbol de ArduPilot SIEMPRE esta "sucio" (lleva los parches aplicados),
    # asi que avisar de eso no informa de nada. Lo que importa es si el repo de
    # la cola tenia cambios sin commitear: eso si hace el binario irreproducible.
    if sby_sucio and not allow_dirty:
        print("\n   AVISO: el repo de la cola tiene cambios sin commitear.")
        print("          Este binario NO se puede reproducir desde el commit %s."
              % (sby_commit or "?"))
        print("          Commitea antes de publicarlo, o usa --allow-dirty.")

    manifest = {
        "board": BOARD,
        "vehicle": VEHICLE,
        "generado_utc": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC"),
        # --- de que se construyo: ArduPilot ---
        "ardupilot_commit": git,
        "ardupilot_tag": tag_ap,
        "ardupilot_dirty": bool(dirty),      # true = tiene los parches aplicados
        # --- de que se construyo: los cambios de SBY ---
        "sby_commit": sby_commit,
        "sby_tag": sby_tag,
        "sby_dirty": sby_sucio,              # true = habia cambios sin commitear
        # compatibilidad con manifests anteriores
        "git_commit": git,
        "git_dirty": bool(dirty),
        "apj_board_id": apj.get("board_id"),
        "apj_git_identity": apj.get("git_identity"),
        "flash_reserve_kb": reserve_kb,
        "app_size": len(app),
        "app_sha256": sha256(app),
        "bootloader_sha256": sha256(bl),
        "bootloader_size": len(bl),
        "combined_size": len(combined),
        "flash_total": flash_total,
        "ficheros": [
            {"nombre": n, "bytes": s, "sha256": h, "para": p} for n, s, h, p in salidas
        ],
    }
    mpath = os.path.join(outdir, "manifest.json")
    with open(mpath, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)
    info("manifest.json              (ArduPilot %s / SBY %s%s)"
         % (tag_ap or git or "?", sby_tag or sby_commit or "?",
            ", SUCIO" if sby_sucio else ""))

    # ------------------------------------------------------------- resumen
    print("""
== Listo. Como grabar cada uno

  ST-LINK / SWD  (produccion, lo mas rapido; graba bootloader + app)
     STM32_Programmer_CLI -c port=SWD -w {hexn} -v -rst

  DFU  (recuperacion / 1a vez; BOOT0 alto + reset, aparece 0483:df11)
     dfu-util -a 0 -d 0483:df11 -s 0x{base:08X}:leave -D {binn}

  ArduPilot  (actualizacion por USB, SIN BOOT0; el bootloader ya esta puesto)
     python Tools/scripts/uploader.py --port COMx {apjn}
     o Mission Planner -> Install Firmware -> Load custom firmware

  UART  (bootloader de ROM AN3155, tras mandar $GO_BOOT,*6D por SERIAL1)
     el .bin combinado, escrito en 0x{base:08X} a 115200 8-EVEN-1

  Solo hay UN .bin en la carpeta ({binn}) y va siempre en 0x{base:08X}.
  La app suelta no se copia aqui a proposito: se graba en otra direccion y
  confundirlas deja la placa sin bootloader. Esta en build/{board}/bin/ si hace falta.
""".format(hexn=BINARY + "_with_bl.hex", binn=combined_name,
           apjn=BINARY + ".apj", base=FLASH_BASE, board=BOARD))


# --------------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(
        description="Genera los 3 ficheros de programacion de la SBY_GPS_INS de una vez.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__)
    ap.add_argument("-o", "--outdir", default=os.path.join(ROOT, "dist"),
                    help="carpeta de salida (por defecto: dist/ en la raiz del repo)")
    ap.add_argument("--skip-build", action="store_true",
                    help="no compilar, empaquetar lo que ya haya en build/")
    ap.add_argument("--bootloader", action="store_true",
                    help="recompilar tambien el bootloader antes del firmware")
    ap.add_argument("--allow-dirty", action="store_true",
                    help="no avisar si hay cambios sin commitear")
    ap.add_argument("--no-wsl", action="store_true",
                    help="en Windows, no delegar la compilacion en WSL")
    ap.add_argument("--distro", default=None,
                    help="distro WSL a usar (por defecto, la primera instalada)")
    args = ap.parse_args()

    print("sby_release.py  -  placa %s, vehiculo %s" % (BOARD, VEHICLE))

    try:
        if not args.skip_build:
            builder = Builder.create(allow_wsl=not args.no_wsl, distro=args.distro)
            if args.bootloader:
                build_bootloader(builder)
            build_app(builder)
        else:
            step("Compilacion omitida (--skip-build)")
        package(os.path.abspath(args.outdir), args.allow_dirty)
    except Fail as e:
        print("\nERROR: %s" % e, file=sys.stderr)
        return 1
    except FileNotFoundError as e:
        print("\nERROR: no encuentro %s" % e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
