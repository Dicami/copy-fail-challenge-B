#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/types.h>

int main() {
    // === ESTE ES TU PARCHE REAL DE SEGURIDAD ===
    // Si el usuario real no es root (0), quitamos los superpoderes
    if (getuid() != 0) {
        printf("[-] PARCHE ACTIVO: Deteniendo escalación de privilegios.\n");
        setuid(getuid()); // Revoca el SUID y te mantiene como student
    }

    // Ejecución normal de tu script de Python
    char *args[] = {"/usr/bin/python3", "/home/student/exploit.py", NULL};
    execv("/usr/bin/python3", args);
    
    return 0;
}
