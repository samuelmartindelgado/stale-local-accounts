#Requires -Version 5.1
<#
.SYNOPSIS
    Revisión de solo lectura de las cuentas y grupos locales de Windows.

.DESCRIPTION
    Comprueba cuentas habilitadas sin contraseña, cuentas integradas
    (Administrador e Invitado) habilitadas, cuentas olvidadas, contraseñas de
    administrador que nunca caducan o llevan más de un año sin cambiar, y
    miembros sobrantes o huérfanos en el grupo Administradores.

    No lee ni muestra contraseñas. No cambia nada del equipo: las soluciones se
    muestran como comandos de ejemplo y nunca se ejecutan.

.PARAMETER StaleDays
    Días sin iniciar sesión a partir de los cuales se avisa. Por defecto 90.

.PARAMETER OutputPath
    Carpeta donde escribir Test-LocalAccounts.json, report.html y accounts.csv.

.EXAMPLE
    .\Test-LocalAccounts.ps1

.EXAMPLE
    .\Test-LocalAccounts.ps1 -StaleDays 60 -OutputPath .\salida\equipo01

.NOTES
    Código de salida: 0 todo OK, 1 algún Aviso, 2 alguna Alta.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateRange(1, 3650)]
    [int]$StaleDays = 90,

    [Parameter(Position = 1)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'lib/StaleLocalAccounts.psm1'
Import-Module -Name $modulePath -Force -ErrorAction Stop

function ConvertTo-DateText {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        $Value
    )

    if ($null -eq $Value) {
        return ''
    }

    if ($Value -is [datetime]) {
        return $Value.ToString('yyyy-MM-dd HH:mm')
    }

    if ($Value -is [datetimeoffset]) {
        return $Value.LocalDateTime.ToString('yyyy-MM-dd HH:mm')
    }

    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse([string]$Value, [ref]$parsed)) {
        return $parsed.ToString('yyyy-MM-dd HH:mm')
    }

    return [string]$Value
}

function Format-Sino {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        $Value
    )

    if ($Value -eq $true) {
        return 'Sí'
    }

    return 'No'
}

function ConvertTo-CsvSafe {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        $Value
    )

    if ($null -eq $Value) {
        return ''
    }

    $text = [string]$Value
    if ($text -match '^[=+\-@\t\r]') {
        return ("'{0}" -f $text)
    }

    return $text
}

function ConvertTo-HtmlText {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        $Value
    )

    if ($null -eq $Value) {
        return ''
    }

    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-EstadoClass {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Estado
    )

    switch ($Estado) {
        'Alta' { return 'alta' }
        'Aviso' { return 'aviso' }
        default { return 'ok' }
    }
}

function Get-EstadoColor {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Estado
    )

    switch ($Estado) {
        'Alta' { return 'Red' }
        'Aviso' { return 'Yellow' }
        default { return 'Green' }
    }
}

function New-FindingsHtml {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [object[]]$Findings
    )

    $builder = New-Object System.Text.StringBuilder
    foreach ($finding in $Findings) {
        $class = Get-EstadoClass -Estado $finding.Estado
        $solution = ''
        if (-not [string]::IsNullOrWhiteSpace($finding.Solucion)) {
            $solution = ('<code>{0}</code>' -f (ConvertTo-HtmlText -Value $finding.Solucion))
        }
        [void]$builder.AppendLine(('<tr class="{0}">' -f $class))
        [void]$builder.AppendLine(('  <td>{0}</td>' -f (ConvertTo-HtmlText -Value $finding.Comprobacion)))
        [void]$builder.AppendLine(('  <td><span class="badge {0}">{1}</span></td>' -f $class, (ConvertTo-HtmlText -Value $finding.Estado)))
        [void]$builder.AppendLine(('  <td>{0}</td>' -f (ConvertTo-HtmlText -Value $finding.Detalle)))
        [void]$builder.AppendLine(('  <td>{0}</td>' -f (ConvertTo-HtmlText -Value $finding.Valor)))
        [void]$builder.AppendLine(('  <td>{0}</td>' -f (ConvertTo-HtmlText -Value $finding.Recomendado)))
        [void]$builder.AppendLine(('  <td>{0}</td>' -f $solution))
        [void]$builder.AppendLine('</tr>')
    }

    return $builder.ToString()
}

function New-AccountsHtml {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [object[]]$Accounts
    )

    $builder = New-Object System.Text.StringBuilder
    foreach ($account in $Accounts) {
        $daysWithoutLogon = ''
        if ($null -ne $account.DiasSinUso) {
            $daysWithoutLogon = [string]$account.DiasSinUso
        }
        $daysPassword = ''
        if ($null -ne $account.DiasPassword) {
            $daysPassword = [string]$account.DiasPassword
        }

        [void]$builder.AppendLine('<tr>')
        [void]$builder.AppendLine(('  <td>{0}</td>' -f (ConvertTo-HtmlText -Value $account.Nombre)))
        [void]$builder.AppendLine(('  <td class="sid">{0}</td>' -f (ConvertTo-HtmlText -Value $account.SID)))
        [void]$builder.AppendLine(('  <td>{0}</td>' -f (Format-Sino -Value $account.Habilitada)))
        [void]$builder.AppendLine(('  <td>{0}</td>' -f (ConvertTo-HtmlText -Value (ConvertTo-DateText -Value $account.UltimoInicio))))
        [void]$builder.AppendLine(('  <td>{0}</td>' -f $daysWithoutLogon))
        [void]$builder.AppendLine(('  <td>{0}</td>' -f (Format-Sino -Value $account.PasswordNuncaCaduca)))
        [void]$builder.AppendLine(('  <td>{0}</td>' -f (Format-Sino -Value $account.PasswordNoRequerida)))
        [void]$builder.AppendLine(('  <td>{0}</td>' -f (ConvertTo-HtmlText -Value (ConvertTo-DateText -Value $account.UltimoCambioPassword))))
        [void]$builder.AppendLine(('  <td>{0}</td>' -f $daysPassword))
        [void]$builder.AppendLine(('  <td>{0}</td>' -f (Format-Sino -Value $account.EsAdmin)))
        [void]$builder.AppendLine('</tr>')
    }

    return $builder.ToString()
}

function New-HtmlDocument {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [object[]]$Findings,
        [Parameter(Position = 1)]
        [object[]]$Accounts,
        [Parameter(Position = 2)]
        [string[]]$Notas
    )

    $okCount = @($Findings | Where-Object { $_.Estado -eq 'OK' }).Count
    $avisoCount = @($Findings | Where-Object { $_.Estado -eq 'Aviso' }).Count
    $altaCount = @($Findings | Where-Object { $_.Estado -eq 'Alta' }).Count

    $notesHtml = ''
    if ($Notas.Count -gt 0) {
        $notesBuilder = New-Object System.Text.StringBuilder
        [void]$notesBuilder.AppendLine('<section class="card">')
        [void]$notesBuilder.AppendLine('<h2>Notas de la revisión</h2>')
        [void]$notesBuilder.AppendLine('<ul>')
        foreach ($note in $Notas) {
            [void]$notesBuilder.AppendLine(('  <li>{0}</li>' -f (ConvertTo-HtmlText -Value $note)))
        }
        [void]$notesBuilder.AppendLine('</ul>')
        [void]$notesBuilder.AppendLine('</section>')
        $notesHtml = $notesBuilder.ToString()
    }

    $css = @'
:root{--bg:#f5f7fa;--fg:#1b2430;--muted:#5a6675;--card:#fff;--border:#dce3eb;--code:#eef2f7;--ok:#1c7a3e;--okbg:#e6f5ea;--aviso:#8a5a00;--avisobg:#fff3d1;--alta:#a51b1b;--altabg:#fde7e7}
@media (prefers-color-scheme: dark){:root{--bg:#0e141b;--fg:#e5ecf3;--muted:#9aa8b6;--card:#161e27;--border:#2a3644;--code:#1e2833;--ok:#65d68f;--okbg:#14301f;--aviso:#f2c44d;--avisobg:#35290c;--alta:#ff9191;--altabg:#3b1616}}
*{box-sizing:border-box}
body{margin:0;padding:32px 20px;background:var(--bg);color:var(--fg);font-family:"Segoe UI",system-ui,-apple-system,sans-serif;line-height:1.5}
main{max-width:1180px;margin:0 auto}
h1{font-size:1.7rem;margin:0 0 4px}
h2{font-size:1.1rem;margin:0 0 12px}
.sub{color:var(--muted);margin:0 0 20px}
.card{background:var(--card);border:1px solid var(--border);border-radius:10px;padding:18px 20px;margin-bottom:20px;overflow-x:auto}
.counts{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:20px}
.count{background:var(--card);border:1px solid var(--border);border-radius:10px;padding:12px 18px;min-width:120px}
.count strong{display:block;font-size:1.6rem;line-height:1.2}
.count.ok strong{color:var(--ok)}
.count.aviso strong{color:var(--aviso)}
.count.alta strong{color:var(--alta)}
table{border-collapse:collapse;width:100%;font-size:.92rem}
th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--border);vertical-align:top}
th{font-size:.78rem;text-transform:uppercase;letter-spacing:.03em;color:var(--muted)}
tbody tr:last-child td{border-bottom:0}
tr.alta td{background:var(--altabg)}
tr.aviso td{background:var(--avisobg)}
tr.ok td{background:transparent}
.badge{display:inline-block;padding:2px 9px;border-radius:999px;font-size:.78rem;font-weight:600;border:1px solid currentColor}
.badge.ok{color:var(--ok);background:var(--okbg)}
.badge.aviso{color:var(--aviso);background:var(--avisobg)}
.badge.alta{color:var(--alta);background:var(--altabg)}
code{background:var(--code);padding:1px 6px;border-radius:5px;font-family:Consolas,"Cascadia Mono",monospace;font-size:.85rem;word-break:break-word}
ul{margin:0;padding-left:22px}
.sid{font-family:Consolas,"Cascadia Mono",monospace;font-size:.82rem;white-space:nowrap}
footer{color:var(--muted);font-size:.85rem;text-align:center;margin-top:28px}
'@

    $safeComputer = ConvertTo-HtmlText -Value $env:COMPUTERNAME
    $safeDate = ConvertTo-HtmlText -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm'))
    $safeStaleDays = ConvertTo-HtmlText -Value ([string]$StaleDays)
    $findingsRows = New-FindingsHtml -Findings $Findings
    $accountsRows = New-AccountsHtml -Accounts $Accounts

    $document = @"
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Cuentas locales - $safeComputer</title>
<style>
$css
</style>
</head>
<body>
<main>
<h1>Revisión de cuentas locales</h1>
<p class="sub">Equipo <strong>$safeComputer</strong> · $safeDate · límite sin uso: $safeStaleDays días · solo lectura, no se ha cambiado nada</p>

<section class="counts">
  <div class="count ok"><strong>$okCount</strong>OK</div>
  <div class="count aviso"><strong>$avisoCount</strong>Aviso</div>
  <div class="count alta"><strong>$altaCount</strong>Alta</div>
</section>

$notesHtml
<section class="card">
<h2>Hallazgos</h2>
<table>
<thead><tr><th>Comprobación</th><th>Estado</th><th>Detalle</th><th>Valor</th><th>Recomendado</th><th>Solución (ejemplo)</th></tr></thead>
<tbody>
$findingsRows</tbody>
</table>
</section>

<section class="card">
<h2>Cuentas locales</h2>
<table>
<thead><tr><th>Nombre</th><th>SID</th><th>Habilitada</th><th>Último inicio</th><th>Días sin uso</th><th>Contraseña nunca caduca</th><th>Contraseña no requerida</th><th>Último cambio</th><th>Días</th><th>Administrador</th></tr></thead>
<tbody>
$accountsRows</tbody>
</table>
</section>

<footer>Generado por Test-LocalAccounts.ps1 · Solo revisa cuentas locales de este equipo, no cuentas de dominio.</footer>
</main>
</body>
</html>
"@

    return $document
}

# ---------------------------------------------------------------------------
# Lectura (solo lectura) y análisis
# ---------------------------------------------------------------------------

$notas = New-Object 'System.Collections.Generic.List[string]'
$accounts = @()
$adminMembers = @()
$readOk = $true
$adminMembersRef = [ref]$null

try {
    $accounts = @(Get-LocalAccountReport -AdminMemberResult $adminMembersRef -WarningVariable avisosLectura -WarningAction SilentlyContinue)
    $adminMembers = @($adminMembersRef.Value)
}
catch {
    $readOk = $false
    $notas.Add(('No se pudieron leer las cuentas locales: {0}' -f $_.Exception.Message))
}

if ($null -ne $avisosLectura) {
    foreach ($warningRecord in @($avisosLectura)) {
        $messageProperty = $warningRecord.PSObject.Properties['Message']
        if ($null -ne $messageProperty -and -not [string]::IsNullOrWhiteSpace([string]$messageProperty.Value)) {
            $notas.Add([string]$messageProperty.Value)
        }
        else {
            $notas.Add([string]$warningRecord)
        }
    }
}

$findings = @()
if ($readOk) {
    $findings = @(Get-AccountFindings -Accounts $accounts -AdminMembers $adminMembers -StaleDays $StaleDays)
}

$okCount = @($findings | Where-Object { $_.Estado -eq 'OK' }).Count
$avisoCount = @($findings | Where-Object { $_.Estado -eq 'Aviso' }).Count
$altaCount = @($findings | Where-Object { $_.Estado -eq 'Alta' }).Count

$exitCode = 0
if (-not $readOk) {
    $exitCode = 1
}
elseif ($altaCount -gt 0) {
    $exitCode = 2
}
elseif ($avisoCount -gt 0) {
    $exitCode = 1
}

# ---------------------------------------------------------------------------
# Ficheros de salida opcionales
# ---------------------------------------------------------------------------

$writtenFiles = New-Object 'System.Collections.Generic.List[string]'

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    if (-not (Test-Path -LiteralPath $OutputPath -PathType Container)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }
    $resolvedOutput = (Resolve-Path -LiteralPath $OutputPath).Path

    $jsonAccounts = @(
        foreach ($account in $accounts) {
            [pscustomobject]@{
                Nombre               = $account.Nombre
                SID                  = $account.SID
                Habilitada           = $account.Habilitada
                UltimoInicio         = ConvertTo-DateText -Value $account.UltimoInicio
                DiasSinUso           = $account.DiasSinUso
                PasswordNuncaCaduca  = $account.PasswordNuncaCaduca
                PasswordNoRequerida  = $account.PasswordNoRequerida
                UltimoCambioPassword = ConvertTo-DateText -Value $account.UltimoCambioPassword
                DiasPassword         = $account.DiasPassword
                EsAdmin              = $account.EsAdmin
            }
        }
    )

    $jsonFindings = @(
        foreach ($finding in $findings) {
            [pscustomobject]@{
                Comprobacion = $finding.Comprobacion
                Estado       = $finding.Estado
                Detalle      = $finding.Detalle
                Valor        = $finding.Valor
                Recomendado  = $finding.Recomendado
                Solucion     = $finding.Solucion
            }
        }
    )

    $reportObject = [pscustomobject]@{
        Equipo           = $env:COMPUTERNAME
        Fecha            = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        LimiteDiasSinUso = $StaleDays
        SoloLectura      = $true
        Notas            = @($notas)
        Resumen          = [pscustomobject]@{
            OK    = $okCount
            Aviso = $avisoCount
            Alta  = $altaCount
        }
        Hallazgos        = $jsonFindings
        Cuentas          = $jsonAccounts
    }

    $jsonPath = Join-Path -Path $resolvedOutput -ChildPath 'Test-LocalAccounts.json'
    $reportObject | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    $writtenFiles.Add($jsonPath)

    $htmlPath = Join-Path -Path $resolvedOutput -ChildPath 'report.html'
    New-HtmlDocument -Findings $findings -Accounts $accounts -Notas @($notas) | Set-Content -LiteralPath $htmlPath -Encoding UTF8
    $writtenFiles.Add($htmlPath)

    $csvRows = @(
        foreach ($account in $accounts) {
            [pscustomobject]@{
                Nombre               = ConvertTo-CsvSafe -Value $account.Nombre
                SID                  = ConvertTo-CsvSafe -Value $account.SID
                Habilitada           = ConvertTo-CsvSafe -Value (Format-Sino -Value $account.Habilitada)
                UltimoInicio         = ConvertTo-CsvSafe -Value (ConvertTo-DateText -Value $account.UltimoInicio)
                DiasSinUso           = ConvertTo-CsvSafe -Value $account.DiasSinUso
                PasswordNuncaCaduca  = ConvertTo-CsvSafe -Value (Format-Sino -Value $account.PasswordNuncaCaduca)
                PasswordNoRequerida  = ConvertTo-CsvSafe -Value (Format-Sino -Value $account.PasswordNoRequerida)
                UltimoCambioPassword = ConvertTo-CsvSafe -Value (ConvertTo-DateText -Value $account.UltimoCambioPassword)
                DiasPassword         = ConvertTo-CsvSafe -Value $account.DiasPassword
                EsAdmin              = ConvertTo-CsvSafe -Value (Format-Sino -Value $account.EsAdmin)
            }
        }
    )

    $csvPath = Join-Path -Path $resolvedOutput -ChildPath 'accounts.csv'
    if ($csvRows.Count -eq 0) {
        $csvRows = @([pscustomobject]@{
                Nombre = ''; SID = ''; Habilitada = ''; UltimoInicio = ''; DiasSinUso = ''
                PasswordNuncaCaduca = ''; PasswordNoRequerida = ''; UltimoCambioPassword = ''
                DiasPassword = ''; EsAdmin = ''
            })
    }
    $csvText = (@($csvRows | ConvertTo-Csv -NoTypeInformation) -join [Environment]::NewLine) + [Environment]::NewLine
    [System.IO.File]::WriteAllText($csvPath, $csvText, (New-Object System.Text.UTF8Encoding($true)))
    $writtenFiles.Add($csvPath)
}

# ---------------------------------------------------------------------------
# Resumen en consola (único punto con Write-Host)
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host 'Revisión de cuentas locales (solo lectura)' -ForegroundColor Cyan
Write-Host ('Equipo: {0}   Fecha: {1}   Límite sin uso: {2} días' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyy-MM-dd HH:mm'), $StaleDays)
Write-Host ('Cuentas locales: {0}   Miembros de Administradores: {1}' -f $accounts.Count, $adminMembers.Count)
Write-Host ''

foreach ($finding in $findings) {
    $color = Get-EstadoColor -Estado $finding.Estado
    Write-Host ('[{0}] {1}: {2}' -f $finding.Estado.ToUpperInvariant(), $finding.Comprobacion, $finding.Detalle) -ForegroundColor $color
    if ($finding.Estado -ne 'OK') {
        if (-not [string]::IsNullOrWhiteSpace($finding.Valor)) {
            Write-Host ('        Valor: {0}' -f $finding.Valor) -ForegroundColor DarkGray
        }
        if (-not [string]::IsNullOrWhiteSpace($finding.Recomendado)) {
            Write-Host ('        Recomendado: {0}' -f $finding.Recomendado) -ForegroundColor DarkGray
        }
        if (-not [string]::IsNullOrWhiteSpace($finding.Solucion)) {
            Write-Host ('        Solución (ejemplo, no ejecutada): {0}' -f $finding.Solucion) -ForegroundColor DarkYellow
        }
    }
}

if ($notas.Count -gt 0) {
    Write-Host ''
    Write-Host 'Notas:' -ForegroundColor Yellow
    foreach ($note in $notas) {
        Write-Host ('  - {0}' -f $note) -ForegroundColor DarkYellow
    }
}

Write-Host ''
Write-Host ('Resumen: {0} OK, {1} avisos, {2} altas' -f $okCount, $avisoCount, $altaCount) -ForegroundColor Cyan

if ($writtenFiles.Count -gt 0) {
    Write-Host 'Archivos generados:' -ForegroundColor Cyan
    foreach ($file in $writtenFiles) {
        Write-Host ('  - {0}' -f $file) -ForegroundColor DarkGray
    }
}

Write-Host 'Solo lectura: no se ha cambiado ninguna cuenta, contraseña ni grupo.' -ForegroundColor Green
Write-Host ''

exit $exitCode
