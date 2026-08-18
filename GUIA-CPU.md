# ENSAIO EM CPU — validar tudo antes de gastar GPU

## Por que estamos fazendo isso

A GPU custa entre US$0,43 e US$0,86 por hora. Uma VPS de CPU comum custa **US$0,060 por hora** — cerca de 14 vezes menos.

O `bootstrap.sh` tem cinco etapas. Só **uma** delas é específica de GPU (o driver NVIDIA). As outras quatro — pacotes, Docker, containers, modelos e Modelfiles — são idênticas em qualquer máquina.

Erro de sintaxe, caminho errado, permissão, YAML mal formado, tag de modelo inexistente: tudo isso aparece igual numa VPS de CPU. E cada tentativa de correção custa centavos em vez de dólares.

**Resultado esperado:** quando a GPU finalmente estiver disponível, a única coisa não testada será o driver. Se algo falhar lá, você sabe exatamente onde olhar, em vez de depurar cinco etapas ao mesmo tempo com o medidor rodando.

Custo total deste ensaio: **~US$0,20 a US$0,40** (3 a 6 horas de VPS).

---

## O que este ensaio valida

| Item | Valida? |
|---|---|
| Clone do repositório do GitHub | ✅ |
| Quebras de linha dos scripts (o problema do CRLF) | ✅ |
| Instalação do Docker | ✅ |
| Sintaxe do `docker-compose.yml` | ✅ |
| Containers subindo e se comunicando | ✅ |
| Sintaxe dos Modelfiles | ✅ |
| `ollama create` funcionando | ✅ |
| Túnel SSH e acesso ao Open WebUI | ✅ |
| Criação de conta, seleção de modelo | ✅ |
| Montagem das coleções de RAG | ✅ |
| Qualidade do system prompt | ✅ (parcial) |
| Driver NVIDIA | ❌ |
| Passthrough de GPU pro container | ❌ |
| Velocidade e VRAM | ❌ |

Onze de treze itens. É por isso que vale.

---

# PASSO 1 — subir os arquivos novos pro GitHub  ✅ FEITO

**O que:** adicionar `bootstrap-cpu.sh` e `docker-compose.cpu.yml` ao repositório.

**Por que:** o bootstrap clona do GitHub. Se o arquivo não estiver lá, a VPS não o encontra.

Os dois arquivos já estão em `C:\Users\kaiqu\IA-LOCAL`, commitados e com push feito.
Se precisar refazer depois de editar algo:

```
cd C:\Users\kaiqu\IA-LOCAL
git add .
git commit -m "ajustes do ensaio em CPU"
git push
```

Confira que subiu:

```
git ls-files --eol bootstrap-cpu.sh
```

Precisa mostrar `i/lf`. Se mostrar `i/crlf`, o `.gitattributes` não pegou — me avise.

---

# PASSO 2 — criar a VPS de CPU

**Por que CPU e não GPU:** é o ponto do exercício. Mesma validação, 1/14 do preço.

No painel Vultr → **Deploy**:

| Campo | Valor | Motivo |
|---|---|---|
| Choose Type | **Shared CPU** ou **Dedicated CPU** | não precisa de GPU |
| Plan | `vx1-g-2c-8g` (2 vCPU, 8 GB) — US$0,060/hr | 8 GB de RAM é o mínimo confortável para um modelo de 3B em CPU |
| Location | **Atlanta** ou **Miami** | menor latência a partir do Brasil |
| Image | Ubuntu 24.04 LTS x64 | mesma imagem da instância de GPU — é isso que torna o ensaio válido |
| Auto Backups | ❌ desmarcar | cobra e é inútil em máquina descartável |
| SSH Keys | ✅ `PC KIQ` | acesso sem senha |
| Startup Script | **None** | modo manual, para você ver os erros na hora |
| Hostname | `ensaio-cpu` | distinguir da futura instância de GPU |

**Deploy Now.** Aguarde **Running** e anote o IP.

> A imagem tem que ser a **mesma** Ubuntu 24.04 da instância de GPU. Se você testar em Debian ou em outra versão, o ensaio perde valor — nomes de pacote e caminhos mudam.

---

# PASSO 3 — rodar o ensaio

```
ssh root@IP_DA_VPS
```

```
git clone https://github.com/kaiquejw/IA-LOCAL.git /opt/ia
cd /opt/ia
chmod +x bootstrap-cpu.sh
./bootstrap-cpu.sh
```

**O que observar em cada etapa:**

**Etapa 1 — pacotes (~2 min).** Se falhar aqui, é rede ou nome de pacote errado. Vale para a GPU também.

**Etapa 2 — Docker (~2 min).** Termina rodando `hello-world`. Se esse container subir, o Docker está saudável.

**Etapa 3 — containers (~1 min).** Aqui o `docker-compose.cpu.yml` é interpretado. Erro de YAML aparece agora. O compose de produção tem a mesma estrutura, então validar um valida quase o outro.

**Etapa 4 — modelo (~3-6 min).** Baixa ~2 GB. Aqui você descobre se as tags de modelo existem e se o `ollama create` aceita a sintaxe dos seus Modelfiles. **Este é o ponto mais valioso do ensaio** — é onde o bootstrap de GPU tem mais chance de falhar, e onde falhar é mais caro.

Ao final: `ENSAIO EM CPU CONCLUÍDO`.

> **Dois detalhes do `bootstrap-cpu.sh`:** ele tenta `qwen2.5:3b`, `llama3.2:3b`,
> `gemma3:4b`, `qwen3:4b` e `phi3:mini` nessa ordem e fica com o primeiro que
> baixar; e reescreve `num_ctx` para 4096 **na cópia** do Modelfile — os
> `modelfiles/*.Modelfile` do repositório continuam com o valor de produção
> (32768). Para testar outro contexto: `NUM_CTX=8192 ./bootstrap-cpu.sh`.

---

# PASSO 4 — acessar e testar

Abra um **segundo terminal** (mantenha o primeiro conectado):

```
ssh -N -L 3000:localhost:3000 root@IP_DA_VPS
```

Não aparece nada — é um túnel. Deixe aberto.

No navegador: **http://localhost:3000**

1. **Sign up** → crie a conta (o primeiro cadastro vira admin)
2. No topo, selecione o modelo **tutor**
3. Mande uma pergunta

⚠️ **A resposta vai sair devagar** — alguns tokens por segundo, contra dezenas na GPU. Isso é esperado e não é problema. O que importa é que ela **sai**.

---

# PASSO 5 — o trabalho de verdade: montar o RAG

**Por que aqui e não na GPU:** RAG é indexação de texto. A GPU não acelera isso de forma relevante, e é o item que mais melhora a qualidade das respostas. Fazer agora significa que sua primeira sessão de GPU já começa com um tutor útil em vez de um chat vazio.

No Open WebUI:

1. Menu lateral → **Workspace** → aba **Knowledge**
2. **+ Create Knowledge** e crie quatro:

| Nome | Conteúdo |
|---|---|
| `trabalho` | docs do SDK Dart, padrões do projeto, contratos de API |
| `aws` | material do Cloud Practitioner, docs dos serviços |
| `seguranca` | material do Hackers do Bem, anotações do PortSwigger |
| `writeups` | seus próprios writeups de lab |

3. Em cada uma: **Add Content** → suba os PDFs e `.md`

**Teste o RAG:** na conversa, digite `#` seguido do nome da coleção:

```
#aws qual a diferença entre bucket policy e ACL?
```

O modelo deve responder citando seus documentos.

> Modelo de 3B responde mal comparado a um de 27B — não julgue a qualidade aqui. O que você está validando é se a **recuperação** funciona: ele está achando o trecho certo do seu documento?

---

# PASSO 6 — validar o backup

**Por que:** é o mecanismo que preserva suas conversas entre instâncias. Melhor descobrir que está quebrado agora.

O jeito certo é usar o próprio `ia-sync.sh` — é ele que roda na GPU depois, então
validá-lo agora é parte do ensaio. No Git Bash ou WSL, dentro da pasta do projeto:

```bash
IA_COMPOSE=docker-compose.cpu.yml ./ia-sync.sh backup IP_DA_VPS
```

A variável `IA_COMPOSE` existe só para isso: apontar o script para o compose de
ensaio. Na GPU você roda sem ela (`./ia-sync.sh backup IP`) e ele usa o
`docker-compose.yml` de produção.

Se preferir não sair do PowerShell, o equivalente à mão:

```
ssh root@IP "cd /opt/ia && docker compose -f docker-compose.cpu.yml stop webui && cd dados && tar czf /tmp/bkp.tar.gz webui && cd .. && docker compose -f docker-compose.cpu.yml start webui"
scp root@IP:/tmp/bkp.tar.gz .
```

Se o arquivo chegou no seu PC (`backups/webui-latest.tar.gz` pelo script, ou
`bkp.tar.gz` à mão), o mecanismo funciona. **Guarde esse arquivo** — as coleções
de RAG que você montou estão nele, e você vai restaurá-las na instância de GPU
com `./ia-sync.sh restore NOVO_IP`.

---

# PASSO 7 — refinar o system prompt

**Por que agora:** é a segunda maior alavanca de qualidade depois do RAG, e não custa GPU nenhuma.

Converse com o modelo por um tempo e observe:

- Ele está verboso demais? Adicione uma instrução de concisão.
- Está dando preâmbulo ("Claro! Vou explicar...")? Reforce a proibição.
- Está inventando comando? Reforce a regra de calibração de confiança.
- Falta algum formato que você quer sempre?

Edite `modelfiles/tutor.Modelfile` no VS Code, faça commit e push. Para testar na hora, sem esperar novo deploy:

```
docker exec ollama ollama create tutor -f /root/.ollama/modelfiles/tutor.Modelfile
```

Mas atenção: esse comando lê o arquivo já processado dentro do container. Para testar uma edição nova, é mais simples editar direto na VPS com `nano /opt/ia/dados/ollama/modelfiles/tutor.Modelfile` e recriar — depois replique a mudança no repositório.

---

# PASSO 8 — destruir

```
ssh root@IP "docker compose -f /opt/ia/docker-compose.cpu.yml down"
```

Painel → **Compute** → `ensaio-cpu` → **Settings** → **Destroy Server**.

Confirme que a lista de Compute ficou vazia.

---

# CHECKLIST DO ENSAIO

- [ ] `bootstrap-cpu.sh` e `docker-compose.cpu.yml` no GitHub, com `i/lf`
- [ ] VPS de CPU criada com Ubuntu 24.04
- [ ] `bootstrap-cpu.sh` rodou até o fim sem erro
- [ ] Correções (se houve) aplicadas no repositório e com push feito
- [ ] Open WebUI acessível e respondendo
- [ ] 4 coleções de RAG montadas com conteúdo
- [ ] RAG testado com `#colecao` e recuperando os trechos certos
- [ ] Backup baixado para o PC
- [ ] System prompt refinado e commitado
- [ ] VPS destruída

Cumprido isso, quando a GPU aparecer você roda o `bootstrap.sh` de produção sabendo que só o driver é território novo.

---

# O QUE MUDA NA INSTÂNCIA DE GPU

Só isto:

| | Ensaio (CPU) | Produção (GPU) |
|---|---|---|
| Script | `bootstrap-cpu.sh` | `bootstrap.sh` |
| Compose | `docker-compose.cpu.yml` | `docker-compose.yml` |
| Modelo | 3B | 27B ou 32B |
| `num_ctx` | 4096 | 32768 |
| Etapa extra | — | driver NVIDIA + container toolkit |

Nada mais. É por isso que o ensaio vale.
