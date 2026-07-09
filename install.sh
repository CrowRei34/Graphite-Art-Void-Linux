#!/bin/sh
# Instalador de Graphite para Void Linux (XBPS)
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" -- && pwd)
XBPS_PKG="graphite-0.0.0rc6_1.x86_64.xbps"
TEMPLATE_DIR="${SCRIPT_DIR}/srcpkgs/graphite"
REPO_DIR="${SCRIPT_DIR}"

uso() {
	cat <<EOF
Uso: $0 [OPCION]

Instala Graphite en Void Linux (x86_64).

Opciones:
  --binary      Instala el paquete .xbps precompilado (por defecto)
  --build       Reconstruye el paquete desde la template con xbps-src y lo instala
  --repo        Registra el directorio como repositorio local de XBPS e instala
  --uninstall   Desinstala Graphite
  --help        Muestra esta ayuda

Requisitos:
  --binary      xbps-install (con privilegios de root)
  --build       void-packages con xbps-src funcional + ~5 GB de disco
EOF
}

es_root() {
	[ "$(id -u)" -eq 0 ]
}

# Detecta un ejecutor de privilegios: doas (preferido) o sudo (respaldo).
priv_cmd() {
	if command -v doas >/dev/null 2>&1; then
		echo doas
	elif command -v sudo >/dev/null 2>&1; then
		echo sudo
	else
		echo ""
	fi
}

asegurar_root() {
	if ! es_root; then
		PRIV=$(priv_cmd)
		if [ -z "${PRIV}" ]; then
			echo "Error: ni doas ni sudo estan disponibles para escalar privilegios." >&2
			exit 1
		fi
		echo "Se requieren privilegios de root. Re-ejecutando con ${PRIV}..."
		exec "${PRIV}" "$0" "$@"
	fi
}

instalar_binario() {
	asegurar_root "$@"
	echo ">> Instalando ${XBPS_PKG}..."
	xbps-install -R "${REPO_DIR}" -y graphite
	echo ">> Instalacion completa."
	echo "   Ejecuta:  graphite"
}

instalar_build() {
	VP_DIR="${HOME}/void-packages"
	if [ ! -x "${VP_DIR}/xbps-src" ]; then
		echo ">> Clonando void-packages..."
		git clone --depth=1 https://github.com/void-linux/void-packages.git "${VP_DIR}"
	fi
	echo ">> Copiando template..."
	mkdir -p "${VP_DIR}/srcpkgs/graphite/files"
	cp "${TEMPLATE_DIR}/template" "${VP_DIR}/srcpkgs/graphite/template"
	cp "${TEMPLATE_DIR}/files/graphite" "${VP_DIR}/srcpkgs/graphite/files/graphite"
	chmod 755 "${VP_DIR}/srcpkgs/graphite/files/graphite"
	echo ">> Construyendo el paquete (esto tarda ~30 min)..."
	cd "${VP_DIR}"
	./xbps-src pkg graphite
	asegurar_root "$@"
	echo ">> Instalando el paquete compilado..."
	xbps-install -R "${VP_DIR}/hostdir/binpkgs" -y graphite
	echo ">> Instalacion completa."
	echo "   Ejecuta:  graphite"
}

instalar_repo() {
	asegurar_root "$@"
	echo ">> Registrando repositorio local..."
	mkdir -p /etc/xbps.d
	echo "repository=${REPO_DIR}" > /etc/xbps.d/10-graphite-local.conf
	xbps-install -S -y graphite
	echo ">> Instalacion completa."
	echo "   Repositorio: ${REPO_DIR}"
	echo "   Ejecuta:     graphite"
}

desinstalar() {
	asegurar_root "$@"
	echo ">> Desinstalando Graphite..."
	xbps-remove -y graphite
	echo ">> Graphite desinstalado."
}

case "${1:-binary}" in
	--binary|"")
		instalar_binario "$@"
		;;
	--build)
		instalar_build "$@"
		;;
	--repo)
		instalar_repo "$@"
		;;
	--uninstall)
		desinstalar
		;;
	--help|-h)
		uso
		;;
	*)
		echo "Opcion no reconocida: $1"
		uso
		exit 1
		;;
esac
