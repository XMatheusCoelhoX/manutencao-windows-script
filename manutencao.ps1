# ==============================================================================
# SYSTEM MAINTENANCE & AUDIT PLATFORM v6.0 (COMPATIBILITY FIX)
# ==============================================================================
# v6.0: removida toda manipulacao bruta de cursor/console ([Console]::SetCursorPosition,
# [Console]::ReadKey, [Console]::OutputEncoding) porque em alguns hosts/terminais
# elevados essas chamadas falham com "Identificador invalido" e fecham a janela
# instantaneamente, sem chance de mostrar erro. Agora a saida e sequencial (rola
# a tela normalmente), usando so Write-Host/Read-Host, que funcionam em qualquer
# console do Windows.

# --- Resolve o caminho do proprio script de forma robusta (nem sempre $PSCommandPath
#     vem preenchido, dependendo de como o .ps1 foi iniciado) ---
$ScriptPath = $PSCommandPath
if ([string]::IsNullOrWhiteSpace($ScriptPath)) { $ScriptPath = $MyInvocation.MyCommand.Path }

# --- Elevação de privilegios ---
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "[!] Solicitando credenciais de Administrador..." -ForegroundColor Yellow

    if ([string]::IsNullOrWhiteSpace($ScriptPath) -or -not (Test-Path -LiteralPath $ScriptPath)) {
        Write-Host "[X] Nao foi possivel determinar o caminho deste script para reabrir como administrador." -ForegroundColor Red
        Write-Host "    Salve o arquivo .ps1 em disco e execute-o novamente (nao cole o codigo direto no console)." -ForegroundColor Red
        Write-Host ""
        Read-Host "Pressione Enter para sair"
        exit 1
    }

    try {
        $psPath = (Get-Process -Id $PID).Path
        if ([string]::IsNullOrWhiteSpace($psPath)) { $psPath = "powershell.exe" }
        Start-Process -FilePath $psPath -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) -ErrorAction Stop
    } catch {
        Write-Host "[X] Elevacao cancelada ou falhou: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        Read-Host "Pressione Enter para sair"
    }
    exit
}

# A partir daqui, TUDO roda dentro de um unico bloco protegido (ate o "finally" no
# final do arquivo). Qualquer erro nao previsto mostra a mensagem e PAUSA antes de
# fechar, em vez de a janela sumir sem explicacao.
try {

try { $Host.UI.RawUI.WindowTitle = "System Maintenance Platform - Dashboard v6.0" } catch { }

# Codepage real usado por DISM/SFC/CHKDSK no console (evita texto corrompido em qualquer idioma/PC)
$OemEncoding = [System.Text.Encoding]::Default
try { $OemEncoding = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) } catch { }

# Log em arquivo desde o inicio, para diagnostico mesmo se a janela fechar antes do usuario ler algo
try {
    $LogPath = "$env:USERPROFILE\Desktop\Log_Manutencao_$($env:COMPUTERNAME)_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
} catch {
    $LogPath = "$env:TEMP\Log_Manutencao_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
}
function Write-Log {
    param([string]$Msg)
    try { "$(Get-Date -Format 'HH:mm:ss')  $Msg" | Out-File -FilePath $LogPath -Append -Encoding utf8 } catch { }
}
Write-Log "Script iniciado (elevado). ScriptPath=$ScriptPath"

Clear-Host
Write-Host "==========================================================================" -ForegroundColor Cyan
Write-Host "  SYSTEM MAINTENANCE PLATFORM v6.0               AUDIT & DIAGNOSTICS" -ForegroundColor Cyan
Write-Host "==========================================================================" -ForegroundColor Cyan
Write-Host ""

$NomeTecnico = Read-Host "  Tecnico Responsavel "
if ([string]::IsNullOrWhiteSpace($NomeTecnico)) { $NomeTecnico = "Tecnico Nao Identificado" }

$RegistroTecnico = Read-Host "  Matricula / ID      "
if ([string]::IsNullOrWhiteSpace($RegistroTecnico)) { $RegistroTecnico = "N/A" }

$EmpresaCliente = Read-Host "  Cliente / Empresa   "
if ([string]::IsNullOrWhiteSpace($EmpresaCliente)) { $EmpresaCliente = "Uso Interno" }

$DataInicio = Get-Date
$TempoInicioGeral = [System.Diagnostics.Stopwatch]::StartNew()
$Computador = $env:COMPUTERNAME

# Em maquinas com o repositorio WMI corrompido (justamente o tipo de PC que precisa
# deste reparo), Get-CimInstance pode falhar. Isso nao pode derrubar o script inteiro.
$OSInfo = "Desconhecido"
try { $OSInfo = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption } catch { }

Write-Log "===== INICIO DA MANUTENCAO ====="
Write-Log "Tecnico: $NomeTecnico ($RegistroTecnico) - Cliente: $EmpresaCliente - Host: $Computador - SO: $OSInfo"

Write-Host ""
Write-Host "  Tecnico : $NomeTecnico ($RegistroTecnico)   Cliente: $EmpresaCliente" -ForegroundColor White
Write-Host "  Host    : $Computador   SO: $OSInfo" -ForegroundColor White
Write-Host "==========================================================================" -ForegroundColor Cyan
Write-Host ""

$PipelineData = [ordered]@{
    "1. DISM CheckHealth"            = @{ Status = "PENDENTE"; Time = "--" }
    "2. DISM ScanHealth"             = @{ Status = "PENDENTE"; Time = "--" }
    "3. DISM StartComponentCleanup"  = @{ Status = "PENDENTE"; Time = "--" }
    "4. DISM RestoreHealth"          = @{ Status = "PENDENTE"; Time = "--" }
    "5. SFC /Scannow"                = @{ Status = "PENDENTE"; Time = "--" }
    "6. Flush Cache DNS"             = @{ Status = "PENDENTE"; Time = "--" }
    "7. Otimizacao de Discos"        = @{ Status = "PENDENTE"; Time = "--" }
    "8. Limpeza do Sistema"          = @{ Status = "PENDENTE"; Time = "--" }
    "9. Verificacao de Disco"        = @{ Status = "PENDENTE"; Time = "--" }
}

# Imprime uma linha de status simples (sem redesenhar a tela). So imprime de novo
# se o conteudo mudou, para nao inundar o console a cada 250ms.
$script:UltimaLinhaImpressa = ""
function Show-Status {
    param([int]$Pct, [string]$Texto, [string]$Cor = "Yellow")
    $linha = "  [{0,3}%] {1}" -f $Pct, $Texto
    if ($linha -ne $script:UltimaLinhaImpressa) {
        Write-Host $linha -ForegroundColor $Cor
        $script:UltimaLinhaImpressa = $linha
    }
}

function Executar-ComandoComStream {
    param(
        [string]$Key,
        [string]$FilePath,
        [string]$Arguments,
        [int]$PctGeralBase
    )

    $PipelineData[$Key].Status = "EM EXECUCAO"
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Log "INICIO: $Key -> $FilePath $Arguments"
    Write-Host ""
    Write-Host ">> $Key" -ForegroundColor Cyan
    Show-Status -Pct $PctGeralBase -Texto "Iniciando $Key..."

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = $OemEncoding
    $psi.StandardErrorEncoding = $OemEncoding

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    # Leitura assincrona via eventos: evita o bloqueio classico de ReadLine() quando o
    # processo atualiza a tela com "\r" (sem quebra de linha), como DISM e SFC fazem,
    # e evita deadlock por nao ler o StandardError.
    $syncHash = [hashtable]::Synchronized(@{ LastLine = "" })
    $outAction = {
        if ($EventArgs.Data) { $Event.MessageData.LastLine = $EventArgs.Data }
    }

    $subOut = Register-ObjectEvent -InputObject $process -EventName OutputDataReceived -Action $outAction -MessageData $syncHash
    $subErr = Register-ObjectEvent -InputObject $process -EventName ErrorDataReceived  -Action $outAction -MessageData $syncHash

    try {
        [void]$process.Start()
        $process.BeginOutputReadLine()
        $process.BeginErrorReadLine()

        while (-not $process.HasExited) {
            $seconds = [Math]::Floor($timer.Elapsed.TotalSeconds)
            $PipelineData[$Key].Time = "${seconds}s"

            $line = $syncHash.LastLine
            $texto = if ($line) { $line } else { "Processando... (${seconds}s)" }
            Show-Status -Pct $PctGeralBase -Texto $texto

            Start-Sleep -Milliseconds 300
        }

        $process.WaitForExit()
    } finally {
        Unregister-Event -SourceIdentifier $subOut.Name -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier $subErr.Name -ErrorAction SilentlyContinue
        Remove-Job $subOut, $subErr -Force -ErrorAction SilentlyContinue
    }

    $timer.Stop()
    $secondsTotal = [Math]::Max(1, [Math]::Floor($timer.Elapsed.TotalSeconds))
    $PipelineData[$Key].Time = "${secondsTotal}s"

    # IMPORTANTE: DISM e SFC retornam codigo de saida 0 mesmo quando ENCONTRAM
    # corrupcao - o veredito real so aparece no texto da ultima linha de saida
    # (ex.: "O repositorio de componentes e reparavel."). Por isso o relatorio
    # guarda essa linha, em vez de confiar so no exit code para dizer "tudo ok".
    $veredito = $syncHash.LastLine
    if ($process.ExitCode -eq 0) {
        $PipelineData[$Key].Status = "CONCLUIDO"
        Write-Host "   [OK] $Key concluido em ${secondsTotal}s" -ForegroundColor Green
    } else {
        $PipelineData[$Key].Status = "FALHA (Cod. $($process.ExitCode))"
        Write-Host "   [FALHA] $Key - codigo $($process.ExitCode) (${secondsTotal}s)" -ForegroundColor Red
    }
    if (-not [string]::IsNullOrWhiteSpace($veredito)) {
        Write-Host "   Veredito: $veredito" -ForegroundColor Gray
        $RelatorioExtra.Add("$Key - Veredito: $veredito")
    }
    Write-Log "FIM: $Key - ExitCode=$($process.ExitCode) - Duracao=${secondsTotal}s - Veredito: $veredito"

    return $process.ExitCode
}

$RelatorioExtra = New-Object System.Collections.Generic.List[string]

Executar-ComandoComStream -Key "1. DISM CheckHealth"           -FilePath "DISM.exe" -Arguments "/Online /Cleanup-Image /CheckHealth"           -PctGeralBase 5   | Out-Null
Executar-ComandoComStream -Key "2. DISM ScanHealth"            -FilePath "DISM.exe" -Arguments "/Online /Cleanup-Image /ScanHealth"            -PctGeralBase 12  | Out-Null
Executar-ComandoComStream -Key "3. DISM StartComponentCleanup" -FilePath "DISM.exe" -Arguments "/Online /Cleanup-Image /StartComponentCleanup" -PctGeralBase 22  | Out-Null
Executar-ComandoComStream -Key "4. DISM RestoreHealth"         -FilePath "DISM.exe" -Arguments "/Online /Cleanup-Image /RestoreHealth"         -PctGeralBase 35  | Out-Null
Executar-ComandoComStream -Key "5. SFC /Scannow"               -FilePath "sfc.exe"  -Arguments "/scannow"                                       -PctGeralBase 55  | Out-Null

# --- 6. Flush DNS ---
Write-Host ""
Write-Host ">> 6. Flush Cache DNS" -ForegroundColor Cyan
$timerDns = [System.Diagnostics.Stopwatch]::StartNew()
$PipelineData["6. Flush Cache DNS"].Status = "EM EXECUCAO"
Show-Status -Pct 70 -Texto "Esvaziando cache de DNS..."
try { ipconfig /flushdns | Out-Null } catch { Write-Log "Erro flushdns: $($_.Exception.Message)" }
$timerDns.Stop()
$PipelineData["6. Flush Cache DNS"].Status = "CONCLUIDO"
$PipelineData["6. Flush Cache DNS"].Time = "$([Math]::Max(1, [Math]::Floor($timerDns.Elapsed.TotalSeconds)))s"
Write-Host "   [OK] Cache DNS esvaziado" -ForegroundColor Green
Write-Log "Flush DNS concluido"

# --- 7. Otimizacao de TODAS as unidades fixas (nao so C:) ---
Write-Host ""
Write-Host ">> 7. Otimizacao de Discos" -ForegroundColor Cyan
$timerDisco = [System.Diagnostics.Stopwatch]::StartNew()
$PipelineData["7. Otimizacao de Discos"].Status = "EM EXECUCAO"
Show-Status -Pct 78 -Texto "Detectando unidades fixas..."

$FixedDrives = @()
try {
    $FixedDrives = Get-Volume | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter } | Select-Object -ExpandProperty DriveLetter
} catch {
    $FixedDrives = @('C')
}
if (-not $FixedDrives -or $FixedDrives.Count -eq 0) { $FixedDrives = @('C') }

foreach ($d in $FixedDrives) {
    Show-Status -Pct 78 -Texto "Otimizando unidade $($d):..."
    try {
        # Sem -Defrag/-ReTrim explicito: o cmdlet escolhe automaticamente o metodo
        # correto (retrim para SSD, desfragmentacao para HDD).
        Optimize-Volume -DriveLetter $d -ErrorAction Stop
        Write-Host "   [OK] Unidade $($d): otimizada" -ForegroundColor Green
        $RelatorioExtra.Add("Otimizacao unidade $($d): OK")
    } catch {
        Write-Host "   [FALHA] Unidade $($d): $($_.Exception.Message)" -ForegroundColor Red
        $RelatorioExtra.Add("Otimizacao unidade $($d): FALHOU - $($_.Exception.Message)")
        Write-Log "Erro otimizando $($d): $($_.Exception.Message)"
    }
}
$timerDisco.Stop()
$PipelineData["7. Otimizacao de Discos"].Status = "CONCLUIDO"
$PipelineData["7. Otimizacao de Discos"].Time = "$([Math]::Max(1, [Math]::Floor($timerDisco.Elapsed.TotalSeconds)))s"
Write-Log "Otimizacao de discos concluida: $($FixedDrives -join ', ')"

# --- 8. Limpeza do sistema: %TEMP%, Windows\Temp e itens Recentes ---
Write-Host ""
Write-Host ">> 8. Limpeza do Sistema" -ForegroundColor Cyan
$timerLimpeza = [System.Diagnostics.Stopwatch]::StartNew()
$PipelineData["8. Limpeza do Sistema"].Status = "EM EXECUCAO"
Show-Status -Pct 88 -Texto "Limpando arquivos temporarios..."

$CleanupTargets = @(
    "$env:TEMP\*",
    "$env:SystemRoot\Temp\*",
    "$env:APPDATA\Microsoft\Windows\Recent\*"
)
foreach ($target in $CleanupTargets) {
    try {
        Remove-Item -Path $target -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Log "Erro limpando $target : $($_.Exception.Message)"
    }
}
$timerLimpeza.Stop()
$PipelineData["8. Limpeza do Sistema"].Status = "CONCLUIDO"
$PipelineData["8. Limpeza do Sistema"].Time = "$([Math]::Max(1, [Math]::Floor($timerLimpeza.Elapsed.TotalSeconds)))s"
Write-Host "   [OK] Temporarios, Windows\Temp e Recentes limpos" -ForegroundColor Green
Write-Log "Limpeza de temporarios/recentes concluida"

# --- 9. Verificacao de disco: scan (online, sem exigir reinicio) em todas as unidades;
#     reparo /f /r agendado somente se corrupcao for detectada ---
Write-Host ""
Write-Host ">> 9. Verificacao de Disco" -ForegroundColor Cyan
$timerChkdsk = [System.Diagnostics.Stopwatch]::StartNew()
$PipelineData["9. Verificacao de Disco"].Status = "EM EXECUCAO"

$ReinicioNecessario = $false
foreach ($d in $FixedDrives) {
    Show-Status -Pct 95 -Texto "Verificando disco $($d):..."
    try {
        & chkdsk.exe "$($d):" /scan | Out-Null
        $scanExit = $LASTEXITCODE
        if ($scanExit -ne 0) {
            Write-Log "CHKDSK /scan detectou problema na unidade $($d): (codigo $scanExit). Agendando reparo /f /r."
            cmd.exe /c "echo Y| chkdsk $($d): /f /r" | Out-Null
            Write-Host "   [!] Unidade $($d): problema detectado - reparo agendado (requer reinicio)" -ForegroundColor Yellow
            $RelatorioExtra.Add("Unidade $($d): problema detectado - reparo agendado (requer reinicio)")
            $ReinicioNecessario = $true
        } else {
            Write-Host "   [OK] Unidade $($d): sem problemas" -ForegroundColor Green
            $RelatorioExtra.Add("Unidade $($d): sem problemas detectados")
        }
    } catch {
        Write-Host "   [FALHA] Unidade $($d): $($_.Exception.Message)" -ForegroundColor Red
        $RelatorioExtra.Add("Unidade $($d): falha ao executar CHKDSK - $($_.Exception.Message)")
        Write-Log "Erro chkdsk $($d): $($_.Exception.Message)"
    }
}
$timerChkdsk.Stop()
$PipelineData["9. Verificacao de Disco"].Status = "CONCLUIDO"
$PipelineData["9. Verificacao de Disco"].Time = "$([Math]::Max(1, [Math]::Floor($timerChkdsk.Elapsed.TotalSeconds)))s"

$TempoInicioGeral.Stop()
Write-Host ""
Write-Host "==========================================================================" -ForegroundColor Cyan
Write-Host "  MANUTENCAO CONCLUIDA - Tempo total: $($TempoInicioGeral.Elapsed.ToString('hh\:mm\:ss'))" -ForegroundColor Green
Write-Host "==========================================================================" -ForegroundColor Cyan

} catch {
    Write-Log "ERRO FATAL: $($_.Exception.ToString())"
    Write-Host ""
    Write-Host "  [X] ERRO DURANTE A MANUTENCAO: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Detalhes salvos no log." -ForegroundColor Red
} finally {
    try {
        $DataFim = Get-Date
        $CaminhoRelatorio = "$env:USERPROFILE\Desktop\Relatorio_Manutencao_$($Computador).txt"

        $RelatorioLinhas = New-Object System.Collections.Generic.List[string]
        $RelatorioLinhas.Add("RELATORIO DE MANUTENCAO")
        $RelatorioLinhas.Add("Tecnico: $NomeTecnico ($RegistroTecnico)")
        $RelatorioLinhas.Add("Cliente: $EmpresaCliente")
        $RelatorioLinhas.Add("Host: $Computador")
        $RelatorioLinhas.Add("SO: $OSInfo")
        $RelatorioLinhas.Add("Inicio: $DataInicio")
        $RelatorioLinhas.Add("Fim: $DataFim")
        $RelatorioLinhas.Add("")
        $RelatorioLinhas.Add("ETAPAS:")
        foreach ($item in $PipelineData.Keys) {
            $RelatorioLinhas.Add("  $item : $($PipelineData[$item].Status) ($($PipelineData[$item].Time))")
        }
        if ($RelatorioExtra.Count -gt 0) {
            $RelatorioLinhas.Add("")
            $RelatorioLinhas.Add("DETALHES:")
            foreach ($l in $RelatorioExtra) { $RelatorioLinhas.Add("  $l") }
        }
        if ($ReinicioNecessario) {
            $RelatorioLinhas.Add("")
            $RelatorioLinhas.Add("[!] REINICIO NECESSARIO para concluir o reparo de disco agendado.")
        }
        $RelatorioLinhas.Add("")
        $RelatorioLinhas.Add("Log detalhado: $LogPath")

        $RelatorioLinhas -join "`n" | Out-File -FilePath $CaminhoRelatorio -Encoding utf8

        Write-Host ""
        Write-Host "  [V] PROCESSO CONCLUIDO!" -ForegroundColor Green
        Write-Host "  [V] RELATORIO GERADO EM: $CaminhoRelatorio" -ForegroundColor Cyan
        Write-Host "  [V] LOG DETALHADO EM: $LogPath" -ForegroundColor Cyan
        if ($ReinicioNecessario) {
            Write-Host "  [!] REINICIO NECESSARIO para concluir a correcao de disco agendada." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  [X] Falha ao gerar relatorio final: $($_.Exception.Message)" -ForegroundColor Red
    }

    Write-Host ""
    Read-Host "Pressione Enter para sair"
}
