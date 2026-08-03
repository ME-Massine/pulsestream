# Regression coverage for the HTTP helpers in lib\PulseStreamValidation.psm1.
#
# Both cases here are ways Invoke-WebRequest declines to hand back a plain
# result, and both broke the default path of
# validate-ingestion-external-access.ps1:
#
# 1. A non-2xx response is raised as a terminating error, and the exception type
#    differs by edition - System.Net.WebException on Windows PowerShell 5.1,
#    Microsoft.PowerShell.Commands.HttpResponseException on PowerShell 7. Code
#    catching one concrete type passes on the edition it was written against and
#    aborts on the other, so the expected 400 from /api/v1/events never gets
#    recorded. Invoke-HttpStatus covers this.
# 2. The response body comes back as bytes rather than a string whenever the
#    Content-Type is not one Invoke-WebRequest recognizes as text, which is the
#    case for Actuator's `application/vnd.spring-boot.actuator.v3+json` on
#    /readyz. Invoke-TextGet covers this.
#
# Because (1) is edition-specific, these cases are only meaningful run on both:
#
#   powershell -File scripts\tests\test-http-helpers.ps1   # Windows PowerShell 5.1
#   pwsh -File scripts/tests/test-http-helpers.ps1         # PowerShell 7
#
# The responder below is a raw TCP socket rather than HttpListener because
# HttpListener needs a URL ACL reservation (or an elevated shell) for its
# prefixes, and rather than a real cluster because the handling being tested is
# in the client, not the server.
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "..\lib\PulseStreamValidation.psm1") -Force

$script:Failures = 0

function Assert-Equal {
    param(
        [Parameter(Mandatory)] [string] $What,
        $Expected,
        $Actual
    )

    if ($Expected -eq $Actual) {
        Write-Host "[ok] $What -> $Actual"
        return
    }

    Write-Host "[fail] $What -> expected '$Expected', got '$Actual'"
    $script:Failures++
}

function Assert-Match {
    param(
        [Parameter(Mandatory)] [string] $What,
        [Parameter(Mandatory)] [string] $Pattern,
        [string] $Actual
    )

    if ($Actual -match $Pattern) {
        Write-Host "[ok] $What -> matched '$Pattern'"
        return
    }

    Write-Host "[fail] $What -> '$Actual' did not match '$Pattern'"
    $script:Failures++
}

# Serves exactly one request with the given status line, then closes.
#
# The listener is bound in this process (port 0, so the OS picks a free port)
# and handed to a runspace rather than to Start-Job: a background job is a
# separate process, which would mean choosing a port here, releasing it, and
# hoping nothing else took it before the job bound it again.
function Start-StubResponder {
    param(
        [Parameter(Mandatory)] [string] $StatusLine,
        [string] $Body = '{"stub":true}',
        [string] $ContentType = "application/json"
    )

    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()

    $runspace = [PowerShell]::Create()
    $null = $runspace.AddScript({
        param($Listener, $StatusLine, $Body, $ContentType)

        $client = $Listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $stream.ReadTimeout = 5000

            # Read what the client has sent so far. The response is written
            # regardless of how much arrived: the point of the stub is the
            # status line, and a real server's parsing is not under test.
            $buffer = New-Object byte[] 8192
            $null = $stream.Read($buffer, 0, $buffer.Length)

            $response = "HTTP/1.1 $StatusLine`r`n" +
                "Content-Type: $ContentType`r`n" +
                "Content-Length: $($Body.Length)`r`n" +
                "Connection: close`r`n`r`n$Body"

            $bytes = [System.Text.Encoding]::ASCII.GetBytes($response)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
        } finally {
            $client.Close()
        }
    })

    $null = $runspace.AddArgument($listener)
    $null = $runspace.AddArgument($StatusLine)
    $null = $runspace.AddArgument($Body)
    $null = $runspace.AddArgument($ContentType)

    return [pscustomobject]@{
        Uri      = "http://127.0.0.1:$($listener.LocalEndpoint.Port)/api/v1/events"
        Listener = $listener
        Runspace = $runspace
        Handle   = $runspace.BeginInvoke()
    }
}

function Stop-StubResponder {
    param([Parameter(Mandatory)] $Responder)

    try { $Responder.Runspace.Stop() } catch { }
    $Responder.Runspace.Dispose()
    $Responder.Listener.Stop()
}

# --- A 400 is a status to return, not an error to raise ----------------------
# The default routing check in validate-ingestion-external-access.ps1 depends on
# this exact case: POST an empty body, expect 400 back as a value.
$responder = Start-StubResponder -StatusLine "400 Bad Request"
try {
    $status = Invoke-HttpStatus -Uri $responder.Uri -Method Post -Body "{}" -ContentType "application/json"
    Assert-Equal -What "POST returning 400 on $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)" -Expected 400 -Actual $status
} catch {
    Write-Host "[fail] POST returning 400 threw $($_.Exception.GetType().FullName): $($_.Exception.Message)"
    $script:Failures++
} finally {
    Stop-StubResponder -Responder $responder
}

# --- A 2xx still comes back the ordinary way ---------------------------------
$responder = Start-StubResponder -StatusLine "202 Accepted"
try {
    $status = Invoke-HttpStatus -Uri $responder.Uri -Method Post -Body "{}" -ContentType "application/json"
    Assert-Equal -What "POST returning 202" -Expected 202 -Actual $status
} finally {
    Stop-StubResponder -Responder $responder
}

$responder = Start-StubResponder -StatusLine "200 OK"
try {
    $status = Invoke-HttpStatus -Uri $responder.Uri
    Assert-Equal -What "GET returning 200" -Expected 200 -Actual $status
} finally {
    Stop-StubResponder -Responder $responder
}

# --- A wrong status is reported, not swallowed -------------------------------
# 404 is the failure the routing check exists to catch (the node port reaching
# some other application), so it has to arrive as a comparable status.
$responder = Start-StubResponder -StatusLine "404 Not Found"
try {
    $status = Invoke-HttpStatus -Uri $responder.Uri -Method Post -Body "{}" -ContentType "application/json"
    Assert-Equal -What "POST returning 404" -Expected 404 -Actual $status
} finally {
    Stop-StubResponder -Responder $responder
}

# --- No response at all is still a failure -----------------------------------
# Catching every exception must not turn an unreachable address into a status.
# The port is bound and released so nothing is listening on it.
$probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$probe.Start()
$deadPort = $probe.LocalEndpoint.Port
$probe.Stop()

$message = $null
try {
    $status = Invoke-HttpStatus -Uri "http://127.0.0.1:$deadPort/api/v1/events" -Method Post -Body "{}" -TimeoutSec 5
    Write-Host "[fail] request to a closed port returned $status instead of throwing"
    $script:Failures++
} catch {
    $message = $_.Exception.Message
}

if ($null -ne $message) {
    Assert-Match -What "closed port reports no response" -Pattern "failed before a response was received" -Actual $message
}

# --- Invoke-TextGet returns text for Actuator's vendor content type ----------
# /readyz answers with `application/vnd.spring-boot.actuator.v3+json`, which
# Invoke-WebRequest does not recognize as a text type, so .Content is a byte
# array. Returning it unchanged enumerates bytes into the caller's pipeline and
# the readiness `-match` in validate-ingestion-external-access.ps1 then yields an
# array instead of a Boolean, which fails to bind to Confirm-Condition.
$responder = Start-StubResponder `
    -StatusLine "200 OK" `
    -Body '{"status":"UP"}' `
    -ContentType "application/vnd.spring-boot.actuator.v3+json"
try {
    $readyBody = Invoke-TextGet -Uri $responder.Uri
    Assert-Equal -What "readiness body is a single string" -Expected 1 -Actual @($readyBody).Count
    Assert-Equal -What "readiness body content" -Expected '{"status":"UP"}' -Actual $readyBody
    Assert-Equal `
        -What "readiness -match yields a Boolean" `
        -Expected "System.Boolean" `
        -Actual ($readyBody -match '"status"\s*:\s*"UP"').GetType().FullName
} finally {
    Stop-StubResponder -Responder $responder
}

if ($script:Failures -gt 0) {
    throw "$script:Failures HTTP helper check(s) failed."
}

Write-Host "[ok] HTTP helpers behave consistently on $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)."
