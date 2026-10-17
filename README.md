# IA-LOCAL

Stack reproduzível de IA local em GPU efêmera na nuvem.
Sobe do zero em uma instância limpa, sem intervenção manual.

**Ollama + Open WebUI + Modelfiles calibrados + RAG**

## Uso rápido

Dentro do pod da RunPod (por SSH):

```bash
git clone https://github.com/kaiquejw/IA-LOCAL.git /workspace/IA-LOCAL   # só na 1ª vez
cd /workspace/IA-LOCAL && git pull && WEBUI=1 bash runpod-start.sh
```

Se o `/workspace` for volume de rede (`findmnt -T /workspace` mostra `fuse.geesefs`),
ele não aceita `chmod`: o `git clone` falha lá. Rode tudo no disco do container
(some no Terminate, então o modelo baixa de novo a cada pod):

```bash
git clone https://github.com/kaiquejw/IA-LOCAL.git /root/ia/IA-LOCAL
cd /root/ia/IA-LOCAL && W=/root/ia LOGS=/workspace/logs WEBUI=1 bash runpod-start.sh
```

Acesso (do seu PC):

```bash
ssh -N -L 3000:localhost:3000 -L 11434:localhost:11434 root@IP -p PORTA
# navegador: http://localhost:3000
```

## Arquivos

| Arquivo | O que faz |
|---|---|
| `runpod-start.sh` | Sobe a stack num pod da RunPod. Modelos e WebUI ficam no volume /workspace (ou no disco do container, com `W=/root/ia`). |
| `modelfiles/tutor.Modelfile` | Modelo principal de estudo. |
| `modelfiles/coder.Modelfile` | Foco em código. |
| `bench.sh` | Roda o conjunto de teste fixo. |
| `prompts-teste.txt` | 15 prompts de avaliação. Não altere sem motivo. |
| `log.md` | Diário de sessões. |
| `legado-vultr/` | Scripts da época da VM na Vultr (`GUIA.md`, `GUIA-CPU.md`, `bootstrap.sh`, `bootstrap-cpu.sh`, `docker-compose*.yml`, `ia-sync.sh`). Não servem no pod da RunPod (container sem systemd/Docker). |

## Segurança

- Portas expostas apenas em `127.0.0.1`. Acesso só via túnel SSH.
- `ufw` habilitado, somente porta 22 aberta.
- **Nenhuma credencial neste repositório.** Nunca comitar token, senha ou chave privada.
- Na RunPod, dê **Terminate** ao fim da sessão (Stop continua cobrando o disco). O volume mantém os modelos (com `W=/root/ia`, só os logs).

## Antes de subir

Configure alerta de gasto no provedor. Instância desligada continua cobrando —
só destruir interrompe a cobrança.
