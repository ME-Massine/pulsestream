package com.pulsestream.query.controller;

import com.pulsestream.query.dto.TelemetryPage;
import com.pulsestream.query.exception.QueryExceptionHandler;
import com.pulsestream.query.service.ProcessedTelemetryService;
import java.util.List;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.springframework.dao.DataAccessResourceFailureException;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import org.springframework.transaction.CannotCreateTransactionException;

import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

class ProcessedTelemetryControllerTest {
    private final ProcessedTelemetryService service = mock(ProcessedTelemetryService.class);
    private MockMvc mvc;

    @BeforeEach
    void setUp() {
        mvc = MockMvcBuilders.standaloneSetup(new ProcessedTelemetryController(service))
                .setControllerAdvice(new QueryExceptionHandler()).build();
    }

    @Test
    void usesAuthenticatedTenantAndReturnsStablePageSchema() throws Exception {
        when(service.query(eq("tenant-a"), any())).thenReturn(new TelemetryPage(List.of(), 0, 50, false));
        mvc.perform(get("/api/v1/telemetry").principal(() -> "tenant-a").header("X-Tenant-Id", "tenant-b"))
                .andExpect(status().isOk()).andExpect(header().string("Cache-Control", "no-store"))
                .andExpect(jsonPath("$.content").isArray())
                .andExpect(jsonPath("$.page").value(0)).andExpect(jsonPath("$.size").value(50))
                .andExpect(jsonPath("$.hasNext").value(false));
        verify(service).query(eq("tenant-a"), any());
    }

    @Test
    void rejectsAbsentIdentityEvenWithSpoofedHeader() throws Exception {
        mvc.perform(get("/api/v1/telemetry").header("X-Tenant-Id", "tenant-b"))
                .andExpect(status().isUnauthorized()).andExpect(content().contentType("application/problem+json"))
                .andExpect(header().string("Cache-Control", "no-store"))
                .andExpect(jsonPath("$.status").value(401));
        verifyNoInteractions(service);
    }

    @ParameterizedTest
    @CsvSource({"tenantId,tenant-b", "tenant_id,tenant-b", "size,101", "page,-1", "from,bad", "deviceId,''", "sort,id"})
    void invalidQueriesReturnControlledErrors(String name, String value) throws Exception {
        mvc.perform(get("/api/v1/telemetry").principal(() -> "tenant-a").param(name, value))
                .andExpect(status().isBadRequest()).andExpect(content().contentType("application/problem+json"))
                .andExpect(jsonPath("$.status").value(400));
        verifyNoInteractions(service);
    }

    @Test
    void duplicateAndInvertedFiltersReturn400() throws Exception {
        mvc.perform(get("/api/v1/telemetry").principal(() -> "tenant-a").param("page", "0", "1"))
                .andExpect(status().isBadRequest());
        mvc.perform(get("/api/v1/telemetry").principal(() -> "tenant-a")
                        .param("from", "2026-01-02T00:00:00Z").param("to", "2026-01-01T00:00:00Z"))
                .andExpect(status().isBadRequest());
        verifyNoInteractions(service);
    }

    @Test
    void databaseAndTransactionFailuresReturn503WithoutSqlDetails() throws Exception {
        when(service.query(any(), any())).thenThrow(new DataAccessResourceFailureException("secret SQL"))
                .thenThrow(new CannotCreateTransactionException("secret credentials"));
        for (int i = 0; i < 2; i++) {
            mvc.perform(get("/api/v1/telemetry").principal(() -> "tenant-a"))
                    .andExpect(status().isServiceUnavailable())
                    .andExpect(jsonPath("$.detail").value("Processed telemetry is temporarily unavailable."));
        }
    }
}
