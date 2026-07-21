#!/usr/bin/env bash
# =============================================================================
# RESPALDO AUTOMATIZADO
# Proyecto Semestral - Seguridad en los Sistemas de Informacion - UTP FISC
# -----------------------------------------------------------------------------
# Programacion recomendada (crontab del usuario ubuntu, 2:00 a.m. diario):
#
# crontab -e
# 0 2 * * * /home/ubuntu/proyecto-seguridad/scripts/respaldo.sh >> \
# /home/ubuntu/respaldos/respaldo.log 2>&1
#
# QUE PILAR DE LA TRIADA CIA CUBRE
# --------------------------------
# DISPONIBILIDAD e INTEGRIDAD. La replica protege frente a la caida del proceso
# de base de datos, pero NO frente al borrado o la corrupcion logica: si se
# elimina una tabla por error, la replica replica fielmente ese borrado en
# segundos. El respaldo historico es la unica defensa contra ese escenario, y
# tambien contra el ransomware.
#
# El volcado se toma desde la REPLICA, no desde el primario, para no imponer
# ninguna carga adicional al nodo que atiende a la aplicacion.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
DIR_RESPALDOS="${HOME}/respaldos"
DIAS_RETENCION=7
MARCA=$(date +%Y%m%d_%H%M%S)
mkdir -p "${DIR_RESPALDOS}"
chmod 700 "${DIR_RESPALDOS}"
echo "======================================================================"
echo " RESPALDO ${MARCA}"
echo "======================================================================"
# -----------------------------------------------------------------------------
# PASO 1: base de datos.
# Se toma de la replica. Si no estuviera disponible, se recurre al primario.
# -----------------------------------------------------------------------------
ORIGEN="sec_mariadb_replica"
if ! docker exec "${ORIGEN}" mariadb-admin ping -u root \
-p"${MYSQL_ROOT_PASSWORD}" --silent >/dev/null 2>&1; then
echo "[!] La replica no responde. Se respalda desde el primario."
ORIGEN="sec_mariadb_primary"
fi
ARCHIVO_BD="${DIR_RESPALDOS}/bd_${MARCA}.sql.gz"
echo "[*] Volcando la base de datos desde ${ORIGEN}..."
docker exec "${ORIGEN}" mariadb-dump \
-u root -p"${MYSQL_ROOT_PASSWORD}" \
--single-transaction \
--routines --triggers --events \
--databases "${MYSQL_DATABASE}" 2>/dev/null | gzip > "${ARCHIVO_BD}"
# -----------------------------------------------------------------------------
# PASO 2: archivos subidos por los usuarios.
# No estan en la imagen de Docker, viven en un volumen. Si se pierde el volumen
# se pierden todas las imagenes y documentos del sitio.
# -----------------------------------------------------------------------------
ARCHIVO_UPLOADS="${DIR_RESPALDOS}/uploads_${MARCA}.tar.gz"
echo "[*] Empaquetando el volumen de archivos subidos..."
docker run --rm --user "$(id -u):$(id -g)" \
-v proyecto-seguridad_uploads:/datos:ro \
-v "${DIR_RESPALDOS}":/destino \
alpine:3.20 \
tar czf "/destino/uploads_${MARCA}.tar.gz" -C /datos . 2>/dev/null
# -----------------------------------------------------------------------------
# PASO 3: verificacion de integridad.
#
# Un respaldo que no se verifica no es un respaldo: es una suposicion. Se
# comprueba que el archivo comprimido no esta truncado y se calcula su suma
# SHA-256, que permite detectar mas adelante cualquier alteracion del archivo.
# -----------------------------------------------------------------------------
echo "[*] Verificando la integridad de los archivos generados..."
if ! gzip -t "${ARCHIVO_BD}" 2>/dev/null; then
echo "ERROR: el respaldo de la base de datos esta corrupto."
exit 1
fi
if ! gzip -t "${ARCHIVO_UPLOADS}" 2>/dev/null; then
echo "ERROR: el respaldo de archivos esta corrupto."
exit 1
fi
sha256sum "${ARCHIVO_BD}" "${ARCHIVO_UPLOADS}" \
> "${DIR_RESPALDOS}/sumas_${MARCA}.sha256"
chmod 600 "${ARCHIVO_BD}" "${ARCHIVO_UPLOADS}"
# -----------------------------------------------------------------------------
# PASO 4: rotacion.
# Sin rotacion, el disco de la instancia se llena y el servidor deja de
# responder. Un respaldo mal gestionado se convierte en la causa de la caida
# que pretendia evitar.
# -----------------------------------------------------------------------------
echo "[*] Eliminando respaldos de mas de ${DIAS_RETENCION} dias..."
find "${DIR_RESPALDOS}" -name "bd_*.sql.gz" -mtime +${DIAS_RETENCION} -delete
find "${DIR_RESPALDOS}" -name "uploads_*.tar.gz" -mtime +${DIAS_RETENCION} -delete
find "${DIR_RESPALDOS}" -name "sumas_*.sha256" -mtime +${DIAS_RETENCION} -delete
echo ""
echo "----------------------------------------------------------------------"
echo " RESPALDO COMPLETADO"
echo "----------------------------------------------------------------------"
ls -lh "${DIR_RESPALDOS}" | tail -n 10
echo ""
echo " Espacio en disco:"
df -h / | tail -n 1
echo "----------------------------------------------------------------------"
# =============================================================================
# COMO RESTAURAR
# -----------------------------------------------------------------------------
# Base de datos:
# gunzip < ~/respaldos/bd_FECHA.sql.gz | \
# docker exec -i sec_mariadb_primary mariadb -u root -pCONTRASENA
#
# Archivos subidos:
# docker run --rm -v proyecto-seguridad_uploads:/datos \
# -v ~/respaldos:/origen alpine:3.20 \
# tar xzf /origen/uploads_FECHA.tar.gz -C /datos
#
# IMPORTANTE: el equipo debe ENSAYAR la restauracion al menos una vez y
# documentarla. Un procedimiento de restauracion nunca probado tiene una
# probabilidad alta de fallar justo cuando se necesita.
# =============================================================================
