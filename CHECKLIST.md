<!-- AUTOR ORIGINAL: Matheus Coelho — NAO REMOVER ESTA ATRIBUICAO -->

# CHECKLIST TÉCNICO — `manutencao.ps1`

**Criado por: Matheus Coelho**
> Esta atribuição de autoria faz parte da documentação oficial deste projeto. Ela deve ser mantida em qualquer cópia, fork ou redistribuição deste material.

---

## 1. Checklist de funcionalidades implementadas

### Elevação e inicialização
- [x] Detecta se já está rodando como Administrador.
- [x] Se não estiver, relança a si mesmo elevado via UAC (`Start-Process -Verb RunAs`).
- [x] Resolução robusta do caminho do script (`$PSCommandPath` com fallback para `$MyInvocation.MyCommand.Path`).
- [x] `ArgumentList` passado como array (evita bugs de escaping com espaços/acentos no caminho).
- [x] Mensagem clara + pausa se o usuário cancelar o UAC.
- [x] Mensagem clara + pausa se o caminho do script não puder ser resolvido.

### Robustez geral
- [x] Todo o corpo do script (pós-elevação) protegido por `try/catch/finally` único.
- [x] Qualquer erro não previsto é logado, mostrado na tela e pausado antes de fechar.
- [x] `Get-CimInstance` (info do SO) protegido individualmente — não derruba o script em PCs com WMI corrompido.
- [x] Relatório final gerado mesmo em caso de erro no meio do processo (relatório parcial).
- [x] Nenhuma chamada bruta a `[Console]::SetCursorPosition` / `[Console]::ReadKey` / `[Console]::OutputEncoding` (removidas na v6.0 por causarem fechamento instantâneo em certos hosts).

### Execução de comandos externos (DISM/SFC)
- [x] Leitura assíncrona de `StandardOutput` e `StandardError` via eventos (`OutputDataReceived`/`ErrorDataReceived`).
- [x] Não bloqueia a thread principal esperando `ReadLine()` (causa raiz do travamento original).
- [x] Lê `StandardError` (evita deadlock de buffer cheio).
- [x] Decodifica a saída no codepage OEM real do console (evita texto corrompido em qualquer idioma de Windows).
- [x] Captura o "veredito" textual (última linha de saída) de cada etapa DISM/SFC, já que o código de saída sozinho não é confiável para indicar corrupção encontrada.
- [x] Cronômetro por etapa e cronômetro total.

### Pipeline de manutenção (9 etapas)
- [x] DISM CheckHealth
- [x] DISM ScanHealth
- [x] DISM StartComponentCleanup
- [x] DISM RestoreHealth
- [x] SFC /Scannow
- [x] Flush de cache DNS
- [x] Otimização de disco em **todas** as unidades fixas (não só `C:`), com método automático (retrim SSD / defrag HDD)
- [x] Limpeza de `%TEMP%`, `C:\Windows\Temp` e pasta "Recentes"
- [x] Verificação de disco (`chkdsk /scan`) em todas as unidades, com reparo `/f /r` agendado **apenas se** corrupção for detectada (não incondicionalmente)

### Saída e relatório
- [x] Saída sequencial no console (compatível com qualquer terminal do Windows).
- [x] Log detalhado em arquivo, criado desde o início da execução elevada.
- [x] Relatório resumido em `.txt` na Área de Trabalho ao final.
- [x] Aviso explícito quando reinício é necessário para concluir o CHKDSK.

---

## 2. Checklist de testes realizados

- [x] Validação de sintaxe via `System.Management.Automation.Language.Parser` (sem erros).
- [x] Execução ponta a ponta simulada (sem privilégio de administrador, para validar que nenhuma etapa derruba o script mesmo falhando) — todas as 9 etapas reportam corretamente `FALHA` com o veredito real do Windows ("Use um prompt de comandos com privilégios elevados...") em vez de travar.
- [x] Confirmado que `[Console]::SetCursorPosition` falha com `"Identificador inválido"` no ambiente de teste, validando a decisão de removê-lo (v6.0).
- [x] Confirmado que `Read-Host` (usado na pausa final) não gera exceção, ao contrário de `[Console]::ReadKey`.
- [x] Relatório final conferido linha a linha, incluindo a seção "DETALHES" com os "Veredito" de cada etapa DISM/SFC.
- [ ] **Pendente:** execução real completa (com privilégio de administrador de verdade) em pelo menos um PC Windows 10 e um Windows 11, do início ao fim, incluindo a etapa `RestoreHealth` com download real do Windows Update.
- [ ] **Pendente:** teste em PC com múltiplos discos fixos (para validar o loop de otimização/verificação em mais de uma unidade).
- [ ] **Pendente:** teste em PC cujo CHKDSK realmente detecte corrupção (validar o fluxo de agendamento de reparo e a mensagem de reinício necessário).

---

## 3. Gaps conhecidos e plano de correção sugerido

| # | Gap | Risco | Ação recomendada | Prioridade |
|---|-----|-------|-------------------|------------|
| 1 | DISM/SFC não têm timeout. Se `RestoreHealth` ficar preso esperando o Windows Update (rede lenta/instável), o script espera indefinidamente. | Médio — pode parecer "travado" em redes ruins, mesmo funcionando corretamente por baixo. | Adicionar um tempo máximo configurável (ex.: 45 min) por etapa DISM; se estourar, avisar o técnico e perguntar se deseja continuar esperando ou abortar (não matar o processo automaticamente, pois interromper o DISM no meio pode corromper ainda mais o componente store). | Média |
| 2 | Sem opção de fonte alternativa para `RestoreHealth` (`/Source:`) quando não há internet. | Alto em ambientes sem acesso à internet — a etapa sempre falhará nesse cenário. | Adicionar parâmetro opcional para apontar uma imagem `install.wim`/`install.esd` local como fonte, com fallback para o comportamento atual (Windows Update) se não for informado. | Média |
| 3 | `chkdsk /scan` interpreta qualquer código de saída diferente de 0 como "problema", mas alguns códigos podem indicar apenas avisos, não corrupção real. | Baixo — pode agendar reinício em situações que não exigiriam. | Mapear explicitamente os códigos de saída do CHKDSK (0/1/2/3) e só agendar `/f /r` para os que realmente indicam necessidade de reparo. | Baixa |
| 4 | Sem transcript completo (`Start-Transcript`) — o log criado é manual e só grava o que o script explicitamente escreve, não a saída completa da sessão. | Baixo — dificulta diagnosticar erros de sintaxe/ambiente que ocorram fora dos pontos já logados. | Adicionar `Start-Transcript` no início do bloco protegido e `Stop-Transcript` no `finally`. | Baixa |
| 5 | O script não verifica espaço livre em disco antes de iniciar (DISM `RestoreHealth` pode precisar de vários GB livres). | Médio — pode falhar no meio de uma etapa demorada por falta de espaço. | Checar espaço livre mínimo (ex.: 5 GB) na unidade do sistema antes de iniciar o pipeline e avisar o técnico se insuficiente. | Média |
| 6 | Não há verificação de versão do Windows antes de rodar. Em versões muito antigas (Windows 7/2008), `Get-Volume`/`Optimize-Volume` não existem. | Baixo — já degrada graciosamente (a etapa falha e o script continua), mas a mensagem de erro não deixa claro que é uma limitação da versão do Windows. | Adicionar checagem de versão (`[Environment]::OSVersion`) no início, com aviso amigável se for anterior ao Windows 8. | Baixa |
| 7 | O e-mail/identidade do técnico não é validado (qualquer texto é aceito, inclusive vazio). | Muito baixo — é só um campo de relatório. | Nenhuma ação necessária; comportamento intencional (não travar o atendimento por causa de um campo de formulário). | N/A (aceitar como está) |
| 8 | O script não oferece modo silencioso/desatendido (sempre pede os 3 campos via `Read-Host`). | Baixo — impede automação em massa (ex.: via RMM em várias máquinas ao mesmo tempo). | Adicionar parâmetros de linha de comando opcionais (`-Tecnico`, `-Matricula`, `-Cliente`) que, se informados, pulam os prompts interativos. | Média |

**Nenhum destes itens é um bug ativo nem causa travamento** — são melhorias incrementais para cenários específicos (rede ruim, ambiente offline, automação em massa). O núcleo de estabilidade (elevação, leitura assíncrona, blindagem contra erros, saída compatível com qualquer console) já foi corrigido e validado nas versões v5.0 e v6.0.

---

## 4. Requisitos do ambiente

- [x] Windows 10 ou 11 (qualquer edição).
- [x] PowerShell 5.1 (nativo do Windows — não requer instalação de nada).
- [x] Privilégio de Administrador local (o próprio script solicita via UAC).
- [x] Conexão com a internet recomendada para a etapa `DISM RestoreHealth` (mas o script não falha catastroficamente sem ela — a etapa individual reporta falha e o pipeline continua).

---

*Fim do documento — Criado por: Matheus Coelho.*
<!-- FIM DO ARQUIVO — AUTOR: Matheus Coelho — NAO REMOVER -->
