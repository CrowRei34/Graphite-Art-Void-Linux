# Notas de compilacion

## Resumen del proceso de build

El build se divide en cinco fases secuenciales:

1. Toolchain de Rust con el target wasm32-unknown-unknown.
   El paquete `rust` de Void no incluye el target wasm32, por lo que se
   instala un toolchain gestionado por rustup durante el build. El toolchain
   y el directorio de cargo se guardan en rutas persistentes del masterdir
   (/var/cache/graphite-rustup, /var/cache/graphite-cargo) para que los
   reintentos no re-descarguen ni recompilen wasm-bindgen-cli.

2. Compilacion del frontend WebAssembly.
   Se compila el crate `graphite-wasm-wrapper` para el target
   wasm32-unknown-unknown, se genera el glue de JS con wasm-bindgen y se
   optimiza el binario wasm con wasm-opt (binaryen 130 precompilado).

3. Bundle del frontend con Vite.
   `vite build --mode native` empaqueta el frontend en frontend/dist,
   incluyendo los assets de branding y el wasm optimizado.

4. Generacion del archivo de licencias.
   graphite-desktop embebe `desktop/third-party-licenses.txt.xz` en tiempo de
   compilacion mediante include_bytes!. El generador upstream
   (`cargo run -p third-party-licenses --features desktop`) enlaza CEF y
   requiere las librerias de runtime de CEF presentes para ejecutarse, lo cual
   no esta disponible en el chroot de build. Se genera un placeholder .xz con
   python3 y lzma usando una ruta absoluta al wrksrc.

5. Compilacion del binario desktop nativo.
   `cargo build --release --package graphite-desktop-platform-linux` produce el
   binario final enlazado contra CEF y las librerias del sistema.

## Trade-offs frente al build upstream completo

### Feature `gpu` desactivado

El feature `gpu` del desktop habilita los nodos de raster con shaders GPU.
Estos shaders se compilan con rust-gpu (backend de codegen SPIR-V), que
requiere un toolchain nightly de Rust y `rustc_codegen_spirv` compilado desde
fuente, ninguno empaquetado en Void. Se desactiva en post_patch() modificando
desktop/Cargo.toml. Los nodos de raster se ejecutan en CPU; el resto del
editor funciona con normalidad.

### LTO y debuginfo desactivados

El proyecto activa por defecto lto="thin" y debug=true en el perfil release,
lo que produce artefactos muy grandes y tiempos de compilacion largos. Se
desactivan ambos mediante variables de entorno para mantener el paquete en un
tamano y tiempo de build razonables.

### Solo x86_64

Los distfiles de CEF y binaryen son binarios precompilados para linux64
(x86_64). El paquete se limita a esta arquitectura.

### Licencias de terceros (placeholder)

El visor de licencias dentro de la aplicacion mostrara un texto placeholder en
lugar del listado completo de licencias cargo/npm. El listado completo se puede
regenerar desde el arbol fuente con:

    cargo run -p third-party-licenses --features desktop

## Bugs encontrados y resueltos durante el build

| Problema | Solucion |
|---|---|
| GNU tar no esta en el chroot de Void (base-chroot usa bsdtar) | Se usa bsdtar en do_extract y do_build |
| Conflictos de dependencias al listar libstdc++-devel y base-devel | Se omiten (ya provistos por base-chroot) |
| rustup-init -c wasm32 trata el target como componente y lo salta | Se usa `rustup target add wasm32-unknown-unknown` |
| -fuse-ld=lld llega al linker wasm (rust-lld -flavor wasm) y falla | El flag se aplica solo al target x86_64 via CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS |
| Espacio en disco insuficiente durante el build nativo | Se elimina target/wasm32-unknown-unknown (~1 GB) tras el bundle de Vite |
| desktop/third-party-licenses.txt.xz requerido en tiempo de compilacion | Se genera un placeholder .xz con python3 + lzma usando ruta absoluta |

## Layout del paquete instalado

```
/usr/bin/graphite                          Script wrapper
/usr/lib/graphite/graphite                 Binario principal
/usr/lib/graphite/cef/                     Runtime de CEF 149
    libcef.so, libEGL.so, libGLESv2.so,
    *.pak, locales/, icudtl.dat,
    v8_context_snapshot.bin, vk_swiftshader
/usr/share/applications/
    art.graphite.Graphite.desktop          Entrada de menu
/usr/share/icons/hicolor/
    scalable/apps/art.graphite.Graphite.svg
    128x128/apps/art.graphite.Graphite.png
    256x256/apps/art.graphite.Graphite.png
    512x512/apps/art.graphite.Graphite.png
/usr/share/licenses/graphite/LICENSE.txt
```

El rpath del binario se ajusta a `$ORIGIN/cef` con patchelf para que
encuentre libcef.so sin requerir configuracion adicional del sistema.

## Verificacion de runtime

El paquete fue probado extrayendolo y ejecutandolo en un escritorio Wayland
con GPU Intel HD Graphics 530. Resultados:

- WGPU detecto el adaptador Vulkan (Intel open-source Mesa driver)
- El frontend web cargo correctamente (errores de ResizeObserver en consola
  indican JS ejecutandose)
- El arbol de procesos CEF se inicio completo (8 procesos: main + GPU +
  renderer + utility)
- Consumo de memoria: ~370 MB RSS
- Las librerias resolvieron sin dependencias faltantes (ldd sin "not found")
