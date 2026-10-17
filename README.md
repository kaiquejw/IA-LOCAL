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

Com o plano de modelos atual (estudo sem filtro + Hermes; ~38 GB no volume de 50 GB):

```bash
cd /workspace/IA-LOCAL && git pull &&   WEBUI=1 HERMES=1 MODELO=huihui_ai/qwen3-abliterated:32b bash runpod-start.sh
```

| Uso | Modelo no Ollama | Base | Contexto |
|---|---|---|---|
| Estudo: `tutor`, `coder`, `redteam` | os três dividem o mesmo blob | `huihui_ai/qwen3-abliterated:32b` (19,8 GB) | 32768 |
| Hermes Agent | `qwen3-coder-hermes` (apelido só com `num_ctx`) | `qwen3-coder:30b` (18,6 GB, janela nativa 262144) | 65536 |

### Nota do volume (persistência)

Testado em 17/10/2026:

- **Network volume regional (CA-MTL-1): serve.** O `findmnt -T /workspace` mostra
  `nfs4` e o `chmod` funciona. `git clone`, os venvs, o Ollama e a memória do Hermes
  ficam no volume e persistem entre pods. É o fluxo acima.
- **Volume Global: não serve.** O `findmnt` mostra `fuse.geesefs`, um volume em S3.
  Ele não aceita `chmod`, e quebram o `git clone`, o venv e o próprio Ollama, que
  baixa os blobs mas falha ao gravar o manifesto (`chmod ... operation not permitted`).
  Se estiver preso nele, rode no disco do container. Nada persiste, e o modelo
  baixa de novo a cada pod:
  ```bash
  git clone https://github.com/kaiquejw/IA-LOCAL.git /root/ia/IA-LOCAL
  cd /root/ia/IA-LOCAL && W=/root/ia LOGS=/workspace/logs WEBUI=1 bash runpod-start.sh
  ```

### Opções do `runpod-start.sh`

| Variável | Efeito |
|---|---|
| `WEBUI=1` | Sobe o Open WebUI em `127.0.0.1:3000`. A 1ª instalação no volume leva ~15 min (NFS); depois é instantânea. |
| `MODELO=huihui_ai/qwen3-abliterated:32b` | Base sem filtro para estudo autorizado de segurança. Com ele, `tutor`, `coder` e `redteam` saem do mesmo modelo, sem baixar outro. |
| `REDTEAM=1` | Só para quando o base é o `qwen3` normal: baixa o abliterated à parte (~20 GB a mais) só para o `redteam`. |
| `HERMES=1` | Instala e configura o Hermes Agent (`$W/venv-hermes`, estado em `$W/hermes`, com `~/.hermes` apontando para lá). Baixa `HERMES_MODELO` (padrão `qwen3-coder:30b`), confere a janela nativa e cria o apelido `<modelo>-hermes` com `num_ctx` = `HERMES_CTX` (padrão 65536). Não sobe sozinho: rode `hermes` no terminal do pod. |
| `RUNPOD_API_KEY` / `AUTO_OFF_API_KEY` | Key que o auto-off usa na API GraphQL (`podTerminate`). A RunPod já injeta uma `RUNPOD_API_KEY` restrita ao pod: ela **lê** o próprio pod (testado), mas o delete com ela não foi testado. Para garantir, guarde uma key sua, com escrita, como **Secret** do pod em `AUTO_OFF_API_KEY` (nunca no repo); ela tem prioridade. Sem key nenhuma, não existe auto-off. |
| `AUTO_OFF_MIN=150` | Apaga o pod depois de N minutos (`0` desliga). Antes de agendar, valida a key com uma leitura e escreve o resultado no log. |
| `NUM_CTX`, `SECUNDARIO=1`, `W`, `LOGS` | Veja o cabeçalho do script. |

### Nota do Hermes (testado em 17/10/2026)

- **Funciona** com o `qwen3-coder-hermes`. Num pedido real, chamou a ferramenta
  `terminal` (`ls`) e a `memory`, e a nota foi gravada de verdade em
  `~/.hermes/memories/MEMORY.md`. Leva ~30 s por pedido; o modelo gera ~40 tok/s.
- **Precisa de 64K de contexto ou mais**, ou recusa iniciar. O `qwen3:32b` não serve
  (janela nativa de 40.960). Não force contexto além do nativo.
- **Por que o apelido:** o Hermes fala pela API OpenAI (`/v1`), e por ali o Ollama
  ignora o `num_ctx` do request e serve no padrão calculado pela VRAM (32768 na A40).
  O apelido só fixa `num_ctx 65536`, sem `SYSTEM`. Confira com `ollama ps`: a
  coluna CONTEXT tem que mostrar 65536.
- **Confirmação de comando:** `approvals.mode: manual`. Testado: um `rm -rf` pediu
  aprovação e, sem resposta, foi negado após 60 s. Comando inofensivo (`ls`) roda direto.
- **Limite conhecido:** às vezes o qwen3-coder escreve a chamada de ferramenta como
  texto (`<function=terminal>...`) em vez de executá-la. Nesse caso nada roda; repita
  o pedido de forma mais direta.
- **Timeout em resposta longa:** o Hermes já sobe a leitura para 1800 s em endpoint
  local. Para forçar: `export HERMES_STREAM_READ_TIMEOUT=3600` antes do `hermes`.
- **Busca web e navegador (desligados):** precisam de chave de provedor externo.
  Para ligar depois: ponha a chave em `~/.hermes/.env` (o navegador pede
  `BROWSERBASE_API_KEY`), tire `web`/`browser` de `agent.disabled_toolsets` no
  `~/.hermes/config.yaml` e rode `hermes tools enable web`.

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
| `modelfiles/redteam.Modelfile` | Mesmo corpo do tutor, papel de mentor de segurança, sobre base abliterated. |
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
