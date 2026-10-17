#!/usr/bin/env bash
#
# bootstrap.sh — provisiona a stack de IA local do zero.
#
# IDEMPOTENTE: pode rodar quantas vezes quiser. Usa marcadores de etapa,
# então se reiniciar no meio, retoma de onde parou (não refaz tudo).
#
# Rode como root:  ./bootstrap.sh
#
set -euo pipefail

DIR="/opt/ia"
LOG="/var/log/bootstrap-ia.log"
ETAPAS="${DIR}/.etapas"

mkdir -p "$ETAPAS"
exec > >(tee -a "$LOG") 2>&1

log()  { echo -e "\n>>> $* \n"; }
feito() { [[ -f "${ETAPAS}/$1" ]]; }
marca() { touch "${ETAPAS}/$1"; }

log "bootstrap iniciado — $(date)"

# ============================================================
# ETAPA 1 — pacotes base e firewall
# ============================================================
if ! feito base; then
  log "ETAPA 1/5 — pacotes base e firewall"
  export DEBIAN_FRONTEND=noninteractive

  apt-get update
  apt-get install -y --no-install-recommends \
      build-essential curl git ca-certificates gnupg \
      htop nvtop jq ufw python3 python3-pip

  ufw allow 22/tcp
  ufw --force enable

  marca base
else
  log "ETAPA 1/5 — já feita, pulando"
fi

# ============================================================
# ETAPA 2 — driver NVIDIA
# ============================================================
if ! feito driver; then
  log "ETAPA 2/5 — driver NVIDIA"
  export DEBIAN_FRONTEND=noninteractive

  apt-get install -y ubuntu-drivers-common
  ubuntu-drivers install --gpgpu || apt-get install -y nvidia-driver-570-server

  modprobe nvidia 2>/dev/null || true

  if nvidia-smi >/dev/null 2>&1; then
    log "driver OK sem reiniciar"
    marca driver
  else
    marca driver
    log "!!! driver instalado mas precisa REINICIAR."
    log "!!! reiniciando em 10s — o bootstrap retoma sozinho no boot."
    sleep 10
    reboot
    exit 0
  fi
else
  log "ETAPA 2/5 — já feita, pulando"
fi

# confere que a GPU responde antes de seguir
if ! nvidia-smi >/dev/null 2>&1; then
  log "ERRO: nvidia-smi não responde. Rode 'nvidia-smi' e veja o erro."
  exit 1
fi
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader

# ============================================================
# ESCOLHA DO MODELO PELA VRAM
# ============================================================
# A fração de A40 que você consegue no dia varia (12 / 24 / 48 GB).
# Modelo grande demais não dá erro: o Ollama joga o excedente na CPU e a
# resposta despenca de dezenas para poucos tokens/s. Por isso o script mede
# a VRAM e escolhe — em vez de confiar que você lembrou de editar a lista.
#
# Tamanhos conferidos no registry (Q4_K_M, o padrão):
#   qwen3:32b 20,2 GB | qwen2.5:32b 19,9 GB | gemma3:27b 17,4 GB
#   qwen3:14b  9,3 GB | qwen2.5-coder:14b 9,0 GB | gemma3:12b 8,1 GB
#   qwen3:8b   5,2 GB
# Some a isso o KV cache: ~2 GB num 32B com num_ctx 16384 (já quantizado a
# q8_0 pelo compose). Daí as margens abaixo.
#
# Para forçar outra escolha:  MODELO=gemma3:27b NUM_CTX=8192 ./bootstrap.sh
VRAM_MB="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1 | tr -d ' ')"
[[ "$VRAM_MB" =~ ^[0-9]+$ ]] || VRAM_MB=0
log "VRAM detectada: ${VRAM_MB} MiB"

if   (( VRAM_MB >= 44000 )); then           # A40 inteira (48 GB)
  CANDIDATOS_PRINCIPAL=( "qwen3:32b" "qwen2.5:32b" )
  CANDIDATOS_SECUNDARIO=( "gemma3:27b" )
  NUM_CTX_PADRAO=32768
  MAX_LOADED_PADRAO=2                       # 20,2 + 17,4 GB cabem juntos
  NUM_PARALLEL_PADRAO=2
elif (( VRAM_MB >= 22000 )); then           # fração de 24 GB
  # gemma3:27b na frente de propósito: usa sliding window attention, então
  # o KV cache dele é uma fração do de um 32B — sobra folga pro contexto.
  CANDIDATOS_PRINCIPAL=( "gemma3:27b" "qwen3:14b" )
  CANDIDATOS_SECUNDARIO=( "qwen2.5-coder:14b" )
  NUM_CTX_PADRAO=16384
  MAX_LOADED_PADRAO=1                       # 17,4 + 9,0 GB NÃO cabem juntos
  NUM_PARALLEL_PADRAO=2
elif (( VRAM_MB >= 11000 )); then           # fração de 12 GB
  CANDIDATOS_PRINCIPAL=( "qwen3:14b" "gemma3:12b" )
  CANDIDATOS_SECUNDARIO=()                  # 2 modelos não cabem em 12 GB
  NUM_CTX_PADRAO=8192
  MAX_LOADED_PADRAO=1
  NUM_PARALLEL_PADRAO=1                     # cada slot duplica o KV cache
else                                        # 8 GB ou menos
  CANDIDATOS_PRINCIPAL=( "qwen3:8b" "gemma3:4b" )
  CANDIDATOS_SECUNDARIO=()
  NUM_CTX_PADRAO=8192
  MAX_LOADED_PADRAO=1
  NUM_PARALLEL_PADRAO=1
fi

# override manual ganha da detecção
if [[ -n "${MODELO:-}" ]]; then
  CANDIDATOS_PRINCIPAL=( "$MODELO" )
fi
NUM_CTX="${NUM_CTX:-$NUM_CTX_PADRAO}"

# Estes dois multiplicam o consumo de VRAM e por isso seguem a mesma detecção:
#   MAX_LOADED_MODELS  — cada modelo vivo ocupa o peso dele inteiro
#   NUM_PARALLEL       — cada slot aloca um KV cache próprio de num_ctx tokens
# Estourar não dá erro: o Ollama derrama na CPU e a resposta despenca.
# Para forçar:  OLLAMA_NUM_PARALLEL=2 ./bootstrap.sh
OLLAMA_MAX_LOADED_MODELS="${OLLAMA_MAX_LOADED_MODELS:-$MAX_LOADED_PADRAO}"
OLLAMA_NUM_PARALLEL="${OLLAMA_NUM_PARALLEL:-$NUM_PARALLEL_PADRAO}"

log "candidatos: ${CANDIDATOS_PRINCIPAL[*]} — num_ctx ${NUM_CTX}, ${OLLAMA_MAX_LOADED_MODELS} modelo(s) vivo(s), ${OLLAMA_NUM_PARALLEL} slot(s)"

# ============================================================
# ETAPA 3 — Docker + NVIDIA Container Toolkit
# ============================================================
if ! feito docker; then
  log "ETAPA 3/5 — Docker e NVIDIA Container Toolkit"
  export DEBIAN_FRONTEND=noninteractive

  if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
  fi

  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list

  apt-get update
  apt-get install -y nvidia-container-toolkit
  nvidia-ctk runtime configure --runtime=docker
  systemctl restart docker

  # valida passthrough da GPU pro container
  docker run --rm --gpus all ubuntu:24.04 nvidia-smi -L

  marca docker
else
  log "ETAPA 3/5 — já feita, pulando"
fi

# ============================================================
# ETAPA 4 — sobe a stack
# ============================================================
log "ETAPA 4/5 — subindo containers"
cd "$DIR"
mkdir -p dados/ollama dados/webui

# O compose lê este .env sozinho (mesmo diretório). Escrevemos toda vez para
# que uma troca de plano — 12 GB hoje, 24 GB amanhã — reconfigure a stack sem
# ninguém precisar lembrar de editar o docker-compose.yml.
cat > "${DIR}/.env" <<ENVFILE
# GERADO PELO bootstrap.sh — não edite à mão, é sobrescrito a cada execução.
# VRAM detectada: ${VRAM_MB} MiB
OLLAMA_MAX_LOADED_MODELS=${OLLAMA_MAX_LOADED_MODELS}
OLLAMA_NUM_PARALLEL=${OLLAMA_NUM_PARALLEL}
ENVFILE

docker compose up -d

log "aguardando Ollama responder..."
for i in $(seq 1 30); do
  if docker exec ollama ollama list >/dev/null 2>&1; then
    log "Ollama pronto"
    break
  fi
  sleep 5
done

# ============================================================
# ETAPA 5 — baixa modelos e cria os Modelfiles
# ============================================================
if ! feito modelos; then
  log "ETAPA 5/5 — baixando modelos (demora, é o passo mais longo)"

  # As listas vieram da detecção de VRAM lá em cima. Tenta em ordem e fica
  # com o primeiro que existir de fato no registry — nome de tag muda entre
  # lançamentos. Confira em https://ollama.com/library se todos falharem.
  BASE_PRINCIPAL=""
  for m in "${CANDIDATOS_PRINCIPAL[@]}"; do
    log "tentando baixar: $m"
    if docker exec ollama ollama pull "$m"; then
      BASE_PRINCIPAL="$m"
      log "modelo principal = $m"
      break
    fi
    log "tag '$m' não existe, tentando próxima"
  done

  if [[ -z "$BASE_PRINCIPAL" ]]; then
    log "ERRO: nenhum modelo principal pôde ser baixado."
    log "Veja os nomes atuais em https://ollama.com/library e ajuste o script."
    exit 1
  fi
  echo "$BASE_PRINCIPAL" > "${DIR}/.modelo_base"

  # Em VRAM pequena a lista vem vazia de propósito: um segundo modelo só
  # serviria para ficar sendo carregado e descarregado.
  if (( ${#CANDIDATOS_SECUNDARIO[@]} > 0 )); then
    for m in "${CANDIDATOS_SECUNDARIO[@]}"; do
      if docker exec ollama ollama pull "$m"; then
        echo "$m" > "${DIR}/.modelo_secundario"
        break
      fi
    done
  fi

  marca modelos
else
  log "ETAPA 5/5 — modelos já baixados, pulando"
  BASE_PRINCIPAL="$(cat "${DIR}/.modelo_base")"
fi

# ---- cria os modelos customizados (sempre, é rápido e pega edições) ----
log "criando modelos customizados a partir dos Modelfiles"
mkdir -p "${DIR}/dados/ollama/modelfiles"
BASE_PRINCIPAL="$(cat "${DIR}/.modelo_base")"

for f in "${DIR}"/modelfiles/*.Modelfile; do
  [[ -e "$f" ]] || continue
  nome="$(basename "$f" .Modelfile)"
  # 1) troca o placeholder pelo modelo base que realmente existe
  # 2) ajusta o num_ctx ao que cabe nesta VRAM (a cópia, não o repositório)
  sed -e "s|__MODELO_BASE__|${BASE_PRINCIPAL}|g" \
      -e "s|^PARAMETER num_ctx .*|PARAMETER num_ctx ${NUM_CTX}|" \
      "$f" > "${DIR}/dados/ollama/modelfiles/${nome}.Modelfile"

  if docker exec ollama ollama create "$nome" \
       -f "/root/.ollama/modelfiles/${nome}.Modelfile"; then
    log "criado: $nome"
  else
    log "AVISO: falhou criar $nome"
  fi
done

# ============================================================
# FIM
# ============================================================
touch "${DIR}/PRONTO"

log "================================================"
log " BOOTSTRAP CONCLUÍDO"
log ""
log " VRAM        : ${VRAM_MB} MiB"
log " Modelo base : ${BASE_PRINCIPAL}   (num_ctx ${NUM_CTX})"
log " Customizados:"
docker exec ollama ollama list || true
log ""
log " No SEU PC, abra o túnel:"
log "   ssh -N -L 3000:localhost:3000 -L 11434:localhost:11434 root@\$(curl -s ifconfig.me)"
log " Depois acesse: http://localhost:3000"
log "================================================"
