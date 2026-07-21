#!/usr/bin/env bash
# =============================================================================
# PUESTA EN MARCHA DE LA REPLICACION PRIMARY-REPLICA
# Proyecto Semestral - Seguridad en los Sistemas de Informacion - UTP FISC
# -----------------------------------------------------------------------------
# Se ejecuta UNA sola vez, desde el host, despues de levantar el stack:
#
# bash scripts/configurar-replica.sh
#
# QUE HACE, EN ORDEN
# ------------------
# 1. Espera a que ambos nodos esten operativos.
# 2. Toma una copia consistente del primario y anota la posicion exacta del
# binlog en la que se tomo.
# 3. Carga esa copia en la replica.
# 4. Apunta la replica al primario en esa posicion y arranca la sincronizacion.
# 5. Verifica que los dos hilos de replicacion quedaron activos.
#
# El paso 2 es el critico. Si se copiaran los datos sin registrar la posicion,
# la replica no sabria desde que punto continuar y quedaria desincronizada de
# forma permanente y silenciosa.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
# Carga las credenciales desde .env sin exponerlas en la linea de comandos.
if [[ ! -f .env ]]; then
echo "ERROR: no se encuentra el archivo .env"
echo " Copielo desde .env.example y complete los valores."
exit 1
fi
set -a; source .env; set +a
PRIMARIO="sec_mariadb_primary"
REPLICA="sec_mariadb_replica"
echo "======================================================================"
echo " CONFIGURACION DE LA REPLICACION MARIADB"
echo "======================================================================"
# -----------------------------------------------------------------------------
# PASO 1: esperar a que ambos nodos respondan.
# -----------------------------------------------------------------------------
esperar_nodo() {
local contenedor="$1"
echo "[*] Esperando a que ${contenedor} este listo..."
for _ in $(seq 1 60); do
if docker exec "${contenedor}" mariadb-admin ping \
-u root -p"${MYSQL_ROOT_PASSWORD}" --silent >/dev/null 2>&1; then
echo "[+] ${contenedor} responde."
return 0
fi
sleep 3
done
echo "ERROR: ${contenedor} no respondio en 180 segundos."
exit 1
}
esperar_nodo "${PRIMARIO}"
esperar_nodo "${REPLICA}"
# -----------------------------------------------------------------------------
# PASO 2: verificar si la replicacion ya esta corriendo (script idempotente).
# -----------------------------------------------------------------------------
ESTADO_ACTUAL=$(docker exec "${REPLICA}" mariadb -u root -p"${MYSQL_ROOT_PASSWORD}" \
-e "SHOW SLAVE STATUS\G" 2>/dev/null | grep "Slave_IO_Running:" | awk '{print $2}' || echo "")
if [[ "${ESTADO_ACTUAL}" == "Yes" ]]; then
echo "[=] La replicacion ya se encuentra activa. No se realizan cambios."
docker exec "${REPLICA}" mariadb -u root -p"${MYSQL_ROOT_PASSWORD}" \
-e "SHOW SLAVE STATUS\G" 2>/dev/null | \
grep -E "Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master|Last_Error"
exit 0
fi
# -----------------------------------------------------------------------------
# PASO 3: copia consistente del primario.
#
# --single-transaction : abre una transaccion con vista consistente. Permite
# volcar sin bloquear las escrituras de la aplicacion.
# --master-data=2 : escribe la posicion exacta del binlog como comentario
# en la cabecera del volcado. Es el dato que sincroniza
# los datos con el punto de arranque de la replica.
# --routines/--triggers/--events : incluye objetos de logica, no solo tablas.
# -----------------------------------------------------------------------------
echo "[*] Generando volcado consistente del nodo primario..."
docker exec "${PRIMARIO}" mariadb-dump \
-u root -p"${MYSQL_ROOT_PASSWORD}" \
--single-transaction \
--master-data=2 \
--routines --triggers --events \
--databases "${MYSQL_DATABASE}" > /tmp/volcado-primario.sql
# -----------------------------------------------------------------------------
# PASO 4: extraer la coordenada del binlog desde la cabecera del volcado.
# -----------------------------------------------------------------------------
ARCHIVO_LOG=$(grep -m1 "CHANGE MASTER TO" /tmp/volcado-primario.sql | \
sed -n "s/.*MASTER_LOG_FILE='\([^']*\)'.*/\1/p")
POSICION_LOG=$(grep -m1 "CHANGE MASTER TO" /tmp/volcado-primario.sql | \
sed -n "s/.*MASTER_LOG_POS=\([0-9]*\).*/\1/p")
if [[ -z "${ARCHIVO_LOG}" || -z "${POSICION_LOG}" ]]; then
echo "ERROR: no se pudo determinar la posicion del binlog."
echo " Verifique que log-bin este activo en primary.cnf."
exit 1
fi
echo "[+] Coordenada de sincronizacion: archivo=${ARCHIVO_LOG} posicion=${POSICION_LOG}"
# -----------------------------------------------------------------------------
# PASO 5: cargar el volcado en la replica.
# Se desactiva temporalmente read_only, que de lo contrario rechazaria la carga.
# -----------------------------------------------------------------------------
echo "[*] Cargando el volcado en el nodo replica..."
docker exec -i "${REPLICA}" mariadb -u root -p"${MYSQL_ROOT_PASSWORD}" \
-e "SET GLOBAL read_only = 0;"
docker exec -i "${REPLICA}" mariadb -u root -p"${MYSQL_ROOT_PASSWORD}" \
< /tmp/volcado-primario.sql
# -----------------------------------------------------------------------------
# PASO 6: apuntar la replica al primario y arrancar.
#
# MASTER_HOST usa el nombre del servicio de Docker Compose, que el DNS interno
# de Docker resuelve a la IP del contenedor. No se fija ninguna IP.
# -----------------------------------------------------------------------------
echo "[*] Estableciendo el enlace de replicacion..."
docker exec -i "${REPLICA}" mariadb -u root -p"${MYSQL_ROOT_PASSWORD}" <<EOSQL
STOP SLAVE;
RESET SLAVE ALL;
CHANGE MASTER TO
MASTER_HOST = 'mariadb-primary',
MASTER_PORT = 3306,
MASTER_USER = '${REPL_USER}',
MASTER_PASSWORD = '${REPL_PASSWORD}',
MASTER_LOG_FILE = '${ARCHIVO_LOG}',
MASTER_LOG_POS = ${POSICION_LOG},
MASTER_CONNECT_RETRY = 10;
START SLAVE;
SET GLOBAL read_only = 1;
EOSQL
rm -f /tmp/volcado-primario.sql
# -----------------------------------------------------------------------------
# PASO 7: verificacion.
#
# Los dos hilos deben reportar "Yes":
# Slave_IO_Running -> descarga los eventos del primario
# Slave_SQL_Running -> los aplica sobre los datos locales
#
# Si uno dice "No", la causa aparece en Last_IO_Error o Last_SQL_Error.
# -----------------------------------------------------------------------------
echo "[*] Esperando la sincronizacion inicial..."
sleep 5
echo ""
echo "======================================================================"
echo " ESTADO DE LA REPLICACION"
echo "======================================================================"
docker exec "${REPLICA}" mariadb -u root -p"${MYSQL_ROOT_PASSWORD}" \
-e "SHOW SLAVE STATUS\G" 2>/dev/null | \
grep -E "Master_Host|Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master|Last_IO_Error|Last_SQL_Error"
echo ""
echo "----------------------------------------------------------------------"
echo " PRUEBA FUNCIONAL (evidencia para la documentacion)"
echo "----------------------------------------------------------------------"
echo "[*] Escribiendo un registro de prueba en el PRIMARIO..."
docker exec "${PRIMARIO}" mariadb -u root -p"${MYSQL_ROOT_PASSWORD}" "${MYSQL_DATABASE}" \
-e "CREATE TABLE IF NOT EXISTS prueba_replicacion (
id INT AUTO_INCREMENT PRIMARY KEY,
momento DATETIME,
nota VARCHAR(120)
);
INSERT INTO prueba_replicacion (momento, nota)
VALUES (NOW(), 'Registro escrito unicamente en el nodo primario');" 2>/dev/null
sleep 3
echo "[*] Leyendo ese mismo registro desde la REPLICA..."
docker exec "${REPLICA}" mariadb -u root -p"${MYSQL_ROOT_PASSWORD}" "${MYSQL_DATABASE}" \
-e "SELECT * FROM prueba_replicacion ORDER BY id DESC LIMIT 3;" 2>/dev/null
echo ""
echo "Si el registro aparece arriba, la replicacion funciona correctamente."
echo "Capture esta salida como evidencia del proyecto."
echo "======================================================================"
