#!/usr/bin/env bash
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

mkdir -p "$INITRAMFS_DIR"/{proc,sys,dev,tmp,etc,root,home/student,usr/bin,usr/lib,lib,lib64,run}

echo -e "${CYAN}[5/6] Copiando Python y solucionando dependencias dinámicas...${NC}"
copy_deps() {
  local bin="$1"
  ldd "$bin" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i ~ /^\//) print $i}' | while read -r lib; do
    mkdir -p "$INITRAMFS_DIR$(dirname "$lib")"
    cp -L "$lib" "$INITRAMFS_DIR$lib"
    chmod 755 "$INITRAMFS_DIR$lib"
  done
}

mkdir -p "$INITRAMFS_DIR/usr/bin"
PYBIN="$(command -v python3)"
install -o root -g root -m 0755 "$PYBIN" "$INITRAMFS_DIR/usr/bin/python3"
ln -sf python3 "$INITRAMFS_DIR/usr/bin/python"
copy_deps "$PYBIN"

PYVER="$(python3 -c 'import sys; print(f"python{sys.version_info.major}.{sys.version_info.minor}")')"
mkdir -p "$INITRAMFS_DIR/usr/lib"
cp -a "/usr/lib/$PYVER" "$INITRAMFS_DIR/usr/lib/" 2>/dev/null || true
cp -a /usr/local/lib/python* "$INITRAMFS_DIR/usr/local/lib/" 2>/dev/null || true

cat > "$INITRAMFS_DIR/etc/passwd" << 'PASS_EOF'
root:x:0:0:root:/root:/bin/sh
student:x:1001:1001:student:/home/student:/bin/sh
PASS_EOF
cat > "$INITRAMFS_DIR/init" << 'VM_INIT'
#!/bin/sh
mkdir -p /proc /sys /dev /tmp /etc
mount -t proc none /proc 2>/dev/null || true
mount -t sysfs none /sys 2>/dev/null || true
mount -t devtmpfs none /dev 2>/dev/null || mdev -s
mount -t tmpfs none /tmp 2>/dev/null || true

modprobe algif_aead 2>/dev/null || true
modprobe authencesn 2>/dev/null || true

echo ""
echo "  ╔══════════════════════════════════════════╗"
echo "  ║   KERNEL VULNERABLE — CVE-2026-31431     ║"
echo "  ╚══════════════════════════════════════════╝"
echo ""

exec su - student
VM_INIT

chmod +x "$INITRAMFS_DIR/init"
mkdir -p "$INITRAMFS_DIR/home/student"
if [ -f "/workspaces/copy-fail-challenge-B/exploit.py" ]; then
    cp "/workspaces/copy-fail-challenge-B/exploit.py" "$INITRAMFS_DIR/home/student/exploit.py"
    chmod +x "$INITRAMFS_DIR/home/student/exploit.py"
fi

echo -e "${CYAN}[6/6] Empaquetando initramfs con cpio...${NC}"
cd "$INITRAMFS_DIR"
find . -print0 | cpio --null -o --format=newc 2>/dev/null | gzip -9 > "$BUILD_DIR/initramfs.cpio.gz"

echo -e "${GREEN}✓ rootfs listo con Python y Exploit integrado!${NC}"

# --- PARCHE COSMÉTICO PARA EL PROMPT ---
# 1. Definir el nombre del host de la máquina virtual
echo "copy-fail" > "$INITRAMFS_DIR/etc/hostname"

# 2. Configurar el prompt para el usuario student en su perfil de arranque
mkdir -p "$INITRAMFS_DIR/home/student"
cat > "$INITRAMFS_DIR/home/student/.profile" << 'PROFILE_EOF'
export PS1='\[\033[01;32m\][\u@$(cat /etc/hostname) \W]\$\[\033[00m\] '
PROFILE_EOF
chown -R 1001:1001 "$INITRAMFS_DIR/home/student/.profile"
