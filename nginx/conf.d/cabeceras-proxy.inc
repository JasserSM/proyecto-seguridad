# =============================================================================
# CABECERAS DE PROXY INVERSO
# Fragmento reutilizable, incluido desde cada bloque location de wordpress.conf
# =============================================================================
# Nombre de host solicitado por el cliente. Sin esto, WordPress generaria todos
# sus enlaces apuntando a "servidores_wordpress" en lugar de la IP publica.
proxy_set_header Host $host;
# IP real del visitante. Sin esta cabecera, WordPress y los plugins de seguridad
# verian TODAS las peticiones como provenientes de la IP interna de nginx, lo
# que inutilizaria por completo el bloqueo por direccion IP.
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
# CABECERA CRITICA.
# Informa a WordPress de que la conexion original del cliente fue HTTPS, aunque
# el tramo interno entre nginx y el contenedor sea HTTP.
#
# Si se omite, ocurre el fallo mas frecuente de este tipo de montaje: WordPress
# detecta HTTP, aplica FORCE_SSL_ADMIN y redirige a HTTPS; nginx vuelve a
# entregar la peticion por HTTP al contenedor; y el ciclo se repite hasta que el
# navegador aborta con ERR_TOO_MANY_REDIRECTS.
#
# El bloque WORDPRESS_CONFIG_EXTRA del docker-compose.yml lee esta cabecera y
# fija $_SERVER['HTTPS'] = 'on' para cerrar el circulo.
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Host $host;
proxy_set_header X-Forwarded-Port 443;
# Version de HTTP hacia el backend. 1.1 es necesario para keepalive.
proxy_http_version 1.1;
proxy_set_header Connection "";
# Tiempos de espera. Valores contenidos para que un backend colgado se detecte
# rapido y el trafico se desvie al nodo sano en lugar de acumular peticiones.
proxy_connect_timeout 5s;
proxy_send_timeout 60s;
proxy_read_timeout 60s;
# Almacenamiento intermedio de la respuesta del backend.
proxy_buffering on;
proxy_buffer_size 16k;
proxy_buffers 8 16k;
# Elimina las cabeceras que delatan la tecnologia del servidor de aplicacion.
proxy_hide_header X-Powered-By;
proxy_hide_header X-Pingback;
