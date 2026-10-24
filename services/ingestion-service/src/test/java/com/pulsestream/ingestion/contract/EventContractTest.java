package com.pulsestream.ingestion.contract;

import com.pulsestream.ingestion.config.PulsestreamKafkaProperties;
import com.pulsestream.ingestion.dto.TelemetryIngestionRequestDto;
import com.pulsestream.ingestion.exception.TelemetryPublishingException;
import com.pulsestream.ingestion.mapper.TelemetryEventMapper;
import com.pulsestream.ingestion.model.DeadLetterEvent;
import com.pulsestream.ingestion.model.TelemetryEvent;
import com.pulsestream.ingestion.service.KafkaProducerService;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.CompletableFuture;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.support.serializer.JacksonJsonSerializer;
import tools.jackson.databind.ObjectMapper;
import tools.jackson.databind.json.JsonMapper;

import static com.pulsestream.ingestion.contract.ContractAssertions.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class EventContractTest {

    private final JsonMapper mapper = JsonMapper.builder().build();

    @Test
    void sharedFixturesValidateAgainstTheirSupportedSchema() throws Exception {
        for (var fixture : fixtures()) {
            valid(fixture.path("schema").asText(), resource(fixture.path("fixture").asText()));
        }
    }

    @Test
    void actualRawPublisherAndBothDlqSerializationPathsSatisfyTheContracts() throws Exception {
        var request = mapper.readValue(resource("fixtures/raw-v1.json"), TelemetryIngestionRequestDto.class);
        var event = new TelemetryEventMapper().toModel(request);
        for (boolean fallback : new boolean[] {false, true}) {
            @SuppressWarnings("unchecked")
            KafkaTemplate<String, TelemetryEvent> raw = mock(KafkaTemplate.class);
            @SuppressWarnings("unchecked")
            KafkaTemplate<String, String> dlq = mock(KafkaTemplate.class);
            ObjectMapper configured = fallback ? mock(ObjectMapper.class) : mapper;
            if (fallback) {
                when(configured.writeValueAsString(any())).thenThrow(new IllegalStateException("mapper failed"));
            }
            when(raw.send(anyString(), anyString(), any(TelemetryEvent.class)))
                    .thenReturn(CompletableFuture.failedFuture(new IllegalStateException("failed \"send\"\nretry")));
            when(dlq.send(anyString(), anyString(), anyString())).thenReturn(CompletableFuture.completedFuture(null));
            var producer = new KafkaProducerService(raw, dlq, configured, new PulsestreamKafkaProperties());
            assertThatThrownBy(() -> producer.publishTelemetryEvent(event)).isInstanceOf(TelemetryPublishingException.class);

            var rawValue = ArgumentCaptor.forClass(TelemetryEvent.class);
            verify(raw).send(eq("telemetry.events.raw"), eq(event.eventId()), rawValue.capture());
            try (var serializer = new JacksonJsonSerializer<TelemetryEvent>(mapper)) {
                valid("schemas/raw/v1.schema.json", new String(serializer.serialize("telemetry.events.raw", rawValue.getValue()),
                        StandardCharsets.UTF_8));
            }
            var dlqValue = ArgumentCaptor.forClass(String.class);
            verify(dlq).send(eq("telemetry.events.dlq"), eq(event.eventId()), dlqValue.capture());
            valid("schemas/dead-letter/v1.schema.json", dlqValue.getValue());
            assertThat(mapper.readValue(dlqValue.getValue(), DeadLetterEvent.class).event()).isEqualTo(event);
        }
    }

    @Test
    void schemasRejectMissingFieldsWrongTypesFormatsAndUnsupportedMajors() throws Exception {
        var raw = mapper.readTree(resource("fixtures/raw-v1.json"));
        for (String field : new String[] {"eventId", "tenantId", "payload", "version"}) {
            var broken = (tools.jackson.databind.node.ObjectNode) raw.deepCopy();
            broken.remove(field);
            invalid("schemas/raw/v1.schema.json", broken.toString());
        }
        invalid("schemas/raw/v1.schema.json", raw.toString().replace("1.0", "2.0"));
        invalid("schemas/raw/v1.schema.json", raw.toString().replace("2026-10-24T12:00:00Z", "yesterday"));
        invalid("schemas/raw/v1.schema.json", raw.toString().replace("28.4", "\"28.4\""));
        invalid("schemas/dead-letter/v1.schema.json", "{\"event\":{}}");
        String anomaly = resource("fixtures/anomaly-v1.json");
        invalid("schemas/anomaly/v1.schema.json", anomaly.replace("WARNING", "NONE"));
        invalid("schemas/anomaly/v1.schema.json", anomaly.replace("2026-10-24T12:00:01Z", "yesterday"));
        String processed = resource("fixtures/processed-v1.json");
        invalid("schemas/processed/v1.schema.json", processed.replace("telemetry.processed", "telemetry.reading"));
        String dlq = resource("fixtures/dead-letter-v1-ingestion-service.json");
        invalid("schemas/dead-letter/v1.schema.json", dlq.replace("ingestion-service", "unknown-producer"));
        invalid("schemas/dead-letter/v1.schema.json", dlq.replace("2026-10-24T12:00:02Z", "yesterday"));
    }
}
