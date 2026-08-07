# Parsing helpers for validate-service-connectivity.ps1 (#146).
#
# These are the parts of the connectivity validator that turn text into a
# verdict: the -Services specification, the JDBC URL a running pod is configured
# with, and the marker lines the debug pod's probe loop emits. They are kept
# apart from the kubectl helpers in PulseStreamKubernetes.psm1 because none of
# them talk to a cluster - which is what makes them coverable by
# scripts\tests\test-service-connectivity-parsing.ps1 on a machine that has no
# cluster to point at.

# curl's exit code is the only thing that separates "the Service DNS name did
# not resolve" from "it resolved and nothing answered on the port", which is the
# first thing a reader of a failed run needs to know. The vocabulary lives here
# rather than inside a failure message so both the script and its tests name
# these the same way.
$script:CurlExitCodeMeanings = @{
    6  = "DNS resolution failed"
    7  = "connection refused or host unreachable"
    22 = "HTTP error response"
    28 = "operation timed out"
    52 = "empty reply from server"
    56 = "failure receiving data"
}

function Get-CurlExitCodeMeaning {
    param([Parameter(Mandatory)] [int] $ExitCode)

    if ($script:CurlExitCodeMeanings.ContainsKey($ExitCode)) {
        return $script:CurlExitCodeMeanings[$ExitCode]
    }

    # Unmapped codes are still reported rather than swallowed: the number is
    # enough to look up, and inventing a meaning for it would be worse.
    return "curl exited $ExitCode"
}

# Parses the "<name>:<port>" entries of -Services. A malformed entry is a caller
# error, so it throws here instead of producing a nonsense DNS name that only
# fails much later inside a debug pod.
function ConvertTo-ServiceTarget {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Specification)

    return @($Specification | ForEach-Object {
        $entry = $_
        $parts = $entry -split ":"

        if (@($parts).Count -ne 2 -or [string]::IsNullOrWhiteSpace($parts[0]) -or $parts[1] -notmatch "^\d+$") {
            throw "Invalid -Services entry '$entry'; expected '<name>:<port>'."
        }

        # Range-checked as well as shape-checked: "svc:0" and "svc:70000" are
        # digits but cannot be a TCP port, and would otherwise be carried all
        # the way into a URL.
        $port = [int] $parts[1]
        if ($port -lt 1 -or $port -gt 65535) {
            throw "Invalid -Services entry '$entry'; port $port is outside 1-65535."
        }

        [pscustomobject]@{ Name = $parts[0]; Port = $port }
    })
}

# Pulls the host and port out of the JDBC URL a service is configured with, so
# the endpoint the process actually runs with can be probed.
#
# The host is either a DNS name / IPv4 literal, or an IPv6 literal in brackets.
# The port is optional in JDBC and defaults to 5432, which is what the driver
# the service runs with would connect to, so a portless URL is valid rather than
# unparseable. IsValid is returned instead of throwing: the caller reports it
# through the same Confirm-Condition as every other check.
function Get-PostgresEndpoint {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $JdbcUrl)

    $match = [regex]::Match(
        $JdbcUrl,
        "^jdbc:postgresql://(?:\[(?<v6>[^\]]+)\]|(?<host>[^:/?]+))(?::(?<port>\d+))?(?:[/?]|$)")

    if (-not $match.Success) {
        return [pscustomobject]@{ IsValid = $false; HostName = $null; Port = $null }
    }

    $hostName = if ($match.Groups["v6"].Success) { $match.Groups["v6"].Value } else { $match.Groups["host"].Value }
    $port = if ($match.Groups["port"].Success) { [int] $match.Groups["port"].Value } else { 5432 }

    return [pscustomobject]@{ IsValid = $true; HostName = $hostName; Port = $port }
}

# Turns the debug pod's log into the three lists the checks assert on:
#
#   Reached  - services that answered (SVC-OK), with the body they answered with
#   Failures - services that did not (SVC-FAIL), with curl's verdict spelled out
#   NotUp    - services that answered on their port without reporting readiness,
#              i.e. something may be serving the port that is not the service
#
# Values are trimmed because the log arrives with CRLF line endings on Windows
# and .NET's `(?m)$` anchors before the \n, leaving the \r on the last field.
function Get-ServiceProbeResult {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Output)

    $failures = @([regex]::Matches($Output, "(?m)^SVC-FAIL\s+(?<rest>.*)$") | ForEach-Object {
        $rest = $_.Groups["rest"].Value.Trim()
        $fields = [regex]::Match($rest, "^(?<service>\S+)\s+(?<url>\S+)\s+rc=(?<rc>\d+)\s*(?<detail>.*)$")

        if (-not $fields.Success) {
            # A marker the probe loop did not format as expected still counts as
            # a failure; reporting the raw line beats dropping it silently.
            return [pscustomobject]@{ Name = $null; Url = $null; ExitCode = $null; Description = $rest }
        }

        $exitCode = [int] $fields.Groups["rc"].Value
        $detail = $fields.Groups["detail"].Value.Trim()
        $description = "$($fields.Groups['service'].Value) at $($fields.Groups['url'].Value): $(Get-CurlExitCodeMeaning -ExitCode $exitCode) (curl exit $exitCode)"
        if ($detail) {
            $description = "$description - $detail"
        }

        [pscustomobject]@{
            Name        = $fields.Groups["service"].Value
            Url         = $fields.Groups["url"].Value
            ExitCode    = $exitCode
            Description = $description
        }
    })

    $reached = @([regex]::Matches($Output, "(?m)^SVC-OK\s+(?<service>\S+)\s+(?<url>\S+)\s+(?<body>.*)$") | ForEach-Object {
        [pscustomobject]@{
            Name = $_.Groups["service"].Value.Trim()
            Url  = $_.Groups["url"].Value.Trim()
            Body = $_.Groups["body"].Value.Trim()
        }
    })

    return [pscustomobject]@{
        Reached  = $reached
        Failures = $failures
        NotUp    = @($reached | Where-Object { $_.Body -notmatch '"status"\s*:\s*"UP"' })
    }
}

Export-ModuleMember -Function Get-CurlExitCodeMeaning, ConvertTo-ServiceTarget, Get-PostgresEndpoint, Get-ServiceProbeResult
