package com.pulsestream.query.service;

import com.pulsestream.query.dto.AnomalyResponse;
import com.pulsestream.query.exception.TenantIdentityException;
import com.pulsestream.query.repository.AnomalyRepository;
import java.util.List;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class AnomalyServiceTest {
    private final AnomalyRepository repository = mock(AnomalyRepository.class);
    private final AnomalyService service = new AnomalyService(repository);
    private final AnomalyQuery query = new AnomalyQuery(new TelemetryQuery(null, null, null, 2, 1), null, null);

    @Test
    void trimsLookaheadAndReturnsImmutableBoundedPage() {
        var row = new AnomalyResponse(1, "event", "tenant", null, null, null, null, null, null, null,
                null, "rule_violation", "WARNING", List.of("reason"), null, null);
        when(repository.find("tenant", query)).thenReturn(List.of(row, row));
        var page = service.query("tenant", query);
        assertThat(page.content()).containsExactly(row);
        assertThat(page.hasNext()).isTrue();
        assertThat(page.page()).isEqualTo(2);
        assertThat(page.size()).isEqualTo(1);
        assertThatThrownBy(() -> page.content().clear()).isInstanceOf(UnsupportedOperationException.class);
        when(repository.find("tenant", query)).thenReturn(List.of(row));
        assertThat(service.query("tenant", query).hasNext()).isFalse();
        when(repository.find("tenant", query)).thenReturn(List.of());
        assertThat(service.query("tenant", query).content()).isEmpty();
        assertThat(service.query("tenant", query).hasNext()).isFalse();
    }

    @Test
    void invalidIdentityFailsBeforeRepositoryAccess() {
        for (String tenant : new String[] {null, "", " ", "x".repeat(101)}) {
            assertThatThrownBy(() -> service.query(tenant, query)).isInstanceOf(TenantIdentityException.class);
        }
        verifyNoInteractions(repository);
    }
}
