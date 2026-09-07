# Compilar en Windows, desde cero

Procedimiento para dejar un Windows sin preparar compilando el firmware. En Linux
o macOS no hace falta: ver [README, sección 5](../README.md#5-instalación), son dos
comandos.

Resultado final: una carpeta `dist/` con los tres formatos de grabación, y la
posibilidad de modificar el firmware y recompilar en ~90 s.

> **Antes de empezar.** Grabar una placa no requiere compilar: los binarios están
> en [Releases](https://github.com/CarlosEGMWar/GPS_INS/releases) y se graban con
> Mission Planner, STM32CubeProgrammer o dfu-util, que son nativos de Windows.
>
> Para obtener el binario de un cambio no publicado sin instalar nada, ver
> [la última sección](#alternativa-compilar-en-github-sin-instalar-nada).
>
> Este documento es para **modificar el firmware**.

---

## Por qué WSL

Windows nativo no compila ArduPilot. El sistema de compilación (waf) y las
herramientas de ChibiOS requieren un entorno POSIX: rutas, permisos, enlaces
simbólicos y utilidades que `cmd` y PowerShell no proveen.

No es una limitación de este proyecto: **el instalador oficial de ArduPilot para
Windows instala Cygwin**, que es otra capa POSIX. WSL es el mismo planteamiento,
integrado en el sistema y con mejor rendimiento.

WSL ejecuta Ubuntu dentro de Windows. No es una máquina virtual convencional ni un
arranque dual: se abre como una terminal más, accede a los archivos de Windows y se
detiene al cerrarla.

---

## Paso 1 — Instalar WSL

En **PowerShell como administrador** (botón derecho en Inicio → *Terminal
(Administrador)*):

```powershell
wsl --install
```

Instala WSL 2 y Ubuntu. **Requiere reiniciar.**

Tras el reinicio se abre una ventana de Ubuntu que solicita usuario y contraseña.
Son credenciales de Ubuntu, sin relación con la cuenta de Windows. La contraseña
hace falta para `sudo`.

Si esa ventana no aparece, abrir *Ubuntu* desde el menú Inicio.

Comprobación, desde PowerShell:

```powershell
wsl --version
wsl --list --verbose
```

Debe indicar `VERSION 2`. Si indica 1: `wsl --set-default-version 2` y reinstalar
Ubuntu.

> **Entorno de referencia.** El firmware se desarrolla sobre WSL 2 con
> **Ubuntu 22.04.5 LTS**, y se compila además en Ubuntu 24.04 en cada push.
> Cualquiera de las dos sirve, igual que la que instale `wsl --install`.

---

## Paso 2 — Dependencias base

Todo lo pesado —ArduPilot, el compilador ARM, las dependencias de Python— lo
descargan los scripts. Solo hay que asegurar esto, presente de serie en la mayoría
de las instalaciones:

```bash
sudo apt update
sudo apt install -y git python3 python3-pip binutils bzip2
```

`binutils` aporta `strings`, con el que se verifica que el firmware salió completo.

---

## Paso 3 — Ubicación del repositorio

Decisión con impacto medible en el tiempo de compilación.

WSL expone dos sistemas de archivos: el propio (`~/`, ext4) y el de Windows,
montado en `/mnt/c/`. **Compilar en `/mnt/c/` es apreciablemente más lento**, porque
cada operación de E/S cruza entre ambos sistemas y una compilación completa toca
miles de archivos.

| Ubicación | Rendimiento | Acceso desde Windows |
|---|---|---|
| `~/GPS_INS` (dentro de WSL) | alto | sí, vía `\\wsl$\Ubuntu\home\usuario\` |
| `/mnt/c/Users/usuario/...` | menor | sí, es una carpeta normal |

**Recomendación: `~/GPS_INS`.** No impide editar desde Windows: con la extensión
[WSL de VS Code](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-wsl)
se abre la carpeta con `code .` desde la terminal de Ubuntu y el uso es idéntico.

La alternativa en una carpeta de Windows funciona igual, solo más despacio.

---

## Paso 4 — Clonar y compilar

```bash
cd ~
git clone https://github.com/CarlosEGMWar/GPS_INS.git
cd GPS_INS
./scripts/compilar.sh
```

No hay que instalar ArduPilot ni el compilador ARM: `compilar.sh` detecta lo que
falta y lo descarga.

La primera ejecución descarga unos 2,4 GB —ArduPilot, sus submódulos y el
compilador— con el progreso a la vista:

```
== Falta parte del entorno: preparandolo
== Descargando ArduPilot (~880 MB, solo esta vez)
== Descargando 11 submodulos (~460 MB, ChibiOS es el grueso)
== Instalando dependencias de Python (con pip --user)
== Descargando el compilador ARM (~150 MB, solo esta vez)
```

**Las ejecuciones siguientes no descargan nada** y compilan en ~90 s.

Salida:

```
dist/
  ardurover_with_bl.hex     ST-LINK / SWD
  ardurover_with_bl.bin     DFU y cable serie
  ardurover.apj             Mission Planner
  manifest.json             huellas SHA-256 y datos de construccion
```

---

## Paso 5 — Acceder a los binarios desde Windows

La grabación se hace con herramientas de Windows, así que hay que llegar a esos
archivos desde el Explorador.

Con el repositorio dentro de WSL, en la barra de direcciones del Explorador:

```
\\wsl$\Ubuntu\home\USUARIO\GPS_INS\dist
```

O directamente desde la terminal de Ubuntu:

```bash
explorer.exe dist
```

Si el repositorio está en `/mnt/c/...`, es una carpeta de Windows corriente.

Los comandos de grabación están en la
[sección 10 del README](../README.md#10-qué-sale-en-dist-y-cómo-se-graba).

---

## Modificar el firmware

El ciclo de trabajo es un solo comando:

```bash
./scripts/compilar.sh
```

Restricción importante: **`build/ardupilot/` es desechable**. Los scripts la
resetean y la reconstruyen. Los cambios hechos ahí que no se trasladen a `overlay/`
o a `patches/` se pierden.

El reparto entre esas dos carpetas está en la
[sección 2 del README](../README.md#2-la-idea-overlay--parches); las advertencias a
tener en cuenta antes de modificar nada, en la
[sección 11](../README.md#11-cosas-que-conviene-saber).

---

## Problemas frecuentes

**`wsl --install` no se reconoce como comando.**
Versión de Windows insuficiente. Requiere Windows 10 versión 2004 o superior, o
Windows 11. Actualizar desde Windows Update.

**La compilación falla al final con `/usr/bin/env: 'python3\r'`.**
Finales de línea CRLF. Ocurre si el repositorio se clonó con Git de Windows y
`core.autocrlf=true`. Los scripts lo corrigen; solución de raíz:

```bash
git config --global core.autocrlf input
```

Clonar desde dentro de WSL, como indica el paso 4, evita el problema.

**`falta 'strings' (paquete binutils)`.**
Falta el paso 2: `sudo apt install binutils`.

**La descarga del compilador se interrumpe.**
Volver a ejecutar `./scripts/compilar.sh`: reanuda y no repite lo ya descargado.

**Compilación lenta.**
Comprobar la ubicación del repositorio. Si está en `/mnt/c/`, moverlo a `~/`
(paso 3).

---

## Alternativa: compilar en GitHub, sin instalar nada

Para obtener el binario de un cambio no publicado sin montar el entorno, la
compilación puede ejecutarse en los servidores de GitHub:

1. Pestaña **[Actions](https://github.com/CarlosEGMWar/GPS_INS/actions)** del
   repositorio.
2. Flujo **compilar** → **Run workflow**.
3. Al terminar (~4 min), descargar de esa ejecución el artefacto
   **firmware-SBY_GPS_INS**: contiene los mismos tres formatos y su
   `manifest.json`.

Compila en una máquina limpia, de modo que el resultado es idéntico al obtenido en
local. Sirve para pruebas, no para entrega: **lo que se entrega se publica con
`publicar.sh`** y queda en Releases bajo una etiqueta de versión.
