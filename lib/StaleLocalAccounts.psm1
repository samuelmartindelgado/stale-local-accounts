#Requires -Version 5.1
<#
.SYNOPSIS
    Revisión de solo lectura de las cuentas y grupos locales de Windows.

.DESCRIPTION
    El módulo expone dos funciones:

    - Get-LocalAccountReport: lee las cuentas locales (Get-LocalUser) y los
      miembros del grupo Administradores (Get-LocalGroupMember por SID, con
      alternativa ADSI) y devuelve una fila por cuenta.
    - Get-AccountFindings: lógica pura de decisión. Recibe las cuentas y los
      miembros ya leídos y devuelve los hallazgos en español.

    No lee, muestra ni modifica contraseñas. No cambia nada del equipo.
#>

$script:AdminGroupSid = 'S-1-5-32-544'
$script:IgnoredStaleSidSuffixes = @('-503', '-504')
$script:MaxAdminMembers = 2
$script:MaxPasswordAgeDays = 365

function ConvertTo-SidText {
    <#
    .SYNOPSIS
        Convierte un SID a texto, acepte SecurityIdentifier u objeto.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        $Sid
    )

    if ($null -eq $Sid) {
        return $null
    }

    if ($Sid -is [System.Security.Principal.SecurityIdentifier]) {
        return $Sid.Value
    }

    $text = [string]$Sid
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    return $text
}

function Get-ObjectPropertyValue {
    <#
    .SYNOPSIS
        Lee una propiedad sin fallar si el objeto no la tiene.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        $Object,
        [Parameter(Position = 1)]
        [string]$Name
    )

    if ($null -eq $Object -or [string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function ConvertTo-DateTimeValue {
    <#
    .SYNOPSIS
        Normaliza fechas que pueden llegar como DateTime, DateTimeOffset o texto.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        $Value
    )

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [datetime]) {
        return $Value
    }

    if ($Value -is [datetimeoffset]) {
        return $Value.LocalDateTime
    }

    if ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value)) {
        $parsed = [datetime]::MinValue
        $styles = [System.Globalization.DateTimeStyles]::None
        if ([datetime]::TryParse($Value, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
            return $parsed
        }
    }

    return $null
}

function Initialize-LocalAccounts {
    <#
    .SYNOPSIS
        Carga el módulo LocalAccounts, también en PowerShell 7.
    #>
    [CmdletBinding()]
    param()

    if (Get-Command -Name 'Get-LocalUser' -ErrorAction SilentlyContinue) {
        return
    }

    $moduleName = 'Microsoft.PowerShell.LocalAccounts'
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        Import-Module -Name $moduleName -UseWindowsPowerShell -WarningAction SilentlyContinue -ErrorAction Stop
    }
    else {
        Import-Module -Name $moduleName -ErrorAction Stop
    }
}

function Get-LocalAdminMemberFromAdsi {
    <#
    .SYNOPSIS
        Alternativa ADSI para leer Administradores cuando Get-LocalGroupMember falla.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$GroupSid = $script:AdminGroupSid
    )

    try {
        $sid = [System.Security.Principal.SecurityIdentifier]::new($GroupSid)

        $groupName = $null
        try {
            $accountName = $sid.Translate([System.Security.Principal.NTAccount]).Value
            $groupName = @($accountName -split '\\')[-1]
        }
        catch {
            $groupName = $null
        }

        if ([string]::IsNullOrWhiteSpace($groupName)) {
            try {
                $groupName = (Get-LocalGroup -SID $GroupSid -ErrorAction Stop).Name
            }
            catch {
                $groupName = $null
            }
        }

        if ([string]::IsNullOrWhiteSpace($groupName)) {
            throw "No se pudo resolver el nombre del grupo con SID $GroupSid."
        }

        $groupPath = 'WinNT://{0}/{1},group' -f $env:COMPUTERNAME, $groupName
        $group = [ADSI]$groupPath
        $children = @($group.Children)

        $result = foreach ($child in $children) {
            $name = $null
            $class = $null
            $sidText = $null

            try {
                $name = [string]$child.Name
            }
            catch {
                $name = $null
            }

            try {
                $class = [string]$child.SchemaClassName
            }
            catch {
                $class = $null
            }

            try {
                $rawSid = @($child.objectSid | Where-Object { $null -ne $_ })
                if ($rawSid.Count -gt 0) {
                    $bytes = New-Object 'System.Byte[]' $rawSid.Count
                    for ($index = 0; $index -lt $rawSid.Count; $index++) {
                        $bytes[$index] = [byte]$rawSid[$index]
                    }
                    $sidText = ([System.Security.Principal.SecurityIdentifier]::new($bytes, 0)).Value
                }
            }
            catch {
                $sidText = $null
            }

            if ([string]::IsNullOrWhiteSpace($name)) {
                $name = $sidText
            }

            [pscustomobject]@{
                Nombre   = [string]$name
                SID      = $sidText
                Clase    = $class
                Origen   = 'ADSI'
                Huerfano = ([string]::IsNullOrWhiteSpace($sidText) -or [string]::IsNullOrWhiteSpace($name))
            }
        }

        return @($result)
    }
    catch {
        Write-Warning ("No se pudo leer el grupo Administradores ({0}) con ADSI: {1}" -f $GroupSid, $_.Exception.Message)
        return @()
    }
}

function Get-LocalAdminMemberData {
    <#
    .SYNOPSIS
        Devuelve los miembros de Administradores normalizados (Nombre, SID, Clase, Origen, Huerfano).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$GroupSid = $script:AdminGroupSid
    )

    try {
        $members = @(Get-LocalGroupMember -SID $GroupSid -ErrorAction Stop)
        $normalized = foreach ($member in $members) {
            $sidText = ConvertTo-SidText -Sid (Get-ObjectPropertyValue -Object $member -Name 'SID')
            $name = [string](Get-ObjectPropertyValue -Object $member -Name 'Name')

            if ([string]::IsNullOrWhiteSpace($name)) {
                $name = $sidText
            }

            [pscustomobject]@{
                Nombre   = $name
                SID      = $sidText
                Clase    = Get-ObjectPropertyValue -Object $member -Name 'ObjectClass'
                Origen   = Get-ObjectPropertyValue -Object $member -Name 'PrincipalSource'
                Huerfano = [string]::IsNullOrWhiteSpace($sidText)
            }
        }

        return @($normalized)
    }
    catch {
        Write-Verbose ("Get-LocalGroupMember falló: {0}. Se intenta la alternativa ADSI." -f $_.Exception.Message)
        return @(Get-LocalAdminMemberFromAdsi -GroupSid $GroupSid)
    }
}

function Format-AccountValue {
    <#
    .SYNOPSIS
        Texto corto "Nombre (SID)" para la columna Valor.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        $Account
    )

    $name = [string](Get-ObjectPropertyValue -Object $Account -Name 'Nombre')
    $sid = ConvertTo-SidText -Sid (Get-ObjectPropertyValue -Object $Account -Name 'SID')

    if ([string]::IsNullOrWhiteSpace($sid)) {
        return $name
    }

    return ('{0} ({1})' -f $name, $sid)
}

function Format-MemberValue {
    <#
    .SYNOPSIS
        Texto corto "Nombre (SID)" para un miembro de grupo.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        $Member
    )

    $name = [string](Get-ObjectPropertyValue -Object $Member -Name 'Nombre')
    $sid = ConvertTo-SidText -Sid (Get-ObjectPropertyValue -Object $Member -Name 'SID')

    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = $sid
    }

    if ([string]::IsNullOrWhiteSpace($sid)) {
        return $name
    }

    return ('{0} ({1})' -f $name, $sid)
}

function New-Finding {
    <#
    .SYNOPSIS
        Crea un hallazgo con la estructura común del informe.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Comprobacion,
        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateSet('OK', 'Aviso', 'Alta')]
        [string]$Estado,
        [Parameter(Mandatory = $true, Position = 2)]
        [string]$Detalle,
        [Parameter(Position = 3)]
        [string]$Valor = '',
        [Parameter(Position = 4)]
        [string]$Recomendado = 'Nada',
        [Parameter(Position = 5)]
        [string]$Solucion = ''
    )

    [pscustomobject]@{
        Comprobacion = $Comprobacion
        Estado       = $Estado
        Detalle      = $Detalle
        Valor        = $Valor
        Recomendado  = $Recomendado
        Solucion     = $Solucion
    }
}

function Test-AdminAccount {
    <#
    .SYNOPSIS
        Indica si una cuenta pertenece a Administradores (por EsAdmin o por SID).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        $Account,
        [Parameter(Position = 1)]
        [string[]]$AdminSids
    )

    if ((Get-ObjectPropertyValue -Object $Account -Name 'EsAdmin') -eq $true) {
        return $true
    }

    $sid = ConvertTo-SidText -Sid (Get-ObjectPropertyValue -Object $Account -Name 'SID')
    if (-not [string]::IsNullOrWhiteSpace($sid) -and $AdminSids -contains $sid) {
        return $true
    }

    return $false
}

function Get-LocalAccountReport {
    <#
    .SYNOPSIS
        Devuelve una fila por cuenta local con su estado, antigüedad y si es administradora.

    .DESCRIPTION
        Solo lectura. Admite datos simulados mediante -InputObject y -AdminMember
        para poder probar la lógica sin depender del equipo.

    .PARAMETER InputObject
        Cuentas simuladas con el formato de Get-LocalUser. Si se omite, se leen del sistema.

    .PARAMETER AdminMember
        Miembros simulados de Administradores. Si se omite, se leen del sistema.

    .PARAMETER UserName
        Limita la lectura real a una cuenta concreta.

    .PARAMETER GroupSid
        SID del grupo de administradores. Por defecto S-1-5-32-544.

    .PARAMETER AdminMemberResult
        Referencia donde se devuelve la lista de miembros leída o inyectada.

    .EXAMPLE
        Get-LocalAccountReport

    .EXAMPLE
        Get-LocalAccountReport -InputObject $cuentas -AdminMember $miembros
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [object[]]$InputObject,
        [Parameter(Position = 1)]
        [object[]]$AdminMember,
        [Parameter(Position = 2)]
        [string]$UserName,
        [Parameter(Position = 3)]
        [string]$GroupSid = $script:AdminGroupSid,
        [Parameter(Position = 4)]
        [ref]$AdminMemberResult
    )

    if ($PSBoundParameters.ContainsKey('InputObject')) {
        $users = @($InputObject)
    }
    else {
        Initialize-LocalAccounts
        try {
            if ([string]::IsNullOrWhiteSpace($UserName)) {
                $users = @(Get-LocalUser -ErrorAction Stop)
            }
            else {
                $users = @(Get-LocalUser -Name $UserName -ErrorAction Stop)
            }
        }
        catch {
            throw ('No se pudieron leer las cuentas locales: {0}' -f $_.Exception.Message)
        }
    }

    if ($PSBoundParameters.ContainsKey('AdminMember')) {
        $members = @($AdminMember)
    }
    else {
        $members = @(Get-LocalAdminMemberData -GroupSid $GroupSid)
    }

    if ($null -ne $AdminMemberResult) {
        $AdminMemberResult.Value = $members
    }

    $adminSids = @(
        foreach ($member in $members) {
            $memberSid = ConvertTo-SidText -Sid (Get-ObjectPropertyValue -Object $member -Name 'SID')
            if (-not [string]::IsNullOrWhiteSpace($memberSid)) {
                $memberSid
            }
        }
    )

    $now = Get-Date

    foreach ($user in $users) {
        if ($null -eq $user) {
            continue
        }

        $sidText = ConvertTo-SidText -Sid (Get-ObjectPropertyValue -Object $user -Name 'SID')
        $name = [string](Get-ObjectPropertyValue -Object $user -Name 'Name')
        $enabled = ((Get-ObjectPropertyValue -Object $user -Name 'Enabled') -eq $true)

        $lastLogon = ConvertTo-DateTimeValue -Value (Get-ObjectPropertyValue -Object $user -Name 'LastLogon')
        $passwordLastSet = ConvertTo-DateTimeValue -Value (Get-ObjectPropertyValue -Object $user -Name 'PasswordLastSet')

        $passwordExpiresRaw = Get-ObjectPropertyValue -Object $user -Name 'PasswordExpires'
        $passwordExpires = ConvertTo-DateTimeValue -Value $passwordExpiresRaw
        $neverExpires = $true
        if ($null -ne $passwordExpires) {
            $neverExpires = ($passwordExpires.Year -ge 9999)
        }

        $passwordRequired = Get-ObjectPropertyValue -Object $user -Name 'PasswordRequired'
        $passwordNotRequired = $false
        if ($null -ne $passwordRequired) {
            $passwordNotRequired = (-not [bool]$passwordRequired)
        }

        $daysWithoutLogon = $null
        if ($null -ne $lastLogon) {
            $daysWithoutLogon = [int][math]::Floor(($now - $lastLogon).TotalDays)
            if ($daysWithoutLogon -lt 0) {
                $daysWithoutLogon = 0
            }
        }

        $daysSincePasswordChange = $null
        if ($null -ne $passwordLastSet) {
            $daysSincePasswordChange = [int][math]::Floor(($now - $passwordLastSet).TotalDays)
            if ($daysSincePasswordChange -lt 0) {
                $daysSincePasswordChange = 0
            }
        }

        $isAdmin = $false
        if (-not [string]::IsNullOrWhiteSpace($sidText)) {
            $isAdmin = $adminSids -contains $sidText
        }

        [pscustomobject]@{
            Nombre               = $name
            SID                  = $sidText
            Habilitada           = $enabled
            UltimoInicio         = $lastLogon
            DiasSinUso           = $daysWithoutLogon
            PasswordNuncaCaduca  = $neverExpires
            PasswordNoRequerida  = $passwordNotRequired
            UltimoCambioPassword = $passwordLastSet
            DiasPassword         = $daysSincePasswordChange
            EsAdmin              = $isAdmin
        }
    }
}

function Get-AccountFindings {
    <#
    .SYNOPSIS
        Aplica las comprobaciones sobre cuentas y miembros ya leídos.

    .DESCRIPTION
        Lógica pura: no lee del sistema ni cambia nada. Devuelve objetos con
        Comprobacion, Estado (OK, Aviso o Alta), Detalle, Valor, Recomendado y
        Solucion. Cuando una comprobación no encuentra problemas, añade una fila OK.

    .PARAMETER Accounts
        Cuentas con el formato devuelto por Get-LocalAccountReport.

    .PARAMETER AdminMembers
        Miembros de Administradores normalizados.

    .PARAMETER StaleDays
        Días sin inicio de sesión a partir de los cuales se avisa.

    .EXAMPLE
        Get-AccountFindings -Accounts $cuentas -AdminMembers $miembros -StaleDays 90
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [object[]]$Accounts,
        [Parameter(Position = 1)]
        [object[]]$AdminMembers,
        [Parameter(Position = 2)]
        [ValidateRange(1, 3650)]
        [int]$StaleDays = 90
    )

    $safeAccounts = @($Accounts | Where-Object { $null -ne $_ })
    $safeMembers = @($AdminMembers | Where-Object { $null -ne $_ })
    $findings = New-Object 'System.Collections.Generic.List[object]'

    $adminSids = @(
        foreach ($member in $safeMembers) {
            $memberSid = ConvertTo-SidText -Sid (Get-ObjectPropertyValue -Object $member -Name 'SID')
            if (-not [string]::IsNullOrWhiteSpace($memberSid)) {
                $memberSid
            }
        }
    )

    # 1. Cuentas habilitadas sin contraseña.
    $issues = @($safeAccounts | Where-Object {
            $_.Habilitada -eq $true -and $_.PasswordNoRequerida -eq $true
        })
    if ($issues.Count -eq 0) {
        [void]$findings.Add((New-Finding -Comprobacion 'Contraseña no requerida' -Estado 'OK' -Detalle 'Ninguna cuenta habilitada tiene el indicador contraseña no requerida.'))
    }
    else {
        foreach ($account in $issues) {
            $name = [string]$account.Nombre
            [void]$findings.Add((New-Finding -Comprobacion 'Contraseña no requerida' -Estado 'Aviso' `
                        -Detalle ("La cuenta habilitada '{0}' tiene el indicador 'contraseña no requerida' (PASSWD_NOTREQD): podría quedarse con la contraseña vacía aunque la directiva exija una. Si ya tiene contraseña no hay riesgo inmediato, pero conviene quitar el indicador." -f $name) `
                        -Valor (Format-AccountValue -Account $account) `
                        -Recomendado 'Quitar el indicador para que la cuenta siempre exija contraseña.' `
                        -Solucion ("Set-LocalUser -Name '{0}' -PasswordRequired `$true" -f $name)))
        }
    }

    # 2. Cuenta integrada de Administrador (-500) habilitada.
    $issues = @($safeAccounts | Where-Object {
            $sid = ConvertTo-SidText -Sid (Get-ObjectPropertyValue -Object $_ -Name 'SID')
            $_.Habilitada -eq $true -and -not [string]::IsNullOrWhiteSpace($sid) -and $sid.EndsWith('-500', [System.StringComparison]::Ordinal)
        })
    if ($issues.Count -eq 0) {
        [void]$findings.Add((New-Finding -Comprobacion 'Administrador integrado' -Estado 'OK' -Detalle 'La cuenta integrada de Administrador no está habilitada.'))
    }
    else {
        foreach ($account in $issues) {
            $name = [string]$account.Nombre
            [void]$findings.Add((New-Finding -Comprobacion 'Administrador integrado' -Estado 'Alta' `
                        -Detalle ("La cuenta integrada de Administrador '{0}' (SID -500) está habilitada." -f $name) `
                        -Valor (Format-AccountValue -Account $account) `
                        -Recomendado 'Mantener deshabilitada la cuenta integrada de Administrador.' `
                        -Solucion ("Disable-LocalUser -Name '{0}'" -f $name)))
        }
    }

    # 3. Cuenta integrada de Invitado (-501) habilitada.
    $issues = @($safeAccounts | Where-Object {
            $sid = ConvertTo-SidText -Sid (Get-ObjectPropertyValue -Object $_ -Name 'SID')
            $_.Habilitada -eq $true -and -not [string]::IsNullOrWhiteSpace($sid) -and $sid.EndsWith('-501', [System.StringComparison]::Ordinal)
        })
    if ($issues.Count -eq 0) {
        [void]$findings.Add((New-Finding -Comprobacion 'Invitado integrado' -Estado 'OK' -Detalle 'La cuenta integrada de Invitado no está habilitada.'))
    }
    else {
        foreach ($account in $issues) {
            $name = [string]$account.Nombre
            [void]$findings.Add((New-Finding -Comprobacion 'Invitado integrado' -Estado 'Alta' `
                        -Detalle ("La cuenta integrada de Invitado '{0}' (SID -501) está habilitada." -f $name) `
                        -Valor (Format-AccountValue -Account $account) `
                        -Recomendado 'Deshabilitar la cuenta de Invitado.' `
                        -Solucion ("Disable-LocalUser -Name '{0}'" -f $name)))
        }
    }

    # 4. Cuentas habilitadas sin uso (se ignoran las integradas -503 y -504).
    $issues = @($safeAccounts | Where-Object {
            if ($_.Habilitada -ne $true) {
                return $false
            }

            $sid = ConvertTo-SidText -Sid (Get-ObjectPropertyValue -Object $_ -Name 'SID')
            if (-not [string]::IsNullOrWhiteSpace($sid)) {
                foreach ($suffix in $script:IgnoredStaleSidSuffixes) {
                    if ($sid.EndsWith($suffix, [System.StringComparison]::Ordinal)) {
                        return $false
                    }
                }
            }

            if ($null -eq $_.DiasSinUso) {
                return $true
            }

            return ([int]$_.DiasSinUso -gt $StaleDays)
        })
    if ($issues.Count -eq 0) {
        [void]$findings.Add((New-Finding -Comprobacion 'Cuentas sin uso' -Estado 'OK' -Detalle ("Ninguna cuenta habilitada lleva más de {0} días sin iniciar sesión." -f $StaleDays)))
    }
    else {
        foreach ($account in $issues) {
            $name = [string]$account.Nombre
            $detail = if ($null -eq $account.DiasSinUso) {
                "La cuenta habilitada '{0}' nunca ha iniciado sesión." -f $name
            }
            else {
                "La cuenta habilitada '{0}' lleva {1} días sin iniciar sesión (límite: {2})." -f $name, $account.DiasSinUso, $StaleDays
            }
            [void]$findings.Add((New-Finding -Comprobacion 'Cuentas sin uso' -Estado 'Aviso' `
                        -Detalle $detail `
                        -Valor (Format-AccountValue -Account $account) `
                        -Recomendado 'Deshabilitar o eliminar la cuenta si ya no se usa.' `
                        -Solucion ("Disable-LocalUser -Name '{0}'" -f $name)))
        }
    }

    # 5. Cuenta administradora habilitada con contraseña que nunca caduca.
    $issues = @($safeAccounts | Where-Object {
            (Test-AdminAccount -Account $_ -AdminSids $adminSids) -and
            $_.Habilitada -eq $true -and
            $_.PasswordNuncaCaduca -eq $true
        })
    if ($issues.Count -eq 0) {
        [void]$findings.Add((New-Finding -Comprobacion 'Contraseña de administrador sin caducidad' -Estado 'OK' -Detalle 'Ninguna cuenta administradora habilitada tiene la contraseña configurada sin caducidad.'))
    }
    else {
        foreach ($account in $issues) {
            $name = [string]$account.Nombre
            [void]$findings.Add((New-Finding -Comprobacion 'Contraseña de administrador sin caducidad' -Estado 'Aviso' `
                        -Detalle ("La cuenta administradora habilitada '{0}' tiene la contraseña configurada para no caducar nunca." -f $name) `
                        -Valor (Format-AccountValue -Account $account) `
                        -Recomendado 'Hacer que la contraseña caduque y rotarla periódicamente.' `
                        -Solucion ("Set-LocalUser -Name '{0}' -PasswordNeverExpires `$false" -f $name)))
        }
    }

    # 6. Contraseña de administrador sin cambiar en más de 365 días.
    $issues = @($safeAccounts | Where-Object {
            (Test-AdminAccount -Account $_ -AdminSids $adminSids) -and
            $_.Habilitada -eq $true -and
            $null -ne $_.DiasPassword -and
            [int]$_.DiasPassword -gt $script:MaxPasswordAgeDays
        })
    if ($issues.Count -eq 0) {
        [void]$findings.Add((New-Finding -Comprobacion 'Contraseña de administrador antigua' -Estado 'OK' -Detalle ("Ninguna cuenta administradora habilitada lleva más de {0} días sin cambiar la contraseña." -f $script:MaxPasswordAgeDays)))
    }
    else {
        foreach ($account in $issues) {
            $name = [string]$account.Nombre
            [void]$findings.Add((New-Finding -Comprobacion 'Contraseña de administrador antigua' -Estado 'Aviso' `
                        -Detalle ("La cuenta administradora habilitada '{0}' no cambia la contraseña desde hace {1} días (límite: {2})." -f $name, $account.DiasPassword, $script:MaxPasswordAgeDays) `
                        -Valor (Format-AccountValue -Account $account) `
                        -Recomendado 'Cambiar la contraseña y revisar si la cuenta sigue siendo necesaria.' `
                        -Solucion ("net user '{0}' *" -f $name)))
        }
    }

    # 7. Más de 2 miembros en Administradores.
    if ($safeMembers.Count -gt $script:MaxAdminMembers) {
        $memberList = @($safeMembers | ForEach-Object { Format-MemberValue -Member $_ }) -join '; '
        [void]$findings.Add((New-Finding -Comprobacion 'Miembros de Administradores' -Estado 'Aviso' `
                    -Detalle ("El grupo Administradores tiene {0} miembros; se recomiendan {1} o menos." -f $safeMembers.Count, $script:MaxAdminMembers) `
                    -Valor $memberList `
                    -Recomendado 'Quitar del grupo los miembros que no necesiten privilegios de administrador.' `
                    -Solucion "Remove-LocalGroupMember -SID S-1-5-32-544 -Member '<miembro>'"))
    }
    else {
        [void]$findings.Add((New-Finding -Comprobacion 'Miembros de Administradores' -Estado 'OK' -Detalle ("El grupo Administradores tiene {0} miembros ({1} o menos)." -f $safeMembers.Count, $script:MaxAdminMembers)))
    }

    # 8. Miembros huérfanos en Administradores (SID sin resolver).
    $issues = @($safeMembers | Where-Object {
            $orphanFlag = Get-ObjectPropertyValue -Object $_ -Name 'Huerfano'
            if ($orphanFlag -eq $true) {
                return $true
            }

            $sid = ConvertTo-SidText -Sid (Get-ObjectPropertyValue -Object $_ -Name 'SID')
            if ([string]::IsNullOrWhiteSpace($sid)) {
                return $true
            }

            $name = [string](Get-ObjectPropertyValue -Object $_ -Name 'Nombre')
            return ($name -match '^S-1-[0-9-]+$')
        })
    if ($issues.Count -eq 0) {
        [void]$findings.Add((New-Finding -Comprobacion 'Miembros huérfanos' -Estado 'OK' -Detalle 'No hay miembros huérfanos en el grupo Administradores.'))
    }
    else {
        foreach ($member in $issues) {
            $value = Format-MemberValue -Member $member
            [void]$findings.Add((New-Finding -Comprobacion 'Miembros huérfanos' -Estado 'Aviso' `
                        -Detalle 'Hay un miembro del grupo Administradores cuyo SID no se puede resolver (posible cuenta eliminada).' `
                        -Valor $value `
                        -Recomendado 'Quitar el miembro huérfano del grupo.' `
                        -Solucion ("Remove-LocalGroupMember -SID S-1-5-32-544 -Member '{0}'" -f $value)))
        }
    }

    return $findings
}

Export-ModuleMember -Function 'Get-LocalAccountReport', 'Get-AccountFindings'
