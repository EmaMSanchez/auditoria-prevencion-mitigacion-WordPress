# WordPress Security Toolkit

Conjunto de scripts Bash para auditoría, hardening y respuesta a incidentes en instalaciones WordPress en producción.

Cubre el ciclo completo de seguridad: desde establecer una línea base en un servidor limpio hasta la remediación guiada después de un compromiso confirmado.

---

## Requisitos

- **Bash** 4.x o superior
- **WP-CLI** instalado y disponible en el PATH —> [Guía de instalación](https://wp-cli.org/#installing)
- **WPScan** —> solo para `audit-externo.sh` — [Guía de instalación](https://github.com/wpscanteam/wpscan#installation)
- **Token de API de WPScan** —> gratuito en [wpscan.com](https://wpscan.com) —> solo para `audit-externo.sh`
- **openssl** —> disponible por defecto en la mayoría de distribuciones Linux
- Acceso SSH al servidor con permisos de lectura sobre el directorio de WordPress

---

## Ciclo completo

```
[ SERVIDOR LIMPIO / RECIÉN INSTALADO ]
            │
            ▼
       baseline.sh          ← foto del estado inicial del servidor
            │
            ▼
       hardening.sh         ← cierra lo que WordPress deja abierto por defecto
            │
            ▼
  audit-interno-diario.sh   ← cron a las 6am, revisa cambios cada 24hs
  audit-externo.sh          ← visión externa del sitio, correr a demanda
            │
            │  (incidente detectado)
            ▼
       containment.sh       ← snapshot forense + contención inmediata
            │
            ▼
  audit-post-incidente.sh   ← análisis forense completo, genera hallazgos
            │
            ▼
       remediacion.sh       ← limpieza guiada por el archivo de hallazgos
            │
            ▼
       hardening.sh         ← reforzar configuración post-incidente
       baseline.sh          ← regenerar línea base con el servidor limpio
            │
            └── (vuelve al ciclo de auditoría diaria)
```

---

## Scripts

### `baseline.sh` — Línea base del servidor

Genera la fotografía del servidor en estado limpio. Es el punto de referencia que usan los scripts de auditoría para detectar cambios.

**Cuándo correrlo:** una sola vez sobre un servidor limpio o recién instalado. También después de cada actualización mayor del core o después de una remediación.

```bash
bash baseline.sh /ruta/al/wordpress
```

**Qué genera** (en `~/.wp-baseline/`):

| Archivo | Contenido |
|---|---|
| `baseline-hashes.sha256` | Hash SHA-256 de cada archivo PHP del sitio |
| `baseline-users.txt` | Usuarios y roles registrados |
| `baseline-plugins.txt` | Plugins activos con versiones |
| `baseline-options.txt` | Opciones críticas de la DB (siteurl, home, admin_email) |
| `baseline-defines.txt` | Defines de seguridad en wp-config.php |
| `baseline-permisos.txt` | Permisos de archivos y carpetas |
| `baseline-version.txt` | Versión del core de WordPress |
| `baseline-fecha.txt` | Timestamp de la generación |

> **⚠️ No sobreescribir el baseline durante un incidente activo.** El script detecta si ya existe un baseline y pide confirmación antes de reemplazarlo. Sobreescribir la referencia mientras se investiga un compromiso elimina la capacidad de comparación.

---

### `hardening.sh` — Configuración de seguridad

Aplica configuraciones de seguridad sobre una instalación WordPress. Interactivo: pide confirmación antes de cada cambio y genera backup de `wp-config.php` antes de modificarlo.

```bash
bash hardening.sh /ruta/al/wordpress
```

**Qué aplica:**

- `DISALLOW_FILE_EDIT` — deshabilita el editor de archivos PHP desde el panel de administración
- `DISALLOW_FILE_MODS` (nivel 2, opcional) — bloquea además la instalación y actualización de plugins desde el panel; las actualizaciones pasan a requerir WP-CLI
- `FORCE_SSL_ADMIN` — fuerza HTTPS en el login y el panel
- `WP_DEBUG false` — sin mensajes de error visibles en producción
- `DISABLE_WP_CRON true` — reemplaza el cron interno por cron real del servidor
- Permisos: archivos PHP → 644, carpetas → 755, wp-config.php → 600
- Elimina archivos de information disclosure: `readme.html`, `license.txt`, `wp-trackback.php`

> **Sobre los niveles de restricción:**
> - **Nivel 1** — solo `DISALLOW_FILE_EDIT`. El cliente puede seguir instalando y actualizando plugins desde el panel. Recomendado cuando el sitio lo administra el cliente.
> - **Nivel 2** — `DISALLOW_FILE_EDIT` + `DISALLOW_FILE_MODS`. Todas las actualizaciones requieren WP-CLI o acceso directo al servidor. Recomendado cuando el sitio lo gestiona el desarrollador.

> **Sobre `DISABLE_WP_CRON`:** al activarlo hay que configurar un cron real en el servidor:
> ```
> */15 * * * * wget -q -O - https://tudominio.com/wp-cron.php?doing_wp_cron
> ```

---

### `audit-interno-diario.sh` — Auditoría interna automatizada

Auditoría completa del servidor, diseñada para correr a diario vía cron. Compara el estado actual del sitio contra el baseline y reporta cualquier diferencia.

```bash
bash audit-interno-diario.sh /ruta/al/wordpress
```

**Configuración del cron** (correr a las 6am todos los días):

```bash
0 6 * * * bash /ruta/a/audit-interno-diario.sh /ruta/al/wordpress
```

**Qué hace antes de analizar:**

Genera un backup de la base de datos en `~/scripts/backups/daily/db-daily-YYYY-MM-DD.sql` y aplica rotación automática: se conservan los últimos 7 días, los backups más antiguos se eliminan.

**Qué revisa:**

- Integridad del core mediante checksums oficiales de WordPress
- Usuarios activos comparados contra el baseline
- Plugins con actualizaciones pendientes
- Archivos PHP modificados en las últimas 24 horas
- Hashes de archivos comparados contra el baseline
- Presencia de archivos PHP en la carpeta `uploads` (nunca debería haber)
- Archivos PHP con permisos 777
- Patrones maliciosos en código: `eval(base64_decode`, `shell_exec`, `passthru`, `gzuncompress`, `str_rot13` y otros
- Base de datos: búsqueda de payloads comunes (`eval(base64_decode`, `<script`, `document.write`, `unescape`)

**Optimización del escaneo de código:** si hubo archivos PHP modificados en las últimas 24 horas, escanea solo esos archivos (rápido). Si no hubo cambios, ejecuta un full scan sobre todos los PHP del sitio.

Al terminar genera un reporte en `~/scripts/reporte-diario-YYYY-MM-DD.txt`.

> **⚠️ Requiere `baseline.sh` ejecutado previamente.** Sin baseline, las comparaciones de usuarios y hashes no funcionan.

---

### `audit-externo.sh` — Auditoría externa

Escanea el sitio desde afuera, sin acceso al servidor. Replica la perspectiva de un atacante que busca puntos de entrada.

```bash
WPSCAN_TOKEN=tu_token_aqui bash audit-externo.sh https://tusitio.com
```

**Qué revisa:**

- **WPScan** — vulnerabilidades conocidas en el core, plugins y temas; usuarios expuestos; versiones desactualizadas
- **xmlrpc.php** — diferencia entre "expuesto y funcional", "bloqueado a nivel servidor" y "bloqueado por firewall"; cada estado tiene una interpretación distinta
- **wp-admin** — diferencia entre "redirige al login nativo de WP" (problema) y "redirige a WAF o página de bloqueo" (correcto)
- **/?action=postpass** — vector relacionado con plugins de protección de contenido; se cruza con el resultado de wp-admin
- **Headers de seguridad HTTP** — `X-Content-Type-Options`, `X-Frame-Options`, `Content-Security-Policy`, `Strict-Transport-Security`, `Referrer-Policy`, `Permissions-Policy`

Al terminar genera un reporte en `~/scripts/reporte-externo-YYYY-MM-DD.txt`.

> **El token de WPScan es necesario** para acceder a la base de datos de vulnerabilidades. El plan gratuito en [wpscan.com](https://wpscan.com) es suficiente para uso personal o en pocos sitios.

---

### `containment.sh` — Contención de incidente

**Primer script a correr ante un incidente confirmado.** No elimina ni modifica archivos del sitio. Solo protege y preserva evidencia. Cada acción (excepto el snapshot) requiere confirmación individual.

```bash
bash containment.sh /ruta/al/wordpress
```

**Paso 1 — Snapshot forense (automático, sin confirmación)**

Se ejecuta siempre, antes de cualquier otra acción. Genera:
- Export completo de la base de datos
- Copia de `wp-config.php` y `.htaccess`
- Lista de todos los archivos PHP con fecha de modificación, hora y permisos al momento del incidente

El snapshot se guarda en `~/scripts/snapshots/snapshot-YYYY-MM-DD_HH-MM-SS/`. El timestamp incluye hora, minuto y segundo para no colisionar con otros snapshots del mismo día.

**Paso 2 — Modo mantenimiento** (con confirmación)

Hace el sitio invisible para visitantes mientras se trabaja.

**Paso 3 — Usuarios administradores** (con confirmación)

Lista todos los administradores, los compara con el baseline, y permite resetear contraseñas a valores aleatorios generados con `openssl`. No elimina usuarios — eso se hace en `remediacion.sh`.

**Paso 4 — Bloqueo de xmlrpc.php** (con confirmación)

Si `xmlrpc.php` existe y no tiene regla en `.htaccess`, agrega el bloqueo.

**Paso 5 — Bloqueo de PHP en uploads** (con confirmación)

Si hay PHP en `uploads`, crea un `.htaccess` que bloquea su ejecución. Los archivos quedan intactos para análisis forense.

> **Regla de oro:** contener primero, analizar después, limpiar al final. El instinto de borrar el archivo malicioso de inmediato destruye la evidencia necesaria para entender cómo entró el atacante y qué más pudo comprometer.

---

### `audit-post-incidente.sh` — Análisis forense

Análisis forense profundo. Corre después de `containment.sh`. No modifica nada: solo analiza y reporta. A diferencia de la auditoría diaria, no tiene límite de tiempo ni de archivos: escanea todo el sitio sin excepción.

```bash
bash audit-post-incidente.sh /ruta/al/wordpress
```

**Qué analiza:**

- Integridad del core de WordPress
- Diferencias de hash en **todos** los archivos PHP contra el baseline
- 10 patrones maliciosos: `eval(base64_decode`, `shell_exec`, `passthru`, `gzuncompress`, `gzinflate`, `str_rot13`, `preg_replace.*\/e`, `assert($`, `create_function`
- Web shells: archivos que reciben datos externos vía `POST` o `GET` fuera de rutas legítimas (`wp-includes`, `wp-admin`, temas, plugins)
- PHP en rutas incorrectas: `uploads`, `wp-content/upgrade`
- Archivos PHP con permisos 777
- Archivos PHP modificados en las últimas 72 horas, con `stat` detallado de cada uno
- Usuarios comparados contra el baseline
- Posts con `post_author=0` — señal de que la base de datos fue manipulada directamente
- Base de datos en tres niveles:
  - **Tier 1** (crítico): `eval(base64_decode`, `base64_decode`, `<script`, `document.write`, `unescape(`
  - **Tier 2** (profundidad media): `String.fromCharCode`, `iframe`, `wp_redirect`, `fromCharCode`
  - **Tier 3** (contexto específico): `http://`, `chmod`, `shell_exec`, `passthru`

**Al terminar genera dos archivos:**

- `~/scripts/reporte-post-incidente-FECHA.txt` — reporte completo y legible
- `~/scripts/hallazgos-FECHA.txt` — archivo estructurado que lee `remediacion.sh`

El formato del archivo de hallazgos es `TIPO|DETALLE|DESCRIPCION`. Los tipos posibles son: `CORE`, `ARCHIVO`, `PERMISO`, `USUARIO`, `DB`, `PLUGIN`.

---

### `remediacion.sh` — Remediación guiada

**El único script del toolkit que elimina archivos y modifica la base de datos.** Requiere el archivo de hallazgos generado por `audit-post-incidente.sh` como entrada. No actúa por intuición: actúa sobre evidencia documentada.

```bash
bash remediacion.sh ~/scripts/hallazgos-FECHA.txt /ruta/al/wordpress
```

**Paso 1 — Backup obligatorio**

Exporta la base de datos y copia los archivos críticos a `~/scripts/backups/remediacion-FECHA/` antes de cualquier acción. Si el backup falla, el script se detiene. No hay remediación sin punto de retorno.

**Paso 2 — Procesamiento de hallazgos**

Lee el archivo línea por línea y propone una acción para cada tipo:

| Tipo | Qué hace |
|---|---|
| `ARCHIVO` | Muestra las primeras 20 líneas. Permite ver el archivo completo, ver el `stat`, o eliminar (guarda copia en backup antes de borrar) |
| `PERMISO` | Muestra los permisos actuales y corrige a 644 con confirmación |
| `USUARIO` | Permite eliminar el usuario (reasignando su contenido al admin ID 1) o solo resetear la contraseña a un valor aleatorio |
| `DB` | Ofrece primero un dry-run para ver qué cambiaría; luego la ejecución real con `search-replace` |
| `CORE` | Descarga y reinstala la versión oficial limpia con `wp core download --force` |

Cada acción queda registrada en `~/scripts/log-acciones-FECHA.txt` con timestamp, tipo, detalle y resultado.

**Paso 3 — Verificación post-remediación**

Comprueba que no quede PHP en `uploads`, que no haya archivos con permisos 777, y que el core pase la verificación de checksums.

---

## Archivos y directorios generados

```

├── .wp-baseline/                        ← baseline del servidor limpio
│   ├── baseline-hashes.sha256
│   ├── baseline-users.txt
│   ├── baseline-plugins.txt
│   ├── baseline-options.txt
│   ├── baseline-defines.txt
│   ├── baseline-permisos.txt
│   ├── baseline-version.txt
│   └── baseline-fecha.txt
│
└── scripts/
    ├── backups/
    │   ├── daily/
    │   │   └── db-daily-YYYY-MM-DD.sql       ← backup diario (rotación 7 días)
    │   ├── wp-config.php.bak-YYYY-MM-DD      ← backup de hardening.sh
    │   └── remediacion-FECHA/                ← backup pre-remediación
    │       ├── db-pre-remediacion.sql
    │       ├── wp-config-pre-remediacion.php
    │       └── htaccess-pre-remediacion.txt
    │
    ├── snapshots/
    │   └── snapshot-YYYY-MM-DD_HH-MM-SS/     ← snapshot forense de containment.sh
    │       ├── db-snapshot-FECHA.sql
    │       ├── wp-config-snapshot.php
    │       ├── htaccess-snapshot.txt
    │       └── php-files-estado.txt
    │
    ├── reporte-baseline-FECHA.txt
    ├── reporte-hardening-YYYY-MM-DD.txt
    ├── reporte-diario-YYYY-MM-DD.txt
    ├── reporte-externo-YYYY-MM-DD.txt
    ├── reporte-containment-FECHA.txt
    ├── reporte-post-incidente-FECHA.txt
    ├── reporte-remediacion-FECHA.txt
    ├── hallazgos-FECHA.txt                   ← entrada para remediacion.sh
    └── log-acciones-FECHA.txt                ← log de remediacion.sh
```

> Los archivos con `FECHA` en el nombre usan el formato `YYYY-MM-DD_HH-MM-SS`. Los archivos con `YYYY-MM-DD` usan solo la fecha. El backup diario usa fecha sola para que no colisione con snapshots forenses del mismo día.

---

## Recomendaciones de uso

**Empezar siempre por `baseline.sh` en un servidor limpio.** Sin baseline, las comparaciones de usuarios y hashes no funcionan. La auditoría diaria y el análisis post-incidente dependen de este archivo.

**Regenerar el baseline después de cada cambio estructural:** actualizaciones mayores del core, instalación o remoción de plugins, cambios intencionales en usuarios o configuración. No regenerarlo durante un incidente activo.

**Configurar el cron de `audit-interno-diario.sh` antes de poner el sitio en producción.** La auditoría corre cada mañana a las 6am y genera un backup diario de la base de datos con rotación de 7 días. Sin el cron, la detección temprana no funciona.

**Correr `audit-externo.sh` a demanda**, no en cron. Es útil después de cambios importantes en la configuración del servidor, después de instalar un nuevo plugin de seguridad, o como verificación periódica mensual.

**Ante un incidente confirmado, el orden importa:**
1. `containment.sh` —> contener y preservar evidencia
2. `audit-post-incidente.sh` —> analizar qué pasó
3. `remediacion.sh` —> limpiar basado en los hallazgos
4. `hardening.sh` —> reforzar la configuración
5. `baseline.sh` —> regenerar la línea base con el servidor limpio

**`remediacion.sh` siempre recibe el archivo de hallazgos como primer argumento.** Si se corre sin él, el script se detiene. El archivo lo genera `audit-post-incidente.sh` al terminar.

**Los scripts con confirmaciones individuales** (`hardening.sh`, `containment.sh`, `remediacion.sh`) están diseñados para leerse antes de aceptar cada paso. No ejecutar en modo automático ni aceptar todo sin revisar el contexto de cada hallazgo.

---

## Licencia

MIT
