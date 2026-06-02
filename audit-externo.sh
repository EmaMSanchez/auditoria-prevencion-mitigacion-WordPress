#!/bin/bash
URL=$1  
FECHA=$(date +%Y-%m-%d)
mkdir -p ~/scripts
REPORTE=~/scripts/reporte-externo-$FECHA.txt
if [ -z "$URL" ]; then
    echo "Uso: WPSCAN_TOKEN=token bash  audit-externo.sh https://sitio-a-auditar.com"
    exit 1
fi
echo "================================" | tee $REPORTE
echo "AUDITORÍA EXTERNA - $FECHA" | tee -a $REPORTE
echo "Sitio: $URL" | tee -a $REPORTE
echo "================================" | tee -a $REPORTE
echo "--- WPSCAN ---" | tee -a $REPORTE
wpscan --url $URL --api-token $WPSCAN_TOKEN --random-user-agent -e u,p,t 2>&1 | tee -a $REPORTE
echo "--- XMLRPC ---" | tee -a $REPORTE
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$URL/xmlrpc.php")
BODY=$(curl -s "$URL/xmlrpc.php")

if [ "$STATUS" = "200" ]; then
    if echo "$BODY" | grep -qi "XML-RPC server accepts POST requests only"; then
        echo "✘ xmlrpc.php — EXPUESTO y funcional (status: $STATUS)" | tee -a $REPORTE
    else
        echo "⚠️ xmlrpc.php — Responde 200 pero body inesperado, posible WAF (status: $STATUS)" | tee -a $REPORTE
    fi
elif [ "$STATUS" = "405" ]; then
    echo "✔️ xmlrpc.php — BLOQUEADO a nivel servidor, método no permitido (status: $STATUS)" | tee -a $REPORTE
elif [ "$STATUS" = "403" ]; then
    echo "✔️ xmlrpc.php — BLOQUEADO (status: $STATUS)" | tee -a $REPORTE
elif [ "$STATUS" = "000" ]; then
    echo "✔️ xmlrpc.php — BLOQUEADO a nivel firewall (status: $STATUS)" | tee -a $REPORTE
elif [ "$STATUS" = "404" ]; then
    echo "✔️ xmlrpc.php — No existe o está oculto (status: $STATUS)" | tee -a $REPORTE
else
    echo "⚠️ xmlrpc.php — status: $STATUS" | tee -a $REPORTE
fi
echo "--- WP-ADMIN ---" | tee -a $REPORTE
STATUS_ADMIN=$(curl -s -o /dev/null -w "%{http_code}" "$URL/wp-admin/")
REDIRECT_URL=$(curl -s -o /dev/null -w "%{redirect_url}" "$URL/wp-admin/")

if [ "$STATUS_ADMIN" = "200" ]; then
    echo "✘ wp-admin/ — EXPUESTO sin redirección (status: $STATUS_ADMIN)" | tee -a $REPORTE
elif [ "$STATUS_ADMIN" = "301" ] || [ "$STATUS_ADMIN" = "302" ] || [ "$STATUS_ADMIN" = "307" ] || [ "$STATUS_ADMIN" = "308" ]; then
    if echo "$REDIRECT_URL" | grep -qi "wp-login"; then
        echo "✘ wp-admin/ — ACCESIBLE, redirige al login nativo de WP (status: $STATUS_ADMIN)" | tee -a $REPORTE
    elif echo "$REDIRECT_URL" | grep -qiE "(firewall|security|blocked|waf|captcha|deny)"; then
        echo "✔️ wp-admin/ — BLOQUEADO por WAF/seguridad → $REDIRECT_URL (status: $STATUS_ADMIN)" | tee -a $REPORTE
    else
        echo "⚠️ wp-admin/ — Redirige a destino no estándar, revisar manualmente → $REDIRECT_URL (status: $STATUS_ADMIN)" | tee -a $REPORTE
    fi
elif [ "$STATUS_ADMIN" = "403" ] || [ "$STATUS_ADMIN" = "000" ]; then
    echo "✔️ wp-admin/ — BLOQUEADO (status: $STATUS_ADMIN)" | tee -a $REPORTE
else
    echo "⚠️ wp-admin/ — status: $STATUS_ADMIN" | tee -a $REPORTE
fi
echo "--- POSTPASS ---" | tee -a $REPORTE
STATUS_POSTPASS=$(curl -s -o /dev/null -w "%{http_code}" "$URL/?action=postpass")
REDIRECT_POSTPASS=$(curl -s -o /dev/null -w "%{redirect_url}" "$URL/?action=postpass")

if [ "$STATUS_POSTPASS" = "200" ]; then
    echo "✘ /?action=postpass — ACCESIBLE, plugin mal configurado (status: $STATUS_POSTPASS)" | tee -a $REPORTE
elif [ "$STATUS_POSTPASS" = "301" ] || [ "$STATUS_POSTPASS" = "302" ] || [ "$STATUS_POSTPASS" = "307" ] || [ "$STATUS_POSTPASS" = "308" ]; then
    if echo "$REDIRECT_POSTPASS" | grep -qi "wp-login"; then
        # Cruzar con el resultado de wp-admin
        if [ "$STATUS_ADMIN" = "403" ] || [ "$STATUS_ADMIN" = "000" ]; then
            echo "✔️ /?action=postpass — Redirige al login pero wp-admin está BLOQUEADO (status: $STATUS_POSTPASS)" | tee -a $REPORTE
        else
            echo "✘ /?action=postpass — REDIRIGE AL LOGIN y wp-admin accesible, plugin mal configurado (status: $STATUS_POSTPASS)" | tee -a $REPORTE
        fi
    elif echo "$REDIRECT_POSTPASS" | grep -qiE "(firewall|security|blocked|waf|captcha|deny)"; then
        echo "✔️ /?action=postpass — BLOQUEADO por WAF/seguridad → $REDIRECT_POSTPASS (status: $STATUS_POSTPASS)" | tee -a $REPORTE
    else
        echo "⚠️ /?action=postpass — Redirige a destino no estándar, revisar manualmente → $REDIRECT_POSTPASS (status: $STATUS_POSTPASS)" | tee -a $REPORTE
    fi
elif [ "$STATUS_POSTPASS" = "403" ] || [ "$STATUS_POSTPASS" = "000" ]; then
    echo "✔️ /?action=postpass — BLOQUEADO (status: $STATUS_POSTPASS)" | tee -a $REPORTE
else
    echo "⚠️ /?action=postpass — status: $STATUS_POSTPASS" | tee -a $REPORTE
fi
echo "--- HEADERS DE SEGURIDAD ---" | tee -a $REPORTE

HEADERS_ESPERADOS=(
    "X-Content-Type-Options"
    "X-Frame-Options"
    "Content-Security-Policy"
    "Strict-Transport-Security"
    "Referrer-Policy"
    "Permissions-Policy"
)

RESPONSE=$(curl -s -I "$URL")

for header in "${HEADERS_ESPERADOS[@]}"; do
    if echo "$RESPONSE" | grep -qi "$header"; then
        echo "✔️ $header — presente" | tee -a $REPORTE
    else
        echo "✘ $header — FALTANTE" | tee -a $REPORTE
    fi
done
echo "================================" | tee -a $REPORTE
echo "AUDITORÍA FINALIZADA - $FECHA" | tee -a $REPORTE
echo "Sitio auditado: $URL" | tee -a $REPORTE
echo "Reporte guardado en: $REPORTE" | tee -a $REPORTE
echo "================================" | tee -a $REPORTE
