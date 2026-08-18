# Log de sessões

Anote a cada sessão. No dia 25 você não vai lembrar o que testou.

## Template

### AAAA-MM-DD — sessão N
- **Plano/VRAM:**
- **Modelo:**
- **num_ctx:**
- **O que testei:**
- **Resultado:**
- **Crédito gasto (aprox.):**
- **Próximo passo:**

---

### 2026-08-18 — sessão 1 (sem servidor, validação em Docker local)

- **Plano/VRAM:** nenhum. Rodou no Docker do PC, em CPU.
- **Modelo:** `qwen2.5:3b` → `tutor` e `coder`
- **num_ctx:** 4096
- **O que testei:** `docker-compose.cpu.yml` subindo os dois containers,
  `ollama pull`, `ollama create` com os dois Modelfiles, inferência real,
  `bench.sh` completo, WebUI respondendo.
- **Resultado:** funciona. 12,5 tok/s em CPU. Modelfiles válidos no ollama
  0.32.14 — os 6 `PARAMETER` e o `SYSTEM` com acentos chegaram intactos.
  `OLLAMA_KEEP_ALIVE=-1` ativo (`UNTIL: Forever`), portas só em 127.0.0.1,
  WebUI HTTP 200.
  Três bugs corrigidos: `bench.sh` (escape ANSI de `ollama run`, prompt
  quebrando nas aspas, e stdin comido dentro do `while read` — rodava só o
  primeiro prompt e dizia OK); tags de modelo inexistentes no `bootstrap.sh`;
  URL do repositório errada no GUIA e no README.
  `bootstrap.sh` agora escolhe modelo e `num_ctx` pela VRAM detectada.
- **Crédito gasto (aprox.):** US$0,00
- **NÃO validado (é o que sobra para o dia da GPU):** etapas 1 e 2 do
  bootstrap (pacotes do apt, `ufw`, `get.docker.com`), driver NVIDIA,
  passthrough da GPU pro container, túnel SSH, cadastro no WebUI, RAG.
  Nenhum desses passou de `bash -n`.
- **Próximo passo:** quando liberar qualquer fração de A40 (12 GB serve),
  rodar a FASE 2 do GUIA em modo manual. Se quebrar, será na etapa 1 ou 2.

---
