#!/usr/bin/env bash
# scripts/02_build_rootfs.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUSYBOX_SRC="$WORKSPACE_ROOT/kernel/busybox"
INITRAMFS_DIR="$WORKSPACE_ROOT/kernel/initramfs"
BUILD_DIR="$WORKSPACE_ROOT/kernel/build"
JOBS=$(nproc)

GREEN='\033[1;32m'; CYAN='\033[1;36m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo -e "${CYAN}[1/6] Clonando/Verificando BusyBox...${NC}"
if [ ! -d "$BUSYBOX_SRC" ]; then
    git clone --depth 1 https://git.busybox.net/busybox "$BUSYBOX_SRC"
fi

cd "$BUSYBOX_SRC"
echo -e "${CYAN}[2/6] Configurando BusyBox (binario estático)...${NC}"
make defconfig
sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
grep -q "CONFIG_STATIC=y" .config || echo "CONFIG_STATIC=y" >> .config
sed -i 's/CONFIG_TC=y/CONFIG_TC=n/' .config

echo -e "${CYAN}[3/6] Compilando BusyBox...${NC}"
make -j"$JOBS" 2>&1 | tail -3

echo -e "${CYAN}[4/6] Instalando BusyBox en el initramfs...${NC}"
mkdir -p "$INITRAMFS_DIR"
make CONFIG_PREFIX="$INITRAMFS_DIR" install

# Estructura de directorios de un sistema Linux/UNIX real
mkdir -p "$INITRAMFS_DIR"/{proc,sys,dev,tmp,etc,root,home/student,usr/bin,usr/lib,lib,lib64,run}

echo -e "${CYAN}[5/6] Copiando Python y solucionando dependencias (Método de la Guía)...${NC}"

# Función de tu documento para rastrear y copiar librerías dinámicas obligatorias
copy_deps() {
  local bin="$1"
  ldd "$bin" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i ~ /^\//) print $i}' | while read -r lib; do
    mkdir -p "$INITRAMFS_DIR$(dirname "$lib")"
    cp -L "$lib" "$INITRAMFS_DIR$lib"
    chmod 755 "$INITRAMFS_DIR$lib"
  done
}

# Configurar e instalar el ejecutable de Python3
mkdir -p "$INITRAMFS_DIR/usr/bin"
PYBIN="$(command -v python3)"
install -o root -g root -m 0755 "$PYBIN" "$INITRAMFS_DIR/usr/bin/python3"
ln -sf python3 "$INITRAMFS_DIR/usr/bin/python"

# Ejecutar el rastreador de librerías sobre Python
copy_deps "$PYBIN"

# Copiar la librería estándar de Python
PYVER="$(python3 -c 'import sys; print(f"python{sys.version_info.major}.{sys.version_info.minor}")')"
mkdir -p "$INITRAMFS_DIR/usr/lib"
cp -a "/usr/lib/$PYVER" "$INITRAMFS_DIR/usr/lib/" 2>/dev/null || true
cp -a /usr/local/lib/python* "$INITRAMFS_DIR/usr/local/lib/" 2>/dev/null || true

# Configuración básica de usuarios
cat > "$INITRAMFS_DIR/etc/passwd" << 'EOF'
root:x:0:0:root:/root:/bin/sh
student:x:1001:1001:student:/home/student:/bin/sh
