# Minimal YAML reader for the committed Kubernetes manifests.
#
# The structural tests need a manifest as an object graph without a cluster.
# `kubectl create --dry-run=client -o json` produced exactly the shape that
# `kubectl get -o json` returns, which is why it was used, but --dry-run=client
# still performs API discovery against the current context: with no reachable
# cluster it fails with "connection refused" and a test whose whole point is to
# run without a cluster could not run at all.
#
# PowerShell ships no YAML reader (neither 5.1 nor 7), and these scripts
# deliberately have no module dependencies, so this covers the subset the
# manifests in infrastructure/kubernetes actually use:
#
#   block mappings, block sequences, plain and quoted scalars, comments,
#   and a single optional leading document marker.
#
# Everything outside that subset - flow collections, anchors, aliases, tags,
# block scalars, multiple documents, tab indentation - throws with the line
# number instead of being silently misread. A structural validator built on a
# reader that guesses is worse than one that refuses.

# Strips a trailing comment while respecting quotes, so `value: "a # b"` keeps
# its hash and `maxReplicas: 3  # ceiling` does not.
function Remove-YamlComment {
    param([string] $Line)

    $inSingleQuote = $false
    $inDoubleQuote = $false

    for ($index = 0; $index -lt $Line.Length; $index++) {
        $character = $Line[$index]

        if ($character -eq "'" -and -not $inDoubleQuote) {
            $inSingleQuote = -not $inSingleQuote
            continue
        }

        if ($character -eq '"' -and -not $inSingleQuote) {
            $inDoubleQuote = -not $inDoubleQuote
            continue
        }

        # A hash only opens a comment at the start of the line or after
        # whitespace; `app.kubernetes.io/name: a#b` is a plain scalar.
        if ($character -eq '#' -and -not $inSingleQuote -and -not $inDoubleQuote) {
            if ($index -eq 0 -or [char]::IsWhiteSpace($Line[$index - 1])) {
                return $Line.Substring(0, $index)
            }
        }
    }

    return $Line
}

function ConvertTo-YamlScalar {
    param(
        [string] $Text,
        [int] $Line,
        [string] $Source
    )

    if ($Text.Length -eq 0) {
        return $null
    }

    # `{}` is the one flow collection the manifests use (`emptyDir: {}`,
    # `podSelector: {}`, where the empty mapping is what carries the meaning),
    # so the empty forms are supported and everything else in flow style is not.
    if ($Text -eq '{}') {
        return [pscustomobject]@{}
    }

    if ($Text -eq '[]') {
        return , @()
    }

    $first = [string] $Text[0]
    if (@('{', '[', '&', '*', '!', '|', '>', '%', '@', '`') -contains $first) {
        throw "$Source line ${Line}: '$Text' uses a YAML construct this reader does not support (flow collections, anchors, aliases, tags and block scalars)."
    }

    if ($Text.Length -ge 2) {
        if ($Text.StartsWith('"') -and $Text.EndsWith('"')) {
            return $Text.Substring(1, $Text.Length - 2)
        }
        if ($Text.StartsWith("'") -and $Text.EndsWith("'")) {
            return $Text.Substring(1, $Text.Length - 2).Replace("''", "'")
        }
    }

    if ($Text -eq '~' -or $Text -in @('null', 'Null', 'NULL')) {
        return $null
    }

    if ($Text -in @('true', 'True', 'TRUE')) {
        return $true
    }

    if ($Text -in @('false', 'False', 'FALSE')) {
        return $false
    }

    # Numbers are converted so that comparisons in the validators
    # (`-eq 70`, `-eq 300`) mean the same thing here as they do against
    # `kubectl get -o json`, which also returns them as numbers.
    if ($Text -match '^-?\d+$') {
        $parsedInteger = 0
        if ([int]::TryParse($Text, [ref] $parsedInteger)) {
            return $parsedInteger
        }
        return [long] $Text
    }

    if ($Text -match '^-?(\d+\.\d*|\.\d+)([eE][-+]?\d+)?$') {
        return [double] $Text
    }

    return $Text
}

function ConvertFrom-YamlSequence {
    param($Entries, $State, [int] $Indent, [string] $Source)

    $items = [System.Collections.Generic.List[object]]::new()

    while ($State.Index -lt $Entries.Count) {
        $entry = $Entries[$State.Index]

        if ($entry.Indent -lt $Indent -or -not $entry.Text.StartsWith('-')) {
            break
        }

        if ($entry.Indent -gt $Indent) {
            throw "$Source line $($entry.Line): unexpected indentation inside a sequence."
        }

        $content = $entry.Text.Substring(1).TrimStart(' ')

        if ($content.Length -eq 0) {
            # `-` alone: the item is the block on the following lines.
            $State.Index++
            $next = if ($State.Index -lt $Entries.Count) { $Entries[$State.Index] } else { $null }
            if ($null -ne $next -and $next.Indent -gt $Indent) {
                $items.Add((ConvertFrom-YamlBlock -Entries $Entries -State $State -Indent $next.Indent -Source $Source)) | Out-Null
            } else {
                $items.Add($null) | Out-Null
            }
            continue
        }

        # `- type: Resource` starts a mapping whose remaining keys are aligned
        # under the content column, not under the dash. Rewriting the entry to
        # that column lets the mapping parser treat both alike.
        $contentIndent = $Indent + ($entry.Text.Length - $content.Length)

        if ($content -match '^[^:]+:(\s|$)' -or $content.StartsWith('-')) {
            $Entries[$State.Index] = [pscustomobject]@{
                Indent = $contentIndent
                Text   = $content
                Line   = $entry.Line
            }
            $items.Add((ConvertFrom-YamlBlock -Entries $Entries -State $State -Indent $contentIndent -Source $Source)) | Out-Null
            continue
        }

        $State.Index++
        $items.Add((ConvertTo-YamlScalar -Text $content -Line $entry.Line -Source $Source)) | Out-Null
    }

    # The comma keeps PowerShell from unrolling the array, which would turn a
    # single-element `metrics:` list into a bare object and an empty one into
    # $null.
    return , $items.ToArray()
}

function ConvertFrom-YamlMapping {
    param($Entries, $State, [int] $Indent, [string] $Source)

    $map = [ordered]@{}

    while ($State.Index -lt $Entries.Count) {
        $entry = $Entries[$State.Index]

        if ($entry.Indent -lt $Indent -or $entry.Text.StartsWith('-')) {
            break
        }

        if ($entry.Indent -gt $Indent) {
            throw "$Source line $($entry.Line): unexpected indentation inside a mapping."
        }

        $match = [regex]::Match($entry.Text, '^(?<key>[^:]+):(?<rest>.*)$')
        if (-not $match.Success) {
            throw "$Source line $($entry.Line): expected 'key: value', got '$($entry.Text)'."
        }

        $key = $match.Groups['key'].Value.Trim()
        if ($map.Contains($key)) {
            throw "$Source line $($entry.Line): duplicate key '$key'."
        }

        $rest = $match.Groups['rest'].Value.Trim()
        $State.Index++

        if ($rest.Length -gt 0) {
            $map[$key] = ConvertTo-YamlScalar -Text $rest -Line $entry.Line -Source $Source
            continue
        }

        $next = if ($State.Index -lt $Entries.Count) { $Entries[$State.Index] } else { $null }

        # A nested block is either indented further, or - for sequences, which
        # Kubernetes manifests often write flush with their key - at the same
        # indentation and starting with a dash.
        $hasChild = $null -ne $next -and (
            $next.Indent -gt $Indent -or ($next.Indent -eq $Indent -and $next.Text.StartsWith('-'))
        )

        if ($hasChild) {
            $map[$key] = ConvertFrom-YamlBlock -Entries $Entries -State $State -Indent $next.Indent -Source $Source
        } else {
            $map[$key] = $null
        }
    }

    return [pscustomobject] $map
}

function ConvertFrom-YamlBlock {
    param($Entries, $State, [int] $Indent, [string] $Source)

    if ($Entries[$State.Index].Text.StartsWith('-')) {
        return ConvertFrom-YamlSequence -Entries $Entries -State $State -Indent $Indent -Source $Source
    }

    return ConvertFrom-YamlMapping -Entries $Entries -State $State -Indent $Indent -Source $Source
}

function ConvertFrom-KubernetesYaml {
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path', Position = 0)] [string] $Path,
        # Used by the reader's own tests so they do not need temporary files.
        [Parameter(Mandatory, ParameterSetName = 'Text')] [string] $Text
    )

    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "Manifest '$Path' was not found."
        }
        $lines = @(Get-Content -LiteralPath $Path)
        $source = $Path
    } else {
        $lines = @($Text -split "`r?`n")
        $source = "YAML text"
    }

    $entries = [System.Collections.Generic.List[object]]::new()
    $lineNumber = 0
    $sawDocumentMarker = $false

    foreach ($line in $lines) {
        $lineNumber++
        $content = (Remove-YamlComment -Line $line).TrimEnd()

        if ($content.Trim().Length -eq 0) {
            continue
        }

        $text = $content.TrimStart(" `t")
        $indentation = $content.Substring(0, $content.Length - $text.Length)
        if ($indentation.Contains("`t")) {
            throw "$source line ${lineNumber}: tabs are not valid YAML indentation."
        }

        if ($text -eq '---') {
            if ($sawDocumentMarker -or $entries.Count -gt 0) {
                throw "$source line ${lineNumber}: this reader handles a single document per file."
            }
            $sawDocumentMarker = $true
            continue
        }

        if ($text -eq '...') {
            break
        }

        $entries.Add([pscustomobject]@{
            Indent = $indentation.Length
            Text   = $text
            Line   = $lineNumber
        }) | Out-Null
    }

    if ($entries.Count -eq 0) {
        throw "$source contains no YAML content."
    }

    $state = @{ Index = 0 }
    $document = ConvertFrom-YamlBlock -Entries $entries -State $state -Indent $entries[0].Indent -Source $source

    if ($state.Index -lt $entries.Count) {
        throw "$source line $($entries[$state.Index].Line): '$($entries[$state.Index].Text)' is outside the document structure."
    }

    return $document
}

Export-ModuleMember -Function ConvertFrom-KubernetesYaml
