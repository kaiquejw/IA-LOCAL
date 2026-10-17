#!/usr/bin/env bash
# bench.sh — roda o conjunto de teste com configuração fixa.
# Uso (na VPS):  ./bench.sh tutor
#
# Usa a API HTTP em vez de `ollama run`. Dois motivos, os dois descobertos
# apanhando:
#   1. `ollama run` desenha spinner e reposiciona o cursor. Redirecionado
#      para arquivo, isso vira lixo de escape ANSI no meio das respostas.
#   2. prompt passado como argumento de shell quebra nas aspas e no `$(pwd)`
#      que existem no prompts-teste.txt. O jq monta o JSON e escapa certo.
set -euo pipefail

MODELO="${1:-tutor}"
API="${OLLAMA_API:-http://localhost:11434}"
SAIDA="resultados-${MODELO}-$(date +%Y%m%d-%H%M).txt"

command -v jq   >/dev/null || { echo "ERRO: jq não instalado (apt install jq)";   exit 1; }
command -v curl >/dev/null || { echo "ERRO: curl não instalado (apt install curl)"; exit 1; }

{
  echo "MODELO: $MODELO"
  echo "DATA:   $(date)"
  echo "PARAMS:"
  ollama show "$MODELO" --parameters 2>/dev/null || true
  echo "PROCESSADOR (queremos 100% GPU):"
  ollama ps 2>/dev/null || true
  echo "========================================"
} > "$SAIDA"

# Lê os prompts no descritor 3, não no stdin. Se ficasse no stdin, qualquer
# comando de dentro do loop que leia stdin (curl, docker exec -i) engoliria o
# resto da lista e o bench rodaria só o primeiro prompt, em silêncio.
while IFS= read -r p <&3; do
  # pula comentários e linhas em branco
  [[ -z "$p" || "$p" == \#* ]] && continue

  RESP="$(jq -n --arg m "$MODELO" --arg p "$p" '{model:$m, prompt:$p, stream:false}' \
          | curl -sS --max-time 600 "${API}/api/generate" -d @- || echo '{}')"

  TXT="$(jq -r '.response // "ERRO: sem resposta da API"' <<<"$RESP")"
  TPS="$(jq -r 'if (.eval_count // 0) > 0 and (.eval_duration // 0) > 0
                then ((.eval_count / (.eval_duration / 1000000000) * 10 | round) / 10 | tostring) + " tok/s"
                else "n/d" end' <<<"$RESP")"

  {
    echo ""
    echo "### PROMPT: $p"
    echo "### VELOCIDADE: $TPS"
    echo ""
    echo "$TXT"
    echo ""
    echo "----------------------------------------"
  } >> "$SAIDA"

  echo "feito (${TPS}): ${p:0:50}..."
done 3< prompts-teste.txt

echo ""
echo "OK -> $SAIDA"
