# Instalacion

## Opcion 1: Instalar el binario precompilado

    xbps-install -R /ruta/a/graphite-void-export graphite

Reemplaza `/ruta/a/graphite-void-export` por la ruta absoluta donde se
encuentra el archivo `.xbps`.

Si se quiere usar como repositorio local permanente:

    mkdir -p /etc/xbps.d
    echo "repository=/ruta/a/graphite-void-export" > /etc/xbps.d/10-graphite.conf
    xbps-install -S graphite

## Opcion 2: Reconstruir desde la template

1. Clonar void-packages:

       git clone --depth=1 https://github.com/void-linux/void-packages.git
       cd void-packages

2. Copiar la template:

       cp -r /ruta/a/graphite-void-export/srcpkgs/graphite srcpkgs/

3. Construir el paquete:

       ./xbps-src pkg graphite

4. Instalar desde el repositorio local generado:

       xbps-install -R hostdir/binpkgs graphite

## Ejecutar

Tras instalar, Graphite aparece en el menu de aplicaciones como "Graphite"
o se lanza desde terminal:

    graphite

Si la aceleracion GPU causa problemas graficos:

    graphite --disable-ui-acceleration

## Dependencias de runtime

El paquete declara las siguientes dependencias que xbps-install instalara
automaticamente:

mesa, mesa-dri, libglvnd, libgbm, vulkan-loader, wayland, openssl, libraw,
libxkbcommon, libXcursor, libxcb, libX11, libXcomposite, libXdamage,
libXext, libXfixes, libXrandr, nss, nspr, libcups, alsa-lib, dbus-libs,
glib, cairo, pango, atk, at-spi2-core, expat, eudev-libudev, fontconfig,
freetype, hicolor-icon-theme, desktop-file-utils
