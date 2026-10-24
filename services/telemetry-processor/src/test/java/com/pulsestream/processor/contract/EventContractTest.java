package com.pulsestream.processor.contract;

import com.pulsestream.processor.config.KafkaConsumerConfiguration;
import com.pulsestream.processor.config.TelemetryProcessorKafkaProperties;
import com.pulsestream.processor.model.*;
import com.pulsestream.processor.service.*;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.support.serializer.JacksonJsonDeserializer;
import org.springframework.kafka.support.serializer.JacksonJsonSerializer;
import tools.jackson.databind.ObjectMapper;
import tools.jackson.databind.json.JsonMapper;

import static com.pulsestream.processor.contract.ContractAssertions.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class EventContractTest {

    private final JsonMapper mapper = JsonMapper.builder().build();
    private final TelemetryProcessorKafkaProperties properties = new TelemetryProcessorKafkaProperties();

    @Test
    void sharedFixturesValidateAndDeserializeUsingTheConsumerConfiguration() throws Exception {
        var configuration = new KafkaConsumerConfiguration();
        properties.getConsumer().getProperties().put(JacksonJsonDeserializer.USE_TYPE_INFO_HEADERS, "false");
        // Use the deserializers configured for production, including ignoring foreign
        // producer type headers and using the processor's own model types.
        var rawDeserializer = new JacksonJsonDeserializer<TelemetryEvent>();
        rawDeserializer.configure(configuration.telemetryConsumerFactory(properties).getConfigurationProperties(), false);
        var dlqDeserializer = new JacksonJsonDeserializer<DeadLetterEvent>();
        dlqDeserializer.configure(configuration.dlqConsumerFactory(properties).getConfigurationProperties(), false);
        for (var fixture : fixtures()) {
            String schema = fixture.path("schema").asText();
            String json = resource(fixture.path("fixture").asText());
            valid(schema, json);
            byte[] bytes = json.getBytes(StandardCharsets.UTF_8);
            if (schema.contains("/raw/")) {
                var headers = new org.apache.kafka.common.header.internals.RecordHeaders();
                headers.add("__TypeId__", "com.pulsestream.ingestion.model.TelemetryEvent".getBytes(StandardCharsets.UTF_8));
                assertThat(rawDeserializer.deserialize("telemetry.events.raw", headers, bytes).payload().value())
                        .isEqualByComparingTo("28.4");
            } else if (schema.contains("/dead-letter/")) {
                assertThat(dlqDeserializer.deserialize("telemetry.events.dlq", bytes).event()).isNotNull();
            } else if (schema.contains("/anomaly/")) {
                assertThat(mapper.readValue(json, TelemetryAnomalyEvent.class).severity())
                        .isIn(AnomalySeverity.WARNING, AnomalySeverity.CRITICAL);
            } else {
                assertThat(mapper.readValue(json, TelemetryEvent.class).eventType()).isEqualTo("telemetry.processed");
            }
        }
        rawDeserializer.close();
        dlqDeserializer.close();
    }

    @Test
    void processedAndAnomalyPublishersEmitTheirOwnSchemaVersionAndKafkaJsonContract() throws Exception {
        var raw = mapper.readValue(resource("fixtures/raw-v1-extensions.json"), TelemetryEvent.class);
        @SuppressWarnings("unchecked")
        KafkaTemplate<String, TelemetryEnvelope> kafka = mock(KafkaTemplate.class);
        when(kafka.send(anyString(), anyString(), any(TelemetryEnvelope.class)))
                .thenReturn(CompletableFuture.completedFuture(null));
        var processed = new TelemetryProcessingService(new ProcessedTelemetryPublisher(kafka, properties),
                mock(ProcessedTelemetryPersistenceService.class)).process(raw);
        assertThat(processed.version()).isEqualTo("1.0");
        var anomalyService = new AnomalyProcessingService(new AnomalyTelemetryPublisher(kafka, properties),
                mock(AnomalyPersistenceService.class));
        var result = TelemetryAnomalyResult.anomalous(new TelemetryNormalizationService().normalize(raw),
                AnomalySeverity.WARNING, List.of("temperature is above maximum threshold"));
        var anomaly = anomalyService.process(raw, result);
        assertThat(anomaly.version()).isEqualTo("1.0");
        var published = ArgumentCaptor.forClass(TelemetryEnvelope.class);
        verify(kafka).send(eq("telemetry.events.processed"), eq(raw.eventId()), published.capture());
        assertKafkaContract("processed", published.getValue());
        verify(kafka).send(eq("telemetry.events.anomalies"), eq(raw.eventId()), published.capture());
        assertKafkaContract("anomaly", published.getValue());

        var missing = new TelemetryEvent(raw.eventId(), raw.tenantId(), raw.eventType(), raw.timestamp(),
                raw.source(), raw.version(), new TelemetryPayload(null, null, null, null, null, null));
        assertKafkaContract("anomaly", anomalyService.process(missing, result));
        var missingMetadata = new TelemetryEvent(raw.eventId(), raw.tenantId(), raw.eventType(), raw.timestamp(),
                raw.source(), raw.version(), new TelemetryPayload("sensor-1042", null, "temperature",
                raw.payload().value(), null, null));
        assertKafkaContract("processed", new TelemetryProcessingService(new ProcessedTelemetryPublisher(kafka, properties),
                mock(ProcessedTelemetryPersistenceService.class)).process(missingMetadata));
    }

    @Test
    void replayPublishesTheSharedRawContractAndPreservesVersionAndIdentity() throws Exception {
        var event = mapper.readValue(resource("fixtures/raw-v1-extensions.json"), TelemetryEvent.class);
        @SuppressWarnings("unchecked")
        KafkaTemplate<String, TelemetryEnvelope> kafka = mock(KafkaTemplate.class);
        when(kafka.send(any(ProducerRecord.class))).thenReturn(CompletableFuture.completedFuture(null));
        new ReplayEventPublisher(kafka, properties).publish(event);
        @SuppressWarnings("unchecked")
        ArgumentCaptor<ProducerRecord<String, TelemetryEnvelope>> record = ArgumentCaptor.forClass(ProducerRecord.class);
        verify(kafka).send(record.capture());
        assertThat(record.getValue().value()).isEqualTo(event);
        assertKafkaContract("raw", record.getValue().value());
    }

    @Test
    void dlqPublisherProducesSharedJsonEvenWhenTheConfiguredMapperFails() throws Exception {
        for (boolean fallback : new boolean[] {false, true}) {
            @SuppressWarnings("unchecked")
            KafkaTemplate<String, String> kafka = mock(KafkaTemplate.class);
            when(kafka.send(anyString(), anyString(), anyString())).thenReturn(CompletableFuture.completedFuture(null));
            ObjectMapper configured = fallback ? mock(ObjectMapper.class) : mapper;
            if (fallback) {
                when(configured.writeValueAsString(any())).thenThrow(new IllegalStateException("mapper failed"));
            }
            var event = mapper.readValue(resource("fixtures/raw-v1.json"), TelemetryEvent.class);
            new DeadLetterPublisher(kafka, properties, configured).publish(event,
                    new IllegalStateException("failed \"send\"\nretry"));
            var json = ArgumentCaptor.forClass(String.class);
            verify(kafka).send(eq("telemetry.events.dlq"), eq(event.eventId()), json.capture());
            valid("schemas/dead-letter/v1.schema.json", json.getValue());
            assertThat(mapper.readValue(json.getValue(), DeadLetterEvent.class).event()).isEqualTo(event);
        }
    }

    @Test
    void consumerToleratesNewOptionalEnvelopePayloadAndDlqFields() throws Exception {
        String raw = resource("fixtures/raw-v1-extensions.json");
        try (var deserializer = new JacksonJsonDeserializer<>(TelemetryEvent.class, mapper, false)) {
            var event = deserializer.deserialize("telemetry.events.raw", raw.getBytes(StandardCharsets.UTF_8));
            assertThat(event.eventId()).isEqualTo("evt-contract-001");
            assertThat(event.version()).isEqualTo("1.1");
        }
        String dlq = resource("fixtures/dead-letter-v1-ingestion-service.json")
                .replace("\"errorMessage\":", "\"futureMetadata\":{},\"errorMessage\":");
        valid("schemas/dead-letter/v1.schema.json", dlq);
        assertThat(mapper.readValue(dlq, DeadLetterEvent.class).sourceService()).isEqualTo("ingestion-service");
    }

    private void assertKafkaContract(String name, TelemetryEnvelope event) {
        try (var serializer = new JacksonJsonSerializer<TelemetryEnvelope>(mapper)) {
            valid("schemas/" + name + "/v1.schema.json", new String(serializer.serialize("telemetry.events." + name, event),
                    StandardCharsets.UTF_8));
        }
    }
}
