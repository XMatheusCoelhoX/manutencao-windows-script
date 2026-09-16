<!-- AUTOR ORIGINAL: Matheus Coelho — NAO REMOVER ESTA ATRIBUICAO -->

# System Maintenance Platform — `manutencao.ps1`

**Criado por: Matheus Coelho**
> Esta atribuição de autoria faz parte da documentação oficial deste projeto. Ela deve ser mantida em qualquer cópia, fork ou redistribuição deste material.

---

## 1. O que é

`manutencao.ps1` é um script de PowerShell para diagnóstico e reparo automatizado de PCs com Windows. Ele foi criado para uso por técnicos de suporte/manutenção: roda uma sequência de rotinas nativas do Windows (DISM, SFC, CHKDSK, otimização de disco, limpeza de temporários) em um único fluxo, mostra o progresso em tempo real no console e, ao final, gera um relatório e um log em arquivo para o técnico anexar ao atendimento.

- **Linguagem:** PowerShell (compatível com Windows PowerShell 5.1, que vem de fábrica em todo Windows 10/11).
- **Escopo:** requer privilégios de Administrador (o próprio script se reabre elevado via UAC).
- **Sistemas suportados:** Windows 10 e Windows 11 (qualquer edição). Funciona em Windows 8/8.1 com pequenas degradações graciosas (ver seção de limitações). **Não** foi projetado para Windows 7 ou anterior (`Get-Volume`/`Optimize-Volume` não existem nessas versões).

---

## 2. Como usar

1. Copie `manutencao.ps1` para o PC a ser atendido (pen-drive, rede, etc.).
2. Clique com o botão direito no arquivo → **Executar com o PowerShell**.
   - Se o Windows pedir para escolher um programa em vez de rodar diretamente, abra um PowerShell e rode: `powershell -ExecutionPolicy Bypass -File "caminho\para\manutencao.ps1"`.
3. Aceite o prompt do UAC (Controle de Conta de Usuário) — o script relança a si mesmo como Administrador automaticamente.
4. Preencha os 3 campos pedidos: **Técnico Responsável**, **Matrícula/ID**, **Cliente/Empresa** (todos opcionais — Enter em branco usa um valor padrão).
5. Aguarde a execução completa das 9 etapas (pode levar de poucos minutos a mais de 1 hora, dependendo do estado do disco e da necessidade de baixar arquivos do Windows Update na etapa de `RestoreHealth`).
6. Ao final, dois arquivos são criados na **Área de Trabalho** do usuário atual:
   - `Relatorio_Manutencao_<NOME-DO-PC>.txt` — resumo para o cliente/atendimento.
   - `Log_Manutencao_<NOME-DO-PC>_<data-hora>.txt` — log técnico detalhado, linha a linha, para diagnóstico caso algo dê errado.
7. Se o script indicar **"REINÍCIO NECESSÁRIO"**, reinicie o PC para que o CHKDSK conclua o reparo agendado.

---

## 3. Arquitetura e como funciona internamente

### 3.1 Auto-elevação (UAC)
O script verifica se já está rodando como Administrador (`WindowsPrincipal.IsInRole`). Se não estiver, ele:
1. Resolve o próprio caminho (`$PSCommandPath`, com fallback para `$MyInvocation.MyCommand.Path`).
2. Relança a si mesmo via `Start-Process -Verb RunAs`, usando uma **lista de argumentos** (não uma string concatenada manualmente) — isso evita bugs de escaping quando o caminho do arquivo tem espaços ou acentos (ex.: pastas como "Utilitários" ou "Manutenção").
3. Se o usuário cancelar o UAC, ou o caminho do script não puder ser determinado, mostra uma mensagem de erro clara e pausa antes de fechar (em vez de a janela simplesmente sumir).

### 3.2 Execução dos comandos externos (DISM/SFC)
Cada etapa que chama um `.exe` externo (DISM, SFC) usa `System.Diagnostics.Process` com leitura **assíncrona** da saída (`OutputDataReceived`/`ErrorDataReceived` + `BeginOutputReadLine`/`BeginErrorReadLine`), em vez de `StandardOutput.ReadLine()` bloqueante.

**Por quê isso importa:** DISM e SFC atualizam a porcentagem de progresso usando retorno de carro (`\r`), não quebra de linha (`\n`). Uma leitura bloqueante por linha (`ReadLine()`) trava esperando um `\n` que só chega minutos depois — foi essa a causa raiz do "travamento" que motivou a reescrita do script (ver seção 6, Histórico de Versões). A leitura assíncrona por eventos nunca bloqueia a thread principal, então o cronômetro e o status continuam atualizando mesmo durante trechos longos sem saída nova.

Também é lido o `StandardError` (não só o `StandardOutput`) — isso evita um deadlock clássico do .NET: se o processo filho escrever no buffer de erro e ninguém o ler, o buffer enche (~4 KB) e o processo trava esperando espaço para escrever.

A saída dos processos é decodificada usando o **codepage OEM real do console do Windows** (detectado via `CultureInfo.CurrentCulture.TextInfo.OEMCodePage`), não UTF-8 fixo — isso evita texto corrompido/ilegível em qualquer idioma de Windows (PT-BR, EN-US, etc.), já que DISM/SFC escrevem no codepage nativo do console, não em UTF-8.

### 3.3 Interface (saída no console)
Até a v5.0, o script usava um "dashboard" que reposicionava o cursor (`[Console]::SetCursorPosition`) para redesenhar a tela inteira a cada atualização, como um painel ao vivo. **Isso foi removido na v6.0**: em certos hosts de console (terminais elevados, Windows Terminal em algumas configurações, sessões remotas/RMM), essa chamada falha com `"Identificador inválido"` e **fecha a janela instantaneamente**, sem chance de mostrar qualquer erro.

A v6.0 usa saída **sequencial** (rola a tela normalmente, como qualquer script de linha de comando), só com `Write-Host`/`Read-Host` — APIs do host do PowerShell, muito mais compatíveis entre diferentes terminais/consoles do Windows. Para não inundar a tela, a função `Show-Status` só imprime uma nova linha quando o texto realmente muda.

### 3.4 Blindagem contra falhas silenciosas
Todo o corpo do script (exceto o bloco de elevação, que tem seu próprio tratamento) roda dentro de um único `try { ... } catch { ... } finally { ... }`. Qualquer erro não previsto — WMI corrompido, política de execução restritiva, permissão negada, etc. — é:
1. Registrado no arquivo de log.
2. Mostrado na tela em vermelho.
3. Seguido de uma pausa (`Read-Host`) antes do script terminar, para o técnico sempre conseguir ler o que aconteceu.

O relatório final também é gerado dentro do próprio `finally`, então mesmo em caso de erro no meio do processo, um relatório parcial (com o que já foi concluído) ainda é salvo.

---

## 4. As 9 etapas do pipeline

| # | Etapa | Comando | Objetivo |
|---|-------|---------|----------|
| 1 | DISM CheckHealth | `DISM /Online /Cleanup-Image /CheckHealth` | Verifica rapidamente (sem varredura completa) se há uma marcação de corrupção conhecida no componente store. |
| 2 | DISM ScanHealth | `DISM /Online /Cleanup-Image /ScanHealth` | Faz uma varredura completa do componente store em busca de corrupção (mais lento, mais confiável que o CheckHealth). |
| 3 | DISM StartComponentCleanup | `DISM /Online /Cleanup-Image /StartComponentCleanup` | Remove versões antigas/superadas de componentes do Windows Update, liberando espaço e preparando o componente store para o reparo. Executado **antes** do RestoreHealth por recomendação do próprio fluxo de reparo da Microsoft. |
| 4 | DISM RestoreHealth | `DISM /Online /Cleanup-Image /RestoreHealth` | Repara a corrupção encontrada, baixando arquivos limpos do Windows Update (ou de uma fonte alternativa, se configurada). Etapa mais demorada — pode levar dezenas de minutos dependendo da internet. |
| 5 | SFC /Scannow | `SFC /scannow` | Verifica a integridade dos arquivos de sistema e substitui os corrompidos, usando o componente store (já reparado na etapa anterior) como fonte. |
| 6 | Flush Cache DNS | `ipconfig /flushdns` | Limpa o cache de resolução de nomes, resolvendo problemas comuns de navegação/conectividade após mudanças de rede. |
| 7 | Otimização de Discos | `Optimize-Volume` (para **todas** as unidades fixas detectadas) | Desfragmenta HDDs ou faz retrim de SSDs — o cmdlet escolhe automaticamente o método certo por tipo de mídia (não força um método fixo). |
| 8 | Limpeza do Sistema | `Remove-Item` em `%TEMP%`, `C:\Windows\Temp` e a pasta "Recentes" | Libera espaço em disco removendo arquivos temporários e o histórico de itens recentes. Arquivos em uso são ignorados silenciosamente (comportamento esperado). |
| 9 | Verificação de Disco | `chkdsk /scan` em todas as unidades; `chkdsk /f /r` **somente se** corrupção for detectada | Verifica a integridade do sistema de arquivos sem exigir reinício (`/scan` é uma varredura online). Só agenda o reparo completo (que exige reinício) se um problema real for encontrado — evita forçar reinicializações desnecessárias a cada execução. |

### Sobre os códigos de saída do DISM/SFC (limitação conhecida do Windows, não do script)
DISM e SFC frequentemente retornam **código de saída 0 mesmo quando encontram corrupção** — o veredito real só existe no texto da última linha de saída (ex.: *"O repositório de componentes é reparável."*). Por isso, a partir desta versão, o script captura essa última linha de cada etapa DISM/SFC e a grava no relatório como **"Veredito"**, para o técnico sempre conferir o texto real, não só o rótulo "CONCLUÍDO"/"FALHA".

---

## 5. Saídas geradas

| Arquivo | Local | Conteúdo |
|---|---|---|
| `Relatorio_Manutencao_<PC>.txt` | Área de Trabalho | Resumo: técnico, cliente, host, SO, horários, status de cada etapa, veredito de cada verificação, unidades com problema, aviso de reinício necessário. |
| `Log_Manutencao_<PC>_<timestamp>.txt` | Área de Trabalho | Log cronológico linha a linha (criado desde o início da execução elevada) — usado para diagnosticar o que aconteceu caso a janela feche antes do usuário conseguir ler algo na tela. |

---

## 6. Histórico de versões (resumo técnico)

- **v4.0** — Versão original. Dashboard com redesenho de tela via `[Console]::SetCursorPosition`. Leitura de saída bloqueante (`StandardOutput.ReadLine()`). Limpeza só de `%TEMP%`. Otimização e CHKDSK só na unidade `C:`. CHKDSK `/f /r` agendado incondicionalmente a cada execução.
- **v5.0** — Corrigido o travamento causado pela leitura bloqueante (trocada por leitura assíncrona por eventos). Adicionada etapa `DISM StartComponentCleanup`. Otimização e verificação de disco passaram a cobrir todas as unidades fixas. Limpeza passou a incluir `C:\Windows\Temp` e "Recentes". CHKDSK passou a só agendar reparo se corrupção for detectada. Adicionado log em arquivo e blindagem parcial contra erros (try/catch em torno do pipeline).
- **v6.0** *(atual)* — Removida **toda** manipulação bruta de `[Console]` (`SetCursorPosition`, `ReadKey`, `OutputEncoding`), pois falhava com `"Identificador inválido"` em certos hosts elevados e fechava a janela instantaneamente sem mostrar erro. Interface trocada para saída sequencial simples. Blindagem contra erros estendida para o script inteiro (não só o pipeline). Resolução do caminho do script tornada mais robusta para o relançamento elevado. Adicionada captura do "veredito" textual de DISM/SFC no relatório (em vez de confiar só no código de saída).

---

## 7. Limitações conhecidas / gaps em aberto

Ver [`CHECKLIST.md`](CHECKLIST.md) para a lista completa e o plano de correção sugerido para cada item.

---

*Fim do documento — Criado por: Matheus Coelho.*
<!-- FIM DO ARQUIVO — AUTOR: Matheus Coelho — NAO REMOVER -->
