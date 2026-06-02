#!/bin/bash

# ============================================================
# BASELINE WORDPRESS
# Uso: bash baseline.sh /ruta/al/wordpress
#
# Ejecutar UNA SOLA VEZ sobre un servidor limpio o recién
# instalado. Genera los archivos de referencia que usan
# audit-interno-diario.sh y audit-post-incidente.sh
# para detectar cambios.
#
# No modifica nada. Solo lee y guarda.
# ============================================================

FECHA=$(date +%Y-%m-%d_%H-%M-%S)
WP_PATH=$1
BASELINE_DIR=~/.wp-baseline
REPORTE=~/scripts/reporte-baseline-$FECHA.txt

# ============================================================
# VALIDACIONES PREVIAS
# ============================================================

if [ -z "$WP_PATH" ]; then
    echo "Uso: bash baseline.sh /ruta/al/wordpress"
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
mkdir -p "$BASELINE_DIR"

# ============================================================
# ADVERTENCIA SI YA EXISTE UN BASELINE
# Sobreescribir el baseline durante un incidente activo
# destruye la referencia de comparación.
# ============================================================

if [ -f "$BASELINE_DIR/baseline-fecha.txt" ]; then
    FECHA_ANTERIOR=$(cat "$BASELINE_DIR/baseline-fecha.txt")
    echo "" 
    echo "⚠️  Ya existe un baseline generado el: $FECHA_ANTERIOR"
    echo "   Sobreescribirlo durante un incidente activo elimina"
    echo "   la referencia de comparación."
    echo ""
    read -p "¿Sobreescribir el baseline existente? (s/n): " CONFIRM_OVERWRITE
    if [ "$CONFIRM_OVERWRITE" != "s" ]; then
        echo "Operación cancelada. Baseline anterior conservado."
        exit 0
    fi
    echo ""
    echo "Generando nuevo baseline — el anterior será reemplazado."
fi

# ============================================================
# ENCABEZADO
# ============================================================

echo "================================" | tee $REPORTE
echo "GENERACIÓN DE BASELINE - $FECHA" | tee -a $REPORTE
echo "Sitio: $WP_PATH" | tee -a $REPORTE
echo "================================" | tee -a $REPORTE

# ============================================================
# DETECCIÓN MULTISITE
# ============================================================

echo "" | tee -a $REPORTE
echo "--- TIPO DE INSTALACIÓN ---" | tee -a $REPORTE
IS_MULTISITE=$(wp --path="$WP_PATH" config get MULTISITE 2>/dev/null)
if [ "$IS_MULTISITE" = "true" ]; then
    echo "⚠️  Instalación MULTISITE detectada" | tee -a $REPORTE
    NETWORK_FLAG="--network"
else
    echo "✔️  Instalación single site" | tee -a $REPORTE
    NETWORK_FLAG=""
fi

# ============================================================
# 1. TIMESTAMP
# ============================================================

echo "" | tee -a $REPORTE
echo "--- TIMESTAMP ---" | tee -a $REPORTE
echo "$FECHA" > "$BASELINE_DIR/baseline-fecha.txt"
echo "✔️  Fecha guardada: $FECHA" | tee -a $REPORTE

# ============================================================
# 2. HASHES SHA256 DE TODOS LOS .PHP
# Base de comparación para detectar archivos modificados.
# Puede tardar varios minutos en instalaciones grandes.
# ============================================================

echo "" | tee -a $REPORTE
echo "--- HASHES SHA256 DE ARCHIVOS PHP ---" | tee -a $REPORTE
echo "Generando hashes (puede tardar en instalaciones grandes)..." | tee -a $REPORTE

find "$WP_PATH" -name "*.php" -type f | sort | xargs sha256sum 2>/dev/null > "$BASELINE_DIR/baseline-hashes.sha256"

TOTAL_HASHES=$(wc -l < "$BASELINE_DIR/baseline-hashes.sha256")
if [ "$TOTAL_HASHES" -gt 0 ]; then
    echo "✔️  $TOTAL_HASHES archivos PHP hasheados" | tee -a $REPORTE
    echo "   Guardado en: $BASELINE_DIR/baseline-hashes.sha256" | tee -a $REPORTE
else
    echo "❌ Error al generar hashes" | tee -a $REPORTE
fi

# ============================================================
# 3. USUARIOS Y ROLES
# ============================================================

echo "" | tee -a $REPORTE
echo "--- USUARIOS Y ROLES ---" | tee -a $REPORTE
wp --path="$WP_PATH" user list --fields=user_login,user_email,roles 2>/dev/null \
    > "$BASELINE_DIR/baseline-users.txt"

cat "$BASELINE_DIR/baseline-users.txt" | tee -a $REPORTE

TOTAL_USERS=$(wc -l < "$BASELINE_DIR/baseline-users.txt")
echo "✔️  $TOTAL_USERS usuario(s) registrado(s) en baseline" | tee -a $REPORTE

# ============================================================
# 4. PLUGINS ACTIVOS CON VERSIONES
# ============================================================

echo "" | tee -a $REPORTE
echo "--- PLUGINS ACTIVOS ---" | tee -a $REPORTE
wp --path="$WP_PATH" plugin list \
    --fields=name,status,version,auto_update 2>/dev/null \
    > "$BASELINE_DIR/baseline-plugins.txt"

cat "$BASELINE_DIR/baseline-plugins.txt" | tee -a $REPORTE
echo "✔️  Lista de plugins guardada en baseline" | tee -a $REPORTE

# ============================================================
# 5. OPCIONES CRITICAS DE LA DB
# ============================================================

echo "" | tee -a $REPORTE
echo "--- OPCIONES CRITICAS DE LA DB ---" | tee -a $REPORTE
{
    echo "siteurl: $(wp --path="$WP_PATH" option get siteurl 2>/dev/null)"
    echo "home: $(wp --path="$WP_PATH" option get home 2>/dev/null)"
    echo "admin_email: $(wp --path="$WP_PATH" option get admin_email 2>/dev/null)"
    echo "blogname: $(wp --path="$WP_PATH" option get blogname 2>/dev/null)"
} > "$BASELINE_DIR/baseline-options.txt"

cat "$BASELINE_DIR/baseline-options.txt" | tee -a $REPORTE
echo "✔️  Opciones críticas guardadas en baseline" | tee -a $REPORTE

# ============================================================
# 6. DEFINES DE SEGURIDAD EN WP-CONFIG
# ============================================================

echo "" | tee -a $REPORTE
echo "--- DEFINES DE SEGURIDAD ---" | tee -a $REPORTE
{
    for DEFINE in DISALLOW_FILE_EDIT DISALLOW_FILE_MODS FORCE_SSL_ADMIN \
                  WP_DEBUG WP_DEBUG_LOG WP_DEBUG_DISPLAY DISABLE_WP_CRON; do
        VALUE=$(wp --path="$WP_PATH" config get "$DEFINE" 2>/dev/null)
        if [ -z "$VALUE" ]; then
            echo "$DEFINE = (no definido)"
        else
            echo "$DEFINE = $VALUE"
        fi
    done
} > "$BASELINE_DIR/baseline-defines.txt"

cat "$BASELINE_DIR/baseline-defines.txt" | tee -a $REPORTE
echo "✔️  Defines guardados en baseline" | tee -a $REPORTE

# ============================================================
# 7. PERMISOS DE ARCHIVOS CRÍTICOS
# ============================================================

echo "" | tee -a $REPORTE
echo "--- PERMISOS DE ARCHIVOS CRÍTICOS ---" | tee -a $REPORTE
{
    echo "=== wp-config.php ==="
    stat -c "%a %n" "$WP_PATH/wp-config.php" 2>/dev/null

    echo "=== .htaccess ==="
    stat -c "%a %n" "$WP_PATH/.htaccess" 2>/dev/null

    echo "=== Archivos PHP con permisos distintos a 644 ==="
    find "$WP_PATH" -type f -name "*.php" -not -perm 644 2>/dev/null

    echo "=== Carpetas con permisos distintos a 755 ==="
    find "$WP_PATH" -type d -not -perm 755 2>/dev/null

    echo "=== Archivos PHP con permisos 777 ==="
    find "$WP_PATH" -type f -name "*.php" -perm 0777 2>/dev/null
} > "$BASELINE_DIR/baseline-permisos.txt"

cat "$BASELINE_DIR/baseline-permisos.txt" | tee -a $REPORTE
echo "✔️  Permisos guardados en baseline" | tee -a $REPORTE

# ============================================================
# 8. VERSIÓN DEL CORE
# ============================================================

echo "" | tee -a $REPORTE
echo "--- VERSIÓN DEL CORE ---" | tee -a $REPORTE
WP_VERSION=$(wp --path="$WP_PATH" core version 2>/dev/null)
echo "WordPress $WP_VERSION" > "$BASELINE_DIR/baseline-version.txt"
echo "✔️  Versión del core: WordPress $WP_VERSION" | tee -a $REPORTE

# ============================================================
# RESUMEN DE ARCHIVOS GENERADOS
# ============================================================

echo "" | tee -a $REPORTE
echo "================================" | tee -a $REPORTE
echo "BASELINE GENERADO - $FECHA" | tee -a $REPORTE
echo "================================" | tee -a $REPORTE
echo "Archivos creados en $BASELINE_DIR:" | tee -a $REPORTE
echo "   baseline-fecha.txt       → timestamp de esta ejecución" | tee -a $REPORTE
echo "   baseline-hashes.sha256   → hashes de $TOTAL_HASHES archivos PHP" | tee -a $REPORTE
echo "   baseline-users.txt       → usuarios y roles" | tee -a $REPORTE
echo "   baseline-plugins.txt     → plugins activos con versiones" | tee -a $REPORTE
echo "   baseline-options.txt     → opciones críticas de la DB" | tee -a $REPORTE
echo "   baseline-defines.txt     → defines de seguridad en wp-config" | tee -a $REPORTE
echo "   baseline-permisos.txt    → permisos de archivos críticos" | tee -a $REPORTE
echo "   baseline-version.txt     → versión del core" | tee -a $REPORTE
echo "" | tee -a $REPORTE
echo "Reporte guardado en: $REPORTE" | tee -a $REPORTE
echo "" | tee -a $REPORTE
echo "⚠️  Próximos pasos:" | tee -a $REPORTE
echo "   1. Configurar cron diario: audit-interno-diario.sh" | tee -a $REPORTE
echo "   0 6 * * * bash ~/scripts/audit-interno-diario.sh $WP_PATH" | tee -a $REPORTE
echo "   2. Regenerar baseline después de cada actualización mayor del core." | tee -a $REPORTE
echo "================================" | tee -a $REPORTE
