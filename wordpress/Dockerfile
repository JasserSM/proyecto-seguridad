# =============================================================================
# IMAGEN INMUTABLE DE WORDPRESS
# Proyecto Semestral - Seguridad en los Sistemas de Informacion - UTP FISC
# -----------------------------------------------------------------------------
# CONCEPTO CLAVE: INFRAESTRUCTURA INMUTABLE
#
# Todo lo que este servidor necesita queda congelado dentro de esta imagen
# durante la construccion: extensiones de PHP, endurecimiento del interprete y
# los plugins de seguridad.
#
# La regla operativa del proyecto es:
# NUNCA se repara un contenedor en ejecucion. Se corrige el Dockerfile,
# se reconstruye la imagen y se reemplaza el contenedor.
#
# Por que importa desde el punto de vista de seguridad:
# 1. Reproducibilidad - los dos nodos WordPress son bit a bit identicos.
# No existe la "deriva de configuracion" en la que un
# servidor quedo parchado y el otro no.
# 2. Auditabilidad - el estado del servidor es este archivo, versionado
# en Git. Se sabe exactamente que hay instalado.
# 3. Respuesta a incidentes - ante un compromiso, no se limpia el servidor:
# se destruye y se levanta uno nuevo desde la imagen
# limpia. Cualquier puerta trasera que el atacante
# haya dejado en el sistema de archivos desaparece.
# =============================================================================
# -----------------------------------------------------------------------------
# IMAGEN BASE
# -----------------------------------------------------------------------------
# Se usa la variante "apache" en lugar de "fpm" porque cada contenedor debe ser
# un servidor web completo y autonomo detras del balanceador. Con fpm haria
# falta un nginx adicional dentro de cada nodo, complicando la arquitectura sin
# beneficio para los objetivos de este proyecto.
#
# BUENA PRACTICA DE INMUTABILIDAD: tras la primera construccion, sustituir esta
# etiqueta por el digest exacto para que la imagen sea irrepetiblemente la misma:
# docker image inspect wordpress:php8.3-apache --format='{{index .RepoDigests 0}}'
# FROM wordpress@sha256:<digest>
# -----------------------------------------------------------------------------
FROM wordpress:php8.3-apache
LABEL org.opencontainers.image.title="WordPress endurecido - Proyecto UTP FISC"
LABEL org.opencontainers.image.description="Imagen inmutable de WordPress con plugins de seguridad y PHP endurecido"
LABEL org.opencontainers.image.vendor="Universidad Tecnologica de Panama - FISC"
# -----------------------------------------------------------------------------
# PASO 1: DEPENDENCIAS DEL SISTEMA
# -----------------------------------------------------------------------------
# Se instala lo minimo indispensable y se limpia la cache de apt en la MISMA
# capa. Si se limpiara en una instruccion RUN posterior, los archivos seguirian
# ocupando espacio en la capa anterior y aumentarian innecesariamente la
# superficie de la imagen.
# -----------------------------------------------------------------------------
RUN set -eux; \
apt-get update; \
apt-get install -y --no-install-recommends \
curl \
unzip \
less \
default-mysql-client; \
rm -rf /var/lib/apt/lists/*
# -----------------------------------------------------------------------------
# PASO 2: EXTENSION REDIS PARA PHP
# -----------------------------------------------------------------------------
# Sin esta extension, el plugin Redis Object Cache no puede conectarse y
# WordPress seguiria consultando la base de datos en cada peticion.
# -----------------------------------------------------------------------------
RUN set -eux; \
pecl install redis; \
docker-php-ext-enable redis
# -----------------------------------------------------------------------------
# PASO 3: MODULOS DE APACHE
# -----------------------------------------------------------------------------
# headers : necesario para manipular cabeceras HTTP
# remoteip : traduce la cabecera X-Forwarded-For a la IP real del cliente, para
# que los registros de Apache y los plugins de seguridad vean al
# visitante y no al balanceador
# rewrite : requerido por los enlaces permanentes de WordPress
# -----------------------------------------------------------------------------
RUN a2enmod headers remoteip rewrite
# Configuracion del modulo remoteip: se confia unicamente en el rango privado
# de Docker, nunca en cabeceras provenientes de Internet.
RUN set -eux; \
{ \
echo 'RemoteIPHeader X-Forwarded-For'; \
echo 'RemoteIPTrustedProxy 172.16.0.0/12'; \
echo 'RemoteIPTrustedProxy 192.168.0.0/16'; \
echo 'RemoteIPTrustedProxy 10.0.0.0/8'; \
} > /etc/apache2/conf-available/remoteip.conf; \
a2enconf remoteip
# Oculta la firma de Apache en las respuestas y paginas de error.
RUN set -eux; \
{ \
echo 'ServerTokens Prod'; \
echo 'ServerSignature Off'; \
echo 'TraceEnable Off'; \
} > /etc/apache2/conf-available/endurecimiento.conf; \
a2enconf endurecimiento
# -----------------------------------------------------------------------------
# PASO 4: ENDURECIMIENTO DEL INTERPRETE PHP
# -----------------------------------------------------------------------------
COPY php-endurecimiento.ini /usr/local/etc/php/conf.d/zz-endurecimiento.ini
# -----------------------------------------------------------------------------
# PASO 5: PLUGINS DE SEGURIDAD PREINSTALADOS
# -----------------------------------------------------------------------------
# Los plugins se incorporan a la imagen en tiempo de construccion, NO se
# instalan desde el panel de administracion.
#
# Razon de seguridad: en wp-config.php se define DISALLOW_FILE_MODS = true, que
# desactiva por completo la instalacion de codigo desde el navegador. Es una de
# las medidas de endurecimiento mas efectivas contra el escalamiento de
# privilegios: aunque un atacante consiga credenciales de administrador, no
# puede subir un plugin malicioso, que es la via habitual para obtener ejecucion
# remota de codigo.
#
# El precio es que instalar un plugin nuevo exige reconstruir la imagen. Ese es
# exactamente el compromiso que propone la infraestructura inmutable.
# -----------------------------------------------------------------------------
# Plugins instalados y el pilar de la triada CIA que refuerza cada uno:
#
# wordfence Confidencialidad + Integridad
# Cortafuegos de aplicacion web (WAF) y escaner de malware. Filtra
# inyeccion SQL, XSS e inclusion de archivos antes de que la peticion
# llegue al codigo de WordPress.
#
# limit-login-attempts-reloaded Confidencialidad
# Limita los intentos de inicio de sesion. Segunda capa contra fuerza
# bruta, complementaria a la limitacion de tasa de nginx.
#
# wps-hide-login Confidencialidad
# Reubica /wp-login.php en una ruta personalizada. Elimina de un golpe
# el trafico de los robots que solo conocen la ruta estandar.
#
# sucuri-scanner Integridad
# Monitoreo de integridad de archivos: compara el nucleo instalado con
# los originales de wordpress.org y alerta ante cualquier modificacion,
# que es el indicador clasico de una puerta trasera inyectada.
#
# redis-cache Disponibilidad
# Conecta WordPress con Redis como cache de objetos persistente.
#
# NOTA TECNICA: los comentarios explicativos se mantienen FUERA del bloque RUN.
# Una linea de comentario dentro de una continuacion con "\" puede consumir la
# instruccion siguiente y romper la construccion de forma silenciosa.
WORKDIR /usr/src/wordpress/wp-content/plugins
RUN set -eux; \
descargar_plugin() { \
echo " -> instalando $1"; \
curl -fsSL -o "/tmp/$1.zip" "https://downloads.wordpress.org/plugin/$1.latest-stable.zip"; \
unzip -q -o "/tmp/$1.zip" -d .; \
rm -f "/tmp/$1.zip"; \
}; \
descargar_plugin "wordfence"; \
descargar_plugin "limit-login-attempts-reloaded"; \
descargar_plugin "wps-hide-login"; \
descargar_plugin "sucuri-scanner"; \
descargar_plugin "redis-cache"; \
chown -R www-data:www-data /usr/src/wordpress/wp-content/plugins
# -----------------------------------------------------------------------------
# PASO 6: PERMISOS DEL SISTEMA DE ARCHIVOS
# -----------------------------------------------------------------------------
# Regla general de WordPress: 755 en directorios, 644 en archivos. El servidor
# web no debe poder escribir en el codigo de la aplicacion, solo en uploads.
# -----------------------------------------------------------------------------
WORKDIR /var/www/html
RUN set -eux; \
find /usr/src/wordpress -type d -exec chmod 755 {} \; ; \
find /usr/src/wordpress -type f -exec chmod 644 {} \;
# -----------------------------------------------------------------------------
# PASO 7: VERIFICACION DE SALUD
# -----------------------------------------------------------------------------
# Docker marca el contenedor como "unhealthy" si esta prueba falla, y el
# balanceador deja de recibirlo como nodo valido.
# -----------------------------------------------------------------------------
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
CMD curl -fsS -o /dev/null http://localhost/wp-includes/js/wp-emoji-loader.min.js || exit 1
EXPOSE 80
