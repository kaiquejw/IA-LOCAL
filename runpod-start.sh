#!/usr/bin/env bash
#
# runpod-start.sh — sobe a stack num pod da RunPod.
#
# O pod da RunPod é um CONTAINER, não uma VM: não tem systemd, não roda
# Docker dentro, não tem ufw e o driver NVIDIA já vem do host. Por isso o
# bootstrap.sh (feito para VM da Vultr) não serve aqui. Este script faz o
# mesmo papel sem Docker: Ollama direto no pod, tudo que precisa sobreviver
# fica no volume em /workspace.
#
# O que fica no volume (persiste entre pods):  modelos, venv do WebUI,
#                                              dados do WebUI, logs
# O que some a cada Terminate (reinstala ~30s): binário do ollama
#
# Uso, dentro do pod:
#   bash /workspace/IA-LOCAL/runpod-start.sh
#
# Opções (variáveis de ambiente):
#   WEBUI=1            sobe o Open WebUI em 127.0.0.1:3000 (acesso por túnel)
#   SECUNDARIO=1       baixa também o 2º modelo (só em 48 GB; ocupa ~17 GB a mais)
#   AUTO_OFF_MIN=150   apaga o pod sozinho depois de N minutos (0 = desliga)
#   MODELO=gemma3:27b  força o modelo base
#   NUM_CTX=16384      força o contexto
#   W=/root/ia         raiz de tudo (padrão /workspace). Use o disco do container
#                      quando o volume for de rede (fuse.geesefs): ele não aceita
#                      chmod, e git clone e venv quebram lá. Nesse caso nada persiste.
#   LOGS=/workspace/logs  onde gravar os logs (padrão $W/logs)
#
set -euo pipefail

W="${W:-/workspace}"
REPO="${REPO:-$W/IA-LOCAL}"
LOGS="${LOGS:-$W/logs}"
mkdir -p "$LOGS" "$W/ollama" "$W/modelfiles-gerados"

log() { echo -e "\n>>> $*"; }

# Mesmas otimizações do docker-compose.yml
export OLLAMA_MODELS="$W/ollama"
export OLLAMA_HOST=127.0.0.1:11434        # nunca 0.0.0.0: a RunPod tem proxy público
export OLLAMA_KEEP_ALIVE=-1
export OLLAMA_FLASH_ATTENTION=1
export OLLAMA_KV_CACHE_TYPE=q8_0

# ============================================================
# 0 — desligamento automático (o maior risco de custo é esquecer)
# ============================================================
AUTO_OFF_MIN="${AUTO_OFF_MIN:-150}"
if (( AUTO_OFF_MIN > 0 )) && [[ -n "${RUNPOD_POD_ID:-}" ]] && command -v runpodctl >/dev/null; then
  if ! pgrep -f "ia-auto-off" >/dev/null; then
    # sem exec: exec trocaria o shell pelo sleep e o runpodctl nunca rodaria.
    # "ia-auto-off" vai como $0 só para o pgrep/pkill -f acharem o processo.
    nohup bash -c "sleep $(( AUTO_OFF_MIN * 60 )); runpodctl remove pod $RUNPOD_POD_ID" ia-auto-off \
      > "$LOGS/auto-off.log" 2>&1 &
    log "pod será APAGADO em ${AUTO_OFF_MIN} min ($(date -d "+${AUTO_OFF_MIN} min" +%H:%M) UTC)."
    log "para cancelar: pkill -f ia-auto-off"
  else
    log "desligamento automático já agendado"
  fi
else
  log "AVISO: sem desligamento automático. Lembre de dar Terminate."
fi

# ============================================================
# 1 — ollama (disco do container: reinstala a cada pod novo)
# ============================================================
if ! command -v ollama >/dev/null; then
  log "instalando ollama"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq zstd pciutils lshw jq >/dev/null
  curl -fsSL https://ollama.com/install.sh | sh
fi
command -v jq >/dev/null || apt-get install -y -qq jq >/dev/null

# ============================================================
# 2 — escolha do modelo pela VRAM (mesma tabela do bootstrap.sh)
# ============================================================
VRAM_MB="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1 | tr -d ' ')"
[[ "$VRAM_MB" =~ ^[0-9]+$ ]] || { log "ERRO: nvidia-smi não respondeu"; exit 1; }
log "GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1) — ${VRAM_MB} MiB"

if   (( VRAM_MB >= 44000 )); then
  PRINCIPAL=( "qwen3:32b" "qwen2.5:32b" ); SEGUNDO=( "gemma3:27b" )
  CTX=32768; MAXLOAD=2; PAR=2
elif (( VRAM_MB >= 22000 )); then
  PRINCIPAL=( "gemma3:27b" "qwen3:14b" ); SEGUNDO=( "qwen2.5-coder:14b" )
  CTX=16384; MAXLOAD=1; PAR=2
elif (( VRAM_MB >= 11000 )); then
  PRINCIPAL=( "qwen3:14b" "gemma3:12b" ); SEGUNDO=()
  CTX=8192; MAXLOAD=1; PAR=1
else
  PRINCIPAL=( "qwen3:8b" "gemma3:4b" ); SEGUNDO=()
  CTX=8192; MAXLOAD=1; PAR=1
fi
[[ -n "${MODELO:-}" ]] && PRINCIPAL=( "$MODELO" )
NUM_CTX="${NUM_CTX:-$CTX}"
export OLLAMA_MAX_LOADED_MODELS="${OLLAMA_MAX_LOADED_MODELS:-$MAXLOAD}"
export OLLAMA_NUM_PARALLEL="${OLLAMA_NUM_PARALLEL:-$PAR}"

# ============================================================
# 3 — sobe o servidor
# ============================================================
if ! curl -sf http://127.0.0.1:11434/api/version >/dev/null; then
  log "subindo ollama serve"
  nohup ollama serve >> "$LOGS/ollama.log" 2>&1 &
  for _ in $(seq 1 30); do
    curl -sf http://127.0.0.1:11434/api/version >/dev/null && break
    sleep 1
  done
fi
curl -sf http://127.0.0.1:11434/api/version >/dev/null \
  || { log "ERRO: ollama não subiu. Veja $LOGS/ollama.log"; exit 1; }

# ============================================================
# 4 — modelos (pull é instantâneo se já estiver no volume)
# ============================================================
BASE=""
for m in "${PRINCIPAL[@]}"; do
  log "modelo principal: tentando $m"
  if ollama pull "$m"; then BASE="$m"; break; fi
done
[[ -n "$BASE" ]] || { log "ERRO: nenhum modelo baixou. Veja ollama.com/library"; exit 1; }

if [[ "${SECUNDARIO:-0}" == "1" ]] && (( ${#SEGUNDO[@]} > 0 )); then
  for m in "${SEGUNDO[@]}"; do ollama pull "$m" && break; done
fi

# ============================================================
# 5 — modelos customizados a partir dos Modelfiles do repo
# ============================================================
for f in "$REPO"/modelfiles/*.Modelfile; do
  [[ -e "$f" ]] || continue
  nome="$(basename "$f" .Modelfile)"
  out="$W/modelfiles-gerados/${nome}.Modelfile"
  sed -e "s|__MODELO_BASE__|${BASE}|g" \
      -e "s|^PARAMETER num_ctx .*|PARAMETER num_ctx ${NUM_CTX}|" "$f" > "$out"
  ollama create "$nome" -f "$out" >/dev/null && log "criado: $nome" || log "AVISO: falhou $nome"
done

# ============================================================
# 6 — Open WebUI (opcional). venv no volume: instala uma vez só.
# ============================================================
if [[ "${WEBUI:-0}" == "1" ]]; then
  if [[ ! -x "$W/venv-webui/bin/open-webui" ]]; then
    log "instalando Open WebUI no volume (só na primeira vez, alguns minutos)"
    # --system-site-packages reaproveita o torch que já vem na imagem
    python3 -m venv --system-site-packages "$W/venv-webui"
    "$W/venv-webui/bin/pip" install -q open-webui
  fi
  if ! curl -sf http://127.0.0.1:3000 >/dev/null; then
    log "subindo Open WebUI em 127.0.0.1:3000"
    DATA_DIR="$W/webui" \
    OLLAMA_BASE_URL=http://127.0.0.1:11434 \
    WEBUI_AUTH=True \
    RAG_TOP_K=5 \
    nohup "$W/venv-webui/bin/open-webui" serve --host 127.0.0.1 --port 3000 \
      >> "$LOGS/webui.log" 2>&1 &
  fi
fi

# ============================================================
log "================================================"
log " PRONTO — base: ${BASE} | num_ctx ${NUM_CTX}"
ollama list
log " Chat no terminal:   ollama run tutor"
log " No SEU PC (túnel):  ssh -N -L 3000:localhost:3000 -L 11434:localhost:11434 root@IP -p PORTA"
log " Ao terminar:        Terminate no painel (ou espere o auto-off)"
log "================================================"
