#!/bin/bash
# =============================================================================
# CREACION DEL USUARIO DE REPLICACION
# Proyecto Semestral - Seguridad en los Sistemas de Informacion - UTP FISC
# -----------------------------------------------------------------------------
# MariaDB ejecuta automaticamente los archivos de /docker-entrypoint-initdb.d
# la PRIMERA vez que se inicializa el volumen de datos.
#
# Se usa un script .sh y no un .sql porque los archivos .sql se ejecutan tal
# cual, sin expandir variables de entorno. Necesitamos leer las credenciales
# desde el entorno para no escribirlas en ningun archivo versionado.
# =============================================================================
set -eu
echo "[*] Creando el usuario dedicado a la replicacion..."
mariadb -u root -p"${MARIADB_ROOT_PASSWORD}" <<-EOSQL
-- =====================================================================
-- PRINCIPIO DE MINIMO PRIVILEGIO
-- ---------------------------------------------------------------------
-- Este usuario existe con un unico proposito: leer el registro binario
-- del primario. Se le concede exclusivamente REPLICATION SLAVE.
--
-- Lo que este usuario NO puede hacer, aunque sus credenciales se filtren:
-- * leer el contenido de ninguna tabla (sin SELECT)
-- * modificar datos (sin INSERT, UPDATE, DELETE)
-- * alterar la estructura (sin CREATE, DROP, ALTER)
-- * leer archivos del sistema (sin FILE)
--
-- Un atacante que obtuviera esta contrasena solo podria observar el flujo
-- de cambios, nunca consultar ni alterar la base de datos directamente.
-- =====================================================================
CREATE USER IF NOT EXISTS '${REPL_USER}'@'%'
IDENTIFIED BY '${REPL_PASSWORD}';
GRANT REPLICATION SLAVE ON *.* TO '${REPL_USER}'@'%';
-- =====================================================================
-- ENDURECIMIENTO DE LA INSTALACION POR DEFECTO
-- ---------------------------------------------------------------------
-- Equivale a ejecutar mysql_secure_installation.
-- =====================================================================
-- Elimina los usuarios anonimos, que permiten conectarse sin credenciales.
DELETE FROM mysql.global_priv WHERE User = '';
-- Restringe root al acceso local. Impide el inicio de sesion remoto como
-- superusuario incluso desde dentro de la red interna de Docker.
DELETE FROM mysql.global_priv
WHERE User = 'root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
-- Elimina la base de datos de prueba, accesible por cualquier usuario.
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
EOSQL
echo "[+] Usuario de replicacion '${REPL_USER}' creado con privilegio minimo."
echo "[+] Endurecimiento inicial de MariaDB aplicado."
