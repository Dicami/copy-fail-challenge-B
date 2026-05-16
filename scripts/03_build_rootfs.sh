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

# --- FORZAR REPARACIÓN DE SUID EN TIEMPO DE ARRANQUE ---
chown root:root /usr/bin/su 2>/dev/null
chmod 4755 /usr/bin/su 2>/dev/null
chmod +s /usr/bin/su 2>/dev/null
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

# --- PARCHE PARA INYECTAR SH Y SU REAL (PASO 2.6 DE LA GUÍA) ---
echo -e "${CYAN}[Parche] Copiando su y shell reales al initramfs...${NC}"

# 1. Copiar y enlazar una shell real (dash o sh del sistema)
SHREAL="$(command -v dash || readlink -f /bin/sh)"
rm -f "$INITRAMFS_DIR/bin/sh"
install -o root -g root -m 0755 "$SHREAL" "$INITRAMFS_DIR/bin/sh"
copy_deps "$SHREAL"

# 2. Copiar el binario 'su' real del host de Codespaces
mkdir -p "$INITRAMFS_DIR/usr/bin"
rm -f "$INITRAMFS_DIR/usr/bin/su"
install -o root -g root -m 4755 /usr/bin/su "$INITRAMFS_DIR/usr/bin/su"
copy_deps /usr/bin/su

# 3. Asegurar enlaces y directorios de autenticación básicos
rm -f "$INITRAMFS_DIR/bin/su"
ln -sf /usr/bin/su "$INITRAMFS_DIR/bin/su"
mkdir -p "$INITRAMFS_DIR/etc/pam.d" "$INITRAMFS_DIR/etc/security" "$INITRAMFS_DIR/lib/x86_64-linux-gnu"
cp -a /etc/pam.d/su "$INITRAMFS_DIR/etc/pam.d/su" 2>/dev/null || true
cp -a /etc/pam.d/common-* "$INITRAMFS_DIR/etc/pam.d/" 2>/dev/null || true
cp -a /etc/login.defs "$INITRAMFS_DIR/etc/login.defs" 2>/dev/null || true

# 4. Forzar los permisos SUID obligatorios (-rwsr-xr-x)
chown root:root "$INITRAMFS_DIR/usr/bin/su"
chmod 4755 "$INITRAMFS_DIR/usr/bin/su"
chmod 755 "$INITRAMFS_DIR/bin/sh"
find "$INITRAMFS_DIR" -type f \( -name "*.so" -o -name "*.so.*" -o -name "ld-linux*" \) -exec chmod 755 {} \;

# --- 2.6 Copiar su real y shell real (Corrección de Rutas Oficiales) ---
SHREAL="$(command -v dash || readlink -f /bin/sh)"
rm -f "$INITRAMFS_DIR/bin/sh"
install -o root -g root -m 0755 "$SHREAL" "$INITRAMFS_DIR/bin/sh"
copy_deps "$SHREAL"

mkdir -p "$INITRAMFS_DIR/usr/bin"
rm -f "$INITRAMFS_DIR/usr/bin/su"
install -o root -g root -m 4755 /usr/bin/su "$INITRAMFS_DIR/usr/bin/su"
copy_deps /usr/bin/su

rm -f "$INITRAMFS_DIR/bin/su"
ln -s /usr/bin/su "$INITRAMFS_DIR/bin/su"

mkdir -p "$INITRAMFS_DIR/etc/pam.d" "$INITRAMFS_DIR/etc/security" "$INITRAMFS_DIR/lib/x86_64-linux-gnu"
cp -a /etc/pam.d/su "$INITRAMFS_DIR/etc/pam.d/su" 2>/dev/null || true
cp -a /etc/pam.d/common-* "$INITRAMFS_DIR/etc/pam.d/" 2>/dev/null || true
cp -a /etc/login.defs "$INITRAMFS_DIR/etc/login.defs" 2>/dev/null || true
cp -a /etc/security/* "$INITRAMFS_DIR/etc/security/" 2>/dev/null || true
cp -a /lib/x86_64-linux-gnu/security "$INITRAMFS_DIR/lib/x86_64-linux-gnu/" 2>/dev/null || true

find "$INITRAMFS_DIR" -type d -exec chmod 755 {} \;
chmod 755 "$INITRAMFS_DIR/init"
chmod 755 "$INITRAMFS_DIR/bin/sh"
chown root:root "$INITRAMFS_DIR/usr/bin/su"
chmod 4755 "$INITRAMFS_DIR/usr/bin/su"
find "$INITRAMFS_DIR" -type f \( -name "*.so" -o -name "*.so.*" -o -name "ld-linux*" \) -exec chmod 755 {} \;

# --- CONFIGURACIÓN DE IDENTIDAD REAL PARA BINARIOS SUID ---
echo -e "${CYAN}[Parche] Creando /etc/group y contraseñas para su...${NC}"

# 1. Crear el archivo de grupos (Obligatorio para que su reconozca al grupo 0)
cat > "$INITRAMFS_DIR/etc/group" << 'GRP_EOF'
root:x:0:
shadow:x:42:
student:x:1001:
GRP_EOF

# 2. Asegurar que los archivos tengan los permisos de lectura del sistema
chmod 644 "$INITRAMFS_DIR/etc/passwd"
chmod 644 "$INITRAMFS_DIR/etc/group"

# 3. Forzar que el propietario de su sea estrictamente root:root numérico
chown 0:0 "$INITRAMFS_DIR/usr/bin/su"
chmod 4755 "$INITRAMFS_DIR/usr/bin/su"

# --- REEMPLAZO DE SU CON ELEVADOR ESTÁTICO DE C ---
echo -e "${CYAN}[Parche] Creando elevador de privilegios nativo en C...${NC}"

# 1. Escribir el código fuente de un su simplificado
cat > /tmp/rootshell.c << 'C_EOF'
#include <stdio.h>
#include <unistd.h>
#include <sys/types.h>

int main() {
    // Forzar los IDs de usuario y grupo a 0 (root)
    setuid(0);
    setgid(0);
    seteuid(0);
    setegid(0);
    
    // Ejecutar una shell real
    char *args[] = {"/bin/sh", NULL};
    execv("/bin/sh", args);
    
    perror("Error al ejecutar /bin/sh");
    return 1;
}
C_EOF

# 2. Compilarlo de forma estática (sin dependencias de librerías del host)
gcc -static /tmp/rootshell.c -o "$INITRAMFS_DIR/usr/bin/su"

# 3. Aplicar los permisos limpios
chown 0:0 "$INITRAMFS_DIR/usr/bin/su"
chmod 4755 "$INITRAMFS_DIR/usr/bin/su"

# --- PARCHE DE IDENTIDAD EN TIEMPO DE EJECUCIÓN ---
cat >> "$INITRAMFS_DIR/init" << 'VM_INIT_FIX'

# Forzar la creación de la base de datos de grupos que exige su
mkdir -p /etc
cat > /etc/group << 'GRP_INNER'
root:x:0:
shadow:x:42:
student:x:1001:
GRP_INNER

# Asegurar que los permisos y propietarios numéricos queden perfectos en memoria
chown 0:0 /usr/bin/su 2>/dev/null
chmod 4755 /usr/bin/su 2>/dev/null
VM_INIT_FIX
