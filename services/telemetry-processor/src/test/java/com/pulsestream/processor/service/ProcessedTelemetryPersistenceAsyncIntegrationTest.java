package com.pulsestream.processor.service;

import com.pulsestream.processor.config.AsyncConfiguration;
import com.pulsestream.processor.model.TelemetryEvent;
import com.pulsestream.processor.model.TelemetryPayload;
import com.pulsestream.processor.repository.ProcessedTelemetryRepository;
import java.math.BigDecimal;
import java.time.Instant;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.junit.jupiter.SpringJUnitConfig;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.doAnswer;

/**
 * Verifies that {@link ProcessedTelemetryPersistenceService#persist} is genuinely dispatched to the
 * dedicated {@code persistenceExecutor} thread pool (issue #92: persistence must not block the Kafka
 * consumer thread). A regression here — e.g. a broken {@code @EnableAsync} proxy — would silently make
 * persistence synchronous again without any other test catching it.
 */
@SpringJUnitConfig(classes = {AsyncConfiguration.class, ProcessedTelemetryPersistenceService.class})
@DirtiesContext
class ProcessedTelemetryPersistenceAsyncIntegrationTest {

    @Autowired
    private ProcessedTelemetryPersistenceService persistenceService;

    @MockBean
    private ProcessedTelemetryRepository repository;

    @Test
    void shouldPersistOnDedicatedExecutorThreadNotCallingThread() throws InterruptedException {
        CountDownLatch latch = new CountDownLatch(1);
        AtomicReference<String> persistingThreadName = new AtomicReference<>();

        doAnswer(invocation -> {
            persistingThreadName.set(Thread.currentThread().getName());
            latch.countDown();
            return invocation.getArgument(0);
        }).when(repository).save(any());

        String callingThreadName = Thread.currentThread().getName();

        persistenceService.persist(processedEvent());

        assertThat(latch.await(2, TimeUnit.SECONDS)).as("persistence should complete asynchronously").isTrue();
        assertThat(persistingThreadName.get())
                .startsWith("telemetry-persist-")
                .isNotEqualTo(callingThreadName);
    }

    private TelemetryEvent processedEvent() {
        return new TelemetryEvent(
                "evt-async-001",
                "factory-01",
                "telemetry.processed",
                Instant.parse("2026-03-15T12:05:21Z"),
                "telemetry-processor",
                "1.0",
                new TelemetryPayload(
                        "sensor_1042",
                        "temperature-sensor",
                        "temperature",
                        BigDecimal.valueOf(28.4),
                        "C",
                        "zone-a"
                )
        );
    }
}
