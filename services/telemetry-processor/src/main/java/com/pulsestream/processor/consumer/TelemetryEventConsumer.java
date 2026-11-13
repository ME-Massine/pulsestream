package com.pulsestream.processor.consumer;

import com.pulsestream.processor.model.TelemetryEvent;
import com.pulsestream.processor.service.TelemetryDeliveryService;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.stereotype.Service;

@Service
public class TelemetryEventConsumer {
    private final TelemetryDeliveryService delivery;

    public TelemetryEventConsumer(TelemetryDeliveryService delivery) {
        this.delivery = delivery;
    }

    @KafkaListener(topics = "${pulsestream.kafka.topics.raw}",
            groupId = "${pulsestream.kafka.consumer.group-id}",
            containerFactory = "telemetryKafkaListenerContainerFactory")
    public void consumeTelemetryRecord(ConsumerRecord<String, TelemetryEvent> record) {
        delivery.consume(record);
    }
}
