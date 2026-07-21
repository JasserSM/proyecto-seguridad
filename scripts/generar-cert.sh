#!/bin/sh
# =============================================================================
# GENERACION DEL CERTIFICADO TLS AUTOFIRMADO
# Proyecto Semestral - Seguridad en los Sistemas de Informacion - UTP FISC
# -----------------------------------------------------------------------------
# Este script se ejecuta automaticamente en CADA arranque del stack, antes de
# que nginx levante.
#
# PROBLEMA QUE RESUELVE
# ---------------------
# En AWS Academy Learner Lab, al pulsar "End Lab" la instancia EC2 se detiene.
# Al reiniciarla, AWS le asigna una IP publica DISTINTA (salvo que se tenga una
# Elastic IP asociada). Como nuestro certificado autofirmado lleva la IP en el
# campo SAN, quedaria invalido en cada sesion de laboratorio.
#
# SOLUCION
# --------
# En vez de reconfigurar a mano, el sistema consulta su propia IP publica al
# arrancar y regenera el certificado si esta cambio. Es la aplicacion practica
# del principio de INFRAESTRUCTURA INMUTABLE: el servidor no conserva estado
# configurado manualmente, se autoconfigura desde su entorno en cada arranque.
# =============================================================================
set -eu
DIR_CERTS="/certs"
ARCHIVO_CERT="${DIR_CERTS}/servidor.crt"
ARCHIVO_LLAVE="${DIR_CERTS}/servidor.key"
ARCHIVO_DHPARAM="${DIR_CERTS}/dhparam.pem"
ARCHIVO_IP="${DIR_CERTS}/.ip-emitida"
BITS="${CERT_BITS:-4096}"
DIAS="${CERT_DAYS:-365}"
PAIS="${CERT_PAIS:-PA}"
ORG="${CERT_ORG:-UTP-FISC}"
echo "======================================================================"
echo " Generacion de certificado TLS autofirmado"
echo "======================================================================"
# -----------------------------------------------------------------------------
# PASO 1: instalar las herramientas necesarias dentro del contenedor efimero.
# -----------------------------------------------------------------------------
apk add --no-cache openssl curl >/dev/null 2>&1
# -----------------------------------------------------------------------------
# PASO 2: determinar la IP publica actual.
#
# Se usa IMDSv2 (Instance Metadata Service version 2), que exige obtener primero
# un token de sesion mediante PUT y luego enviarlo en cada consulta. IMDSv2 es
# la version segura del servicio de metadatos: mitiga los ataques SSRF que en
# IMDSv1 permitian a una aplicacion web comprometida leer las credenciales del
# rol de la instancia con una simple peticion GET.
# -----------------------------------------------------------------------------
IP_PUBLICA=""
if [ -n "${CERT_IP_MANUAL:-}" ]; then
# Permite forzar una IP concreta (por ejemplo, una Elastic IP fija)
IP_PUBLICA="${CERT_IP_MANUAL}"
echo "[*] Usando la IP declarada manualmente en .env : ${IP_PUBLICA}"
else
echo "[*] Consultando la IP publica de la instancia via IMDSv2..."
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
-H "X-aws-ec2-metadata-token-ttl-seconds: 300" \
--max-time 3 2>/dev/null || true)
if [ -n "${TOKEN}" ]; then
IP_PUBLICA=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" \
"http://169.254.169.254/latest/meta-data/public-ipv4" \
--max-time 3 2>/dev/null || true)
fi
fi
# Respaldo: si no estamos en EC2 (por ejemplo, pruebas en una maquina local)
if [ -z "${IP_PUBLICA}" ]; then
IP_PUBLICA="127.0.0.1"
echo "[!] No se detecto metadato de EC2. Se usara ${IP_PUBLICA} (modo local)."
else
echo "[+] IP publica detectada: ${IP_PUBLICA}"
fi
# -----------------------------------------------------------------------------
# PASO 3: decidir si hace falta regenerar.
# Si el certificado ya existe y fue emitido para esta misma IP, no se toca.
# -----------------------------------------------------------------------------
if [ -f "${ARCHIVO_CERT}" ] && [ -f "${ARCHIVO_IP}" ]; then
IP_ANTERIOR=$(cat "${ARCHIVO_IP}")
if [ "${IP_ANTERIOR}" = "${IP_PUBLICA}" ]; then
echo "[=] El certificado vigente ya corresponde a ${IP_PUBLICA}."
echo "[=] No es necesario regenerarlo. Finalizando."
exit 0
fi
echo "[!] La IP cambio: ${IP_ANTERIOR} -> ${IP_PUBLICA}. Se regenera."
fi
# -----------------------------------------------------------------------------
# PASO 4: construir el archivo de configuracion de OpenSSL.
#
# El campo SAN (Subject Alternative Name) es OBLIGATORIO. Desde 2017 los
# navegadores basados en Chromium ignoran por completo el Common Name (CN) y
# solo validan el SAN. Un certificado sin SAN es rechazado con el error
# ERR_CERT_COMMON_NAME_INVALID incluso antes de mostrar la advertencia de
# certificado autofirmado.
# -----------------------------------------------------------------------------
cat > /tmp/openssl.cnf <<EOF
[ req ]
default_bits = ${BITS}
prompt = no
default_md = sha256
distinguished_name = dn
x509_extensions = v3_ca
[ dn ]
C = ${PAIS}
ST = Panama
L = Panama
O = ${ORG}
OU = Facultad de Ingenieria de Sistemas Computacionales
CN = ${IP_PUBLICA}
[ v3_ca ]
subjectAltName = @alt_names
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
[ alt_names ]
IP.1 = ${IP_PUBLICA}
IP.2 = 127.0.0.1
DNS.1 = localhost
EOF
# -----------------------------------------------------------------------------
# PASO 5: emitir la llave privada y el certificado.
#
# req -x509 : genera un certificado autofirmado (no una solicitud CSR)
# -newkey rsa:N : crea una llave RSA nueva de N bits en el mismo comando
# -nodes : "no DES", guarda la llave sin cifrar con passphrase, para
# que nginx pueda arrancar sin intervencion humana
# -sha256 : algoritmo de firma. SHA-1 esta obsoleto y es rechazado.
# -days : periodo de validez
# -----------------------------------------------------------------------------
echo "[*] Emitiendo certificado RSA de ${BITS} bits, valido por ${DIAS} dias..."
openssl req -x509 \
-newkey "rsa:${BITS}" \
-sha256 \
-days "${DIAS}" \
-nodes \
-keyout "${ARCHIVO_LLAVE}" \
-out "${ARCHIVO_CERT}" \
-config /tmp/openssl.cnf \
-extensions v3_ca 2>/dev/null
# -----------------------------------------------------------------------------
# PASO 6: generar los parametros Diffie-Hellman.
#
# Refuerzan el intercambio de llaves DHE y garantizan Perfect Forward Secrecy:
# si en el futuro alguien roba la llave privada del servidor, NO puede descifrar
# el trafico que capturo en el pasado, porque cada sesion negocio una llave
# efimera independiente.
#
# Se usan 2048 bits: con 4096 la generacion tarda varios minutos y el beneficio
# de seguridad real es marginal frente al costo de arranque.
# -----------------------------------------------------------------------------
if [ ! -f "${ARCHIVO_DHPARAM}" ]; then
echo "[*] Generando parametros Diffie-Hellman de 2048 bits (puede tardar)..."
openssl dhparam -out "${ARCHIVO_DHPARAM}" 2048 2>/dev/null
fi
# -----------------------------------------------------------------------------
# PASO 7: permisos restrictivos sobre la llave privada.
# 600 = solo el propietario puede leer y escribir. Confidencialidad.
# -----------------------------------------------------------------------------
chmod 600 "${ARCHIVO_LLAVE}"
chmod 644 "${ARCHIVO_CERT}" "${ARCHIVO_DHPARAM}"
echo "${IP_PUBLICA}" > "${ARCHIVO_IP}"
# -----------------------------------------------------------------------------
# PASO 8: mostrar el resultado como evidencia para la documentacion.
# -----------------------------------------------------------------------------
echo ""
echo "----------------------------------------------------------------------"
echo " CERTIFICADO EMITIDO CORRECTAMENTE"
echo "----------------------------------------------------------------------"
openssl x509 -in "${ARCHIVO_CERT}" -noout \
-subject -issuer -dates \
-ext subjectAltName 2>/dev/null
echo ""
echo " Tamano de la llave:"
openssl rsa -in "${ARCHIVO_LLAVE}" -noout -text 2>/dev/null | head -n 1
echo ""
echo " URL de acceso al sitio: https://${IP_PUBLICA}"
echo "----------------------------------------------------------------------"
