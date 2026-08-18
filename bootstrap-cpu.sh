#!/usr/bin/env bash
#
# bootstrap-cpu.sh — ENSAIO em VPS de CPU (sem GPU).
#
# Mesma sequência do bootstrap.sh de produção, MENOS a etapa do driver NVIDIA
# e do container toolkit. Serve para validar, a ~1/14 do custo da GPU:
#   clone do repositório, quebras de linha dos scripts, pacotes base,
#   instalação do Docker, sintaxe do compose, containers subindo,
#   sintaxe dos Modelfiles e o `ollama create`.
#
# IDEMPOTENTE: usa marcadores em .etapas/, retoma de onde parou.
#
# Rode como root:  ./bootstrap-cpu.sh
#
set -euo pipefail

DIR="/opt/ia"
LOG="/var/log/bootstrap-ia.log"
ETAPAS="${DIR}/.etapas"
COMPOSE="docker-compose.cpu.yml"

# Contexto curto no ensaio: 32768 tokens de KV cache em CPU estouram os 8 GB
# de RAM da VPS. O valor de produção continua no Modelfile — aqui ele é
# reescrito na cópia, o arquivo do repositório não é tocado.
NUM_CTX="${NUM_CTX:-4096}"

# Modelos pequenos, na ordem de preferência. O primeiro que existir de fato
# no registry é o usado — é exatamente esta lógica que estamos ensaiando.
CANDIDATOS_CPU=(
  "qwen2.5:3b"
  "llama3.2:3b"
  "gemma3:4b"
  "qwen3:4b"
  "phi3:mini"
)

mkdir -p "$ETAPAS"
exec > >(tee -a "$LOG") 2>&1

log()   { echo -e "\n>>> $* \n"; }
feito() { [[ -f "${ETAPAS}/$1" ]]; }
marca() { touch "${ETAPAS}/$1"; }

log "ENSAIO EM CPU iniciado — $(date)"

cd "$DIR"
if [[ ! -f "$COMPOSE" ]]; then
  log "ERRO: $COMPOSE não existe em $DIR. O clone veio incompleto?"
  exit 1
fi

# ============================================================
# ETAPA 1 — pacotes base e firewall   (idêntica à de produção)
# ============================================================
if ! feito base; then
  log "ETAPA 1/4 — pacotes base e firewall"
  export DEBIAN_FRONTEND=noninteractive

  apt-get update
  apt-get install -y --no-install-recommends \
      build-essential curl git ca-certificates gnupg \
      htop nvtop jq ufw python3 python3-pip

  ufw allow 22/tcp
  ufw --force enable

  marca base
else
  log "ETAPA 1/4 — já feita, pulando"
fi

# ============================================================
# ETAPA 2 — Docker   (sem o NVIDIA Container Toolkit)
# ============================================================
# Marcador próprio: se um dia esta máquina virar GPU, a etapa 3 do
# bootstrap.sh de produção ainda precisa rodar para instalar o toolkit.
if ! feito docker-cpu; then
  log "ETAPA 2/4 — Docker"
  export DEBIAN_FRONTEND=noninteractive

  if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
  fi

  # Se este container sobe, o Docker está saudável.
  docker run --rm hello-world

  marca docker-cpu
else
  log "ETAPA 2/4 — já feita, pulando"
fi

# ============================================================
# ETAPA 3 — sobe a stack
# ============================================================
log "ETAPA 3/4 — subindo containers ($COMPOSE)"
mkdir -p dados/ollama dados/webui
docker compose -f "$COMPOSE" up -d

log "aguardando Ollama responder..."
PRONTO_OLLAMA=0
for i in $(seq 1 30); do
  if docker exec ollama ollama list >/dev/null 2>&1; then
    log "Ollama pronto"
    PRONTO_OLLAMA=1
    break
  fi
  sleep 5
done

if [[ "$PRONTO_OLLAMA" -eq 0 ]]; then
  log "ERRO: Ollama não respondeu em 150s."
  docker compose -f "$COMPOSE" ps
  docker compose -f "$COMPOSE" logs --tail 40 ollama
  exit 1
fi

# ============================================================
# ETAPA 4 — baixa o modelo pequeno
# ============================================================
if ! feito modelos-cpu; then
  log "ETAPA 4/4 — baixando modelo pequeno (~2 GB, 3 a 6 min)"

  BASE=""
  for m in "${CANDIDATOS_CPU[@]}"; do
    log "tentando baixar: $m"
    if docker exec ollama ollama pull "$m"; then
      BASE="$m"
      log "modelo do ensaio = $m"
      break
    fi
    log "tag '$m' não existe, tentando próxima"
  done

  if [[ -z "$BASE" ]]; then
    log "ERRO: nenhum dos candidatos pôde ser baixado."
    log "Candidatos tentados: ${CANDIDATOS_CPU[*]}"
    log "Veja os nomes atuais em https://ollama.com/library e ajuste o script."
    exit 1
  fi
  echo "$BASE" > "${DIR}/.modelo_base_cpu"

  marca modelos-cpu
else
  log "ETAPA 4/4 — modelo já baixado, pulando"
fi

# ---- cria os modelos customizados (sempre, é rápido e pega edições) ----
log "criando modelos customizados a partir dos Modelfiles"
mkdir -p "${DIR}/dados/ollama/modelfiles"
BASE="$(cat "${DIR}/.modelo_base_cpu")"

for f in "${DIR}"/modelfiles/*.Modelfile; do
  [[ -e "$f" ]] || continue
  nome="$(basename "$f" .Modelfile)"
  # 1) troca o placeholder pelo modelo base que realmente existe
  # 2) derruba o num_ctx para caber na RAM da VPS de CPU
  sed -e "s|__MODELO_BASE__|${BASE}|g" \
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

IP_PUBLICO="$(curl -s --max-time 5 ifconfig.me || echo SEU_IP)"

log "================================================"
log " ENSAIO EM CPU CONCLUÍDO"
log ""
log " Modelo base : ${BASE}   (num_ctx ${NUM_CTX})"
log " Customizados:"
docker exec ollama ollama list || true
log ""
log " No SEU PC, abra o túnel:"
log "   ssh -N -L 3000:localhost:3000 root@${IP_PUBLICO}"
log " Depois acesse: http://localhost:3000"
log ""
log " A resposta vai sair devagar — é CPU. O que importa é que ela sai."
log "================================================"
