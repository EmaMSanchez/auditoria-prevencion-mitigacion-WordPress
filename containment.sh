#!/bin/bash

# ============================================================
# CONTENCIÓN — WORDPRESS
# Uso: bash containment.sh /ruta/al/wordpress
#
# PRIMER script a correr ante un incidente confirmado.
# Contiene el daño antes de analizar o remediar.
# Cada acción pide confirmación individual.
# No borra nada — solo protege y preserva evidencia.
# ============================================================

FECHA=$(date +%Y-%m-%d_%H-%M-%S)
WP_PATH=$1
REPORTE=~/scripts/reporte-containment-$FECHA.txt
SNAPSHOT_DIR=~/scripts/snapshots/snapshot-$FECHA

# ============================================================
# VALIDACIONES PREVIAS
# ============================================================

if [ -z "$WP_PATH" ]; then
    echo "Uso: bash containment.sh /ruta/al/wordpress"
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
mkdir -p "$SNAPSHOT_DIR"

# ============================================================
# ENCABEZADO
# ============================================================

echo "================================" | tee $REPORTE
echo "CONTENCIÓN DE INCIDENTE - $FECHA" | tee -a $REPORTE
echo "Sitio: $WP_PATH" | tee -a $REPORTE
echo "================================" | tee -a $REPORTE
echo "" | tee -a $REPORTE
echo "⚠️  Este script contiene el incidente sin borrar evidencia." | tee -a $REPORTE
echo "   Cada acción requiere confirmación individual." | tee -a $REPORTE
echo "   Después de este script: correr audit-post-incidente.sh" | tee -a $REPORTE

# ============================================================
# PASO 1 — SNAPSHOT FORENSE (obligatorio, sin confirmación)
# Se ejecuta siempre antes de cualquier otra acción.
# Preserva el estado del servidor en el momento del incidente.
# ============================================================

echo "" | tee -a $REPORTE
echo "--- PASO 1: SNAPSHOT FORENSE ---" | tee -a $REPORTE
echo "Generando snapshot — esto puede tardar..." | tee -a $REPORTE

# Export de la base de datos completa
wp --path="$WP_PATH" db export "$SNAPSHOT_DIR/db-snapshot-$FECHA.sql" 2>&1 | tee -a $REPORTE
if [ $? -eq 0 ]; then
    echo "✔️  DB exportada: $SNAPSHOT_DIR/db-snapshot-$FECHA.sql" | tee -a $REPORTE
else
    echo "❌ Error al exportar DB — continuar con precaución" | tee -a $REPORTE
fi

# Copia de archivos críticos
cp "$WP_PATH/wp-config.php" "$SNAPSHOT_DIR/wp-config-snapshot.php" 2>/dev/null
cp "$WP_PATH/.htaccess" "$SNAPSHOT_DIR/htaccess-snapshot.txt" 2>/dev/null
echo "✔️  Archivos críticos copiados al snapshot" | tee -a $REPORTE

# Lista de archivos PHP con fecha y permisos al momento del incidente
find "$WP_PATH" -name "*.php" -type f \
    -printf "%M %u %g %TY-%Tm-%Td_%TH:%TM %p\n" 2>/dev/null \
    > "$SNAPSHOT_DIR/php-files-estado.txt"
echo "✔️  Estado de archivos PHP guardado" | tee -a $REPORTE
echo "   Snapshot en: $SNAPSHOT_DIR" | tee -a $REPORTE

# ============================================================
# PASO 2 — MODO MANTENIMIENTO
# ============================================================

echo "" | tee -a $REPORTE
echo "--- PASO 2: MODO MANTENIMIENTO ---" | tee -a $REPORTE
MAINT_STATUS=$(wp --path="$WP_PATH" maintenance-mode status 2>/dev/null)
echo "Estado actual: $MAINT_STATUS" | tee -a $REPORTE

read -p "¿Activar modo mantenimiento? (s/n): " CONFIRM_MAINT
if [ "$CONFIRM_MAINT" = "s" ]; then
    wp --path="$WP_PATH" maintenance-mode activate 2>&1 | tee -a $REPORTE
    echo "✔️  Modo mantenimiento activado — el sitio no es visible para visitantes" | tee -a $REPORTE
    echo "   Para desactivar: wp --path=$WP_PATH maintenance-mode deactivate" | tee -a $REPORTE
else
    echo "⚠️  Modo mantenimiento omitido — el sitio sigue públicamente accesible" | tee -a $REPORTE
fi

# ============================================================
# PASO 3 — REVISIÓN DE USUARIOS ADMINISTRADORES
# ============================================================

echo "" | tee -a $REPORTE
echo "--- PASO 3: USUARIOS ADMINISTRADORES ---" | tee -a $REPORTE
echo "Usuarios con rol administrator:" | tee -a $REPORTE
wp --path="$WP_PATH" user list --role=administrator \
    --fields=ID,user_login,user_email,user_registered 2>&1 | tee -a $REPORTE

# Comparar con baseline si existe
BASELINE_DIR=~/.wp-baseline
if [ -f "$BASELINE_DIR/baseline-users.txt" ]; then
    echo "" | tee -a $REPORTE
    echo "Diferencias respecto al baseline:" | tee -a $REPORTE
    DIFF_USERS=$(diff "$BASELINE_DIR/baseline-users.txt" \
        <(wp --path="$WP_PATH" user list --fields=user_login,user_email,roles 2>/dev/null))
    if [ -n "$DIFF_USERS" ]; then
        echo "⚠️  Cambios detectados en usuarios:" | tee -a $REPORTE
        echo "$DIFF_USERS" | tee -a $REPORTE
    else
        echo "✔️  Sin cambios respecto al baseline" | tee -a $REPORTE
    fi
else
    echo "⚠️  Sin baseline de usuarios para comparar" | tee -a $REPORTE
fi

echo "" | tee -a $REPORTE
read -p "¿Deshabilitar algún usuario sospechoso? Ingresá el ID (o Enter para omitir): " USER_ID
if [ -n "$USER_ID" ]; then
    wp --path="$WP_PATH" user update "$USER_ID" --user_pass="$(openssl rand -base64 32)" 2>&1 | tee -a $REPORTE
    echo "✔️  Contraseña del usuario ID $USER_ID reseteada a valor aleatorio" | tee -a $REPORTE
    echo "   Para eliminar definitivamente: usar remediacion.sh" | tee -a $REPORTE
fi

# ============================================================
# PASO 4 — BLOQUEO DE XMLRPC
# ============================================================

echo "" | tee -a $REPORTE
echo "--- PASO 4: BLOQUEO DE XMLRPC ---" | tee -a $REPORTE

# Verificar si xmlrpc.php existe
if [ ! -f "$WP_PATH/xmlrpc.php" ]; then
    echo "✔️  xmlrpc.php no existe en el servidor" | tee -a $REPORTE
else
    # Verificar si ya está bloqueado en .htaccess
    if grep -q "xmlrpc.php" "$WP_PATH/.htaccess" 2>/dev/null; then
        echo "✔️  xmlrpc.php ya tiene regla en .htaccess" | tee -a $REPORTE
    else
        echo "⚠️  xmlrpc.php existe y no tiene bloqueo en .htaccess" | tee -a $REPORTE
        read -p "¿Agregar bloqueo de xmlrpc.php en .htaccess? (s/n): " CONFIRM_XMLRPC
        if [ "$CONFIRM_XMLRPC" = "s" ]; then
            # Insertar al inicio del .htaccess, antes de las reglas de WP
            XMLRPC_BLOCK="\n# BLOQUEO XMLRPC - agregado por containment.sh $FECHA\n<Files xmlrpc.php>\n    Order Allow,Deny\n    Deny from all\n</Files>\n"
            sed -i "1s|^|$XMLRPC_BLOCK|" "$WP_PATH/.htaccess" 2>&1 | tee -a $REPORTE
            echo "✔️  Bloqueo de xmlrpc.php agregado en .htaccess" | tee -a $REPORTE
        else
            echo "⚠️  xmlrpc.php no bloqueado" | tee -a $REPORTE
        fi
    fi
fi

# ============================================================
# PASO 5 — BLOQUEO DE PHP EN UPLOADS
# ============================================================

echo "" | tee -a $REPORTE
echo "--- PASO 5: BLOQUEO DE PHP EN UPLOADS ---" | tee -a $REPORTE

PHP_EN_UPLOADS=$(find "$WP_PATH/wp-content/uploads" -name "*.php" 2>/dev/null)
if [ -n "$PHP_EN_UPLOADS" ]; then
    echo "⚠️  Archivos PHP detectados en uploads:" | tee -a $REPORTE
    echo "$PHP_EN_UPLOADS" | tee -a $REPORTE
    read -p "¿Agregar bloqueo de PHP en uploads vía .htaccess? (s/n): " CONFIRM_UPLOADS
    if [ "$CONFIRM_UPLOADS" = "s" ]; then
        UPLOADS_HTACCESS="$WP_PATH/wp-content/uploads/.htaccess"
        echo "<Files *.php>" > "$UPLOADS_HTACCESS"
        echo "    deny from all" >> "$UPLOADS_HTACCESS"
        echo "</Files>" >> "$UPLOADS_HTACCESS"
        echo "✔️  .htaccess creado en uploads — ejecución de PHP bloqueada" | tee -a $REPORTE
        echo "   Los archivos PHP siguen ahí — remediacion.sh los eliminará" | tee -a $REPORTE
    fi
else
    echo "✔️  Sin archivos PHP en uploads" | tee -a $REPORTE
fi

# ============================================================
# CIERRE
# ============================================================

echo "" | tee -a $REPORTE
echo "================================" | tee -a $REPORTE
echo "CONTENCIÓN FINALIZADA - $FECHA" | tee -a $REPORTE
echo "================================" | tee -a $REPORTE
echo "Snapshot forense en: $SNAPSHOT_DIR" | tee -a $REPORTE
echo "Reporte guardado en: $REPORTE" | tee -a $REPORTE
echo "" | tee -a $REPORTE
echo "Próximo paso: bash audit-post-incidente.sh $WP_PATH" | tee -a $REPORTE
echo "================================" | tee -a $REPORTE
