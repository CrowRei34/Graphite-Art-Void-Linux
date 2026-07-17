# Compilación automatizada (GitHub Actions)

El workflow compila la versión más reciente de Graphite (`latest-stable`) en
Ubuntu y la publica como un **AppImage portable x86_64**. Sin xbps, sin Void
Linux: corre en cualquier distribución.

## Archivos involucrados

```
.github/workflows/build.yml   El workflow de GitHub Actions (Ubuntu → AppImage)
ci/build-appimage.sh          El script de build reutilizable
```

Los archivos del empaquetado para Void (`srcpkgs/graphite/`, `ci/build.sh`,
`install.sh`) quedan como referencia y ya no los usa el workflow.

## Cómo funciona

Dos jobs, ambos en `ubuntu-22.04` / `ubuntu-latest`:

### 1. `build`

Corre en `ubuntu-22.04` (glibc 2.35, para que el AppImage sea compatible con
más distros). Pasos:

1. **checkout** del repositorio.
2. **Resolver el commit** de Graphite (si no se especifica, el HEAD de
   `latest-stable`). La versión se deriva del commit: `0.0.0git<7-hex>`.
3. **Cachear** el toolchain de Rust y el `target/` de cargo entre runs.
4. **`sh ci/build-appimage.sh`** — el build completo (ver abajo).
5. **Subir el artifact** `graphite-appimage` (el `.AppImage` + su `.sha256`).

### 2. `release`

Corre **solo** en ejecuciones manuales o programadas (no en push). Descarga el
artifact y crea un release de GitHub adjuntando el `.AppImage` y su suma.

## Disparadores

| Evento             | Qué hace                                            |
|--------------------|-----------------------------------------------------|
| `workflow_dispatch`| Ejecución manual (opcionalmente con un commit dado) |
| `schedule` (lunes) | Build automático semanal del último latest-stable   |
| `push` a main      | Sólo compila + artifact (no crea release)           |

Para lanzarlo a mano: pestaña **Actions** → **Build Graphite AppImage** →
**Run workflow**.

## El script `ci/build-appimage.sh`

Corre en cualquier Ubuntu con `sh ci/build-appimage.sh`. Etapas:

1. **Dependencias apt**: herramientas de build + las librerías `-dev` que
   Graphite enlaza (mapeadas del flake de Nix de upstream) + las librerías de
   runtime de CEF/Chromium (para bundlearlas después).
2. **Rust** (toolchain fijo) con el target `wasm32-unknown-unknown`.
3. **Herramientas que el build espera**: `wasm-opt` (binaryen), `wasm-bindgen`
   (versión exacta), `cargo-about`.
4. **CEF 149** y el **código fuente** de Graphite (checksum verificado en CEF).
5. Desactivar el feature `gpu` (necesita el toolchain SPIR-V nightly).
6. **`cargo run build desktop`** — el propio build tool de Graphite: descarga
   los assets de branding, instala las dependencias npm, compila y optimiza el
   WebAssembly, empaqueta el frontend con Vite, genera la lista de licencias de
   terceros y enlaza el binario nativo.
7. **Bundling de CEF**: como el bundler de Linux de upstream es un stub
   (*"Bundling for Linux is not yet implemented"*), aquí se arma el AppDir a
   mano — el binario + el runtime de CEF juntos, con `rpath = $ORIGIN/cef` — el
   mismo layout que usa el paquete de Void, que se sabe que funciona. Las
   librerías de sistema que Chromium necesita se copian junto a `libcef.so`
   (salvo glibc, el driver de GL y el núcleo de X, que vienen del host).
8. **AppImage**: `appimagetool` con `APPIMAGE_EXTRACT_AND_RUN=1` y
   `--runtime-file`, de modo que no se necesita FUSE (no disponible en CI).

Todas las versiones son configurables por variables de entorno (ver la cabecera
del script).

## Ejecutarlo localmente

En cualquier máquina Ubuntu:

```sh
git clone https://github.com/CrowRei34/Graphite-Art-Void-Linux.git
cd Graphite-Art-Void-Linux
sh ci/build-appimage.sh                        # build del último latest-stable
GRAPHITE_COMMIT=<hash> sh ci/build-appimage.sh  # un commit específico
```

El `.AppImage` resultante queda en `artifacts/`.
