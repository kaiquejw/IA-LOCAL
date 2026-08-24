# GUIA — do zero à IA rodando

Siga na ordem. Cada passo diz **onde ir** e **o que colar**.

Leia a Fase 0 antes de gastar um centavo.

> **Antes da Fase 2, faça o ensaio em CPU:** [GUIA-CPU.md](GUIA-CPU.md).
> Valida 11 dos 13 itens desta stack por ~US$0,30, em vez de depurar com o
> medidor da GPU rodando. Depois volte para cá — só o driver NVIDIA fica
> como território novo.

---

# FASE 0 — proteção contra fatura surpresa

Faça isso **antes** de criar qualquer servidor.

### Passo 0.1 — alerta de gasto

1. Entre no painel da Vultr
2. Menu lateral esquerdo → **Billing**
3. Aba **Alerts** (ou "Billing Alerts")
4. Clique em **Add Alert**
5. Valor: **220** (dólares)
6. Salve

**Por quê:** quando o crédito promocional zera, a Vultr passa a cobrar o cartão automaticamente, sem avisar. Uma A40 esquecida ligada consome ~US$41/dia.

### Passo 0.2 — lembrete de expiração

No celular, crie um alarme para **3 dias antes** da data em que o crédito expira (30 dias após o cadastro).

Título: `DESTRUIR GPU VULTR — crédito expira em 3 dias`

### Passo 0.3 — chave SSH

Se você ainda não tem chave SSH, no seu PC (PowerShell ou WSL):

```bash
ssh-keygen -t ed25519 -C "kaique"
```

Aceite o caminho padrão, dê Enter nas senhas (ou coloque uma, mais seguro).

Copie a chave pública:

```bash
# WSL / Linux / Git Bash
cat ~/.ssh/id_ed25519.pub

# PowerShell
type $env:USERPROFILE\.ssh\id_ed25519.pub
```

No painel da Vultr:
1. Menu lateral → **Products** → **Orchestration** → **SSH Keys**
2. **Add SSH Key**
3. Nome: `meu-pc`
4. Cole o conteúdo copiado
5. **Add SSH Key**

---

# FASE 1 — o repositório no GitHub

**Onde:** seu PC, no VS Code. Não precisa de GPU nem servidor.

### Passo 1.1 — colocar os arquivos no lugar

Baixe os arquivos deste pacote e coloque numa pasta assim:

```
IA-LOCAL/
├── GUIA.md
├── GUIA-CPU.md
├── README.md
├── bootstrap.sh
├── bootstrap-cpu.sh
├── docker-compose.yml
├── docker-compose.cpu.yml
├── ia-sync.sh
├── bench.sh
├── prompts-teste.txt
├── log.md
├── .gitignore
├── .gitattributes
└── modelfiles/
    ├── tutor.Modelfile
    └── coder.Modelfile
```

Abra a pasta no VS Code: `File → Open Folder`.

### Passo 1.2 — validar antes de subir

No terminal do VS Code (`Ctrl + '`):

```bash
bash -n bootstrap.sh
docker compose config
```

O primeiro checa sintaxe do script. O segundo valida o YAML (funciona mesmo sem Docker rodando, se você tiver o CLI instalado; se não tiver, pule).

### Passo 1.3 — criar o repositório

1. Acesse **github.com** → botão **+** no topo direito → **New repository**
2. Nome: `IA-LOCAL`
3. Visibilidade: **Public**
4. **Não** marque "Add a README file"
5. **Create repository**

> **Por que público:** o `git clone` roda dentro do startup script, como root, sem interação e sem chave. Repositório privado exigiria embutir token — e token em script é vazamento esperando acontecer.
>
> **Regra absoluta:** nenhuma senha, token ou chave privada neste repositório. Nunca.

### Passo 1.4 — enviar

No terminal do VS Code:

```bash
git init
git add .
git commit -m "stack inicial de IA local"
git branch -M main
git remote add origin https://github.com/kaiquejw/IA-LOCAL.git
git push -u origin main
```

A URL acima já é a deste repositório. Se você for usar outra conta, troque o usuário.

### Passo 1.5 — confirmar

Abra `https://github.com/kaiquejw/IA-LOCAL` no navegador. Os arquivos devem estar lá.

Guarde essa URL — ela vai ser usada no próximo passo.

---

# FASE 2 — primeira instância, em modo manual

**Importante:** nesta fase você **não** vai usar Startup Script. Vai rodar tudo à mão.

**Motivo:** você vai errar. Se o script estiver automático, cada erro custa destruir + recriar + 15 min de espera. Em modo manual você corrige na hora, na mesma máquina.

### Passo 2.1 — criar o servidor

1. Painel Vultr → botão **Deploy** (canto superior direito) → **Deploy New Server**
2. **Choose Type:** clique em **Cloud GPU**
3. **Location:** `Miami`
4. **GPU Type / Plan:** selecione **qualquer** fração de **A40** que estiver
   disponível. Não fique esperando a de 24 GB liberar — o `bootstrap.sh` mede a
   VRAM e escolhe o modelo sozinho:

   | VRAM | Modelo principal | `num_ctx` | Segundo modelo | Modelos vivos | Slots paralelos |
   |---|---|---|---|---|---|
   | 48 GB | `qwen3:32b` (20,2 GB) | 32768 | `gemma3:27b` | 2 | 2 |
   | 24 GB | `gemma3:27b` (17,4 GB) | 16384 | `qwen2.5-coder:14b` | 1 | 2 |
   | 12 GB | `qwen3:14b` (9,3 GB) | 8192 | nenhum | 1 | 1 |
   | 8 GB | `qwen3:8b` (5,2 GB) | 8192 | nenhum | 1 | 1 |

   As duas últimas colunas viram um `.env` que o `bootstrap.sh` escreve e o
   `docker-compose.yml` lê. **Modelos vivos** é quantos pesos ficam na VRAM ao
   mesmo tempo; **slots paralelos** é quantas conversas simultâneas — cada slot
   aloca um KV cache próprio de `num_ctx` tokens. Só a A40 completa segura dois
   modelos: em 24 GB, `gemma3:27b` + `qwen2.5-coder:14b` soma 26,4 GB. Com 1
   modelo vivo, trocar de `tutor` para `coder` na WebUI recarrega — alguns
   segundos, muito melhor que rodar transbordado na CPU.

   Em 24 GB o `gemma3:27b` vem na frente de um 32B de propósito: ele usa
   *sliding window attention*, então o KV cache custa uma fração — sobra folga
   para contexto em vez de o modelo transbordar para a CPU.

   Para forçar outra escolha: `MODELO=qwen3:32b NUM_CTX=8192 ./bootstrap.sh`
5. **Image / Operating System:** `Ubuntu 24.04 LTS x64`
6. Role para baixo até **Additional Features**:
   - ❌ **Auto Backups** — desmarque (cobra e é inútil aqui)
   - ✅ IPv6 — pode deixar
7. **SSH Keys:** marque `meu-pc`
8. **Startup Script:** deixe em **None** (é de propósito)
9. **Server Hostname & Label:** `gpu-ia`
10. **Deploy Now**

Espere o status ficar **Running** (2-3 minutos). Anote o **IP**.

### Passo 2.2 — conectar

No seu PC:

```bash
ssh root@SEU_IP
```

Se aparecer pergunta sobre fingerprint, digite `yes`.

### Passo 2.3 — clonar e rodar

Já conectado na VPS:

```bash
git clone https://github.com/kaiquejw/IA-LOCAL.git /opt/ia
cd /opt/ia
chmod +x bootstrap.sh
./bootstrap.sh
```

Agora **acompanhe a saída**.

### O que esperar

- **Etapa 1** (base): ~2 min
- **Etapa 2** (driver NVIDIA): ~5 min. **Pode reiniciar a máquina.** Se reiniciar, a conexão SSH cai — espere 1 minuto, reconecte e rode `./bootstrap.sh` de novo. Ele retoma de onde parou.
- **Etapa 3** (Docker): ~3 min
- **Etapa 4** (containers): ~1 min
- **Etapa 5** (modelos): **10-25 min** — é o passo mais longo, está baixando ~30 GB

Ao final você verá `BOOTSTRAP CONCLUÍDO`.

### Passo 2.4 — se algo falhar

O script para no primeiro erro. Leia a mensagem.

```bash
# log completo
tail -100 /var/log/bootstrap-ia.log

# a GPU responde?
nvidia-smi

# containers de pé?
docker ps

# o container vê a GPU?
docker exec ollama nvidia-smi
```

Corrija o problema na VPS, e rode `./bootstrap.sh` novamente. As etapas já concluídas são puladas.

**Erro mais comum:** nenhuma tag de modelo funcionou. O script lista os candidatos que tentou. Vá em `https://ollama.com/library`, veja os nomes reais, e edite `bootstrap.sh` (arrays `CANDIDATOS_PRINCIPAL` / `CANDIDATOS_SECUNDARIO`).

> **Dica que muda tudo:** instale a extensão **Remote - SSH** no VS Code (`Ctrl+Shift+X`, busque "Remote - SSH"). Depois `Ctrl+Shift+P` → `Remote-SSH: Connect to Host` → `root@SEU_IP`. Você edita os arquivos da VPS no seu editor normal, com terminal integrado. Muito melhor que `vim`.

### Passo 2.5 — abrir o túnel e acessar

Abra um **segundo terminal** no seu PC (deixe o primeiro conectado):

```bash
ssh -N -L 3000:localhost:3000 -L 11434:localhost:11434 root@SEU_IP
```

Não vai aparecer nada — é normal, é um túnel. **Deixe essa janela aberta.**

No navegador: **http://localhost:3000**

1. Clique em **Sign up**
2. Crie sua conta (o primeiro cadastro vira administrador)
3. No topo, selecione o modelo **tutor**
4. Mande uma pergunta

Se respondeu, está funcionando.

### Passo 2.6 — verificar se está na GPU

Na VPS:

```bash
docker exec ollama ollama ps
```

Deve mostrar `100% GPU`. Se aparecer qualquer percentual de CPU, o modelo não caiu inteiro na VRAM — reduza `num_ctx` no Modelfile ou use quantização menor.

Monitor em tempo real:

```bash
nvtop
```

---

# FASE 3 — corrigir o repositório

As correções que você fez na VPS precisam voltar pro GitHub. Se não voltarem, a próxima instância repete o mesmo erro.

**No seu PC**, no VS Code, aplique as mesmas correções nos arquivos locais e:

```bash
git add .
git commit -m "correcoes do primeiro deploy"
git push
```

Se você editou via Remote-SSH direto na VPS, copie os trechos alterados para os arquivos locais.

---

# FASE 4 — automatizar (o teste que prova tudo)

### Passo 4.1 — criar o Startup Script

1. Painel Vultr → **Products** → **Orchestration** → **Startup Scripts**
2. **Add Startup Script**
3. **Name:** `ia-bootstrap`
4. **Type:** `Boot`
5. **Script:** cole exatamente isto (trocando o usuário):

```bash
#!/bin/bash
if [ ! -d /opt/ia ]; then
  git clone https://github.com/kaiquejw/IA-LOCAL.git /opt/ia
fi
cd /opt/ia
chmod +x bootstrap.sh
./bootstrap.sh
```

6. **Add Script**

> `Type: Boot` significa que roda a cada boot. Isso é intencional: se o bootstrap reiniciar a máquina na etapa do driver, ele retoma sozinho no boot seguinte.

### Passo 4.2 — destruir a instância atual

1. Painel → **Products** → **Compute** → clique no servidor `gpu-ia`
2. Aba **Settings** (menu à esquerda dentro do servidor)
3. **Destroy Server**
4. Confirme

Antes de destruir, se já tem conversa que quer guardar, rode no seu PC:

```bash
./ia-sync.sh backup SEU_IP
```

### Passo 4.3 — recriar do zero, automático

Repita o **Passo 2.1**, com uma diferença:

- **Startup Script:** selecione `ia-bootstrap`

**Deploy Now.** Agora vá fazer outra coisa por ~25 minutos.

### Passo 4.4 — validar

```bash
ssh root@NOVO_IP
ls /opt/ia/PRONTO && echo "PRONTO" || tail -40 /var/log/bootstrap-ia.log
docker exec ollama ollama list
```

Se apareceu `PRONTO` e os modelos estão listados **sem você ter tocado em nada** — a configuração é portável. Terminou.

Se falhou: volte para a Fase 2 (modo manual), corrija, atualize o repositório, tente de novo. É normal falhar na primeira: coisas que funcionam digitadas à mão quebram em modo não-interativo.

---

# FASE 5 — RAG (onde está o maior ganho de qualidade)

Isso é o que faz o modelo parar de adivinhar e passar a ler seu material.

### Passo 5.1 — criar as coleções

No Open WebUI (`http://localhost:3000`):

1. Menu lateral → **Workspace**
2. Aba **Knowledge**
3. **+ Create Knowledge**
4. Crie estas quatro:

| Nome | O que colocar |
|---|---|
| `trabalho` | Docs do SDK Dart, padrões do projeto, contratos de API |
| `aws` | Material oficial do Cloud Practitioner, docs dos serviços que estuda |
| `seguranca` | Material do Hackers do Bem, suas anotações do PortSwigger Academy |
| `writeups` | Seus próprios writeups de lab e máquinas resolvidas |

5. Dentro de cada uma, **Add Content** → suba PDF, `.md` ou `.txt`

### Passo 5.2 — usar

Na conversa, digite `#` e o nome da coleção. Exemplo:

```
#aws qual a diferença entre um bucket policy e uma ACL?
```

O modelo responde com base nos seus documentos, citando os trechos.

### Passo 5.3 — a coleção mais valiosa

`writeups` é a que quase ninguém monta e a que rende mais. Cada lab que você resolver, escreva um `.md`: o que encontrou, como explorou, qual foi o mecanismo, o que aprendeu.

Seis meses depois você pergunta "como eu resolvi aquele caso de SSRF" e o modelo responde com o **seu** método.

---

# ROTINA DIÁRIA (depois de tudo pronto)

## Subir

1. Painel → **Deploy** → Cloud GPU → A40 → Ubuntu 24.04 → SSH key → **Startup Script: `ia-bootstrap`** → Deploy
2. Anote o IP
3. No seu PC, dispare o restore (ele espera o bootstrap sozinho):
   ```bash
   ./ia-sync.sh restore NOVO_IP
   ```
4. Quando terminar, abra o túnel:
   ```bash
   ssh -N -L 3000:localhost:3000 -L 11434:localhost:11434 root@NOVO_IP
   ```
5. Navegador: `http://localhost:3000`

## Encerrar

```bash
./ia-sync.sh backup SEU_IP
```

Depois: Painel → Compute → servidor → **Settings** → **Destroy Server** → confirmar.

**Confira em Compute que a lista está vazia.** Instância desligada continua cobrando; só destruir para a conta.

---

# CHECKLIST DE FIM DE MÊS

Nos 3 dias antes do crédito expirar:

- [ ] `./ia-sync.sh backup` — histórico salvo no PC
- [ ] Pesos de LoRA ou qualquer artefato baixado
- [ ] `log.md` atualizado e commitado no GitHub
- [ ] **Servidor destruído** (Compute vazio)
- [ ] **Snapshots destruídos** (Products → Snapshots) — cobram armazenamento
- [ ] **Reserved IPs destruídos** (Products → Network) — cobram ~US$3/mês parados
- [ ] Billing → confirmar que nada está consumindo

---

# PASSAR PARA A CONTA DO SEU AMIGO

Ele faz **apenas isto**:

1. Cria a conta na Vultr (promoção dele, legítima)
2. Adiciona a chave SSH dele: Products → Orchestration → SSH Keys
3. Cria o Startup Script `ia-bootstrap` com as **mesmas 6 linhas** da Fase 4.1 — aponta pro **seu** repositório público, funciona igual
4. Deploy, mesmos parâmetros
5. Ele adiciona sua chave pública em `/root/.ssh/authorized_keys` para você acessar
6. No Open WebUI, o primeiro a se cadastrar é admin e libera o segundo em **Admin Panel → Users**

Startup Scripts não atravessam contas — é por isso que a configuração vive no git, não no painel.

---

# TROUBLESHOOTING

| Sintoma | Causa provável | O que fazer |
|---|---|---|
| `nvidia-smi: command not found` | Driver não instalou | `./bootstrap.sh` de novo; se persistir, `reboot` |
| `could not select device driver ... gpu` | Container toolkit não configurado | `nvidia-ctk runtime configure --runtime=docker && systemctl restart docker` |
| `ollama ps` mostra % em CPU | Modelo não caiu na VRAM | `NUM_CTX=4096 ./bootstrap.sh`, ou `MODELO=` menor |
| Resposta lenta na 1ª pergunta | Modelo carregando | Confirme `OLLAMA_KEEP_ALIVE=-1` no compose |
| `localhost:3000` não abre | Túnel caiu | Reabra o `ssh -N -L ...` |
| Modelo trunca meu código longo | `num_ctx` insuficiente | `NUM_CTX=16384 ./bootstrap.sh` e confira `ollama ps` depois |
| Código sai com sintaxe estranha | `repeat_penalty` alto | Mantenha ≤ 1.10 |
| Modelo inventou comando/CVE | Comportamento esperado do tamanho | Confirme no `man`. Use RAG para fatos. |

Túnel caindo sozinho? No `~/.ssh/config` do seu PC:

```
Host gpu
    HostName SEU_IP
    User root
    ServerAliveInterval 60
    ServerAliveCountMax 3
    LocalForward 3000 localhost:3000
    LocalForward 11434 localhost:11434
```

Depois é só `ssh -N gpu`.

---

# EXPECTATIVA HONESTA

O modelo que você vai rodar é bom, e vai ajudar muito. Mas não é um modelo de fronteira, e nenhuma calibração muda isso — o gap está nos pesos, não na configuração.

E o tamanho depende da fração que você conseguir. Num plano de **12 GB** você roda um 14B, não um 32B: a diferença aparece principalmente em raciocínio de vários passos e em código longo. Explicação de conceito e leitura de código continuam bem servidas. Se a instância de 12 GB é a que está disponível, ela vale muito mais que a de 24 GB que você não conseguiu criar.

**Ele vai ser excelente em:** explicar conceito, ler e explicar código, analisar output de ferramenta, rubber duck, responder em cima do seu RAG.

**Ele vai falhar em:** raciocínio longo de muitos passos, arquitetura de sistema inteiro, refactor multi-arquivo, bug sutil de lógica. E vai inventar nome de comando, flag e CVE com total confiança.

Aprender a reconhecer qual pergunta é de qual tipo — e levar as difíceis pra um modelo maior — é parte do aprendizado, não uma falha do setup.
