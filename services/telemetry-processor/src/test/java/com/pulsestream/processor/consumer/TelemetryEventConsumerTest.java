package com.pulsestream.processor.consumer;

import com.pulsestream.processor.model.TelemetryEvent;
import com.pulsestream.processor.service.TelemetryDeliveryService;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class TelemetryEventConsumerTest {
    @Test
    void delegatesAndPropagatesDurabilityFailure() {
        var delivery = mock(TelemetryDeliveryService.class);
        var consumer = new TelemetryEventConsumer(delivery);
        var record = new ConsumerRecord<String, TelemetryEvent>("raw", 0, 0, "key", null);
        consumer.consumeTelemetryRecord(record);
        verify(delivery).consume(record);
        doThrow(new IllegalStateException("durability failed")).when(delivery).consume(record);
        assertThatThrownBy(() -> consumer.consumeTelemetryRecord(record)).hasMessage("durability failed");
    }
}
