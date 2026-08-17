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

  # Tenta os candidatos em ordem. Nomes de tag mudam entre lançamentos,
  # então usa o primeiro que existir de fato no registry.
  CANDIDATOS_PRINCIPAL=(
    "qwen3.6:27b-q8_0"
    "qwen3.6:27b"
    "qwen3:32b-q8_0"
    "qwen3:32b"
  )
  CANDIDATOS_SECUNDARIO=(
    "gemma4:31b"
    "gemma3:27b"
  )

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

  for m in "${CANDIDATOS_SECUNDARIO[@]}"; do
    if docker exec ollama ollama pull "$m"; then
      echo "$m" > "${DIR}/.modelo_secundario"
      break
    fi
  done

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
  # substitui o placeholder pelo modelo base que realmente existe
  sed "s|__MODELO_BASE__|${BASE_PRINCIPAL}|g" "$f" \
    > "${DIR}/dados/ollama/modelfiles/${nome}.Modelfile"

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
log " Modelo base : ${BASE_PRINCIPAL}"
log " Customizados:"
docker exec ollama ollama list || true
log ""
log " No SEU PC, abra o túnel:"
log "   ssh -N -L 3000:localhost:3000 -L 11434:localhost:11434 root@\$(curl -s ifconfig.me)"
log " Depois acesse: http://localhost:3000"
log "================================================"
