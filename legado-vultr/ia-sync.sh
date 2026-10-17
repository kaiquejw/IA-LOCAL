#!/usr/bin/env bash
# ia-sync.sh — backup/restore do histórico do Open WebUI
#
# Roda no SEU PC (WSL, Git Bash, Linux ou macOS).
#   ./ia-sync.sh backup  <IP>
#   ./ia-sync.sh restore <IP>
#
# Na VPS de ensaio (CPU), aponte para o outro compose:
#   IA_COMPOSE=docker-compose.cpu.yml ./ia-sync.sh backup <IP>
set -euo pipefail

ACAO="${1:-}"; IP="${2:-}"
BKP="./backups"; REMOTO="/opt/ia"; U="root"
COMPOSE="${IA_COMPOSE:-docker-compose.yml}"

[[ -z "$ACAO" || -z "$IP" ]] && { echo "uso: $0 {backup|restore} <IP>"; exit 1; }
mkdir -p "$BKP"
SSH="ssh -o StrictHostKeyChecking=accept-new ${U}@${IP}"

case "$ACAO" in
  backup)
    ARQ="webui-$(date +%Y%m%d-%H%M).tar.gz"
    echo "==> parando webui (evita SQLite corrompido)"
    $SSH "cd ${REMOTO} && docker compose -f ${COMPOSE} stop webui"
    echo "==> compactando"
    $SSH "cd ${REMOTO}/dados && tar czf /tmp/${ARQ} webui"
    echo "==> baixando"
    scp "${U}@${IP}:/tmp/${ARQ}" "${BKP}/${ARQ}"
    cp "${BKP}/${ARQ}" "${BKP}/webui-latest.tar.gz"
    echo "==> religando"
    $SSH "cd ${REMOTO} && docker compose -f ${COMPOSE} start webui"
    echo ""
    echo "OK -> ${BKP}/${ARQ}  ($(du -h "${BKP}/${ARQ}" | cut -f1))"
    echo "Pode destruir a instancia."
    ;;
  restore)
    ARQ="${BKP}/webui-latest.tar.gz"
    [[ -f "$ARQ" ]] || { echo "ERRO: $ARQ nao existe"; ls -1 "$BKP" 2>/dev/null; exit 1; }
    echo "==> esperando bootstrap terminar"
    until $SSH "test -f ${REMOTO}/PRONTO" 2>/dev/null; do
      echo "    ainda instalando... nova checagem em 30s"; sleep 30
    done
    echo "==> enviando"
    scp "$ARQ" "${U}@${IP}:/tmp/r.tar.gz"
    echo "==> restaurando"
    $SSH "cd ${REMOTO} && docker compose -f ${COMPOSE} stop webui && rm -rf dados/webui && tar xzf /tmp/r.tar.gz -C dados && docker compose -f ${COMPOSE} start webui"
    echo ""
    echo "OK. Abra o tunel:"
    echo "  ssh -N -L 3000:localhost:3000 -L 11434:localhost:11434 ${U}@${IP}"
    ;;
  *) echo "acao invalida"; exit 1 ;;
esac
