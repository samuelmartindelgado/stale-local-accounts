#Requires -Version 5.1
<#
    Pruebas de StaleLocalAccounts.
    La lógica de decisión se prueba con datos simulados; además se comprueba
    que la lectura real del equipo no lanza excepciones y que el script genera
    sus ficheros de salida.
#>

BeforeAll {
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    $modulePath = Join-Path -Path (Join-Path -Path $repoRoot -ChildPath 'lib') -ChildPath 'StaleLocalAccounts.psm1'
    Import-Module -Name $modulePath -Force

    function New-TestAccount {
        param(
            [string]$Nombre = 'demo',
            [string]$SID = 'S-1-5-21-1000000001-1000000002-1000000003-1001',
            [bool]$Habilitada = $true,
            $DiasSinUso = 1,
            [bool]$PasswordNuncaCaduca = $false,
            [bool]$PasswordNoRequerida = $false,
            $DiasDesdeCambio = 10,
            [bool]$EsAdmin = $false
        )

        [pscustomobject]@{
            Nombre               = $Nombre
            SID                  = $SID
            Habilitada           = $Habilitada
            UltimoInicio         = $null
            DiasSinUso           = $DiasSinUso
            PasswordNuncaCaduca  = $PasswordNuncaCaduca
            PasswordNoRequerida  = $PasswordNoRequerida
            UltimoCambioPassword = $null
            DiasPassword         = $DiasDesdeCambio
            EsAdmin              = $EsAdmin
        }
    }

    function New-TestMember {
        param(
            [string]$Nombre = 'demo',
            [string]$SID = 'S-1-5-21-1000000001-1000000002-1000000003-1001',
            [string]$Clase = 'Usuario'
        )

        [pscustomobject]@{
            Nombre   = $Nombre
            SID      = $SID
            Clase    = $Clase
            Origen   = 'Local'
            Huerfano = $false
        }
    }

    function Get-FindingsByCheck {
        param(
            [object[]]$Findings,
            [string]$Comprobacion
        )

        return @($Findings | Where-Object { $_.Comprobacion -eq $Comprobacion })
    }
}

Describe 'Get-AccountFindings' {

    Context 'sin problemas' {
        It 'devuelve una fila OK por cada comprobación' {
            $accounts = @(New-TestAccount -Nombre 'normal' -DiasSinUso 5)
            $members = @(New-TestMember -Nombre 'PC-DEMO\normal')

            $findings = @(Get-AccountFindings -Accounts $accounts -AdminMembers $members -StaleDays 90)

            $findings.Count | Should -Be 8
            @($findings | Where-Object { $_.Estado -ne 'OK' }).Count | Should -Be 0
            @($findings | Select-Object -ExpandProperty Comprobacion -Unique).Count | Should -Be 8
            foreach ($finding in $findings) {
                $finding.Detalle | Should -Not -BeNullOrEmpty
                $finding.Solucion | Should -BeExactly ''
            }
        }
    }

    Context 'cuentas sin contraseña' {
        It 'marca Aviso una cuenta habilitada que no requiere contraseña' {
            $accounts = @(New-TestAccount -Nombre 'sinpass' -PasswordNoRequerida $true)

            $findings = @(Get-AccountFindings -Accounts $accounts -AdminMembers @() -StaleDays 90)
            $rows = @(Get-FindingsByCheck -Findings $findings -Comprobacion 'Contraseña no requerida' | Where-Object { $_.Estado -eq 'Aviso' })

            $rows.Count | Should -Be 1
            $rows[0].Valor | Should -Match 'sinpass'
            $rows[0].Solucion | Should -Match 'Set-LocalUser'
            $rows[0].Solucion | Should -Match 'PasswordRequired'
        }

        It 'no marca una cuenta deshabilitada sin contraseña' {
            $accounts = @(New-TestAccount -Nombre 'apagada' -Habilitada $false -PasswordNoRequerida $true)

            $findings = @(Get-AccountFindings -Accounts $accounts -AdminMembers @() -StaleDays 90)
            $rows = @(Get-FindingsByCheck -Findings $findings -Comprobacion 'Contraseña no requerida' | Where-Object { $_.Estado -eq 'Aviso' })

            $rows.Count | Should -Be 0
        }
    }

    Context 'cuentas integradas' {
        It 'marca Alta el Administrador integrado habilitado (SID -500)' {
            $accounts = @(New-TestAccount -Nombre 'Administrador' -SID 'S-1-5-21-1000000001-1000000002-1000000003-500')

            $findings = @(Get-AccountFindings -Accounts $accounts -AdminMembers @() -StaleDays 90)
            $rows = @(Get-FindingsByCheck -Findings $findings -Comprobacion 'Administrador integrado' | Where-Object { $_.Estado -eq 'Alta' })

            $rows.Count | Should -Be 1
            $rows[0].Solucion | Should -Match 'Disable-LocalUser'
            $rows[0].Solucion | Should -Match 'Administrador'
        }

        It 'no marca Alta el Administrador integrado deshabilitado' {
            $accounts = @(New-TestAccount -Nombre 'Administrador' -SID 'S-1-5-21-1000000001-1000000002-1000000003-500' -Habilitada $false)

            $findings = @(Get-AccountFindings -Accounts $accounts -AdminMembers @() -StaleDays 90)
            $rows = @(Get-FindingsByCheck -Findings $findings -Comprobacion 'Administrador integrado' | Where-Object { $_.Estado -eq 'Alta' })

            $rows.Count | Should -Be 0
        }

        It 'marca Alta el Invitado integrado habilitado (SID -501)' {
            $accounts = @(New-TestAccount -Nombre 'Invitado' -SID 'S-1-5-21-1000000001-1000000002-1000000003-501')

            $findings = @(Get-AccountFindings -Accounts $accounts -AdminMembers @() -StaleDays 90)
            $rows = @(Get-FindingsByCheck -Findings $findings -Comprobacion 'Invitado integrado' | Where-Object { $_.Estado -eq 'Alta' })

            $rows.Count | Should -Be 1
            $rows[0].Solucion | Should -Match 'Disable-LocalUser'
        }
    }

    Context 'cuentas sin uso' {
        It 'avisa de una cuenta sin iniciar sesión más de StaleDays' {
            $accounts = @(New-TestAccount -Nombre 'olvidada' -DiasSinUso 120)

            $findings = @(Get-AccountFindings -Accounts $accounts -AdminMembers @() -StaleDays 90)
            $rows = @(Get-FindingsByCheck -Findings $findings -Comprobacion 'Cuentas sin uso' | Where-Object { $_.Estado -eq 'Aviso' })

            $rows.Count | Should -Be 1
            $rows[0].Detalle | Should -Match '120'
            $rows[0].Solucion | Should -Match 'Disable-LocalUser'
        }

        It 'avisa de una cuenta que nunca ha iniciado sesión' {
            $accounts = @(New-TestAccount -Nombre 'nunca' -DiasSinUso $null)

            $findings = @(Get-AccountFindings -Accounts $accounts -AdminMembers @() -StaleDays 90)
            $rows = @(Get-FindingsByCheck -Findings $findings -Comprobacion 'Cuentas sin uso' | Where-Object { $_.Estado -eq 'Aviso' })

            $rows.Count | Should -Be 1
            $rows[0].Detalle | Should -Match 'nunca'
        }

        It 'ignora las cuentas integradas DefaultAccount (-503) y WDAGUtilityAccount (-504)' {
            $accounts = @(
                New-TestAccount -Nombre 'DefaultAccount' -SID 'S-1-5-21-1000000001-1000000002-1000000003-503' -DiasSinUso $null
                New-TestAccount -Nombre 'WDAGUtilityAccount' -SID 'S-1-5-21-1000000001-1000000002-1000000003-504' -DiasSinUso $null
            )

            $findings = @(Get-AccountFindings -Accounts $accounts -AdminMembers @() -StaleDays 90)
            $rows = @(Get-FindingsByCheck -Findings $findings -Comprobacion 'Cuentas sin uso' | Where-Object { $_.Estado -eq 'Aviso' })

            $rows.Count | Should -Be 0
        }

        It 'respeta el límite de StaleDays' {
            $accounts = @(New-TestAccount -Nombre 'limite' -DiasSinUso 90)

            $findings = @(Get-AccountFindings -Accounts $accounts -AdminMembers @() -StaleDays 90)
            $rows = @(Get-FindingsByCheck -Findings $findings -Comprobacion 'Cuentas sin uso' | Where-Object { $_.Estado -eq 'Aviso' })
            $rows.Count | Should -Be 0

            $accounts = @(New-TestAccount -Nombre 'limite' -DiasSinUso 91)
            $findings = @(Get-AccountFindings -Accounts $accounts -AdminMembers @() -StaleDays 90)
            $rows = @(Get-FindingsByCheck -Findings $findings -Comprobacion 'Cuentas sin uso' | Where-Object { $_.Estado -eq 'Aviso' })
            $rows.Count | Should -Be 1
        }
    }

    Context 'contraseñas de administradores' {
        It 'avisa de un administrador habilitado con contraseña que nunca caduca' {
            $accounts = @(New-TestAccount -Nombre 'admin' -EsAdmin $true -PasswordNuncaCaduca $true)

            $findings = @(Get-AccountFindings -Accounts $accounts -AdminMembers @() -StaleDays 90)
            $rows = @(Get-FindingsByCheck -Findings $findings -Comprobacion 'Contraseña de administrador sin caducidad' | Where-Object { $_.Estado -eq 'Aviso' })

            $rows.Count | Should -Be 1
            $rows[0].Solucion | Should -Match 'PasswordNeverExpires'
        }

        It 'no avisa si el administrador está deshabilitado' {
            $accounts = @(New-TestAccount -Nombre 'admin' -EsAdmin $true -Habilitada $false -PasswordNuncaCaduca $true)

            $findings = @(Get-AccountFindings -Accounts $accounts -AdminMembers @() -StaleDays 90)
            $rows = @(Get-FindingsByCheck -Findings $findings -Comprobacion 'Contraseña de administrador sin caducidad' | Where-Object { $_.Estado -eq 'Aviso' })

            $rows.Count | Should -Be 0
        }

        It 'considera administrador por SID aunque EsAdmin sea falso' {
            $accounts = @(New-TestAccount -Nombre 'admin' -EsAdmin $false -PasswordNuncaCaduca $true)
            $members = @(New-TestMember -Nombre 'PC-DEMO\admin')

            $findings = @(Get-AccountFindings -Accounts $accounts -AdminMembers $members -StaleDays 90)
            $rows = @(Get-FindingsByCheck -Findings $findings -Comprobacion 'Contraseña de administrador sin caducidad' | Where-Object { $_.Estado -eq 'Aviso' })

            $rows.Count | Should -Be 1
        }

        It 'avisa de una contraseña de administrador sin cambiar en más de 365 días' {
            $accounts = @(New-TestAccount -Nombre 'admin' -EsAdmin $true -DiasDesdeCambio 400)

            $findings = @(Get-AccountFindings -Accounts $accounts -AdminMembers @() -StaleDays 90)
            $rows = @(Get-FindingsByCheck -Findings $findings -Comprobacion 'Contraseña de administrador antigua' | Where-Object { $_.Estado -eq 'Aviso' })

            $rows.Count | Should -Be 1
            $rows[0].Detalle | Should -Match '400'
        }

        It 'no avisa justo en el día 365' {
            $accounts = @(New-TestAccount -Nombre 'admin' -EsAdmin $true -DiasDesdeCambio 365)

            $findings = @(Get-AccountFindings -Accounts $accounts -AdminMembers @() -StaleDays 90)
            $rows = @(Get-FindingsByCheck -Findings $findings -Comprobacion 'Contraseña de administrador antigua' | Where-Object { $_.Estado -eq 'Aviso' })

            $rows.Count | Should -Be 0
        }
    }

    Context 'grupo Administradores' {
        It 'avisa cuando hay más de 2 miembros y los lista en Valor' {
            $members = @(
                New-TestMember -Nombre 'PC-DEMO\uno' -SID 'S-1-5-21-1000000001-1000000002-1000000003-1001'
                New-TestMember -Nombre 'PC-DEMO\dos' -SID 'S-1-5-21-1000000001-1000000002-1000000003-1002'
                New-TestMember -Nombre 'PC-DEMO\tres' -SID 'S-1-5-21-1000000001-1000000002-1000000003-1003'
            )

            $findings = @(Get-AccountFindings -Accounts @() -AdminMembers $members -StaleDays 90)
            $rows = @(Get-FindingsByCheck -Findings $findings -Comprobacion 'Miembros de Administradores' | Where-Object { $_.Estado -eq 'Aviso' })

            $rows.Count | Should -Be 1
            $rows[0].Valor | Should -Match 'uno'
            $rows[0].Valor | Should -Match 'dos'
            $rows[0].Valor | Should -Match 'tres'
            $rows[0].Detalle | Should -Match '3'
        }

        It 'no avisa cuando hay 2 miembros o menos' {
            $members = @(
                New-TestMember -Nombre 'PC-DEMO\uno' -SID 'S-1-5-21-1000000001-1000000002-1000000003-1001'
                New-TestMember -Nombre 'PC-DEMO\dos' -SID 'S-1-5-21-1000000001-1000000002-1000000003-1002'
            )

            $findings = @(Get-AccountFindings -Accounts @() -AdminMembers $members -StaleDays 90)
            $rows = @(Get-FindingsByCheck -Findings $findings -Comprobacion 'Miembros de Administradores' | Where-Object { $_.Estado -eq 'Aviso' })

            $rows.Count | Should -Be 0
        }

        It 'avisa de un miembro huérfano en Administradores' {
            $members = @(
                [pscustomobject]@{
                    Nombre   = 'S-1-5-21-1000000001-1000000002-1000000003-9999'
                    SID      = $null
                    Clase    = $null
                    Origen   = 'ADSI'
                    Huerfano = $true
                }
            )

            $findings = @(Get-AccountFindings -Accounts @() -AdminMembers $members -StaleDays 90)
            $rows = @(Get-FindingsByCheck -Findings $findings -Comprobacion 'Miembros huérfanos' | Where-Object { $_.Estado -eq 'Aviso' })

            $rows.Count | Should -Be 1
            $rows[0].Solucion | Should -Match 'Remove-LocalGroupMember'
            $rows[0].Solucion | Should -Match 'S-1-5-32-544'
        }

        It 'no avisa de huérfanos cuando todos los SID se resuelven' {
            $members = @(New-TestMember -Nombre 'PC-DEMO\uno' -SID 'S-1-5-21-1000000001-1000000002-1000000003-1001')

            $findings = @(Get-AccountFindings -Accounts @() -AdminMembers $members -StaleDays 90)
            $rows = @(Get-FindingsByCheck -Findings $findings -Comprobacion 'Miembros huérfanos' | Where-Object { $_.Estado -eq 'Aviso' })

            $rows.Count | Should -Be 0
        }
    }

    Context 'estructura de los hallazgos' {
        It 'usa solo los estados OK, Aviso y Alta y rellena todos los campos' {
            $accounts = @(New-TestAccount -Nombre 'sinpass' -PasswordNoRequerida $true)
            $findings = @(Get-AccountFindings -Accounts $accounts -AdminMembers @() -StaleDays 90)

            foreach ($finding in $findings) {
                $finding.Estado | Should -BeIn @('OK', 'Aviso', 'Alta')
                $finding.Comprobacion | Should -Not -BeNullOrEmpty
                $finding.Detalle | Should -Not -BeNullOrEmpty
                $finding.Recomendado | Should -Not -BeNullOrEmpty
                @($finding.PSObject.Properties.Name).Count | Should -Be 6
                $finding.PSObject.Properties.Name | Should -Contain 'Valor'
                $finding.PSObject.Properties.Name | Should -Contain 'Solucion'
            }
        }
    }
}

Describe 'Get-LocalAccountReport' {

    It 'calcula antigüedad, caducidad y pertenencia a Administradores con datos simulados' {
        $adminSid = 'S-1-5-21-1000000001-1000000002-1000000003-500'
        $user = [pscustomobject]@{
            Name              = 'Administrador'
            SID               = [System.Security.Principal.SecurityIdentifier]::new($adminSid)
            Enabled           = $true
            LastLogon         = (Get-Date).AddDays(-12)
            PasswordExpires   = $null
            PasswordRequired  = $true
            PasswordLastSet   = (Get-Date).AddDays(-400)
        }
        $member = [pscustomobject]@{
            Name            = 'PC-DEMO\Administrador'
            SID             = $adminSid
            ObjectClass     = 'Usuario'
            PrincipalSource = 'Local'
        }

        $report = @(Get-LocalAccountReport -InputObject @($user) -AdminMember @($member))

        $report.Count | Should -Be 1
        $report[0].Nombre | Should -Be 'Administrador'
        $report[0].SID | Should -Be $adminSid
        $report[0].Habilitada | Should -BeTrue
        $report[0].PasswordNuncaCaduca | Should -BeTrue
        $report[0].PasswordNoRequerida | Should -BeFalse
        $report[0].DiasSinUso | Should -Be 12
        $report[0].DiasPassword | Should -Be 400
        $report[0].EsAdmin | Should -BeTrue
    }

    It 'expone exactamente las diez columnas del informe' {
        $user = [pscustomobject]@{
            Name             = 'demo'
            SID              = 'S-1-5-21-1000000001-1000000002-1000000003-1001'
            Enabled          = $true
            LastLogon        = (Get-Date).AddDays(-3)
            PasswordExpires  = (Get-Date).AddDays(20)
            PasswordRequired = $false
            PasswordLastSet  = (Get-Date).AddDays(-30)
        }

        $report = @(Get-LocalAccountReport -InputObject @($user) -AdminMember @())

        @($report[0].PSObject.Properties.Name) | Should -Be @(
            'Nombre', 'SID', 'Habilitada', 'UltimoInicio', 'DiasSinUso',
            'PasswordNuncaCaduca', 'PasswordNoRequerida', 'UltimoCambioPassword',
            'DiasPassword', 'EsAdmin'
        )
        $report[0].PasswordNoRequerida | Should -BeTrue
        $report[0].PasswordNuncaCaduca | Should -BeFalse
    }

    It 'devuelve DiasSinUso nulo si la cuenta nunca ha iniciado sesión' {
        $user = [pscustomobject]@{
            Name             = 'nunca'
            SID              = 'S-1-5-21-1000000001-1000000002-1000000003-1001'
            Enabled          = $true
            LastLogon        = $null
            PasswordExpires  = $null
            PasswordRequired = $true
            PasswordLastSet  = $null
        }

        $report = @(Get-LocalAccountReport -InputObject @($user) -AdminMember @())

        $report[0].DiasSinUso | Should -BeNullOrEmpty
        $report[0].DiasPassword | Should -BeNullOrEmpty
    }

    It 'devuelve los miembros leídos o inyectados en la referencia' {
        $member = [pscustomobject]@{ Nombre = 'PC-DEMO\uno'; SID = 'S-1-5-21-1000000001-1000000002-1000000003-1001' }
        $adminRef = [ref]$null

        $null = Get-LocalAccountReport -InputObject @() -AdminMember @($member) -AdminMemberResult $adminRef

        @($adminRef.Value).Count | Should -Be 1
        ($adminRef.Value)[0].Nombre | Should -Be 'PC-DEMO\uno'
    }

    It 'lee el sistema real sin lanzar excepciones' {
        { Get-LocalAccountReport -WarningAction SilentlyContinue } | Should -Not -Throw
    }

    It 'lee el sistema real y devuelve objetos con las columnas esperadas' {
        $report = @(Get-LocalAccountReport -WarningAction SilentlyContinue)

        foreach ($row in $report) {
            $row.SID | Should -Not -BeNullOrEmpty
            @($row.PSObject.Properties.Name).Count | Should -Be 10
        }
    }
}

Describe 'Test-LocalAccounts.ps1' {

    It 'genera JSON, HTML y CSV y termina con un código de salida válido' {
        $scriptPath = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'Test-LocalAccounts.ps1'
        $outputDir = Join-Path -Path $TestDrive -ChildPath 'salida'
        $hostExe = (Get-Process -Id $PID).Path

        $null = & $hostExe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -OutputPath $outputDir

        $LASTEXITCODE | Should -BeIn @(0, 1, 2)

        $jsonPath = Join-Path -Path $outputDir -ChildPath 'Test-LocalAccounts.json'
        $htmlPath = Join-Path -Path $outputDir -ChildPath 'report.html'
        $csvPath = Join-Path -Path $outputDir -ChildPath 'accounts.csv'

        Test-Path -LiteralPath $jsonPath | Should -BeTrue
        Test-Path -LiteralPath $htmlPath | Should -BeTrue
        Test-Path -LiteralPath $csvPath | Should -BeTrue

        $json = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
        $json.Equipo | Should -Not -BeNullOrEmpty
        $json.SoloLectura | Should -BeTrue
        $json.Resumen.PSObject.Properties.Name | Should -Contain 'Alta'

        $html = Get-Content -LiteralPath $htmlPath -Raw
        $html | Should -Match 'prefers-color-scheme'
        $html | Should -Not -Match '<script'
        $html | Should -Match 'Cuentas locales'

        $csv = @(Import-Csv -LiteralPath $csvPath)
        $csv.Count | Should -BeGreaterThan 0
        $csv[0].PSObject.Properties.Name | Should -Contain 'SID'
    }
}
