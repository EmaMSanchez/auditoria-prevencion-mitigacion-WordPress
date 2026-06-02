#!/bin/bash

# ============================================================
# HARDENING WORDPRESS
# Uso: bash hardening.sh /ruta/al/wordpress
# ⚠️  Modifica el servidor — lee cada confirmación antes de aceptar
# ============================================================

WP_PATH=$1
FECHA=$(date +%Y-%m-%d)
REPORTE=~/scripts/reporte-hardening-$FECHA.txt
BACKUP_DIR=~/scripts/backups

# ============================================================
# VALIDACIONES PREVIAS
# ============================================================

if [ -z "$WP_PATH" ]; then
    echo "Uso: bash hardening.sh /ruta/al/wordpress"
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
mkdir -p "$BACKUP_DIR"

# ============================================================
# ENCABEZADO
# ============================================================

echo "================================" | tee $REPORTE
echo "HARDENING WORDPRESS - $FECHA" | tee -a $REPORTE
echo "Sitio: $WP_PATH" | tee -a $REPORTE
echo "================================" | tee -a $REPORTE

# ============================================================
# BACKUP DE WP-CONFIG ANTES DE TOCAR NADA
# El backup se guarda fuera del webroot para que no sea accesible
# ============================================================

echo "" | tee -a $REPORTE
echo "--- BACKUP PREVIO DE WP-CONFIG.PHP ---" | tee -a $REPORTE
cp "$WP_PATH/wp-config.php" "$BACKUP_DIR/wp-config.php.bak-$FECHA"
if [ $? -eq 0 ]; then
    echo "✔️  Backup creado en: $BACKUP_DIR/wp-config.php.bak-$FECHA" | tee -a $REPORTE
else
    echo "❌ Error al crear backup de wp-config.php — abortando" | tee -a $REPORTE
    exit 1
fi

# ============================================================
# ESTADO ACTUAL DE DEFINES — SOLO LECTURA
# ============================================================

echo "" | tee -a $REPORTE
echo "--- ESTADO ACTUAL DE DEFINES DE SEGURIDAD ---" | tee -a $REPORTE
for DEFINE in DISALLOW_FILE_EDIT DISALLOW_FILE_MODS FORCE_SSL_ADMIN WP_DEBUG WP_DEBUG_LOG WP_DEBUG_DISPLAY DISABLE_WP_CRON; do
    VALUE=$(wp --path="$WP_PATH" config get "$DEFINE" 2>/dev/null)
    if [ -z "$VALUE" ]; then
        echo "✘  $DEFINE — NO DEFINIDO" | tee -a $REPORTE
    else
        echo "   $DEFINE = $VALUE" | tee -a $REPORTE
    fi
done

# ============================================================
# APLICAR DEFINES DE SEGURIDAD — CON CONFIRMACIÓN Y NIVEL
#
# Nivel 1 — DISALLOW_FILE_EDIT:
#   Bloquea el editor de archivos del panel.
#   El cliente puede seguir instalando y actualizando plugins.
#   Recomendado para sitios con cliente activo.
#
# Nivel 2 — DISALLOW_FILE_EDIT + DISALLOW_FILE_MODS:
#   Bloquea editor + instalación + actualización desde el panel.
#   Las actualizaciones requieren WP-CLI o acceso directo al servidor.
#   Recomendado para servidores administrados sin acceso de cliente.
# ============================================================

echo "" | tee -a $REPORTE
read -p "¿Aplicar defines de seguridad en wp-config.php? (s/n): " CONFIRM_DEFINES
if [ "$CONFIRM_DEFINES" = "s" ]; then
    echo "" | tee -a $REPORTE
    echo "Nivel de restricción:" | tee -a $REPORTE
    echo "  1) Solo DISALLOW_FILE_EDIT — cliente puede actualizar plugins desde panel" | tee -a $REPORTE
    echo "  2) DISALLOW_FILE_EDIT + DISALLOW_FILE_MODS — máxima seguridad, updates solo via WP-CLI" | tee -a $REPORTE
    read -p "Opción (1/2): " NIVEL_RESTRICCION

    echo "--- APLICANDO DEFINES DE SEGURIDAD ---" | tee -a $REPORTE

    # Define base — siempre se aplica
    wp --path="$WP_PATH" config set DISALLOW_FILE_EDIT true --raw 2>&1 | tee -a $REPORTE
    echo "✔️  DISALLOW_FILE_EDIT = true" | tee -a $REPORTE

    if [ "$NIVEL_RESTRICCION" = "2" ]; then
        wp --path="$WP_PATH" config set DISALLOW_FILE_MODS true --raw 2>&1 | tee -a $REPORTE
        echo "✔️  DISALLOW_FILE_MODS = true" | tee -a $REPORTE
        echo "⚠️  Updates desde panel desactivados — usar WP-CLI para actualizar plugins y temas" | tee -a $REPORTE
    else
        echo "   DISALLOW_FILE_MODS — omitido (nivel 1)" | tee -a $REPORTE
    fi

    # Resto de defines — siempre se aplican
    wp --path="$WP_PATH" config set FORCE_SSL_ADMIN true --raw 2>&1 | tee -a $REPORTE
    wp --path="$WP_PATH" config set WP_DEBUG false --raw 2>&1 | tee -a $REPORTE
    wp --path="$WP_PATH" config set WP_DEBUG_LOG false --raw 2>&1 | tee -a $REPORTE
    wp --path="$WP_PATH" config set WP_DEBUG_DISPLAY false --raw 2>&1 | tee -a $REPORTE
    wp --path="$WP_PATH" config set DISABLE_WP_CRON true --raw 2>&1 | tee -a $REPORTE
    echo "✔️  Resto de defines aplicados" | tee -a $REPORTE
    echo "" | tee -a $REPORTE
    echo "⚠️  DISABLE_WP_CRON=true requiere configurar un cron real en el servidor:" | tee -a $REPORTE
    echo "   */15 * * * * wget -q -O - https://tudominio.com/wp-cron.php?doing_wp_cron" | tee -a $REPORTE
else
    echo "⚠️  Defines omitidos por el usuario" | tee -a $REPORTE
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
# AUDITORÍA DE PERMISOS — SOLO LECTURA PRIMERO
# ============================================================

echo "" | tee -a $REPORTE
echo "--- AUDITORÍA DE PERMISOS INCORRECTOS ---" | tee -a $REPORTE

echo "Archivos PHP sin permiso 644:" | tee -a $REPORTE
PHP_WRONG=$(find "$WP_PATH" -type f -name "*.php" -not -perm 644 2>/dev/null)
if [ -n "$PHP_WRONG" ]; then
    echo "$PHP_WRONG" | tee -a $REPORTE
    echo "Total: $(echo "$PHP_WRONG" | wc -l) archivo(s)" | tee -a $REPORTE
else
    echo "✔️  Todos los archivos PHP tienen permisos correctos" | tee -a $REPORTE
fi

echo "" | tee -a $REPORTE
echo "Carpetas sin permiso 755:" | tee -a $REPORTE
DIRS_WRONG=$(find "$WP_PATH" -type d -not -perm 755 2>/dev/null)
if [ -n "$DIRS_WRONG" ]; then
    echo "$DIRS_WRONG" | tee -a $REPORTE
    echo "Total: $(echo "$DIRS_WRONG" | wc -l) carpeta(s)" | tee -a $REPORTE
else
    echo "✔️  Todas las carpetas tienen permisos correctos" | tee -a $REPORTE
fi

echo "" | tee -a $REPORTE
echo "Archivos PHP con permiso 777 (alarma roja):" | tee -a $REPORTE
PHP_777=$(find "$WP_PATH" -type f -name "*.php" -perm 0777 2>/dev/null)
if [ -n "$PHP_777" ]; then
    echo "$PHP_777" | tee -a $REPORTE
    echo "⚠️  ALARMA: $(echo "$PHP_777" | wc -l) archivo(s) con permisos 777" | tee -a $REPORTE
else
    echo "✔️  Sin archivos PHP con permisos 777" | tee -a $REPORTE
fi

# ============================================================
# CORREGIR PERMISOS — CON CONFIRMACIÓN
# ============================================================

echo "" | tee -a $REPORTE
read -p "¿Corregir permisos automáticamente? (s/n): " CONFIRM_PERMS
if [ "$CONFIRM_PERMS" = "s" ]; then
    echo "--- CORRIGIENDO PERMISOS ---" | tee -a $REPORTE
    find "$WP_PATH" -type f -name "*.php" -exec chmod 644 {} \; 2>&1 | tee -a $REPORTE
    echo "✔️  Archivos PHP → 644 aplicado" | tee -a $REPORTE
    find "$WP_PATH" -type d -exec chmod 755 {} \; 2>&1 | tee -a $REPORTE
    echo "✔️  Carpetas → 755 aplicado" | tee -a $REPORTE
    chmod 600 "$WP_PATH/wp-config.php" 2>&1 | tee -a $REPORTE
    echo "✔️  wp-config.php → 600 aplicado" | tee -a $REPORTE
    chmod 644 "$WP_PATH/.htaccess" 2>&1 | tee -a $REPORTE
    echo "✔️  .htaccess → 644 aplicado" | tee -a $REPORTE
else
    echo "⚠️  Corrección de permisos omitida por el usuario" | tee -a $REPORTE
fi

# ============================================================
# ARCHIVOS DE INFORMATION DISCLOSURE
# readme.html y license.txt vuelven con cada actualización de WP
# ============================================================

echo "" | tee -a $REPORTE
echo "--- ARCHIVOS DE INFORMATION DISCLOSURE ---" | tee -a $REPORTE
DISCLOSURE_FILES=("readme.html" "license.txt" "wp-links-opml.php" "wp-trackback.php")
FOUND_DISCLOSURE=()

for FILE in "${DISCLOSURE_FILES[@]}"; do
    if [ -f "$WP_PATH/$FILE" ]; then
        echo "⚠️  $FILE existe — expone información del servidor" | tee -a $REPORTE
        FOUND_DISCLOSURE+=("$FILE")
    else
        echo "✔️  $FILE — no existe" | tee -a $REPORTE
    fi
done

if [ ${#FOUND_DISCLOSURE[@]} -gt 0 ]; then
    echo "" | tee -a $REPORTE
    read -p "¿Eliminar archivos de information disclosure? (s/n): " CONFIRM_DISCLOSURE
    if [ "$CONFIRM_DISCLOSURE" = "s" ]; then
        for FILE in "${FOUND_DISCLOSURE[@]}"; do
            rm "$WP_PATH/$FILE" 2>&1 | tee -a $REPORTE
            echo "✔️  $FILE eliminado" | tee -a $REPORTE
        done
    else
        echo "⚠️  Eliminación omitida por el usuario" | tee -a $REPORTE
    fi
fi

# ============================================================
# VERIFICACIÓN POST-HARDENING
# ============================================================

echo "" | tee -a $REPORTE
echo "--- VERIFICACIÓN POST-HARDENING ---" | tee -a $REPORTE

echo "Defines actuales:" | tee -a $REPORTE
for DEFINE in DISALLOW_FILE_EDIT DISALLOW_FILE_MODS FORCE_SSL_ADMIN WP_DEBUG DISABLE_WP_CRON; do
    VALUE=$(wp --path="$WP_PATH" config get "$DEFINE" 2>/dev/null)
    echo "   $DEFINE = $VALUE" | tee -a $REPORTE
done

echo "" | tee -a $REPORTE
echo "Archivos PHP con 777 (debe estar vacío):" | tee -a $REPORTE
POST_777=$(find "$WP_PATH" -type f -name "*.php" -perm 0777 2>/dev/null)
if [ -n "$POST_777" ]; then
    echo "$POST_777" | tee -a $REPORTE
    echo "⚠️  Aún hay archivos con 777 — revisar manualmente" | tee -a $REPORTE
else
    echo "✔️  Sin archivos PHP con permisos 777" | tee -a $REPORTE
fi

echo "" | tee -a $REPORTE
echo "Permisos de wp-config.php:" | tee -a $REPORTE
stat -c "%a %n" "$WP_PATH/wp-config.php" 2>&1 | tee -a $REPORTE

# ============================================================
# CIERRE
# ============================================================

echo "" | tee -a $REPORTE
echo "================================" | tee -a $REPORTE
echo "HARDENING FINALIZADO - $FECHA" | tee -a $REPORTE
echo "Reporte guardado en: $REPORTE" | tee -a $REPORTE
echo "Backup de wp-config en: $BACKUP_DIR/wp-config.php.bak-$FECHA" | tee -a $REPORTE
echo "================================" | tee -a $REPORTE
