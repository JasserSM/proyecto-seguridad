#!/usr/bin/env bash
# =============================================================================
# PRUEBA DE ALTA DISPONIBILIDAD
# Proyecto Semestral - Seguridad en los Sistemas de Informacion - UTP FISC
# -----------------------------------------------------------------------------
# Este script genera la evidencia central del proyecto: demuestra que el sitio
# permanece disponible aunque se destruya uno de los nodos de aplicacion.
#
# Uso:
# bash scripts/prueba-alta-disponibilidad.sh
#
# Se recomienda ejecutarlo durante la sustentacion, en vivo, y adjuntar la
# salida completa al documento.
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
URL="${WP_URL}"
TOTAL_PETICIONES=40
# -k acepta el certificado autofirmado. En este contexto es correcto: la
# advertencia se debe a que el certificado no lo emitio una autoridad publica,
# no a un defecto criptografico del cifrado.
CURL="curl -sk -o /dev/null -w %{http_code}"
separador() { echo "----------------------------------------------------------------------"; }
echo "======================================================================"
echo " PRUEBA DE ALTA DISPONIBILIDAD"
echo " Destino: ${URL}"
echo "======================================================================"
# -----------------------------------------------------------------------------
# ESCENARIO 1: estado normal, ambos nodos activos.
# Se verifica que el balanceador reparte el trafico entre los dos.
# -----------------------------------------------------------------------------
separador
echo " ESCENARIO 1 - Operacion normal (dos nodos activos)"
separador
echo "[*] Enviando ${TOTAL_PETICIONES} peticiones..."
for _ in $(seq 1 ${TOTAL_PETICIONES}); do
${CURL} "${URL}/" > /dev/null
done
echo "[*] Distribucion real del trafico segun el registro de nginx:"
docker exec sec_nginx sh -c \
"tail -n ${TOTAL_PETICIONES} /var/log/nginx/access.log | grep -o 'servidor_backend=[^ ]*' | sort | uniq -c"
echo ""
echo " Se deben observar AMBOS nodos. Esa es la prueba del balanceo de carga."
# -----------------------------------------------------------------------------
# ESCENARIO 2: falla del nodo wordpress1.
# -----------------------------------------------------------------------------
separador
echo " ESCENARIO 2 - Falla del nodo wordpress1"
separador
echo "[*] Deteniendo sec_wordpress1 de forma abrupta..."
docker stop sec_wordpress1 >/dev/null 2>&1
echo "[*] Comprobando la disponibilidad del sitio con un nodo caido..."
EXITOS=0
FALLOS=0
for _ in $(seq 1 20); do
CODIGO=$(${CURL} "${URL}/")
if [[ "${CODIGO}" == "200" || "${CODIGO}" == "302" ]]; then
EXITOS=$((EXITOS + 1))
else
FALLOS=$((FALLOS + 1))
echo " respuesta inesperada: HTTP ${CODIGO}"
fi
done
echo ""
echo " Peticiones exitosas : ${EXITOS} de 20"
echo " Peticiones fallidas : ${FALLOS} de 20"
echo ""
if [[ ${FALLOS} -eq 0 ]]; then
echo " RESULTADO: el sitio permanecio 100% disponible con un nodo caido."
echo " La alta disponibilidad esta demostrada."
else
echo " ATENCION: hubo peticiones fallidas. Revisar max_fails y fail_timeout"
echo " en el bloque upstream de nginx/nginx.conf."
fi
echo ""
echo "[*] Nodo que atendio el trafico durante la falla:"
docker exec sec_nginx sh -c \
"tail -n 20 /var/log/nginx/access.log | grep -o 'servidor_backend=[^ ]*' | sort | uniq -c"
# -----------------------------------------------------------------------------
# ESCENARIO 3: recuperacion automatica.
# -----------------------------------------------------------------------------
separador
echo " ESCENARIO 3 - Recuperacion del nodo"
separador
echo "[*] Levantando nuevamente sec_wordpress1..."
docker start sec_wordpress1 >/dev/null 2>&1
echo "[*] Esperando a que supere su verificacion de salud..."
for _ in $(seq 1 30); do
ESTADO=$(docker inspect --format='{{.State.Health.Status}}' sec_wordpress1 2>/dev/null || echo "starting")
if [[ "${ESTADO}" == "healthy" ]]; then
echo "[+] El nodo esta saludable nuevamente."
break
fi
sleep 3
done
echo "[*] Reenviando trafico para confirmar la reincorporacion..."
for _ in $(seq 1 ${TOTAL_PETICIONES}); do
${CURL} "${URL}/" > /dev/null
done
docker exec sec_nginx sh -c \
"tail -n ${TOTAL_PETICIONES} /var/log/nginx/access.log | grep -o 'servidor_backend=[^ ]*' | sort | uniq -c"
echo ""
echo " Ambos nodos deben aparecer de nuevo: nginx reincorporo automaticamente"
echo " el nodo recuperado, sin intervencion manual."
# -----------------------------------------------------------------------------
# ESCENARIO 4: verificacion de la configuracion TLS.
# -----------------------------------------------------------------------------
separador
echo " ESCENARIO 4 - Verificacion de TLS"
separador
IP=$(echo "${URL}" | sed 's|https://||')
echo "[*] Comprobando que TLS 1.2 esta ACEPTADO:"
if echo | openssl s_client -connect "${IP}:443" -tls1_2 2>/dev/null | grep -q "Protocol.*TLSv1.2"; then
echo " CORRECTO - la conexion por TLS 1.2 fue aceptada."
else
echo " Revisar: no se pudo negociar TLS 1.2."
fi
echo ""
echo "[*] Comprobando que TLS 1.3 esta RECHAZADO (solo se admite TLS 1.2):"
if echo | openssl s_client -connect "${IP}:443" -tls1_3 2>&1 | grep -qi "alert\|failure\|error"; then
echo " CORRECTO - TLS 1.3 fue rechazado, conforme a ssl_protocols TLSv1.2."
else
echo " Revisar la directiva ssl_protocols en nginx/conf.d/wordpress.conf."
fi
echo ""
echo "[*] Datos del certificado en uso:"
echo | openssl s_client -connect "${IP}:443" 2>/dev/null | \
openssl x509 -noout -subject -dates -ext subjectAltName 2>/dev/null
echo ""
echo "[*] Verificando la redireccion de HTTP a HTTPS:"
CODIGO_HTTP=$(curl -s -o /dev/null -w "%{http_code}" "http://${IP}/")
echo " Peticion a http://${IP}/ -> HTTP ${CODIGO_HTTP}"
echo " Se espera 301 (redireccion permanente hacia HTTPS)."
# -----------------------------------------------------------------------------
# ESCENARIO 5: aislamiento de la capa de datos.
# -----------------------------------------------------------------------------
separador
echo " ESCENARIO 5 - Aislamiento de la base de datos"
separador
echo "[*] Intentando conectar a MariaDB desde fuera del host (puerto 3306):"
if timeout 5 bash -c "cat < /dev/null > /dev/tcp/${IP}/3306" 2>/dev/null; then
echo " FALLA DE SEGURIDAD: el puerto 3306 esta accesible desde el exterior."
else
echo " CORRECTO - conexion rechazada. La base de datos no es alcanzable"
echo " desde Internet: no publica puerto y vive en una red interna."
fi
echo ""
echo "[*] Intentando conectar a Redis desde fuera del host (puerto 6379):"
if timeout 5 bash -c "cat < /dev/null > /dev/tcp/${IP}/6379" 2>/dev/null; then
echo " FALLA DE SEGURIDAD: el puerto 6379 esta accesible desde el exterior."
else
echo " CORRECTO - conexion rechazada."
fi
separador
echo " PRUEBAS FINALIZADAS"
echo " Capture la salida completa de este script como evidencia del proyecto."
separador
