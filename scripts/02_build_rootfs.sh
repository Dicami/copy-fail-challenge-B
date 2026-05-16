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

# ── [CRÍTICO] SOLUCIÓN AL KERNEL PANIC: LIBS Y ENLAZADOR ─────────────────────
echo -e "${CYAN}[5/6] Copiando Python y solucionando dependencias de librerías...${NC}"
PYTHON_BIN=$(which python3)
cp "$PYTHON_BIN" "$INITRAMFS_DIR/usr/bin/python3"
ln -sf python3 "$INITRAMFS_DIR/usr/bin/python"

# Copiar el enlazador dinámico (evita el Error -2 ENOENT)
cp -L /lib64/ld-linux-x86-64.so.2 "$INITRAMFS_DIR/lib64/" 2>/dev/null || true
cp -L /lib/ld-linux-x86-64.so.2 "$INITRAMFS_DIR/lib/" 2>/dev/null || true

# Rastrear y copiar librerías compartidas de Python usando ldd
for lib in $(ldd "$PYTHON_BIN" 2>/dev/null | grep -oE '/[^ ]+\.so[^ ]*'); do
  mkdir -p "$INITRAMFS_DIR$(dirname "$lib")"
  cp -L "$lib" "$INITRAMFS_DIR$lib" 2>/dev/null || true
done

# Copiar la librería estándar mínima de Python
PYTHON_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
mkdir -p "$INITRAMFS_DIR/usr/lib/python${PYTHON_VER}"
cp -r /usr/lib/python3/* "$INITRAMFS_DIR/usr/lib/python${PYTHON_VER}/" 2>/dev/null || true
# ────────────────────────────────────────────────────────────────────────────────

# Configuración básica de usuarios
cat > "$INITRAMFS_DIR/etc/passwd" << 'EOF'
root:x:0:0:root:/root:/bin/sh
student:x:1001:1001:student:/home/student:/bin/sh
EOF

# Crear el script de arranque /init
cat > "$INITRAMFS_DIR/init" << 'INITEOF'
#!/bin/sh
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev 2>/dev/null || mdev -s
mount -t tmpfs none /tmp

# Módulos para el reto copy-fail (CVE-2026-31431)
modprobe algif_aead 2>/dev/null || true
modprobe authencesn 2>/dev/null || true

echo ""
echo "  ╔══════════════════════════════════════════╗"
echo "  ║   KERNEL VULNERABLE — CVE-2026-31431     ║"
echo "  ╚══════════════════════════════════════════╝"
echo ""

# Forzar el inicio seguro degradando privilegios a student
exec su - student
INITEOF

chmod +x "$INITRAMFS_DIR/init"

echo -e "${CYAN}[6/6] Empaquetando initramfs con cpio...${NC}"
cd "$INITRAMFS_DIR"
find . | cpio -o -H newc 2>/dev/null | gzip > "$BUILD_DIR/initramfs.cpio.gz"

echo -e "${GREEN}✓ rootfs listo y parchado sin Kernel Panic!${NC}"