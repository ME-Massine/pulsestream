package com.pulsestream.query.service;

import com.pulsestream.query.dto.ProcessedTelemetryResponse;
import com.pulsestream.query.exception.TenantIdentityException;
import com.pulsestream.query.repository.ProcessedTelemetryRepository;
import java.util.Collections;
import java.util.List;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.*;

class ProcessedTelemetryServiceTest {
    private final ProcessedTelemetryRepository repository = mock(ProcessedTelemetryRepository.class);
    private final ProcessedTelemetryService service = new ProcessedTelemetryService(repository);

    @Test
    void trimsLookaheadAndReportsNextPageWithoutLeakingExtraRows() {
        var query = new TelemetryQuery(null, null, null, 2, 1);
        var row = new ProcessedTelemetryResponse(1, "event", "tenant", null, null, null, null,
                null, null, null, null, null, null);
        when(repository.find("tenant", query)).thenReturn(Collections.nCopies(2, row));
        var result = service.query("tenant", query);
        assertThat(result.content()).containsExactly(row);
        assertThat(result.hasNext()).isTrue();
        assertThat(result.page()).isEqualTo(2);
        assertThat(result.size()).isEqualTo(1);
    }

    @Test
    void emptyAndExactlyFullPagesHaveNoNextPage() {
        var query = new TelemetryQuery(null, null, null, 0, 50);
        when(repository.find("tenant", query)).thenReturn(List.of());
        assertThat(service.query("tenant", query).hasNext()).isFalse();
        assertThat(service.query("tenant", query).content()).isEmpty();
        var single = new TelemetryQuery(null, null, null, 0, 1);
        var row = new ProcessedTelemetryResponse(1, "event", "tenant", null, null, null, null,
                null, null, null, null, null, null);
        when(repository.find("tenant", single)).thenReturn(List.of(row));
        assertThat(service.query("tenant", single).hasNext()).isFalse();
    }

    @Test
    void rejectsMissingOrInvalidIdentityBeforeAccessingRepository() {
        for (String tenant : new String[] {null, "", " ", "a".repeat(101)}) {
            assertThatThrownBy(() -> service.query(tenant, new TelemetryQuery(null, null, null, 0, 50)))
                    .isInstanceOf(TenantIdentityException.class);
        }
        verifyNoInteractions(repository);
    }
}
