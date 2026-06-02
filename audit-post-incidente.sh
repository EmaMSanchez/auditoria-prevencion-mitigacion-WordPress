#!/bin/bash

# ============================================================
# AUDITORÍA POST-INCIDENTE — WORDPRESS
# Uso: bash audit-post-incidente.sh /ruta/al/wordpress
#
# Correr DESPUÉS de containment.sh.
# Análisis forense profundo — escanea TODO, no solo cambios recientes.
# Genera hallazgos-FECHA.txt que usa remediacion.sh para actuar.
# No modifica nada. Solo analiza y reporta.
# ============================================================

FECHA=$(date +%Y-%m-%d_%H-%M-%S)
WP_PATH=$1
REPORTE=~/scripts/reporte-post-incidente-$FECHA.txt
HALLAZGOS_FILE=~/scripts/hallazgos-$FECHA.txt
BASELINE_DIR=~/.wp-baseline
HALLAZGOS=0

# ============================================================
# VALIDACIONES PREVIAS
# ============================================================

if [ -z "$WP_PATH" ]; then
    echo "Uso: bash audit-post-incidente.sh /ruta/al/wordpress"
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

# ============================================================
# ENCABEZADO
# ============================================================

echo "================================" | tee $REPORTE
echo "AUDITORÍA POST-INCIDENTE - $FECHA" | tee -a $REPORTE
echo "Sitio: $WP_PATH" | tee -a $REPORTE
echo "================================" | tee -a $REPORTE
echo "" | tee -a $REPORTE
echo "Archivo de hallazgos: $HALLAZGOS_FILE" | tee -a $REPORTE
echo "(Este archivo será leído por remediacion.sh)" | tee -a $REPORTE

# Inicializar archivo de hallazgos
echo "# HALLAZGOS - $FECHA" > "$HALLAZGOS_FILE"
echo "# Formato: TIPO|DETALLE|DESCRIPCION" >> "$HALLAZGOS_FILE"
echo "# Generado por: audit-post-incidente.sh" >> "$HALLAZGOS_FILE"

# ============================================================
# DETECCIÓN MULTISITE
# ============================================================

echo "" | tee -a $REPORTE
echo "--- TIPO DE INSTALACIÓN ---" | tee -a $REPORTE
IS_MULTISITE=$(wp --path="$WP_PATH" config get MULTISITE 2>/dev/null)
if [ "$IS_MULTISITE" = "true" ]; then
    echo "⚠️  Instalación MULTISITE" | tee -a $REPORTE
    NETWORK_FLAG="--network"
else
    echo "✔️  Instalación single site" | tee -a $REPORTE
    NETWORK_FLAG=""
fi

# ============================================================
# 1. INTEGRIDAD DEL CORE
# ============================================================

echo "" | tee -a $REPORTE
echo "--- 1. INTEGRIDAD DEL CORE ---" | tee -a $REPORTE
CORE_CHECK=$(wp --path="$WP_PATH" core verify-checksums 2>&1)
echo "$CORE_CHECK" | tee -a $REPORTE
if echo "$CORE_CHECK" | grep -qiE "Error|Warning|doesn't verify|modified"; then
    echo "⚠️  HALLAZGO: Core comprometido" | tee -a $REPORTE
    echo "CORE|wp-core|Integridad del core comprometida — verify-checksums fallido" >> "$HALLAZGOS_FILE"
    HALLAZGOS=$((HALLAZGOS + 1))
fi

# ============================================================
# 2. COMPARACIÓN DE HASHES CONTRA BASELINE
# ============================================================

echo "" | tee -a $REPORTE
echo "--- 2. COMPARACIÓN DE HASHES CON BASELINE ---" | tee -a $REPORTE
if [ -f "$BASELINE_DIR/baseline-hashes.sha256" ]; then
    HASH_FAILS=$(sha256sum --check "$BASELINE_DIR/baseline-hashes.sha256" 2>/dev/null | grep "FAILED")
    if [ -n "$HASH_FAILS" ]; then
        echo "⚠️  Archivos con hash diferente al baseline:" | tee -a $REPORTE
        echo "$HASH_FAILS" | tee -a $REPORTE
        while IFS= read -r linea; do
            ARCHIVO=$(echo "$linea" | awk '{print $1}' | sed 's|:||')
            echo "ARCHIVO|$ARCHIVO|Hash diferente al baseline — posible modificación maliciosa" >> "$HALLAZGOS_FILE"
            HALLAZGOS=$((HALLAZGOS + 1))
        done <<< "$HASH_FAILS"
    else
        echo "✔️  Todos los hashes coinciden con el baseline" | tee -a $REPORTE
    fi
else
    echo "⚠️  Sin baseline de hashes — omitiendo comparación" | tee -a $REPORTE
fi

# ============================================================
# 3. GREP PROFUNDO — PATRONES MALICIOSOS EN TODOS LOS PHP
# A diferencia del diario, escanea todos los archivos sin excepción.
# ============================================================

echo "" | tee -a $REPORTE
echo "--- 3. PATRONES MALICIOSOS EN TODOS LOS PHP ---" | tee -a $REPORTE
echo "Escaneando todos los archivos PHP (puede tardar)..." | tee -a $REPORTE

PATRONES=(
    'eval\s*\(\s*base64_decode'
    'shell_exec\s*\('
    'passthru\s*\('
    'system\s*\('
    'gzuncompress\s*\('
    'gzinflate\s*\('
    'str_rot13\s*\('
    'preg_replace.*\/e'
    'assert\s*\(\s*\$'
    'create_function\s*\('
)

for PATRON in "${PATRONES[@]}"; do
    RESULTADO=$(grep -rliE "$PATRON" "$WP_PATH" --include="*.php" 2>/dev/null)
    if [ -n "$RESULTADO" ]; then
        echo "⚠️  Patrón '$PATRON' encontrado en:" | tee -a $REPORTE
        echo "$RESULTADO" | tee -a $REPORTE
        while IFS= read -r archivo; do
            echo "ARCHIVO|$archivo|Patrón malicioso: $PATRON" >> "$HALLAZGOS_FILE"
            HALLAZGOS=$((HALLAZGOS + 1))
        done <<< "$RESULTADO"
    else
        echo "✔️  '$PATRON' — no encontrado" | tee -a $REPORTE
    fi
done

# Web shells — acceso vía POST/GET/REQUEST
WEBSHELLS=$(grep -rliE '\$_(POST|GET|REQUEST)\s*\[' "$WP_PATH" --include="*.php" 2>/dev/null \
    | grep -vE "wp-includes|wp-admin|/themes/|/plugins/")
if [ -n "$WEBSHELLS" ]; then
    echo "⚠️  Posibles web shells (fuera de rutas legítimas):" | tee -a $REPORTE
    echo "$WEBSHELLS" | tee -a $REPORTE
    while IFS= read -r archivo; do
        echo "ARCHIVO|$archivo|Posible web shell — recibe datos externos vía POST/GET" >> "$HALLAZGOS_FILE"
        HALLAZGOS=$((HALLAZGOS + 1))
    done <<< "$WEBSHELLS"
fi

# ============================================================
# 4. ARCHIVOS PHP EN RUTAS INCORRECTAS
# ============================================================

echo "" | tee -a $REPORTE
echo "--- 4. PHP EN RUTAS INCORRECTAS ---" | tee -a $REPORTE

# PHP en uploads
PHP_UPLOADS=$(find "$WP_PATH/wp-content/uploads" -name "*.php" 2>/dev/null)
if [ -n "$PHP_UPLOADS" ]; then
    echo "⚠️  PHP en uploads:" | tee -a $REPORTE
    echo "$PHP_UPLOADS" | tee -a $REPORTE
    while IFS= read -r archivo; do
        echo "ARCHIVO|$archivo|PHP en uploads — nunca debe existir aquí" >> "$HALLAZGOS_FILE"
        HALLAZGOS=$((HALLAZGOS + 1))
    done <<< "$PHP_UPLOADS"
else
    echo "✔️  Sin PHP en uploads" | tee -a $REPORTE
fi

# PHP en wp-content/upgrade (fuera de actualizaciones)
PHP_UPGRADE=$(find "$WP_PATH/wp-content/upgrade" -name "*.php" 2>/dev/null)
if [ -n "$PHP_UPGRADE" ]; then
    echo "⚠️  PHP en wp-content/upgrade:" | tee -a $REPORTE
    echo "$PHP_UPGRADE" | tee -a $REPORTE
    while IFS= read -r archivo; do
        echo "ARCHIVO|$archivo|PHP en /upgrade — sospechoso fuera de proceso de actualización" >> "$HALLAZGOS_FILE"
        HALLAZGOS=$((HALLAZGOS + 1))
    done <<< "$PHP_UPGRADE"
else
    echo "✔️  Sin PHP sospechoso en upgrade" | tee -a $REPORTE
fi

# ============================================================
# 5. ARCHIVOS CON PERMISOS 777
# ============================================================

echo "" | tee -a $REPORTE
echo "--- 5. PERMISOS 777 ---" | tee -a $REPORTE
PERMS_777=$(find "$WP_PATH" -type f -name "*.php" -perm 0777 2>/dev/null)
if [ -n "$PERMS_777" ]; then
    echo "⚠️  Archivos PHP con permisos 777:" | tee -a $REPORTE
    echo "$PERMS_777" | tee -a $REPORTE
    while IFS= read -r archivo; do
        echo "PERMISO|$archivo|Permisos 777 — corrección necesaria" >> "$HALLAZGOS_FILE"
        HALLAZGOS=$((HALLAZGOS + 1))
    done <<< "$PERMS_777"
else
    echo "✔️  Sin archivos PHP con permisos 777" | tee -a $REPORTE
fi

# ============================================================
# 6. ARCHIVOS MODIFICADOS RECIENTEMENTE
# ============================================================

echo "" | tee -a $REPORTE
echo "--- 6. ARCHIVOS MODIFICADOS — ÚLTIMAS 72HS ---" | tee -a $REPORTE
touch -d "72 hours ago" /tmp/ref-incidente
MODIFIED_72=$(find "$WP_PATH" -name "*.php" -newer /tmp/ref-incidente 2>/dev/null)
if [ -n "$MODIFIED_72" ]; then
    echo "⚠️  $(echo "$MODIFIED_72" | wc -l) archivo(s) PHP modificados en las últimas 72hs:" | tee -a $REPORTE
    echo "$MODIFIED_72" | tee -a $REPORTE
    echo "" | tee -a $REPORTE
    echo "Detalle (stat) de cada archivo:" | tee -a $REPORTE
    while IFS= read -r archivo; do
        stat "$archivo" 2>/dev/null | tee -a $REPORTE
        echo "---" | tee -a $REPORTE
        echo "ARCHIVO|$archivo|Modificado en las últimas 72hs — revisar manualmente" >> "$HALLAZGOS_FILE"
        HALLAZGOS=$((HALLAZGOS + 1))
    done <<< "$MODIFIED_72"
else
    echo "✔️  Sin archivos PHP modificados en las últimas 72hs" | tee -a $REPORTE
fi

# ============================================================
# 7. USUARIOS — ANÁLISIS COMPLETO
# ============================================================

echo "" | tee -a $REPORTE
echo "--- 7. USUARIOS ---" | tee -a $REPORTE
echo "Lista completa:" | tee -a $REPORTE
wp --path="$WP_PATH" user list \
    --fields=ID,user_login,user_email,roles,user_registered 2>&1 | tee -a $REPORTE

# Comparar con baseline
if [ -f "$BASELINE_DIR/baseline-users.txt" ]; then
    DIFF_USERS=$(diff "$BASELINE_DIR/baseline-users.txt" \
        <(wp --path="$WP_PATH" user list --fields=user_login,user_email,roles 2>/dev/null))
    if [ -n "$DIFF_USERS" ]; then
        echo "⚠️  Diferencias respecto al baseline:" | tee -a $REPORTE
        echo "$DIFF_USERS" | tee -a $REPORTE
        echo "USUARIO|diff-usuarios|Cambios en usuarios respecto al baseline — revisar manualmente" >> "$HALLAZGOS_FILE"
        HALLAZGOS=$((HALLAZGOS + 1))
    else
        echo "✔️  Usuarios sin cambios respecto al baseline" | tee -a $REPORTE
    fi
fi

# Detectar usuarios con post_author=0 (creados directo desde DB)
echo "" | tee -a $REPORTE
echo "Posts con post_author=0 (creados directamente en DB — señal de compromiso):" | tee -a $REPORTE
POSTS_AUTHOR_0=$(wp --path="$WP_PATH" post list --post_author=0 \
    --fields=ID,post_title,post_status,post_type --format=table 2>/dev/null)
if [ -n "$POSTS_AUTHOR_0" ]; then
    echo "⚠️  $POSTS_AUTHOR_0" | tee -a $REPORTE
    echo "DB|post_author=0|Posts creados directamente en DB — DB posiblemente comprometida" >> "$HALLAZGOS_FILE"
    HALLAZGOS=$((HALLAZGOS + 1))
else
    echo "✔️  Sin posts con post_author=0" | tee -a $REPORTE
fi

# ============================================================
# 8. PLUGINS — BÚSQUEDA DE NOMBRES SOSPECHOSOS
# ============================================================

echo "" | tee -a $REPORTE
echo "--- 8. PLUGINS ---" | tee -a $REPORTE
wp --path="$WP_PATH" plugin list \
    --fields=name,status,version,update 2>&1 | tee -a $REPORTE

# Comparar con baseline
if [ -f "$BASELINE_DIR/baseline-plugins.txt" ]; then
    DIFF_PLUGINS=$(diff "$BASELINE_DIR/baseline-plugins.txt" \
        <(wp --path="$WP_PATH" plugin list --fields=name,status,version,update 2>/dev/null))
    if [ -n "$DIFF_PLUGINS" ]; then
        echo "⚠️  Diferencias en plugins respecto al baseline:" | tee -a $REPORTE
        echo "$DIFF_PLUGINS" | tee -a $REPORTE
        echo "PLUGIN|diff-plugins|Cambios en plugins respecto al baseline — revisar manualmente" >> "$HALLAZGOS_FILE"
        HALLAZGOS=$((HALLAZGOS + 1))
    else
        echo "✔️  Plugins sin cambios respecto al baseline" | tee -a $REPORTE
    fi
fi

# ============================================================
# 9. BASE DE DATOS — BÚSQUEDA COMPLETA (TIER 1, 2 Y 3)
# ============================================================

echo "" | tee -a $REPORTE
echo "--- 9. BASE DE DATOS — BÚSQUEDA COMPLETA ---" | tee -a $REPORTE
echo "Nota: puede tardar en bases de datos grandes." | tee -a $REPORTE

# Tier 1 — siempre
TIER1=("eval(base64_decode" "base64_decode" "<script" "document.write" "unescape(")
# Tier 2 — profundidad media
TIER2=("String.fromCharCode" "iframe" "wp_redirect" "fromCharCode")
# Tier 3 — contexto específico
TIER3=("http://" "chmod" "shell_exec" "passthru")

echo "" | tee -a $REPORTE
echo "Tier 1:" | tee -a $REPORTE
for PATRON in "${TIER1[@]}"; do
    RESULT=$(wp --path="$WP_PATH" db search "$PATRON" $NETWORK_FLAG 2>/dev/null)
    if [ -n "$RESULT" ]; then
        echo "⚠️  '$PATRON' encontrado en DB" | tee -a $REPORTE
        echo "$RESULT" | tee -a $REPORTE
        echo "DB|$PATRON|Patrón tier 1 encontrado en base de datos" >> "$HALLAZGOS_FILE"
        HALLAZGOS=$((HALLAZGOS + 1))
    else
        echo "✔️  '$PATRON' — no encontrado" | tee -a $REPORTE
    fi
done

echo "" | tee -a $REPORTE
echo "Tier 2:" | tee -a $REPORTE
for PATRON in "${TIER2[@]}"; do
    RESULT=$(wp --path="$WP_PATH" db search "$PATRON" $NETWORK_FLAG 2>/dev/null)
    if [ -n "$RESULT" ]; then
        echo "⚠️  '$PATRON' encontrado en DB" | tee -a $REPORTE
        echo "$RESULT" | tee -a $REPORTE
        echo "DB|$PATRON|Patrón tier 2 encontrado en base de datos" >> "$HALLAZGOS_FILE"
        HALLAZGOS=$((HALLAZGOS + 1))
    else
        echo "✔️  '$PATRON' — no encontrado" | tee -a $REPORTE
    fi
done

echo "" | tee -a $REPORTE
echo "Tier 3:" | tee -a $REPORTE
for PATRON in "${TIER3[@]}"; do
    RESULT=$(wp --path="$WP_PATH" db search "$PATRON" $NETWORK_FLAG 2>/dev/null)
    if [ -n "$RESULT" ]; then
        echo "⚠️  '$PATRON' encontrado en DB (verificar manualmente)" | tee -a $REPORTE
        echo "$RESULT" | tee -a $REPORTE
    else
        echo "✔️  '$PATRON' — no encontrado" | tee -a $REPORTE
    fi
done

# ============================================================
# RESUMEN FINAL Y PRÓXIMOS PASOS
# ============================================================

echo "" | tee -a $REPORTE
echo "================================" | tee -a $REPORTE
echo "RESUMEN POST-INCIDENTE - $FECHA" | tee -a $REPORTE
echo "================================" | tee -a $REPORTE

if [ $HALLAZGOS -eq 0 ]; then
    echo "✔️  Sin hallazgos críticos detectados." | tee -a $REPORTE
    echo "   Revisar el reporte completo para contexto adicional." | tee -a $REPORTE
else
    echo "⚠️  $HALLAZGOS hallazgo(s) registrado(s) en: $HALLAZGOS_FILE" | tee -a $REPORTE
    echo "" | tee -a $REPORTE
    echo "Contenido del archivo de hallazgos:" | tee -a $REPORTE
    grep -v "^#" "$HALLAZGOS_FILE" | tee -a $REPORTE
    echo "" | tee -a $REPORTE
    echo "Próximo paso: bash remediacion.sh $HALLAZGOS_FILE $WP_PATH" | tee -a $REPORTE
fi

echo "Reporte completo: $REPORTE" | tee -a $REPORTE
echo "================================" | tee -a $REPORTE
