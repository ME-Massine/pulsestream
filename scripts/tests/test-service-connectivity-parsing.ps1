# Regression coverage for the parsing helpers in lib\PulseStreamConnectivity.psm1,
# i.e. everything validate-service-connectivity.ps1 (#146) decides from text
# rather than from the cluster:
#
# 1. The -Services specification, where a malformed entry must fail at the
#    caller instead of becoming a DNS name that only fails inside a debug pod.
# 2. The JDBC URL read out of the running telemetry-processor pod. Its host and
#    port are what the live Postgres probe connects to, so a portless URL
#    (5432 by default, as the driver does) or an IPv6 literal has to parse
#    rather than fail the database leg for the wrong reason.
# 3. The SVC-OK / SVC-FAIL markers the debug pod's probe loop emits. These carry
#    the verdict for every Service, including curl's exit code - the only thing
#    that separates an unresolved DNS name from a refused connection.
#
# None of this needs a cluster, which is the point: these are the checks that
# can be run anywhere, on both editions the scripts support.
#
#   powershell -File scripts\tests\test-service-connectivity-parsing.ps1
#   pwsh -File scripts/tests/test-service-connectivity-parsing.ps1
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "..\lib\PulseStreamConnectivity.psm1") -Force

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

function Assert-Throws {
    param(
        [Parameter(Mandatory)] [string] $What,
        [Parameter(Mandatory)] [scriptblock] $Operation
    )

    try {
        & $Operation
    } catch {
        Write-Host "[ok] $What -> rejected: $($_.Exception.Message)"
        return
    }

    Write-Host "[fail] $What -> was accepted instead of rejected"
    $script:Failures++
}

# --- The -Services specification ---------------------------------------------
$targets = ConvertTo-ServiceTarget -Specification @("ingestion-service:8081", "query-service:8083")
Assert-Equal -What "two entries parse into two targets" -Expected 2 -Actual @($targets).Count
Assert-Equal -What "first target name" -Expected "ingestion-service" -Actual $targets[0].Name
Assert-Equal -What "second target port is an int" -Expected 8083 -Actual $targets[1].Port
Assert-Equal -What "port type" -Expected "System.Int32" -Actual $targets[1].Port.GetType().FullName

Assert-Throws -What "entry without a port" -Operation { ConvertTo-ServiceTarget -Specification @("ingestion-service") }
Assert-Throws -What "entry with a non-numeric port" -Operation { ConvertTo-ServiceTarget -Specification @("ingestion-service:http") }
Assert-Throws -What "entry with an empty name" -Operation { ConvertTo-ServiceTarget -Specification @(":8081") }
Assert-Throws -What "entry with two colons" -Operation { ConvertTo-ServiceTarget -Specification @("a:b:8081") }
Assert-Throws -What "port 0" -Operation { ConvertTo-ServiceTarget -Specification @("ingestion-service:0") }
Assert-Throws -What "port above 65535" -Operation { ConvertTo-ServiceTarget -Specification @("ingestion-service:70000") }

# --- The JDBC URL the processor pod runs with --------------------------------
# The canonical value from telemetry-processor/configmap.yaml.
$endpoint = Get-PostgresEndpoint -JdbcUrl "jdbc:postgresql://postgres:5432/pulsestream"
Assert-Equal -What "configured URL is valid" -Expected $true -Actual $endpoint.IsValid
Assert-Equal -What "configured host" -Expected "postgres" -Actual $endpoint.HostName
Assert-Equal -What "configured port" -Expected 5432 -Actual $endpoint.Port

# The port is optional in JDBC; the driver the service runs with would connect
# to 5432, so the probe has to target the same.
$endpoint = Get-PostgresEndpoint -JdbcUrl "jdbc:postgresql://postgres/pulsestream"
Assert-Equal -What "portless URL is valid" -Expected $true -Actual $endpoint.IsValid
Assert-Equal -What "portless URL host" -Expected "postgres" -Actual $endpoint.HostName
Assert-Equal -What "portless URL defaults to the driver's port" -Expected 5432 -Actual $endpoint.Port

$endpoint = Get-PostgresEndpoint -JdbcUrl "jdbc:postgresql://postgres.data.svc.cluster.local:5432/pulsestream?sslmode=require"
Assert-Equal -What "FQDN with a query string host" -Expected "postgres.data.svc.cluster.local" -Actual $endpoint.HostName
Assert-Equal -What "FQDN with a query string port" -Expected 5432 -Actual $endpoint.Port

$endpoint = Get-PostgresEndpoint -JdbcUrl "jdbc:postgresql://[fd00::1]:5433/pulsestream"
Assert-Equal -What "IPv6 literal host is unbracketed" -Expected "fd00::1" -Actual $endpoint.HostName
Assert-Equal -What "IPv6 literal port" -Expected 5433 -Actual $endpoint.Port

$endpoint = Get-PostgresEndpoint -JdbcUrl "jdbc:postgresql://10.96.0.20:5432/pulsestream"
Assert-Equal -What "IPv4 literal host" -Expected "10.96.0.20" -Actual $endpoint.HostName

# A URL the probe cannot act on must be reported, not guessed at: connecting to
# the wrong host would either fail confusingly or pass against something else.
foreach ($invalid in @("", "postgres:5432", "jdbc:mysql://postgres:5432/pulsestream", "not a url")) {
    Assert-Equal -What "invalid URL '$invalid' is rejected" -Expected $false -Actual (Get-PostgresEndpoint -JdbcUrl $invalid).IsValid
}

# --- The debug pod's probe markers -------------------------------------------
# Exactly the shape the probe loop writes, with the CRLF line endings the log
# arrives with on Windows: .NET anchors `(?m)$` before the \n, so an untrimmed
# parse leaves the \r on the last field of every line.
$probeOutput = @(
    'SVC-OK ingestion-service http://ingestion-service:8081/readyz {"status":"UP"}',
    'SVC-OK query-service http://query-service:8083/readyz {"status":"UP"}',
    'SVC-OK telemetry-processor http://telemetry-processor:8082/readyz {"status":"UP"}'
) -join "`r`n"

$result = Get-ServiceProbeResult -Output $probeOutput
Assert-Equal -What "all three Services counted as reached" -Expected 3 -Actual @($result.Reached).Count
Assert-Equal -What "no failures on a clean run" -Expected 0 -Actual @($result.Failures).Count
Assert-Equal -What "no not-UP Services on a clean run" -Expected 0 -Actual @($result.NotUp).Count
Assert-Equal -What "trailing CR is stripped from the body" -Expected '{"status":"UP"}' -Actual $result.Reached[1].Body
Assert-Equal -What "reached Service name" -Expected "query-service" -Actual $result.Reached[1].Name

# A DNS failure and a refused connection are the two outcomes the operator has
# to be able to tell apart, and curl's exit code is the only signal for it.
$probeOutput = @(
    'SVC-OK ingestion-service http://ingestion-service:8081/readyz {"status":"UP"}',
    'SVC-FAIL query-service http://query-service:8083/readyz rc=6 curl: (6) Could not resolve host',
    'SVC-FAIL telemetry-processor http://telemetry-processor:8082/readyz rc=7 curl: (7) Connection refused'
) -join "`n"

$result = Get-ServiceProbeResult -Output $probeOutput
Assert-Equal -What "one Service reached" -Expected 1 -Actual @($result.Reached).Count
Assert-Equal -What "two Services failed" -Expected 2 -Actual @($result.Failures).Count
Assert-Equal -What "failed Service name" -Expected "query-service" -Actual $result.Failures[0].Name
Assert-Equal -What "curl exit code is parsed as a number" -Expected 6 -Actual $result.Failures[0].ExitCode
Assert-Match -What "rc=6 is spelled out as DNS" -Pattern "DNS resolution failed" -Actual $result.Failures[0].Description
Assert-Match -What "rc=7 is spelled out as refused" -Pattern "connection refused" -Actual $result.Failures[1].Description
Assert-Match -What "curl's own stderr is kept" -Pattern "Could not resolve host" -Actual $result.Failures[0].Description

# -f makes a non-2xx a curl failure, so an HTTP error arrives as rc=22 rather
# than as a body to inspect.
$result = Get-ServiceProbeResult -Output 'SVC-FAIL query-service http://query-service:8083/readyz rc=22 '
Assert-Match -What "rc=22 is spelled out as an HTTP error" -Pattern "HTTP error response" -Actual $result.Failures[0].Description
Assert-Match -What "a failure with no stderr still names the Service" -Pattern "query-service" -Actual $result.Failures[0].Description

Assert-Equal -What "an unmapped exit code is still reported" -Expected "curl exited 35" -Actual (Get-CurlExitCodeMeaning -ExitCode 35)

# Something answering 200 on the port that is not the service: reachable, but
# not the readiness state the check is looking for.
$probeOutput = @(
    'SVC-OK ingestion-service http://ingestion-service:8081/readyz {"status":"UP"}',
    'SVC-OK query-service http://query-service:8083/readyz <html>nginx</html>'
) -join "`n"

$result = Get-ServiceProbeResult -Output $probeOutput
Assert-Equal -What "both Services answered" -Expected 2 -Actual @($result.Reached).Count
Assert-Equal -What "one answered without reporting UP" -Expected 1 -Actual @($result.NotUp).Count
Assert-Equal -What "the not-UP Service is named" -Expected "query-service" -Actual $result.NotUp[0].Name

# A DOWN body is a 503 in practice, so curl -f fails it - but if it ever arrives
# as a 200 it must not be read as UP.
$result = Get-ServiceProbeResult -Output 'SVC-OK query-service http://query-service:8083/readyz {"status":"DOWN"}'
Assert-Equal -What "a DOWN body is not UP" -Expected 1 -Actual @($result.NotUp).Count

# No output at all is the pod having produced nothing; it must not read as a
# clean run, which the count check in the script catches via Reached being 0.
$result = Get-ServiceProbeResult -Output ""
Assert-Equal -What "empty output reaches nothing" -Expected 0 -Actual @($result.Reached).Count
Assert-Equal -What "empty output has no failures to report" -Expected 0 -Actual @($result.Failures).Count

# A marker the loop did not format as expected is still surfaced rather than
# dropped, which would otherwise turn an unreachable Service into a pass.
$result = Get-ServiceProbeResult -Output 'SVC-FAIL query-service'
Assert-Equal -What "a malformed failure marker still counts" -Expected 1 -Actual @($result.Failures).Count
Assert-Match -What "a malformed failure marker keeps its raw text" -Pattern "query-service" -Actual $result.Failures[0].Description

if ($script:Failures -gt 0) {
    throw "$script:Failures connectivity parsing check(s) failed."
}

Write-Host "[ok] Connectivity parsing helpers behave consistently on $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)."
