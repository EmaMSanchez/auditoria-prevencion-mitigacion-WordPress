#!/bin/bash

# ============================================================
# AUDITORÍA INTERNA DIARIA — WORDPRESS
# Uso: bash audit-interno-diario.sh /ruta/al/wordpress
# Cron: 0 6 * * * bash /scripts/audit-interno-diario.sh /ruta/wordpress
# ============================================================

FECHA=$(date +%Y-%m-%d)
WP_PATH=$1
REPORTE=~/scripts/reporte-diario-$FECHA.txt
BASELINE_DIR=~/.wp-baseline
HALLAZGOS=0

# ============================================================
# VALIDACIONES PREVIAS
# ============================================================

if [ -z "$WP_PATH" ]; then
    echo "Uso: bash audit-interno-diario.sh /ruta/al/wordpress"
    exit 1
fi

if [ ! -f "$WP_PATH/wp-config.php" ]; then
    echo "❌ Error: No se encontró wp-config.php en $WP_PATH"
    exit 1
fi

if ! command -v wp &> /dev/null; then
    echo "❌ Error: WP-CLI no está instalado"
    exit 1
fi

mkdir -p ~/scripts
mkdir -p ~/scripts/backups/daily

# ============================================================
# BACKUP DIARIO DE LA BASE DE DATOS
# Se ejecuta antes que cualquier análisis.
# Rotación automática: se conservan los últimos 7 días.
# Nombrado por fecha — nunca colisiona con snapshots forenses
# (containment y remediacion usan timestamp con hora:min:seg).
# ============================================================

echo "================================"
echo "BACKUP DIARIO - $FECHA"
echo "Sitio: $WP_PATH"
echo "================================"

BACKUP_DIARIO=~/scripts/backups/daily/db-daily-$FECHA.sql

wp --path="$WP_PATH" db export "$BACKUP_DIARIO" 2>&1
if [ $? -eq 0 ]; then
    BACKUP_SIZE=$(du -sh "$BACKUP_DIARIO" | cut -f1)
    echo "✔️  Backup DB generado: $BACKUP_DIARIO ($BACKUP_SIZE)"
else
    echo "⚠️  Error al generar backup de DB — la auditoría continúa"
    echo "   Revisar permisos de escritura en ~/scripts/backups/daily/"
fi

# Rotación: eliminar backups con más de 7 días
find ~/scripts/backups/daily -name "db-daily-*.sql" -mtime +7 -delete 2>/dev/null
echo "✔️  Rotación aplicada — se conservan los últimos 7 días"
echo ""

# ============================================================
# ENCABEZADO
# ============================================================

echo "================================" | tee $REPORTE
echo "AUDITORÍA INTERNA DIARIA - $FECHA" | tee -a $REPORTE
echo "Sitio: $WP_PATH" | tee -a $REPORTE
echo "================================" | tee -a $REPORTE

# ============================================================
# DETECCIÓN MULTISITE
# ============================================================

echo "" | tee -a $REPORTE
echo "--- TIPO DE INSTALACIÓN ---" | tee -a $REPORTE
IS_MULTISITE=$(wp --path="$WP_PATH" config get MULTISITE 2>/dev/null)
if [ "$IS_MULTISITE" = "true" ]; then
    echo "⚠️  Instalación MULTISITE detectada — usando flag --network en DB search" | tee -a $REPORTE
    NETWORK_FLAG="--network"
else
    echo "✔️  Instalación single site" | tee -a $REPORTE
    NETWORK_FLAG=""
fi

# ============================================================
# INTEGRIDAD DEL CORE
# ============================================================

echo "" | tee -a $REPORTE
echo "--- INTEGRIDAD DEL CORE ---" | tee -a $REPORTE
CORE_CHECK=$(wp --path="$WP_PATH" core verify-checksums 2>&1)
echo "$CORE_CHECK" | tee -a $REPORTE
if echo "$CORE_CHECK" | grep -qiE "Error|Warning|doesn't verify|modified"; then
    echo "⚠️  HALLAZGO: Integridad del core comprometida" | tee -a $REPORTE
    HALLAZGOS=$((HALLAZGOS + 1))
fi

# ============================================================
# DEFINES DE SEGURIDAD EN WP-CONFIG
# ============================================================

echo "" | tee -a $REPORTE
echo "--- DEFINES DE SEGURIDAD EN WP-CONFIG ---" | tee -a $REPORTE
for DEFINE in DISALLOW_FILE_EDIT DISALLOW_FILE_MODS FORCE_SSL_ADMIN WP_DEBUG WP_DEBUG_LOG DISABLE_WP_CRON; do
    VALUE=$(wp --path="$WP_PATH" config get "$DEFINE" 2>/dev/null)
    if [ -z "$VALUE" ]; then
        echo "✘  $DEFINE — NO DEFINIDO" | tee -a $REPORTE
        HALLAZGOS=$((HALLAZGOS + 1))
    else
        echo "✔️  $DEFINE = $VALUE" | tee -a $REPORTE
    fi
done

# ============================================================
# USUARIOS ACTIVOS Y COMPARACIÓN CON BASELINE
# ============================================================

echo "" | tee -a $REPORTE
echo "--- USUARIOS ACTIVOS ---" | tee -a $REPORTE
USUARIOS_ACTUALES=$(wp --path="$WP_PATH" user list --fields=user_login,user_email,roles 2>&1)
echo "$USUARIOS_ACTUALES" | tee -a $REPORTE

if [ -f "$BASELINE_DIR/baseline-users.txt" ]; then
    echo "" | tee -a $REPORTE
    echo "Comparando con baseline de usuarios..." | tee -a $REPORTE
    DIFF_USERS=$(diff "$BASELINE_DIR/baseline-users.txt" <(wp --path="$WP_PATH" user list --fields=user_login,user_email,roles 2>/dev/null))
    if [ -n "$DIFF_USERS" ]; then
        echo "⚠️  HALLAZGO: Cambios en usuarios respecto al baseline:" | tee -a $REPORTE
        echo "$DIFF_USERS" | tee -a $REPORTE
        HALLAZGOS=$((HALLAZGOS + 1))
    else
        echo "✔️  Usuarios sin cambios respecto al baseline" | tee -a $REPORTE
    fi
else
    echo "⚠️  Sin baseline de usuarios. Ejecutá baseline.sh primero." | tee -a $REPORTE
fi

# ============================================================
# OPCIONES CRITICAS DE LA DB
# ============================================================

echo "" | tee -a $REPORTE
echo "--- OPCIONES CRITICAS ---" | tee -a $REPORTE
wp --path="$WP_PATH" option get siteurl 2>&1 | tee -a $REPORTE
wp --path="$WP_PATH" option get home 2>&1 | tee -a $REPORTE
wp --path="$WP_PATH" option get admin_email 2>&1 | tee -a $REPORTE

# ============================================================
# PLUGINS DESACTUALIZADOS
# ============================================================

echo "" | tee -a $REPORTE
echo "--- PLUGINS ---" | tee -a $REPORTE
PLUGINS_INFO=$(wp --path="$WP_PATH" plugin list --fields=name,status,version,update 2>&1)
echo "$PLUGINS_INFO" | tee -a $REPORTE
if echo "$PLUGINS_INFO" | grep -qi "available"; then
    echo "⚠️  HALLAZGO: Hay plugins con actualizaciones pendientes" | tee -a $REPORTE
    HALLAZGOS=$((HALLAZGOS + 1))
fi

# ============================================================
# ARCHIVOS MODIFICADOS EN ÚLTIMAS 24HS
# ============================================================

echo "" | tee -a $REPORTE
echo "--- ARCHIVOS PHP MODIFICADOS ÚLTIMAS 24HS ---" | tee -a $REPORTE
touch -d "24 hours ago" /tmp/ref-diario
MODIFIED=$(find "$WP_PATH" -name "*.php" -newer /tmp/ref-diario 2>/dev/null)
if [ -n "$MODIFIED" ]; then
    echo "$MODIFIED" | tee -a $REPORTE
    echo "⚠️  HALLAZGO: $(echo "$MODIFIED" | wc -l) archivo(s) PHP modificado(s) en las últimas 24hs" | tee -a $REPORTE
    HALLAZGOS=$((HALLAZGOS + 1))
else
    echo "✔️  Sin archivos PHP modificados en las últimas 24hs" | tee -a $REPORTE
fi

# ============================================================
# COMPARACIÓN DE HASHES CONTRA BASELINE
# ============================================================

echo "" | tee -a $REPORTE
echo "--- COMPARACIÓN DE HASHES CON BASELINE ---" | tee -a $REPORTE
if [ -f "$BASELINE_DIR/baseline-hashes.sha256" ]; then
    HASH_FAILS=$(sha256sum --check "$BASELINE_DIR/baseline-hashes.sha256" 2>/dev/null | grep "FAILED")
    if [ -n "$HASH_FAILS" ]; then
        echo "⚠️  HALLAZGO: Archivos con hash diferente al baseline:" | tee -a $REPORTE
        echo "$HASH_FAILS" | tee -a $REPORTE
        HALLAZGOS=$((HALLAZGOS + 1))
    else
        echo "✔️  Todos los hashes coinciden con el baseline" | tee -a $REPORTE
    fi
else
    echo "⚠️  Sin baseline de hashes. Ejecutá baseline.sh primero." | tee -a $REPORTE
fi

# ============================================================
# PHP EN UPLOADS (nunca debería haber)
# ============================================================

echo "" | tee -a $REPORTE
echo "--- PHP EN UPLOADS ---" | tee -a $REPORTE
PHP_UPLOADS=$(find "$WP_PATH/wp-content/uploads" -name "*.php" 2>/dev/null)
if [ -n "$PHP_UPLOADS" ]; then
    echo "$PHP_UPLOADS" | tee -a $REPORTE
    echo "⚠️  HALLAZGO: Archivos PHP en uploads — posible backdoor" | tee -a $REPORTE
    HALLAZGOS=$((HALLAZGOS + 1))
else
    echo "✔️  Sin archivos PHP en uploads" | tee -a $REPORTE
fi

# ============================================================
# PERMISOS 777
# ============================================================

echo "" | tee -a $REPORTE
echo "--- PERMISOS 777 ---" | tee -a $REPORTE
PERMS_777=$(find "$WP_PATH" -type f -name "*.php" -perm 0777 2>/dev/null)
if [ -n "$PERMS_777" ]; then
    echo "$PERMS_777" | tee -a $REPORTE
    echo "⚠️  HALLAZGO: Archivos PHP con permisos 777" | tee -a $REPORTE
    HALLAZGOS=$((HALLAZGOS + 1))
else
    echo "✔️  Sin archivos PHP con permisos 777" | tee -a $REPORTE
fi

# ============================================================
# GREP DE PATRONES MALICIOSOS EN ARCHIVOS
# Corre sobre archivos modificados en 24hs si existen,
# sino full scan (más lento pero más seguro)
# ============================================================

echo "" | tee -a $REPORTE
echo "--- PATRONES MALICIOSOS EN ARCHIVOS PHP ---" | tee -a $REPORTE

if [ -n "$MODIFIED" ]; then
    echo "Escaneando archivos modificados en las últimas 24hs..." | tee -a $REPORTE
    SCAN_TARGET=$(echo "$MODIFIED" | tr '\n' ' ')
    MALICIOUS=$(echo "$MODIFIED" | xargs grep -liE \
        'eval\s*\(\s*base64_decode|shell_exec\s*\(|passthru\s*\(|system\s*\(|\$_(POST|GET|REQUEST)\s*\[|gzuncompress\s*\(|str_rot13\s*\(' \
        2>/dev/null)
else
    echo "Sin archivos modificados — full scan (puede tardar)..." | tee -a $REPORTE
    MALICIOUS=$(grep -rliE \
        'eval\s*\(\s*base64_decode|shell_exec\s*\(|passthru\s*\(|system\s*\(|\$_(POST|GET|REQUEST)\s*\[|gzuncompress\s*\(|str_rot13\s*\(' \
        "$WP_PATH" --include="*.php" 2>/dev/null)
fi

if [ -n "$MALICIOUS" ]; then
    echo "$MALICIOUS" | tee -a $REPORTE
    echo "⚠️  HALLAZGO: Patrones maliciosos detectados en los archivos listados" | tee -a $REPORTE
    HALLAZGOS=$((HALLAZGOS + 1))
else
    echo "✔️  Sin patrones maliciosos detectados" | tee -a $REPORTE
fi

# ============================================================
# BASE DE DATOS — BÚSQUEDA TIER 1
# ============================================================

echo "" | tee -a $REPORTE
echo "--- BASE DE DATOS: BÚSQUEDA TIER 1 ---" | tee -a $REPORTE
echo "Nota: puede tardar en bases de datos grandes." | tee -a $REPORTE

for PATRON in "eval(base64_decode" "base64_decode" "<script" "document.write" "unescape("; do
    RESULT=$(wp --path="$WP_PATH" db search "$PATRON" $NETWORK_FLAG 2>/dev/null)
    if [ -n "$RESULT" ]; then
        echo "⚠️  HALLAZGO: '$PATRON' encontrado en DB" | tee -a $REPORTE
        echo "$RESULT" | tee -a $REPORTE
        HALLAZGOS=$((HALLAZGOS + 1))
    else
        echo "✔️  '$PATRON' — no encontrado en DB" | tee -a $REPORTE
    fi
done

# ============================================================
# RESUMEN FINAL
# ============================================================

echo "" | tee -a $REPORTE
echo "================================" | tee -a $REPORTE
echo "RESUMEN - AUDITORÍA DIARIA $FECHA" | tee -a $REPORTE
echo "================================" | tee -a $REPORTE

if [ $HALLAZGOS -eq 0 ]; then
    echo "✔️  RESULTADO: Sin hallazgos. El sitio está limpio." | tee -a $REPORTE
else
    echo "⚠️  RESULTADO: $HALLAZGOS hallazgo(s) detectado(s)." | tee -a $REPORTE
    echo "   Revisar reporte completo: $REPORTE" | tee -a $REPORTE
    echo "   Si hay indicios de intrusión: correr containment.sh primero." | tee -a $REPORTE
fi

echo "Reporte guardado en: $REPORTE" | tee -a $REPORTE
echo "================================" | tee -a $REPORTE
