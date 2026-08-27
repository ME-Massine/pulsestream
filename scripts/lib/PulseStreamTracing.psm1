# Trace-correlation helpers for validate-distributed-tracing.ps1 (#158).
#
# Jaeger's `tags` query filters TRACES, not spans: a trace comes back when any
# one of its spans matched, so a search result is never on its own evidence
# that a single span carried every attribute the check depends on. Everything
# here re-checks the conditions on the same span.
#
# It lives in a module, apart from the validator, because the ordering that
# broke the validator - Jaeger returning a same-key DLQ trace ahead of the
# raw-topic one - is not something a live run can be made to produce on
# demand, but it can be handed to these functions directly by
# scripts\tests\test-trace-correlation.ps1.

# Jaeger renders a span's attributes as a flat list of {key, type, value}
# objects, so every lookup is a scan. Returns $null when the span does not
# carry the attribute at all, which is distinct from carrying it empty.
function Get-SpanTagValue {
    param(
        [Parameter(Mandatory)] $Span,
        [Parameter(Mandatory)] [string] $Key
    )

    $matched = @($Span.tags | Where-Object { $_.key -eq $Key })
    if ($matched.Count -eq 0) { return $null }
    "$($matched[0].value)"
}

# Whether the trace contains at least one span of the given kind. Used for the
# ingestion trace, where the assertion really is about the trace as a whole:
# the HTTP server span and the Kafka producer span are different spans.
function Test-TraceSpanKind {
    param(
        [Parameter(Mandatory)] $Trace,
        [Parameter(Mandatory)] [string] $Kind
    )

    [bool] @($Trace.spans | Where-Object {
        (Get-SpanTagValue -Span $_ -Key "span.kind") -eq $Kind
    }).Count
}

# The consumer span that proves THIS run's event travelled the normal ingest
# path: one span that is a consumer, carries the run's Kafka message key, and
# names the raw topic.
#
# All three have to hold on the SAME span. A DLQ or replay record carries the
# same message key - it is the same event - so the key alone does not establish
# the path, and the topic alone does not establish which event. Selecting
# whichever trace the key search returned first and checking its topic
# afterwards fails a run in which Jaeger happened to list a same-key DLQ trace
# ahead of the raw-topic trace, even though the correct trace was present in
# the same response.
#
# Returns a result object rather than throwing so the caller decides whether a
# miss is worth another attempt; the search runs inside a retry, and the
# raw-topic trace may simply not have been exported yet.
function Select-CorrelatedConsumerSpan {
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyCollection()] $Traces,
        [Parameter(Mandatory)] [string] $MessageKey,
        [Parameter(Mandatory)] [string] $DestinationTopic
    )

    $observed = @()

    foreach ($trace in @($Traces | Where-Object { $null -ne $_ })) {
        foreach ($span in @($trace.spans)) {
            if ((Get-SpanTagValue -Span $span -Key "span.kind") -ne "consumer") { continue }
            if ((Get-SpanTagValue -Span $span -Key "messaging.kafka.message.key") -ne $MessageKey) { continue }

            $destination = Get-SpanTagValue -Span $span -Key "messaging.destination.name"

            if ($destination -eq $DestinationTopic) {
                return [pscustomobject]@{
                    Trace                = $trace
                    Span                 = $span
                    ObservedDestinations = @()
                }
            }

            # A consumer span for this event on some other topic. Recorded so a
            # run that times out can name what it saw instead of only what it
            # wanted: "the event was consumed from telemetry.events.dlq" is a
            # diagnosis, "no trace found" is not.
            if ($null -eq $destination) {
                $observed += "(no messaging.destination.name)"
            } else {
                $observed += $destination
            }
        }
    }

    [pscustomobject]@{
        Trace                = $null
        Span                 = $null
        ObservedDestinations = @($observed | Select-Object -Unique)
    }
}

Export-ModuleMember -Function Get-SpanTagValue, Test-TraceSpanKind, Select-CorrelatedConsumerSpan
