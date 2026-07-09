# Compilación automatizada (GitHub Actions)

Este repositorio incluye un workflow que compila automáticamente la versión
más reciente de Graphite y la empaqueta como `.xbps` para Void Linux x86_64.

## Archivos involucrados

```
.github/workflows/build.yml   El workflow de GitHub Actions
ci/build.sh                   El script de build (reutilizable, no depende de xbps-src)
```

## Cómo funciona

El workflow tiene dos jobs:

### 1. `build`

Corre en `ubuntu-latest`. La razón de usar Ubuntu (y no el contenedor Void
directamente con `container:`) es que las actions de GitHub escritas en
JavaScript (`actions/checkout`, `actions/cache`, `actions/upload-artifact`)
necesitan `node` y el runtime de actions en el entorno donde se ejecutan.
Dentro de un contenedor personalizado eso es frágil; en el runner Ubuntu
funciona nativamente.

El build real ocurre **dentro** de un contenedor Void Linux, lanzado con
`docker run`:

```
ghcr.io/void-linux/void-glibc-full:latest
```

Es la imagen OCI oficial de Void (glibc, variante "full", ~135 MB). Se monta:

- `$PWD` (el checkout) en `/work` → el contenedor lee `ci/build.sh` y escribe
  el `.xbps` en `/work/artifacts`.
- `/tmp/rustup-cache` y `/tmp/cargo-cache` en
  `/var/cache/graphite-{rustup,cargo}` → persisten el toolchain de Rust y el
  registry de cargo entre runs (cacheado por `actions/cache`).

Pasos del job `build`:

1. **checkout** del repositorio.
2. **Resolver el commit** de Graphite: si no se especifica uno, consulta
   `latest-stable` con `git ls-remote` y toma el HEAD. La versión del paquete
   se deriva del commit: `0.0.0git<7-hex>`.
3. **Cachear** el toolchain de Rust (clave basada en la versión de Rust +
   wasm-bindgen + el hash de `ci/build.sh`).
4. **`docker run`** del contenedor Void ejecutando `sh ci/build.sh`, pasando
   las variables de configuración por entorno.
5. **Subir el artifact** `graphite-xbps` (el `.xbps` + su `.sha256`).

### 2. `release`

Corre en `ubuntu-latest` **solo** en ejecuciones manuales o programadas (no
en push). Descarga el artifact del job anterior y crea un release de GitHub
con `softprops/action-gh-release@v2`, adjuntando el `.xbps` y la suma de
verificación.

## Disparadores

| Evento             | Qué hace                                            |
|--------------------|----------------------------------------------------|
| `workflow_dispatch`| Ejecución manual (opcionalmente con un commit dado)|
| `schedule` (lunes) | Build automático semanal del último latest-stable  |
| `push` a main      | Sólo compila + artifact (no crea release)           |

Para lanzarlo a mano: pestaña **Actions** → **Build Graphite XBPS** →
**Run workflow**.

## El script `ci/build.sh`

Es un script POSIX `sh` que replica la lógica de `srcpkgs/graphite/template`
sin depender de `xbps-src` (ni del masterdir/chroot). Esto lo hace:

- Portátil: corre en cualquier Void (máquina o contenedor) con `sh ci/build.sh`.
- Reproducible: descarga y verifica los distfiles (checksum SHA256 para los
  prebuilt pinned; el source se descarga sin verificar porque cambia cada
  commit).

Etapas del script (idénticas a la template):

1. Instalar dependencias de build de Void (`INSTALL_DEPS=0` para saltarlo).
2. Descargar los 4 distfiles (Graphite, CEF 149, binaryen 130, branding).
3. Extraer.
4. Desactivar el feature `gpu` (necesita toolchain SPIR-V nightly no empaquetado).
5. Instalar toolchain de Rust vía rustup + target `wasm32-unknown-unknown` +
   `wasm-bindgen-cli`.
6. Compilar el wrapper wasm, generar el glue con `wasm-bindgen`, optimizar con
   `wasm-opt`.
7. Empaquetar el frontend con Vite (`--mode native`).
8. Generar un placeholder de `third-party-licenses.txt.xz`.
9. Compilar el binario desktop nativo (`cargo build --release`).
10. Ensamblar el árbol del paquete (`do_install` equivalente), filtrando los
    locales de CEF (sólo `en-US` + `es`).
11. Crear el `.xbps` con `xbps-create`.

Todas las versiones de componentes son configurables por variables de entorno
(ver la cabecera del script).

## Ejecutarlo localmente

En una máquina Void Linux (o contenedor):

```sh
git clone https://github.com/CrowRei34/Graphite-Art-Void-Linux.git
cd Graphite-Art-Void-Linux
sh ci/build.sh                       # build del último latest-stable
GRAPHITE_COMMIT=<hash> sh ci/build.sh  # build de un commit específico
```

El `.xbps` resultante queda en `artifacts/`.

## Por qué no se usa `xbps-src` en CI

`xbps-src` construye dentro de un masterdir aislado con `bubblewrap`. Dentro
de un contenedor Docker (anidado en el runner de GitHub) el `bubblewrap` puede
fallar por restricciones de namespaces. El script standalone evita ese
problema construyendo directamente sobre el contenedor Void, que ya aporta el
aislamiento necesario.
