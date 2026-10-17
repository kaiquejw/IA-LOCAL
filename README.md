# IA-LOCAL

Stack reproduzível de IA local em GPU efêmera na nuvem.
Sobe do zero em uma instância limpa, sem intervenção manual.

**Ollama + Open WebUI + Modelfiles calibrados + RAG**

## Uso rápido

Dentro do pod da RunPod (por SSH):

```bash
git clone https://github.com/kaiquejw/IA-LOCAL.git /workspace/IA-LOCAL   # 1ª vez (ver nota do volume)
cd /workspace/IA-LOCAL && git pull && WEBUI=1 bash runpod-start.sh
```

### Nota do volume (persistência)

Testado em 17/10/2026: o volume **Global** da RunPod (`findmnt -T /workspace` mostra
`fuse.geesefs`, um volume em S3) **não serve** para esta stack. Ele não aceita
`chmod`, e três coisas quebram nele: o `git clone`, o venv do WebUI/Hermes e o
próprio Ollama, que baixa os blobs mas falha ao gravar o manifesto
(`chmod ... operation not permitted`).

- **Para persistir modelos:** use um **Network volume regional**, que é disco de
  verdade. Aí o fluxo acima funciona como está.
- **Preso no Global:** rode tudo no disco do container. Nada persiste: o modelo
  baixa de novo a cada pod, em ~1 min a 300 MB/s.
  ```bash
  git clone https://github.com/kaiquejw/IA-LOCAL.git /root/ia/IA-LOCAL
  cd /root/ia/IA-LOCAL && W=/root/ia LOGS=/workspace/logs WEBUI=1 bash runpod-start.sh
  ```

### Opções do `runpod-start.sh`

| Variável | Efeito |
|---|---|
| `WEBUI=1` | Sobe o Open WebUI em `127.0.0.1:3000`. |
| `REDTEAM=1` | Baixa `huihui_ai/qwen3-abliterated:32b` (~20 GB a mais) e cria o modelo `redteam`, para estudo de segurança em laboratório autorizado. Só cabe com disco sobrando (o container tem 30 GB). |
| `HERMES=1` | Instala e configura o Hermes Agent apontando para o Ollama local. Não sobe sozinho: rode `hermes` no terminal do pod. Confirmação antes de comando perigoso fica **ligada**. Busca web e navegador ficam **desligados**. |
| `RUNPOD_API_KEY` | Sua API key da RunPod, com escrita, guardada como **Secret** do pod (nunca no repo). Sem ela não existe auto-off. A key que a RunPod injeta no pod tem o mesmo nome, mas dá `Unauthorized`. Se colidir, use `AUTO_OFF_API_KEY`. |
| `AUTO_OFF_MIN=150` | Apaga o pod depois de N minutos (`0` desliga). Só funciona com a key acima. |
| `MODELO`, `NUM_CTX`, `SECUNDARIO=1`, `W`, `LOGS` | Veja o cabeçalho do script. |

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
| `modelfiles/redteam.Modelfile` | Mesmo corpo do tutor sobre base abliterated (`REDTEAM=1`). |
| `bench.sh` | Roda o conjunto de teste fixo. |
| `prompts-teste.txt` | 15 prompts de avaliação. Não altere sem motivo. |
| `log.md` | Diário de sessões. |
| `legado-vultr/` | Scripts da época da VM na Vultr (`GUIA.md`, `GUIA-CPU.md`, `bootstrap.sh`, `bootstrap-cpu.sh`, `docker-compose*.yml`, `ia-sync.sh`). Não servem no pod da RunPod (container sem systemd/Docker). |

## Segurança

- Portas expostas apenas em `127.0.0.1`. Acesso só via túnel SSH.
- `ufw` habilitado, somente porta 22 aberta.
- **Nenhuma credencial neste repositório.** Nunca comitar token, senha ou chave privada.
- Na RunPod, dê **Terminate** ao fim da sessão (Stop continua cobrando o disco). Um Network volume regional mantém os modelos; o Global (geesefs) não (ver nota do volume).
- Hermes Agent: `approvals.mode: manual` (pergunta antes de comando perigoso). Nunca `--yolo`, `approvals.mode: off` ou `HERMES_YOLO_MODE`.

## Antes de subir

Configure alerta de gasto no provedor. Instância desligada continua cobrando —
só destruir interrompe a cobrança.
