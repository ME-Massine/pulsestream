package com.pulsestream.processor.config;

import java.util.LinkedHashMap;
import java.util.Map;

import org.apache.kafka.common.serialization.StringDeserializer;
import org.apache.kafka.common.serialization.StringSerializer;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.kafka.support.serializer.JsonDeserializer;
import org.springframework.kafka.support.serializer.JsonSerializer;

@ConfigurationProperties(prefix = "pulsestream.kafka")
public class TelemetryProcessorKafkaProperties {

    private String bootstrapServers = "localhost:9092";

    private final Consumer consumer = new Consumer();

    private final Producer producer = new Producer();

    private final Topics topics = new Topics();

    public String getBootstrapServers() {
        return bootstrapServers;
    }

    public void setBootstrapServers(String bootstrapServers) {
        this.bootstrapServers = bootstrapServers;
    }

    public Consumer getConsumer() {
        return consumer;
    }

    public Producer getProducer() {
        return producer;
    }

    public Topics getTopics() {
        return topics;
    }

    public static class Consumer {

        private String groupId = "telemetry-processor";

        private String keyDeserializer = StringDeserializer.class.getName();

        private String valueDeserializer = JsonDeserializer.class.getName();

        private String autoOffsetReset = "earliest";

        private Integer concurrency = 1;

        private Map<String, String> properties = new LinkedHashMap<>();

        public String getGroupId() {
            return groupId;
        }

        public void setGroupId(String groupId) {
            this.groupId = groupId;
        }

        public String getKeyDeserializer() {
            return keyDeserializer;
        }

        public void setKeyDeserializer(String keyDeserializer) {
            this.keyDeserializer = keyDeserializer;
        }

        public String getValueDeserializer() {
            return valueDeserializer;
        }

        public void setValueDeserializer(String valueDeserializer) {
            this.valueDeserializer = valueDeserializer;
        }

        public String getAutoOffsetReset() {
            return autoOffsetReset;
        }

        public void setAutoOffsetReset(String autoOffsetReset) {
            this.autoOffsetReset = autoOffsetReset;
        }

        public Integer getConcurrency() {
            return concurrency;
        }

        public void setConcurrency(Integer concurrency) {
            this.concurrency = concurrency;
        }

        public Map<String, String> getProperties() {
            return properties;
        }

        public void setProperties(Map<String, String> properties) {
            this.properties = properties != null ? properties : new LinkedHashMap<>();
        }
    }

    public static class Producer {

        private String clientId = "telemetry-processor-producer";

        private String keySerializer = StringSerializer.class.getName();

        private String valueSerializer = JsonSerializer.class.getName();

        private String acknowledgements = "all";

        private Integer retries = 3;

        private java.time.Duration deliveryTimeout = java.time.Duration.ofSeconds(30);

        private java.time.Duration publishTimeout = java.time.Duration.ofSeconds(5);

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

        public java.time.Duration getDeliveryTimeout() {
            return deliveryTimeout;
        }

        public void setDeliveryTimeout(java.time.Duration deliveryTimeout) {
            this.deliveryTimeout = deliveryTimeout;
        }

        public java.time.Duration getPublishTimeout() {
            return publishTimeout;
        }

        public void setPublishTimeout(java.time.Duration publishTimeout) {
            this.publishTimeout = publishTimeout;
        }

        public Map<String, String> getProperties() {
            return properties;
        }

        public void setProperties(Map<String, String> properties) {
            this.properties = properties != null ? properties : new LinkedHashMap<>();
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
