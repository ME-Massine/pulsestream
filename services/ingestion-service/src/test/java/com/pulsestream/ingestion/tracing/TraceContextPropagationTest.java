package com.pulsestream.ingestion.tracing;

import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.SpanContext;
import io.opentelemetry.api.trace.TraceFlags;
import io.opentelemetry.api.trace.TraceState;
import io.opentelemetry.api.trace.propagation.W3CTraceContextPropagator;
import io.opentelemetry.context.Context;
import io.opentelemetry.context.propagation.TextMapGetter;
import io.opentelemetry.context.propagation.TextMapSetter;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.HashMap;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Verifies that W3C trace context (the propagator configured via {@code otel.propagators}
 * in {@code application.yml}) carries trace IDs over HTTP headers so that a trace stays
 * consistent as it flows into and out of the ingestion service.
 */
class TraceContextPropagationTest {

    private static final String TRACE_ID = "0af7651916cd43dd8448eb211c80319c";
    private static final String SPAN_ID = "b7ad6b7169203331";
    private static final String TRACEPARENT = "00-" + TRACE_ID + "-" + SPAN_ID + "-01";

    private final W3CTraceContextPropagator propagator = W3CTraceContextPropagator.getInstance();

    private static final TextMapGetter<Map<String, String>> GETTER = new TextMapGetter<>() {
        @Override
        public Iterable<String> keys(Map<String, String> carrier) {
            return carrier.keySet();
        }

        @Override
        public String get(Map<String, String> carrier, String key) {
            return carrier == null ? null : carrier.get(key);
        }
    };

    private static final TextMapSetter<Map<String, String>> SETTER =
            (carrier, key, value) -> carrier.put(key, value);

    @Test
    @DisplayName("should extract the incoming trace ID from a W3C traceparent header")
    void shouldExtractTraceIdFromIncomingHeader() {
        Map<String, String> incomingHeaders = Map.of("traceparent", TRACEPARENT);

        Context extracted = propagator.extract(Context.root(), incomingHeaders, GETTER);
        SpanContext spanContext = Span.fromContext(extracted).getSpanContext();

        assertThat(spanContext.isValid()).isTrue();
        assertThat(spanContext.isRemote()).isTrue();
        assertThat(spanContext.getTraceId()).isEqualTo(TRACE_ID);
        assertThat(spanContext.getSpanId()).isEqualTo(SPAN_ID);
    }

    @Test
    @DisplayName("should inject the active trace ID into outgoing headers unchanged")
    void shouldInjectTraceIdIntoOutgoingHeaders() {
        SpanContext active = SpanContext.create(
                TRACE_ID, SPAN_ID, TraceFlags.getSampled(), TraceState.getDefault());
        Context context = Context.root().with(Span.wrap(active));

        Map<String, String> outgoingHeaders = new HashMap<>();
        propagator.inject(context, outgoingHeaders, SETTER);

        assertThat(outgoingHeaders).containsEntry("traceparent", TRACEPARENT);
    }

    @Test
    @DisplayName("should keep the trace ID consistent across an extract then inject hop")
    void shouldKeepTraceIdConsistentAcrossHop() {
        Map<String, String> incomingHeaders = Map.of("traceparent", TRACEPARENT);

        Context extracted = propagator.extract(Context.root(), incomingHeaders, GETTER);
        Map<String, String> forwardedHeaders = new HashMap<>();
        propagator.inject(extracted, forwardedHeaders, SETTER);

        SpanContext forwarded = Span.fromContext(
                propagator.extract(Context.root(), forwardedHeaders, GETTER)).getSpanContext();

        assertThat(forwarded.getTraceId())
                .as("trace ID must survive the extract -> inject propagation hop")
                .isEqualTo(TRACE_ID);
    }
}
