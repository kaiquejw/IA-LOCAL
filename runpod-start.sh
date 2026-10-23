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
#   AIDER=1            instala e configura o aider (cria/edita arquivos no disco)
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
espaco() { df -h --output=used,size,pcent "$W/ollama" | tail -1 | awk '{print $1 " de " $2 " (" $3 ")"}'; }

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
  log "modelo principal: tentando $m | disco antes: $(espaco)"
  if ollama pull "$m"; then BASE="$m"; log "disco depois: $(espaco)"; break; fi
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
    log "modelo redteam: baixando $m (~20 GB a mais) | disco antes: $(espaco)"
    if ollama pull "$m"; then REDTEAM_BASE="$m"; log "disco depois: $(espaco)"
    else log "AVISO: não baixou $m; redteam pulado."; fi
  fi
elif [[ "$BASE" == *abliterated* ]]; then
  # Base já é sem filtro (MODELO=huihui_ai/qwen3-abliterated:32b): um modelo só
  # serve tutor, coder e redteam, sem baixar mais 20 GB.
  REDTEAM_BASE="$BASE"
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
  # Modelfile com FROM fixo (o coder usa qwen3-coder:30b, não o base): baixa o
  # modelo se ainda não estiver no volume. Já presente, não faz nada.
  from="$(awk '/^FROM / {print $2; exit}' "$out")"
  if [[ -n "$from" && "$from" != /* ]] \
     && ! ollama list | awk -v m="$from" 'NR>1 && ($1==m || $1==m":latest") {f=1} END {exit !f}'; then
    log "baixando $from (FROM de $nome) | disco antes: $(espaco)"
    if ollama pull "$from"; then log "disco depois: $(espaco)"
    else log "AVISO: falhou $nome (não baixou $from)"; continue; fi
  fi
  ollama create "$nome" -f "$out" >/dev/null && log "criado: $nome (FROM $from)" || log "AVISO: falhou $nome"
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
  # O Hermes recusa iniciar com menos de 64K de contexto, e o qwen3:32b tem
  # janela nativa de 40960 no Ollama. Por isso o Hermes tem modelo PRÓPRIO, com
  # janela nativa >= 64K e chamada de ferramenta. Nunca force além do nativo.
  HERMES_MODELO="${HERMES_MODELO:-qwen3-coder:30b}"
  HERMES_CTX="${HERMES_CTX:-65536}"
  livre_gb="$(df -BG --output=avail "$W/ollama" | tail -1 | tr -dc '0-9')"
  if ! ollama list | awk -v m="$HERMES_MODELO" 'NR>1 && $1==m {f=1} END {exit !f}' && (( ${livre_gb:-0} < 21 )); then
    log "AVISO: só ${livre_gb} GB livres; $HERMES_MODELO precisa de ~19 GB. Hermes sem modelo."
  else
    log "Hermes: baixando $HERMES_MODELO | disco antes: $(espaco)"
    ollama pull "$HERMES_MODELO" && log "disco depois: $(espaco)" \
      || log "AVISO: não baixou $HERMES_MODELO"
  fi
  nativo="$(ollama show "$HERMES_MODELO" 2>/dev/null | awk '/context length/ {print $3; exit}')"
  if (( ${nativo:-0} < HERMES_CTX )); then
    log "AVISO: $HERMES_MODELO tem janela nativa ${nativo:-desconhecida}, menor que ${HERMES_CTX}."
    log "       O Hermes não vai iniciar com ele. Troque HERMES_MODELO."
  else
    log "Hermes: $HERMES_MODELO tem janela nativa ${nativo}; usando ${HERMES_CTX}"
  fi
  # O Hermes fala pela API OpenAI (/v1), e por ali o Ollama ignora o num_ctx do
  # request e serve no padrão calculado pela VRAM (32768 na A40). Um apelido só
  # com o num_ctx, sem SYSTEM, fixa os 64K e não muda o comportamento do modelo.
  HERMES_ALIAS="${HERMES_MODELO%%:*}-hermes"
  printf 'FROM %s\nPARAMETER num_ctx %s\n' "$HERMES_MODELO" "$HERMES_CTX" \
    > "$W/modelfiles-gerados/${HERMES_ALIAS}.Modelfile"
  ollama create "$HERMES_ALIAS" -f "$W/modelfiles-gerados/${HERMES_ALIAS}.Modelfile" >/dev/null \
    && log "criado: $HERMES_ALIAS ($HERMES_MODELO com num_ctx $HERMES_CTX)" \
    || log "AVISO: falhou $HERMES_ALIAS"
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
  default: "${HERMES_ALIAS}"      # ${HERMES_MODELO} cru + num_ctx; NÃO tutor/coder: o Hermes tem prompt próprio
  context_length: ${HERMES_CTX}           # o Hermes exige >= 64000
  ollama_num_ctx: ${HERMES_CTX}           # o Hermes manda esse num_ctx em cada request
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
  # BROWSERBASE_API_KEY), tire o nome desta lista e rode \`hermes tools enable web\`
  # (ou \`hermes tools\`, que é interativo).
  disabled_toolsets: [web, search, browser]

memory:
  memory_enabled: true                    # grava em ~/.hermes/memories/MEMORY.md
  user_profile_enabled: true
EOF
    log "Hermes configurado: $W/hermes/config.yaml (modelo ${HERMES_ALIAS}, ctx ${HERMES_CTX})"
  else
    log "Hermes: config existente mantida ($W/hermes/config.yaml)"
  fi
fi

# ============================================================
# 8 — aider (opcional): agente que cria e edita os arquivos no disco.
#     Só instala e configura; rode `aider` dentro da pasta do projeto.
# ============================================================
if [[ "${AIDER:-0}" == "1" ]]; then
  AIDER_MODELO="${AIDER_MODELO:-qwen3-coder:30b}"
  if ! ollama list | awk -v m="$AIDER_MODELO" 'NR>1 && $1==m {f=1} END {exit !f}'; then
    log "aider: baixando $AIDER_MODELO | disco antes: $(espaco)"
    if ollama pull "$AIDER_MODELO"; then log "disco depois: $(espaco)"
    else log "AVISO: não baixou $AIDER_MODELO"; fi
  fi
  if [[ ! -x "$W/venv-aider/bin/aider" ]]; then
    log "instalando aider em $W/venv-aider (só na primeira vez) | disco antes: $(espaco)"
    python3 -m venv --system-site-packages "$W/venv-aider"
    "$W/venv-aider/bin/pip" install -q aider-chat
    log "disco depois: $(espaco)"
  fi
  ln -sf "$W/venv-aider/bin/aider" /usr/local/bin/aider
  # Config no volume; ~/.aider.conf.yml aponta para ela (o aider lê da home,
  # da raiz do git e da pasta atual, nessa ordem).
  mkdir -p "$W/aider"
  if [[ ! -f "$W/aider/aider.conf.yml" ]]; then
    cat > "$W/aider/aider.conf.yml" <<EOF
# Gerado pelo runpod-start.sh (só quando não existe; o seu fica intacto).
# ollama_chat/ usa a API nativa do Ollama: o aider ajusta o num_ctx sozinho.
model: ollama_chat/${AIDER_MODELO}
editor-model: ollama_chat/${AIDER_MODELO}
set-env:
  - OLLAMA_API_BASE=http://127.0.0.1:11434

# Confirmação ANTES de gravar: no modo architect o modelo propõe a mudança e o
# aider pergunta "Edit the files?". Sem isso, o aider aplica direto. Nunca use
# yes-always.
architect: true
auto-accept-architect: false

# Nada de commit sem revisão: revise com git diff e descarte com git restore.
auto-commits: false
dirty-commits: false

analytics: false
check-update: false
show-release-notes: false
EOF
    log "aider configurado: $W/aider/aider.conf.yml (modelo ${AIDER_MODELO})"
  else
    log "aider: config existente mantida ($W/aider/aider.conf.yml)"
  fi
  ln -sf "$W/aider/aider.conf.yml" "$HOME/.aider.conf.yml"
fi

# ============================================================
log "================================================"
log " PRONTO — base: ${BASE} | num_ctx ${NUM_CTX}"
ollama list
log " Chat no terminal:   ollama run tutor"
[[ -n "$REDTEAM_BASE" ]] && log " Segurança:          ollama run redteam  (base ${REDTEAM_BASE})"
[[ "${AIDER:-0}" == "1" ]] && log " aider:              cd <pasta-do-projeto> && aider   (pergunta antes de gravar; sem auto-commit)"
[[ "${HERMES:-0}" == "1" ]] && log " Hermes Agent:       hermes   (modelo ${HERMES_ALIAS}, ctx ${HERMES_CTX}; pede confirmação antes de comando perigoso)"
log " No SEU PC (túnel):  ssh -N -L 3000:localhost:3000 -L 11434:localhost:11434 root@IP -p PORTA"
log " Ao terminar:        Terminate no painel (ou espere o auto-off)"
log "================================================"
