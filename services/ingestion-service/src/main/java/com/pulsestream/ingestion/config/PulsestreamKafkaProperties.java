package com.pulsestream.ingestion.config;

import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.Map;

import org.apache.kafka.common.serialization.StringSerializer;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.kafka.support.serializer.JsonSerializer;

@ConfigurationProperties(prefix = "pulsestream.kafka")
public class PulsestreamKafkaProperties {

    private String bootstrapServers = "localhost:9092";

    private final Producer producer = new Producer();

    private final Topics topics = new Topics();

    public String getBootstrapServers() {
        return bootstrapServers;
    }

    public void setBootstrapServers(String bootstrapServers) {
        this.bootstrapServers = bootstrapServers;
    }

    public Producer getProducer() {
        return producer;
    }

    public Topics getTopics() {
        return topics;
    }

    public static class Producer {

        private String clientId = "ingestion-service-producer";

        private String keySerializer = StringSerializer.class.getName();

        private String valueSerializer = JsonSerializer.class.getName();

        private String acknowledgements = "all";

        private Integer retries = 3;

        private Duration deliveryTimeout = Duration.ofSeconds(30);

        private Map<String, String> properties = new LinkedHashMap<>();

        public String getClientId() {
            return clientId;
        }

        public void setClientId(String clientId) {
            this.clientId = clientId;
        }

        public String getKeySerializer() {
            return keySerializer;
        }

        public void setKeySerializer(String keySerializer) {
            this.keySerializer = keySerializer;
        }

        public String getValueSerializer() {
            return valueSerializer;
        }

        public void setValueSerializer(String valueSerializer) {
            this.valueSerializer = valueSerializer;
        }

        public String getAcknowledgements() {
            return acknowledgements;
        }

        public void setAcknowledgements(String acknowledgements) {
            this.acknowledgements = acknowledgements;
        }

        public Integer getRetries() {
            return retries;
        }

        public void setRetries(Integer retries) {
            this.retries = retries;
        }

        public Duration getDeliveryTimeout() {
            return deliveryTimeout;
        }

        public void setDeliveryTimeout(Duration deliveryTimeout) {
            this.deliveryTimeout = deliveryTimeout;
        }

        public Map<String, String> getProperties() {
            return properties;
        }

        public void setProperties(Map<String, String> properties) {
            this.properties = properties;
        }
    }

    public static class Topics {

        private String raw = "telemetry.events.raw";

        private String processed = "telemetry.events.processed";

        private String anomalies = "telemetry.events.anomalies";

        private String dlq = "telemetry.events.dlq";

        public String getRaw() {
            return raw;
        }

        public void setRaw(String raw) {
            this.raw = raw;
        }

        public String getProcessed() {
            return processed;
        }

        public void setProcessed(String processed) {
            this.processed = processed;
        }

        public String getAnomalies() {
            return anomalies;
        }

        public void setAnomalies(String anomalies) {
            this.anomalies = anomalies;
        }

        public String getDlq() {
            return dlq;
        }

        public void setDlq(String dlq) {
            this.dlq = dlq;
        }
    }
}
