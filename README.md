# IA-LOCAL

Stack reproduzível de IA local em GPU efêmera na nuvem.
Sobe do zero em uma instância limpa, sem intervenção manual.

**Ollama + Open WebUI + Modelfiles calibrados + RAG**

## Uso rápido

Startup Script da instância (Vultr / RunPod / qualquer Ubuntu 24.04 com GPU):

```bash
#!/bin/bash
if [ ! -d /opt/ia ]; then
  git clone https://github.com/kaiquejw/IA-LOCAL.git /opt/ia
fi
cd /opt/ia && chmod +x bootstrap.sh && ./bootstrap.sh
```

Acesso (do seu PC):

```bash
ssh -N -L 3000:localhost:3000 -L 11434:localhost:11434 root@IP
# navegador: http://localhost:3000
```

## Arquivos

| Arquivo | O que faz |
|---|---|
| `GUIA.md` | **Comece aqui.** Passo a passo completo. |
| `GUIA-CPU.md` | Ensaio em VPS de CPU antes de gastar GPU. |
| `bootstrap.sh` | Provisiona tudo. Idempotente, retoma se reiniciar. |
| `bootstrap-cpu.sh` | Mesma sequência sem a etapa do driver NVIDIA. |
| `docker-compose.yml` | Ollama + Open WebUI. Portas presas em 127.0.0.1. |
| `docker-compose.cpu.yml` | Mesma stack sem o passthrough de GPU. |
| `modelfiles/tutor.Modelfile` | Modelo principal de estudo. |
| `modelfiles/coder.Modelfile` | Foco em código. |
| `ia-sync.sh` | Backup/restore do histórico entre instâncias. |
| `bench.sh` | Roda o conjunto de teste fixo. |
| `prompts-teste.txt` | 15 prompts de avaliação. Não altere sem motivo. |
| `log.md` | Diário de sessões. |

## Segurança

- Portas expostas apenas em `127.0.0.1`. Acesso só via túnel SSH.
- `ufw` habilitado, somente porta 22 aberta.
- **Nenhuma credencial neste repositório.** Nunca comitar token, senha ou chave privada.

## Antes de subir

Configure alerta de gasto no provedor. Instância desligada continua cobrando —
só destruir interrompe a cobrança.
