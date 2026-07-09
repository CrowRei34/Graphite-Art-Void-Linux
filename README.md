# Graphite para Void Linux

Paquete XBPS de Graphite, el editor de gráficos vectoriales y raster
procedurales basado en nodos, construido y empaquetado para Void Linux.

## Contenido de este directorio

```
graphite-void-export/
├── install.sh                              Script de instalacion automatica
├── README.md                               Este archivo
├── BUILD-NOTES.md                          Notas técnicas del build y caveats
├── CHECKSUMS.txt                           Sumas de verificacion de distfiles
├── INSTALL.md                              Instrucciones de instalacion
├── graphite-0.0.0rc6_1.x86_64.xbps        Paquete binario compilado
└── srcpkgs/
    └── graphite/
        ├── template                        Receta xbps-src
        └── files/
            └── graphite                    Script wrapper de lanzamiento
```

## Que es Graphite

Graphite es un editor de graficos 2D de codigo abierto con un flujo de trabajo
no destructivo basado en nodos. Combina edicion vectorial y raster en una
misma aplicacion. La version de escritorio usa el Chromium Embedded Framework
(CEF) 149 para renderizar la interfaz web (Svelte/TypeScript) y Rust para el
motor de edicion (compilado a WebAssembly).

- Pagina oficial: https://graphite.art
- Repositorio:    https://github.com/GraphiteEditor/Graphite
- Licencia:       Apache-2.0

## Version empaquetada

- Version de Graphite: latest-stable (commit 95c1ab8, "Prep for the RC6
  release of the desktop app")
- CEF: 149.0.5+g6770623+chromium-149.0.7827.197
- Arquitectura: x86_64

## Requisitos

El paquete fue construido con xbps-src dentro de un arbol void-packages.
Para reconstruirlo se necesita:

- Void Linux (o un entorno con xbps-src funcional)
- ~5 GB de espacio libre en disco
- Conectividad a internet (descarga de distfiles y dependencias cargo/npm)
- ~30 minutos de compilacion (frontend wasm + desktop nativo)

Para instalar el binario precompilado solo se necesita Void Linux x86_64.
