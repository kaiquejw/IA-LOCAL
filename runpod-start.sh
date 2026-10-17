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
#                                              dados do WebUI, logs, Hermes
# O que some a cada Terminate (reinstala ~30s): binário do ollama
#
# Uso, dentro do pod:
#   bash /workspace/IA-LOCAL/runpod-start.sh
#
# Opções (variáveis de ambiente):
#   WEBUI=1            sobe o Open WebUI em 127.0.0.1:3000 (acesso por túnel)
#   SECUNDARIO=1       baixa também o 2º modelo (só em 48 GB; ocupa ~17 GB a mais)
#   AUTO_OFF_MIN=150   apaga o pod sozinho depois de N minutos (0 = desliga).
#                      Usa RUNPOD_API_KEY (a RunPod injeta uma restrita ao pod);
#                      sem key só avisa. AUTO_OFF_API_KEY (sua, como Secret) tem prioridade.
#   REDTEAM=1          baixa um Qwen3 32B abliterated (~20 GB a mais) e cria o
#                      modelo "redteam". MODELO_REDTEAM=... troca a tag.
#   HERMES=1           instala e configura o Hermes Agent (não sobe sozinho)
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
# Usa RUNPOD_API_KEY. A RunPod já injeta no pod uma key restrita com esse nome.
# Em 17/10/2026 ela LEU o próprio pod pela API GraphQL; o Unauthorized de antes
# vinha do runpodctl sem config, não da key. O delete com ela nunca foi testado.
# Para ter certeza, use uma key SUA com escrita, guardada como Secret do pod
# (nunca no repo), em AUTO_OFF_API_KEY, que tem prioridade.
#
# ssh não interativo não lê /etc/rp_environment (o .bashrc só faz isso em shell
# interativo), então as variáveis da RunPod vêm de lá quando faltarem.
if [[ -r /etc/rp_environment ]]; then
  [[ -n "${RUNPOD_POD_ID:-}" ]]  || eval "$(grep -E '^export RUNPOD_POD_ID=' /etc/rp_environment || true)"
  [[ -n "${RUNPOD_API_KEY:-}" ]] || eval "$(grep -E '^export RUNPOD_API_KEY=' /etc/rp_environment || true)"
fi
AUTO_OFF_MIN="${AUTO_OFF_MIN:-150}"
AUTO_OFF_KEY="${AUTO_OFF_API_KEY:-${RUNPOD_API_KEY:-}}"
RP_API=https://api.runpod.io/graphql

# A key vai pelo stdin do curl (-H @-), nunca na linha de comando: assim não
# aparece no ps nem no log.
rp_api() {
  printf 'Authorization: Bearer %s\n' "$AUTO_OFF_KEY" \
    | curl -sS --max-time 30 -H @- -H 'Content-Type: application/json' -d "$1" "$RP_API" 2>&1 || true
}

if (( AUTO_OFF_MIN <= 0 )); then
  log "AVISO: auto-off desligado (AUTO_OFF_MIN=0). Só o Terminate manual encerra a cobrança."
elif [[ -z "$AUTO_OFF_KEY" ]]; then
  log "AVISO: RUNPOD_API_KEY não definida: desligamento automático DESLIGADO."
  log "       Só o Terminate manual encerra a cobrança."
elif [[ ! "${RUNPOD_POD_ID:-}" =~ ^[a-z0-9]+$ ]]; then
  log "AVISO: RUNPOD_POD_ID ausente (fora da RunPod?): desligamento automático DESLIGADO."
else
  # Validação só com LEITURA. O delete não dá para testar: apagaria o pod.
  resp="$(rp_api "$(printf '{"query":"query { pod(input: {podId: \\"%s\\"}) { id desiredStatus } }"}' "$RUNPOD_POD_ID")")"
  if [[ "$resp" == *"\"id\":\"$RUNPOD_POD_ID\""* ]]; then
    log "auto-off: a key autentica (leitura do pod ok; o delete não dá para testar)"
  else
    log "AVISO: a key NÃO autenticou na leitura: ${resp:0:200}"
    log "       O auto-off vai ser agendado mesmo assim, mas PROVAVELMENTE NÃO VAI FUNCIONAR."
    log "       Dê Terminate na mão."
  fi
  if ! pgrep -f "ia-auto-off" >/dev/null; then
    # Sem exec: "exec -a ... sleep" trocava o shell pelo sleep e o comando de
    # remover nunca rodava. "ia-auto-off" vai como $0 só para o pgrep/pkill -f.
    # Key e corpo vão pelo ambiente do processo, não pela linha de comando.
    IA_KEY="$AUTO_OFF_KEY" RP_API="$RP_API" \
    IA_BODY="$(printf '{"query":"mutation { podTerminate(input: {podId: \\"%s\\"}) }"}' "$RUNPOD_POD_ID")" \
    nohup bash -c 'sleep "$1"
      echo "$(date -u +%FT%TZ) encerrando o pod (podTerminate)"
      printf "Authorization: Bearer %s\n" "$IA_KEY" \
        | curl -sS --max-time 60 -H @- -H "Content-Type: application/json" -d "$IA_BODY" "$RP_API"
      echo' ia-auto-off "$(( AUTO_OFF_MIN * 60 ))" > "$LOGS/auto-off.log" 2>&1 &
    log "pod será APAGADO em ${AUTO_OFF_MIN} min ($(date -u -d "+${AUTO_OFF_MIN} min" +%H:%M) UTC)."
    log "para cancelar: pkill -f ia-auto-off"
  else
    log "desligamento automático já agendado"
  fi
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

# Modelo sem filtro para estudo autorizado de segurança: menos recusa falsa em
# pergunta técnica legítima. Tag conferida no registry.ollama.ai (19,8 GB).
REDTEAM_BASE=""
if [[ "${REDTEAM:-0}" == "1" ]]; then
  m="${MODELO_REDTEAM:-huihui_ai/qwen3-abliterated:32b}"
  livre_gb="$(df -BG --output=avail "$W/ollama" | tail -1 | tr -dc '0-9')"
  if ! ollama list | awk -v m="$m" 'NR>1 && $1==m {f=1} END {exit !f}' && (( ${livre_gb:-0} < 22 )); then
    log "AVISO: só ${livre_gb} GB livres em $W/ollama; $m precisa de ~20 GB. redteam pulado."
  else
    log "modelo redteam: baixando $m (~20 GB a mais)"
    if ollama pull "$m"; then REDTEAM_BASE="$m"; else log "AVISO: não baixou $m; redteam pulado."; fi
  fi
fi

# ============================================================
# 5 — modelos customizados a partir dos Modelfiles do repo
# ============================================================
for f in "$REPO"/modelfiles/*.Modelfile; do
  [[ -e "$f" ]] || continue
  nome="$(basename "$f" .Modelfile)"
  if grep -q '__MODELO_REDTEAM__' "$f" && [[ -z "$REDTEAM_BASE" ]]; then
    log "pulado: $nome (precisa de REDTEAM=1)"; continue
  fi
  out="$W/modelfiles-gerados/${nome}.Modelfile"
  sed -e "s|__MODELO_BASE__|${BASE}|g" \
      -e "s|__MODELO_REDTEAM__|${REDTEAM_BASE}|g" \
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
# 7 — Hermes Agent (opcional, Nous Research, MIT). Só instala e configura;
#     quem inicia é você, com `hermes` no terminal do pod.
# ============================================================
if [[ "${HERMES:-0}" == "1" ]]; then
  if [[ ! -x "$W/venv-hermes/bin/hermes" ]]; then
    log "instalando Hermes Agent em $W/venv-hermes"
    command -v rg >/dev/null || apt-get install -y -qq ripgrep >/dev/null || true
    python3 -m venv --system-site-packages "$W/venv-hermes"
    "$W/venv-hermes/bin/pip" install -q hermes-agent
  fi
  # Estado do Hermes (config, memória, sessões) em $W/hermes; ~/.hermes aponta
  # para lá, então `hermes` acha sem precisar de HERMES_HOME.
  mkdir -p "$W/hermes"
  [[ -e "$HOME/.hermes" ]] || ln -s "$W/hermes" "$HOME/.hermes"
  ln -sf "$W/venv-hermes/bin/hermes" /usr/local/bin/hermes
  if [[ ! -f "$W/hermes/config.yaml" ]]; then
    cat > "$W/hermes/config.yaml" <<EOF
# Gerado pelo runpod-start.sh (só quando não existe; o seu fica intacto).
model:
  provider: "custom"                      # endpoint OpenAI-compat local
  base_url: "http://127.0.0.1:11434/v1"
  api_key: ""                             # Ollama local não usa key
  default: "${BASE}"                      # o modelo base, NÃO o tutor: o Hermes tem prompt próprio
  context_length: ${NUM_CTX}
  ollama_num_ctx: ${NUM_CTX}              # o Hermes manda o num_ctx em cada request
  # Resposta longa dando timeout? O Hermes já sobe a leitura para 1800 s em
  # endpoint local; para forçar: export HERMES_STREAM_READ_TIMEOUT=3600

approvals:
  # Confirmação ANTES de executar comando perigoso: LIGADA. "manual" sempre
  # pergunta (o padrão "smart" deixa um LLM aprovar sozinho). Nunca use "off",
  # --yolo nem HERMES_YOLO_MODE.
  mode: "manual"

agent:
  # Busca web e navegador na nuvem DESLIGADOS: precisam de chave de provedor
  # externo. Para ligar depois: ponha a chave em ~/.hermes/.env (o browser pede
  # BROWSERBASE_API_KEY) e tire o nome desta lista, ou use \`hermes tools\`.
  disabled_toolsets: [web, search, browser]

memory:
  memory_enabled: true                    # grava em ~/.hermes/memories/MEMORY.md
  user_profile_enabled: true
EOF
    log "Hermes configurado: $W/hermes/config.yaml (modelo ${BASE}, ctx ${NUM_CTX})"
  else
    log "Hermes: config existente mantida ($W/hermes/config.yaml)"
  fi
  # Testado em 17/10/2026: o Hermes recusa iniciar abaixo de 64K de contexto, e
  # o qwen3:32b tem janela nativa de 40960 no Ollama. Ver a nota no README.
  if (( NUM_CTX < 64000 )); then
    log "AVISO: o Hermes exige >= 64K de contexto e NÃO inicia com ${NUM_CTX} (${BASE})."
    log "       Veja a nota do Hermes no README antes de usar."
  fi
fi

# ============================================================
log "================================================"
log " PRONTO — base: ${BASE} | num_ctx ${NUM_CTX}"
ollama list
log " Chat no terminal:   ollama run tutor"
[[ -n "$REDTEAM_BASE" ]] && log " Segurança:          ollama run redteam  (base ${REDTEAM_BASE})"
[[ "${HERMES:-0}" == "1" ]] && log " Hermes Agent:       hermes   (no terminal do pod; pede confirmação antes de comando perigoso)"
log " No SEU PC (túnel):  ssh -N -L 3000:localhost:3000 -L 11434:localhost:11434 root@IP -p PORTA"
log " Ao terminar:        Terminate no painel (ou espere o auto-off)"
log "================================================"
