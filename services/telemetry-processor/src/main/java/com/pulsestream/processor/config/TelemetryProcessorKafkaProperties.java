package com.pulsestream.processor.config;

import java.util.LinkedHashMap;
import java.util.Map;

import org.apache.kafka.common.serialization.StringDeserializer;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.kafka.support.serializer.JsonDeserializer;

@ConfigurationProperties(prefix = "pulsestream.kafka")
public class TelemetryProcessorKafkaProperties {

    private String bootstrapServers = "localhost:9092";

    private final Consumer consumer = new Consumer();

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