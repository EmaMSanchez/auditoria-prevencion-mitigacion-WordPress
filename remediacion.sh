#!/bin/bash

# ============================================================
# REMEDIACIÓN — WORDPRESS
# Uso: bash remediacion.sh /ruta/hallazgos-FECHA.txt /ruta/al/wordpress
#
# Lee el archivo de hallazgos generado por audit-post-incidente.sh
# y propone una acción por cada hallazgo con confirmación manual.
# Genera un backup obligatorio antes de cualquier acción.
# Es el único script que borra archivos y modifica la DB.
# ============================================================

FECHA=$(date +%Y-%m-%d_%H-%M-%S)
HALLAZGOS_FILE=$1
WP_PATH=$2
REPORTE=~/scripts/reporte-remediacion-$FECHA.txt
LOG_ACCIONES=~/scripts/log-acciones-$FECHA.txt
BACKUP_DIR=~/scripts/backups/remediacion-$FECHA

ACCIONES_TOMADAS=0
ACCIONES_OMITIDAS=0

# ============================================================
# VALIDACIONES PREVIAS
# ============================================================

if [ -z "$HALLAZGOS_FILE" ] || [ -z "$WP_PATH" ]; then
    echo "Uso: bash remediacion.sh /ruta/hallazgos-FECHA.txt /ruta/al/wordpress"
    exit 1
fi

if [ ! -f "$HALLAZGOS_FILE" ]; then
    echo "❌ Error: Archivo de hallazgos no encontrado: $HALLAZGOS_FILE"
    echo "   Primero correr: audit-post-incidente.sh"
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
echo "REMEDIACIÓN - $FECHA" | tee -a $REPORTE
echo "Sitio: $WP_PATH" | tee -a $REPORTE
echo "Hallazgos: $HALLAZGOS_FILE" | tee -a $REPORTE
echo "================================" | tee -a $REPORTE
echo "" | tee -a $REPORTE
echo "⚠️  Este script modifica y elimina archivos y registros de DB." | tee -a $REPORTE
echo "   Cada hallazgo requiere confirmación individual." | tee -a $REPORTE
echo "   Las acciones tomadas quedan registradas en: $LOG_ACCIONES" | tee -a $REPORTE

# Inicializar log de acciones
echo "# LOG DE ACCIONES - $FECHA" > "$LOG_ACCIONES"
echo "# Formato: TIMESTAMP|ACCION|DETALLE|RESULTADO" >> "$LOG_ACCIONES"

# ============================================================
# PASO 1 — BACKUP OBLIGATORIO
# Si falla el backup, el script se detiene.
# No hay remediación sin backup previo.
# ============================================================

echo "" | tee -a $REPORTE
echo "--- PASO 1: BACKUP OBLIGATORIO ---" | tee -a $REPORTE
echo "Generando backup antes de cualquier acción..." | tee -a $REPORTE

wp --path="$WP_PATH" db export "$BACKUP_DIR/db-pre-remediacion.sql" 2>&1 | tee -a $REPORTE
if [ $? -ne 0 ]; then
    echo "❌ Error al generar backup de DB — abortando remediación" | tee -a $REPORTE
    echo "$(date)|BACKUP|DB export|FALLIDO — remediación abortada" >> "$LOG_ACCIONES"
    exit 1
fi
echo "✔️  DB exportada: $BACKUP_DIR/db-pre-remediacion.sql" | tee -a $REPORTE

cp "$WP_PATH/wp-config.php" "$BACKUP_DIR/wp-config-pre-remediacion.php" 2>/dev/null
cp "$WP_PATH/.htaccess" "$BACKUP_DIR/htaccess-pre-remediacion.txt" 2>/dev/null
echo "✔️  Archivos críticos copiados al backup" | tee -a $REPORTE
echo "   Backup en: $BACKUP_DIR" | tee -a $REPORTE
echo "$(date)|BACKUP|DB + archivos críticos|OK — $BACKUP_DIR" >> "$LOG_ACCIONES"

# ============================================================
# PASO 2 — PROCESAMIENTO DE HALLAZGOS
# Lee el archivo línea por línea.
# Por cada hallazgo: muestra el tipo, propone acción, pide s/n.
# ============================================================

echo "" | tee -a $REPORTE
echo "--- PASO 2: PROCESAMIENTO DE HALLAZGOS ---" | tee -a $REPORTE
echo "Se procesará cada hallazgo individualmente." | tee -a $REPORTE
echo "" | tee -a $REPORTE

TOTAL_HALLAZGOS=$(grep -v "^#" "$HALLAZGOS_FILE" | grep -c "|")
echo "Total de hallazgos a procesar: $TOTAL_HALLAZGOS" | tee -a $REPORTE
echo "" | tee -a $REPORTE

CONTADOR=0

while IFS='|' read -r TIPO DETALLE DESCRIPCION; do
    # Saltar líneas de comentario o vacías
    [[ "$TIPO" =~ ^#.*$ ]] && continue
    [ -z "$TIPO" ] && continue

    CONTADOR=$((CONTADOR + 1))

    echo "----------------------------------------" | tee -a $REPORTE
    echo "Hallazgo $CONTADOR/$TOTAL_HALLAZGOS" | tee -a $REPORTE
    echo "Tipo:        $TIPO" | tee -a $REPORTE
    echo "Detalle:     $DETALLE" | tee -a $REPORTE
    echo "Descripción: $DESCRIPCION" | tee -a $REPORTE
    echo "" | tee -a $REPORTE

    case "$TIPO" in

        # --------------------------------------------------------
        # ARCHIVO — eliminar archivo malicioso
        # --------------------------------------------------------
        ARCHIVO)
            if [ ! -f "$DETALLE" ]; then
                echo "ℹ️  Archivo ya no existe: $DETALLE" | tee -a $REPORTE
                echo "$(date)|OMITIDO|$DETALLE|Archivo no encontrado" >> "$LOG_ACCIONES"
                ACCIONES_OMITIDAS=$((ACCIONES_OMITIDAS + 1))
                continue
            fi

            echo "Contenido del archivo (primeras 20 líneas):" | tee -a $REPORTE
            head -20 "$DETALLE" | tee -a $REPORTE
            echo "" | tee -a $REPORTE
            echo "Opciones:" | tee -a $REPORTE
            echo "  1) Eliminar el archivo permanentemente" | tee -a $REPORTE
            echo "  2) Ver archivo completo (cat)" | tee -a $REPORTE
            echo "  3) Ver stat del archivo" | tee -a $REPORTE
            echo "  n) Omitir este hallazgo" | tee -a $REPORTE
            read -p "Opción: " ACCION_ARCHIVO

            case "$ACCION_ARCHIVO" in
                1)
                    cp "$DETALLE" "$BACKUP_DIR/$(basename $DETALLE)-backup" 2>/dev/null
                    rm -f "$DETALLE" 2>&1 | tee -a $REPORTE
                    echo "✔️  Archivo eliminado: $DETALLE" | tee -a $REPORTE
                    echo "   Copia de seguridad en: $BACKUP_DIR/$(basename $DETALLE)-backup" | tee -a $REPORTE
                    echo "$(date)|ELIMINADO|$DETALLE|Archivo eliminado por operador" >> "$LOG_ACCIONES"
                    ACCIONES_TOMADAS=$((ACCIONES_TOMADAS + 1))
                    ;;
                2)
                    cat "$DETALLE" | tee -a $REPORTE
                    echo "⚠️  Hallazgo omitido — revisar manualmente" | tee -a $REPORTE
                    echo "$(date)|OMITIDO|$DETALLE|Operador eligió revisar manualmente" >> "$LOG_ACCIONES"
                    ACCIONES_OMITIDAS=$((ACCIONES_OMITIDAS + 1))
                    ;;
                3)
                    stat "$DETALLE" | tee -a $REPORTE
                    echo "⚠️  Hallazgo omitido — revisar manualmente" | tee -a $REPORTE
                    echo "$(date)|OMITIDO|$DETALLE|Operador eligió revisar manualmente" >> "$LOG_ACCIONES"
                    ACCIONES_OMITIDAS=$((ACCIONES_OMITIDAS + 1))
                    ;;
                *)
                    echo "⚠️  Hallazgo omitido por el operador" | tee -a $REPORTE
                    echo "$(date)|OMITIDO|$DETALLE|Omitido por operador" >> "$LOG_ACCIONES"
                    ACCIONES_OMITIDAS=$((ACCIONES_OMITIDAS + 1))
                    ;;
            esac
            ;;

        # --------------------------------------------------------
        # PERMISO — corregir permisos de archivo
        # --------------------------------------------------------
        PERMISO)
            if [ ! -f "$DETALLE" ]; then
                echo "ℹ️  Archivo no encontrado: $DETALLE" | tee -a $REPORTE
                ACCIONES_OMITIDAS=$((ACCIONES_OMITIDAS + 1))
                continue
            fi

            PERMS_ACTUAL=$(stat -c "%a" "$DETALLE" 2>/dev/null)
            echo "Permisos actuales: $PERMS_ACTUAL → Correcto: 644" | tee -a $REPORTE
            read -p "¿Corregir permisos a 644? (s/n): " CONFIRM_PERM

            if [ "$CONFIRM_PERM" = "s" ]; then
                chmod 644 "$DETALLE" 2>&1 | tee -a $REPORTE
                echo "✔️  Permisos corregidos: $DETALLE → 644" | tee -a $REPORTE
                echo "$(date)|PERMISO|$DETALLE|Cambiado de $PERMS_ACTUAL a 644" >> "$LOG_ACCIONES"
                ACCIONES_TOMADAS=$((ACCIONES_TOMADAS + 1))
            else
                echo "⚠️  Permiso no corregido" | tee -a $REPORTE
                echo "$(date)|OMITIDO|$DETALLE|Corrección de permisos omitida" >> "$LOG_ACCIONES"
                ACCIONES_OMITIDAS=$((ACCIONES_OMITIDAS + 1))
            fi
            ;;

        # --------------------------------------------------------
        # USUARIO — eliminar o resetear usuario sospechoso
        # --------------------------------------------------------
        USUARIO)
            echo "Opciones:" | tee -a $REPORTE
            echo "  Ingresá el ID del usuario sospechoso para actuar sobre él" | tee -a $REPORTE
            wp --path="$WP_PATH" user list \
                --fields=ID,user_login,user_email,roles 2>&1 | tee -a $REPORTE
            echo "" | tee -a $REPORTE
            echo "  1) Eliminar usuario (reasignar contenido al admin ID 1)" | tee -a $REPORTE
            echo "  2) Solo resetear contraseña a valor aleatorio" | tee -a $REPORTE
            echo "  n) Omitir" | tee -a $REPORTE
            read -p "Opción: " ACCION_USER

            case "$ACCION_USER" in
                1)
                    read -p "ID del usuario a eliminar: " DEL_USER_ID
                    wp --path="$WP_PATH" user delete "$DEL_USER_ID" --reassign=1 2>&1 | tee -a $REPORTE
                    echo "$(date)|USUARIO_ELIMINADO|ID:$DEL_USER_ID|Contenido reasignado a ID 1" >> "$LOG_ACCIONES"
                    ACCIONES_TOMADAS=$((ACCIONES_TOMADAS + 1))
                    ;;
                2)
                    read -p "ID del usuario a resetear: " RESET_USER_ID
                    NUEVA_PASS=$(openssl rand -base64 16)
                    wp --path="$WP_PATH" user update "$RESET_USER_ID" \
                        --user_pass="$NUEVA_PASS" 2>&1 | tee -a $REPORTE
                    echo "✔️  Contraseña reseteada — nueva contraseña: $NUEVA_PASS" | tee -a $REPORTE
                    echo "$(date)|USUARIO_RESETEADO|ID:$RESET_USER_ID|Contraseña cambiada a valor aleatorio" >> "$LOG_ACCIONES"
                    ACCIONES_TOMADAS=$((ACCIONES_TOMADAS + 1))
                    ;;
                *)
                    echo "⚠️  Hallazgo de usuario omitido" | tee -a $REPORTE
                    echo "$(date)|OMITIDO|usuario|Omitido por operador" >> "$LOG_ACCIONES"
                    ACCIONES_OMITIDAS=$((ACCIONES_OMITIDAS + 1))
                    ;;
            esac
            ;;

        # --------------------------------------------------------
        # DB — limpiar contenido malicioso en base de datos
        # --------------------------------------------------------
        DB)
            echo "Patrón encontrado en DB: $DETALLE" | tee -a $REPORTE
            echo "" | tee -a $REPORTE
            echo "  1) Simular limpieza (--dry-run, sin cambios reales)" | tee -a $REPORTE
            echo "  2) Ejecutar limpieza real (reemplaza patrón por vacío)" | tee -a $REPORTE
            echo "  n) Omitir" | tee -a $REPORTE
            read -p "Opción: " ACCION_DB

            case "$ACCION_DB" in
                1)
                    wp --path="$WP_PATH" search-replace "$DETALLE" "" --dry-run 2>&1 | tee -a $REPORTE
                    echo "ℹ️  Dry-run completado — ningún cambio aplicado" | tee -a $REPORTE
                    echo "$(date)|DB_DRYRUN|$DETALLE|Simulación ejecutada sin cambios" >> "$LOG_ACCIONES"
                    ACCIONES_OMITIDAS=$((ACCIONES_OMITIDAS + 1))
                    ;;
                2)
                    wp --path="$WP_PATH" search-replace "$DETALLE" "" 2>&1 | tee -a $REPORTE
                    echo "✔️  Limpieza de DB ejecutada para patrón: $DETALLE" | tee -a $REPORTE
                    echo "$(date)|DB_LIMPIADA|$DETALLE|Patrón eliminado de la DB" >> "$LOG_ACCIONES"
                    ACCIONES_TOMADAS=$((ACCIONES_TOMADAS + 1))
                    ;;
                *)
                    echo "⚠️  Hallazgo de DB omitido" | tee -a $REPORTE
                    echo "$(date)|OMITIDO|DB:$DETALLE|Omitido por operador" >> "$LOG_ACCIONES"
                    ACCIONES_OMITIDAS=$((ACCIONES_OMITIDAS + 1))
                    ;;
            esac
            ;;

        # --------------------------------------------------------
        # CORE — restaurar archivos del core comprometidos
        # --------------------------------------------------------
        CORE)
            echo "⚠️  Core comprometido — opciones:" | tee -a $REPORTE
            echo "  1) Descargar y reemplazar core limpio (wp core download --force)" | tee -a $REPORTE
            echo "  n) Omitir" | tee -a $REPORTE
            read -p "Opción: " ACCION_CORE

            if [ "$ACCION_CORE" = "1" ]; then
                wp --path="$WP_PATH" core download --force 2>&1 | tee -a $REPORTE
                echo "✔️  Core reemplazado con versión oficial limpia" | tee -a $REPORTE
                echo "$(date)|CORE_RESTAURADO|wp-core|Reemplazado con versión oficial" >> "$LOG_ACCIONES"
                ACCIONES_TOMADAS=$((ACCIONES_TOMADAS + 1))
            else
                echo "⚠️  Restauración de core omitida" | tee -a $REPORTE
                echo "$(date)|OMITIDO|wp-core|Omitido por operador" >> "$LOG_ACCIONES"
                ACCIONES_OMITIDAS=$((ACCIONES_OMITIDAS + 1))
            fi
            ;;

        # --------------------------------------------------------
        # Tipo no reconocido
        # --------------------------------------------------------
        *)
            echo "ℹ️  Tipo de hallazgo no reconocido: $TIPO — omitiendo" | tee -a $REPORTE
            echo "$(date)|OMITIDO|$TIPO:$DETALLE|Tipo no reconocido" >> "$LOG_ACCIONES"
            ACCIONES_OMITIDAS=$((ACCIONES_OMITIDAS + 1))
            ;;
    esac

    echo "" | tee -a $REPORTE

done < <(grep -v "^#" "$HALLAZGOS_FILE")

# ============================================================
# PASO 3 — VERIFICACIÓN POST-REMEDIACIÓN
# ============================================================

echo "" | tee -a $REPORTE
echo "--- PASO 3: VERIFICACIÓN POST-REMEDIACIÓN ---" | tee -a $REPORTE

echo "PHP en uploads (debe estar vacío):" | tee -a $REPORTE
POST_UPLOADS=$(find "$WP_PATH/wp-content/uploads" -name "*.php" 2>/dev/null)
if [ -n "$POST_UPLOADS" ]; then
    echo "⚠️  Aún hay PHP en uploads:" | tee -a $REPORTE
    echo "$POST_UPLOADS" | tee -a $REPORTE
else
    echo "✔️  Sin PHP en uploads" | tee -a $REPORTE
fi

echo "" | tee -a $REPORTE
echo "Archivos PHP con 777 (debe estar vacío):" | tee -a $REPORTE
POST_777=$(find "$WP_PATH" -type f -name "*.php" -perm 0777 2>/dev/null)
if [ -n "$POST_777" ]; then
    echo "⚠️  Aún hay archivos con 777:" | tee -a $REPORTE
    echo "$POST_777" | tee -a $REPORTE
else
    echo "✔️  Sin archivos PHP con 777" | tee -a $REPORTE
fi

echo "" | tee -a $REPORTE
echo "Integridad del core post-remediación:" | tee -a $REPORTE
wp --path="$WP_PATH" core verify-checksums 2>&1 | tee -a $REPORTE

# ============================================================
# RESUMEN FINAL
# ============================================================

echo "" | tee -a $REPORTE
echo "================================" | tee -a $REPORTE
echo "RESUMEN REMEDIACIÓN - $FECHA" | tee -a $REPORTE
echo "================================" | tee -a $REPORTE
echo "Total hallazgos procesados: $TOTAL_HALLAZGOS" | tee -a $REPORTE
echo "Acciones tomadas:           $ACCIONES_TOMADAS" | tee -a $REPORTE
echo "Acciones omitidas:          $ACCIONES_OMITIDAS" | tee -a $REPORTE
echo "" | tee -a $REPORTE
echo "Backup pre-remediación en:  $BACKUP_DIR" | tee -a $REPORTE
echo "Log de acciones en:         $LOG_ACCIONES" | tee -a $REPORTE
echo "Reporte completo en:        $REPORTE" | tee -a $REPORTE
echo "" | tee -a $REPORTE
echo "Próximos pasos:" | tee -a $REPORTE
echo "  1. Correr hardening.sh para reforzar la configuración" | tee -a $REPORTE
echo "  2. Regenerar baseline.sh con el servidor limpio" | tee -a $REPORTE
echo "  3. Desactivar modo mantenimiento si estaba activo:" | tee -a $REPORTE
echo "     wp --path=$WP_PATH maintenance-mode deactivate" | tee -a $REPORTE
echo "================================" | tee -a $REPORTE
