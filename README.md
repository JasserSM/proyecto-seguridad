[README-seguridad.md](https://github.com/user-attachments/files/33583594/README-seguridad.md)
# Infraestructura Web Endurecida con Alta Disponibilidad y Despliegue Continuo

Implementación de una infraestructura WordPress endurecida sobre AWS EC2, diseñada bajo los tres pilares de la seguridad de la información (confidencialidad, integridad y disponibilidad). Combina alta disponibilidad, infraestructura inmutable, segmentación de red y un canal de CI/CD con controles de seguridad obligatorios.

> Proyecto académico — Seguridad Informática, Universidad Tecnológica de Panamá (UTP). Proyecto en equipo.

---

## Arquitectura

Arquitectura multicapa con redes aisladas. El único servicio expuesto a Internet es el balanceador Nginx (puerto 443):

```
Internet -> Nginx (balanceador, TLS 1.2, rate limiting)
              |-- WordPress 1 (contenedor, imagen inmutable)
              |-- WordPress 2 (contenedor, imagen inmutable)
                     |-- [red backend interna, sin salida a Internet]
                            |-- MariaDB primario (escrituras + binlog)
                            |-- MariaDB replica (solo lectura)
                            |-- Redis (cache de objetos)
```

## Caracteristicas principales

**Alta disponibilidad**
- Balanceador Nginx con algoritmo `least_conn` y verificacion de salud pasiva.
- Dos nodos WordPress redundantes: la caida de uno no interrumpe el servicio (verificado con pruebas).
- Replicacion MariaDB primario-replica con binlog y recuperacion a punto en el tiempo.

**Confidencialidad**
- TLS 1.2 con conjuntos de cifrado de intercambio efimero (PFS), certificado RSA 4096 bits.
- Segmentacion de red: la capa de datos no es alcanzable desde Internet.
- Credenciales en variables de entorno (`.env` con permiso 600), fuera del codigo, excluidas del repositorio.
- Rate limiting, Fail2ban y reubicacion de la ruta de login (defensa en profundidad contra fuerza bruta).

**Integridad**
- Imagenes Docker inmutables: los servidores no se modifican, se reconstruyen y reemplazan.
- Endurecimiento de PHP (`disable_functions`, `open_basedir`) para neutralizar web shells.
- Respaldos verificados con sumas SHA-256.

**Automatizacion (CI/CD)**
- Canal en GitHub Actions: analisis estatico (Hadolint, ShellCheck), deteccion de secretos (Gitleaks) y escaneo de vulnerabilidades (Trivy) que bloquea el despliegue ante severidad critica/alta.
- Despliegue progresivo que reemplaza nodos sin interrumpir el servicio.

## Stack

- **Nube:** AWS EC2 (Ubuntu Server 22.04)
- **Contenedores:** Docker + Docker Compose
- **Balanceador / TLS:** Nginx
- **Base de datos:** MariaDB (primario + replica)
- **Cache:** Redis
- **Aplicacion:** WordPress (imagen inmutable endurecida)
- **CI/CD:** GitHub Actions (Hadolint, ShellCheck, Gitleaks, Trivy)
- **Endurecimiento del host:** UFW, Fail2ban, SSH por llave

## Estructura del repositorio

```
proyecto-seguridad/
├── .github/workflows/    # Pipeline de CI/CD
├── mariadb/              # Configuracion primario, replica e init
├── nginx/                # Balanceador, TLS, cabeceras de seguridad
├── scripts/              # Certificado, respaldo, replica, pruebas
├── wordpress/            # Dockerfile inmutable y endurecimiento PHP
├── docker-compose.yml
└── .env.example          # Plantilla de variables (sin secretos)
```

## Como ejecutar

```bash
cp .env.example .env
# Editar .env con las credenciales propias
chmod +x scripts/*.sh
docker compose up -d --build
```

## Verificaciones realizadas

- Prueba de alta disponibilidad: con un nodo detenido, el sitio sigue respondiendo (HTTP 200).
- Rate limiting: solicitudes excedentes reciben codigo 429.
- TLS: `nmap` confirma unicamente TLS 1.2 con cifrados de calificacion A.
- Replicacion: registro escrito en el primario y leido desde la replica.
- Segmentacion: solo el balanceador publica puertos al exterior.

## Limitaciones reconocidas

Toda la infraestructura reside en una unica instancia EC2, por lo que la falla del anfitrion interrumpe el servicio; el balanceador es un punto unico de falla. El certificado autofirmado provee cifrado equivalente al de una autoridad, pero no verificacion de identidad por un tercero. En un entorno productivo, los registros requeririan agregacion centralizada.

## Autoria

Proyecto en equipo (grupo 1SG141). Contribucion propia: aprovisionamiento y endurecimiento del host, segmentacion de red, certificado TLS, imagen inmutable de la aplicacion y balanceador. La arquitectura, la capa de datos con replicacion y el canal de CI/CD fueron liderados por otra integrante del equipo.

---

*Proyecto con fines academicos. No contiene credenciales ni material sensible; los secretos se gestionan por variables de entorno excluidas del repositorio.*
