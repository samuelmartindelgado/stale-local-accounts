# stale-local-accounts

[![CI](https://github.com/samuelmartindelgado/stale-local-accounts/actions/workflows/ci.yml/badge.svg)](https://github.com/samuelmartindelgado/stale-local-accounts/actions/workflows/ci.yml)

Revisión **de solo lectura** de las cuentas y grupos locales de un equipo Windows: cuentas olvidadas, contraseñas que nunca caducan y administradores de más.

Después de instalar un equipo casi nadie vuelve a mirar sus cuentas locales. Quedan cuentas de prueba habilitadas, el Administrador integrado activo, contraseñas que no caducan nunca y usuarios que siguen en el grupo Administradores años después de dejar esa responsabilidad. Este script lo revisa en segundos, sin tocar nada y sin leer contraseñas.

## Qué revisa

| Comprobación | Estado | Qué busca |
| --- | --- | --- |
| Contraseña no requerida | Aviso | Cuenta habilitada con el indicador PASSWD_NOTREQD: podría tener la contraseña vacía aunque la directiva exija una. |
| Administrador integrado | Alta | Cuenta integrada de Administrador (SID termina en `-500`) habilitada. |
| Invitado integrado | Alta | Cuenta integrada de Invitado (SID termina en `-501`) habilitada. |
| Cuentas sin uso | Aviso | Cuenta habilitada sin iniciar sesión en más de `StaleDays` días o que nunca lo ha hecho. Se ignoran `DefaultAccount` (`-503`) y `WDAGUtilityAccount` (`-504`). |
| Contraseña de administrador sin caducidad | Aviso | Cuenta administradora habilitada con contraseña configurada para no caducar. |
| Contraseña de administrador antigua | Aviso | Contraseña de una cuenta administradora habilitada sin cambiar en más de 365 días. |
| Miembros de Administradores | Aviso | Más de 2 miembros (usuarios y grupos) en el grupo Administradores. |
| Miembros huérfanos | Aviso | Miembro de Administradores con un SID que ya no se puede resolver (cuenta eliminada). |

Las cuentas y los grupos se comparan **por SID, nunca por nombre**, así que funciona igual en Windows en español, inglés o cualquier otro idioma. Cuando una comprobación no encuentra nada, aparece una fila `OK` para dejarlo claro.

## Requisitos

- Windows 10, Windows 11 o Windows Server.
- Windows PowerShell 5.1 o PowerShell 7.
- Ningún módulo externo: usa `Microsoft.PowerShell.LocalAccounts` y, si falla, ADSI.

No hace falta ser administrador. Si el equipo no permite leer algo (por ejemplo, los miembros del grupo Administradores), esa parte se salta con un aviso en la sección de notas y el resto del informe se genera igualmente.

## Uso

```powershell
# Revisión por defecto: avisa a partir de 90 días sin uso
.\Test-LocalAccounts.ps1

# Cambiar el umbral de días sin uso
.\Test-LocalAccounts.ps1 -StaleDays 60

# Guardar los informes en una carpeta
.\Test-LocalAccounts.ps1 -StaleDays 60 -OutputPath .\salida\PC-DEMO

# Consultar el código de salida (0 OK, 1 avisos, 2 altas)
$LASTEXITCODE
```

Si la ejecución está bloqueada por la política de scripts:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-LocalAccounts.ps1
```

### Ficheros que genera `-OutputPath`

| Fichero | Contenido |
| --- | --- |
| `Test-LocalAccounts.json` | Equipo, fecha, notas, recuento, hallazgos y cuentas en formato JSON. |
| `report.html` | Informe autónomo con CSS incrustado, modo oscuro automático (`prefers-color-scheme`), filas en rojo/ámbar y textos escapados. Sin JavaScript externo. |
| `accounts.csv` | Una fila por cuenta con las diez columnas del informe. Los valores que empiezan por `=`, `+`, `-`, `@`, tabulador o retorno de carro se neutralizan con una comilla simple para evitar inyección de fórmulas. |

### Códigos de salida

| Código | Significado |
| --- | --- |
| `0` | Todo OK. |
| `1` | Algún aviso (o no se pudo completar la lectura). |
| `2` | Alguna comprobación en estado Alta. |

## Ejemplo de salida (datos ficticios, equipo `PC-DEMO`)

```text
Revisión de cuentas locales (solo lectura)
Equipo: PC-DEMO   Fecha: 2026-05-12 09:14   Límite sin uso: 90 días
Cuentas locales: 5   Miembros de Administradores: 3

[OK] CONTRASEÑA NO REQUERIDA: Todas las cuentas habilitadas exigen contraseña.
[ALTA] ADMINISTRADOR INTEGRADO: La cuenta integrada de Administrador 'Administrador' (SID -500) está habilitada.
        Valor: Administrador (S-1-5-21-1111111111-2222222222-3333333333-500)
        Recomendado: Mantener deshabilitada la cuenta integrada de Administrador.
        Solución (ejemplo, no ejecutada): Disable-LocalUser -Name 'Administrador'
[OK] INVITADO INTEGRADO: La cuenta integrada de Invitado no está habilitada.
[AVISO] CUENTAS SIN USO: La cuenta habilitada 'soporte' nunca ha iniciado sesión.
        Valor: soporte (S-1-5-21-1111111111-2222222222-3333333333-1002)
        Recomendado: Deshabilitar o eliminar la cuenta si ya no se usa.
        Solución (ejemplo, no ejecutada): Disable-LocalUser -Name 'soporte'
[AVISO] CONTRASEÑA DE ADMINISTRADOR SIN CADUCIDAD: La cuenta administradora habilitada 'ana' tiene la contraseña configurada para no caducar nunca.
        Valor: ana (S-1-5-21-1111111111-2222222222-3333333333-1001)
        Recomendado: Hacer que la contraseña caduque y rotarla periódicamente.
        Solución (ejemplo, no ejecutada): Set-LocalUser -Name 'ana' -PasswordNeverExpires $false
[OK] CONTRASEÑA DE ADMINISTRADOR ANTIGUA: Ninguna cuenta administradora habilitada lleva más de 365 días sin cambiar la contraseña.
[AVISO] MIEMBROS DE ADMINISTRADORES: El grupo Administradores tiene 3 miembros; se recomiendan 2 o menos.
        Valor: PC-DEMO\Administrador (...); PC-DEMO\ana (...); PC-DEMO\soporte (...)
        Recomendado: Quitar del grupo los miembros que no necesiten privilegios de administrador.
        Solución (ejemplo, no ejecutada): Remove-LocalGroupMember -SID S-1-5-32-544 -Member '<miembro>'
[OK] MIEMBROS HUÉRFANOS: No hay miembros huérfanos en el grupo Administradores.

Resumen: 4 OK, 3 avisos, 1 alta
Archivos generados:
  - C:\Users\demo\salida\PC-DEMO\Test-LocalAccounts.json
  - C:\Users\demo\salida\PC-DEMO\report.html
  - C:\Users\demo\salida\PC-DEMO\accounts.csv
Solo lectura: no se ha cambiado ninguna cuenta, contraseña ni grupo.
```

## Cómo corregir cada hallazgo

Los comandos siguientes son ejemplos. El script **nunca** los ejecuta: solo los muestra para que los revises y decidas.

| Hallazgo | Qué hacer |
| --- | --- |
| Contraseña no requerida | `Set-LocalUser -Name 'cuenta' -PasswordRequired $true` o deshabilitarla si no se usa. |
| Administrador integrado habilitado | `Disable-LocalUser -Name 'Administrador'` (el nombre puede variar según el idioma; usa el que muestra el informe). |
| Invitado habilitado | `Disable-LocalUser -Name 'Invitado'`. |
| Cuenta sin uso | Deshabilitar primero y, tras comprobar que nadie la necesita, eliminar: `Disable-LocalUser -Name 'cuenta'` y después `Remove-LocalUser -Name 'cuenta'`. |
| Contraseña de administrador sin caducidad | `Set-LocalUser -Name 'cuenta' -PasswordNeverExpires $false`. |
| Contraseña de administrador antigua | Cambiarla (`net user 'cuenta' *` pide la nueva) y revisar si la cuenta sigue siendo necesaria. |
| Más de 2 administradores | Quitar los que no necesiten el privilegio: `Remove-LocalGroupMember -SID S-1-5-32-544 -Member 'cuenta'`. |
| Miembro huérfano | Quitar el SID sin resolver: `Remove-LocalGroupMember -SID S-1-5-32-544 -Member '<SID>'`. |

Antes de deshabilitar o eliminar una cuenta, comprueba que no sea la cuenta con la que se inicia sesión nadie del equipo y que no la use ningún servicio. Para revisar el estado actual:

```powershell
Get-LocalUser
Get-LocalGroupMember -SID S-1-5-32-544
```

## Solo lectura y alcance

- **No cambia nada:** no habilita, deshabilita, renombra, elimina ni modifica cuentas, contraseñas o grupos. Las soluciones son texto de ejemplo.
- **No lee contraseñas:** solo consulta si la cuenta las requiere, si caducan y cuándo se cambiaron por última vez.
- **Solo cuentas locales:** revisa las cuentas locales del equipo y los miembros locales del grupo Administradores. **No revisa cuentas de dominio**, ni sus contraseñas, ni su último inicio de sesión, ni grupos de Active Directory. Si un equipo está unido a un dominio, las cuentas de dominio que pertenezcan a Administradores se listan como miembros, pero no se analizan.
- No requiere conexión a Internet ni módulos de terceros.
- Las cuentas y grupos se identifican por SID, por lo que el idioma de Windows no altera el resultado.

## Pruebas

```powershell
# Pester 5.5 o superior
Invoke-Pester ./tests -Output Detailed

# En Windows PowerShell 5.1
powershell -NoProfile -Command "Invoke-Pester ./tests -Output Detailed"
```

Las pruebas usan datos simulados para la lógica de decisión, comprueban que la lectura real del equipo no lanza excepciones y ejecutan el script en un proceso hijo para verificar que genera JSON, HTML y CSV.

La integración continua se ejecuta en `windows-latest`: PSScriptAnalyzer (falla solo con errores), Pester en PowerShell 7 y en Windows PowerShell 5.1, y una ejecución real en cada versión.

## Licencia

MIT. Consulta [LICENSE](LICENSE).

---

## English summary

Read-only audit of local Windows accounts and the local Administrators group. It flags enabled accounts without a password, the built-in Administrator (`-500`) and Guest (`-501`) accounts when enabled, accounts unused for more than `-StaleDays` days (or never logged in, ignoring `-503`/`-504`), administrator passwords that never expire or are older than 365 days, more than two Administrators members, and orphaned SIDs in that group.

It never reads or displays passwords and never changes anything on the machine: remediation commands are printed as examples only. Accounts and groups are matched by SID, so it works on any Windows display language.

Usage: `.\Test-LocalAccounts.ps1 [-StaleDays 90] [-OutputPath .\salida]`. With `-OutputPath` it writes `Test-LocalAccounts.json`, a self-contained dark-mode `report.html`, and `accounts.csv` (CSV formula injection guarded). Exit codes: `0` all OK, `1` warnings, `2` high-severity findings.

Local accounts only, not domain accounts. MIT licensed.
