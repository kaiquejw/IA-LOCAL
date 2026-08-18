#!/usr/bin/env bash
# bench.sh — roda o conjunto de teste com configuração fixa.
# Uso (na VPS):  ./bench.sh tutor
set -euo pipefail
MODELO="${1:-tutor}"
SAIDA="resultados-${MODELO}-$(date +%Y%m%d-%H%M).txt"

{
  echo "MODELO: $MODELO"
  echo "DATA:   $(date)"
  echo "PARAMS:"
  docker exec ollama ollama show "$MODELO" --parameters 2>/dev/null || true
  echo "========================================"
} > "$SAIDA"

grep -v '^#' prompts-teste.txt | grep -v '^$' | while IFS= read -r p; do
  echo "" >> "$SAIDA"
  echo "### PROMPT: $p" >> "$SAIDA"
  echo "" >> "$SAIDA"
  docker exec ollama ollama run "$MODELO" "$p" >> "$SAIDA" 2>&1
  echo "" >> "$SAIDA"
  echo "----------------------------------------" >> "$SAIDA"
  echo "feito: ${p:0:50}..."
done

echo ""
echo "OK -> $SAIDA"
