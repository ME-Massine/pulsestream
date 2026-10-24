package com.pulsestream.query.controller;

import com.pulsestream.query.dto.AnomalyPage;
import com.pulsestream.query.exception.QueryExceptionHandler;
import com.pulsestream.query.service.AnomalyService;
import java.util.List;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.dao.DataAccessResourceFailureException;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import org.springframework.transaction.CannotCreateTransactionException;

import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

class AnomalyControllerTest {
    private final AnomalyService service = mock(AnomalyService.class);
    private MockMvc mvc;

    @BeforeEach
    void setup() {
        mvc = MockMvcBuilders.standaloneSetup(new AnomalyController(service)).setControllerAdvice(new QueryExceptionHandler()).build();
    }

    @Test
    void trustsPrincipalAndIgnoresSpoofedHeader() throws Exception {
        when(service.query(eq("tenant"), any())).thenReturn(new AnomalyPage(List.of(), 0, 50, false));
        mvc.perform(get("/api/v1/anomalies").principal(() -> "tenant").header("X-Tenant-Id", "other"))
                .andExpect(status().isOk()).andExpect(header().string("Cache-Control", "no-store"))
                .andExpect(jsonPath("$.content").isArray()).andExpect(jsonPath("$.size").value(50));
        verify(service).query(eq("tenant"), any());
    }

    @Test
    void requiresIdentityAndRejectsTenantOverridesUnknownAndRepeatedFilters() throws Exception {
        mvc.perform(get("/api/v1/anomalies").header("X-Tenant-Id", "tenant"))
                .andExpect(status().isUnauthorized()).andExpect(jsonPath("$.status").value(401));
        for (String name : new String[] {"tenantId", "tenant_id", "sort"}) {
            mvc.perform(get("/api/v1/anomalies").principal(() -> "tenant").param(name, "other"))
                    .andExpect(status().isBadRequest()).andExpect(header().string("Cache-Control", "no-store"));
        }
        mvc.perform(get("/api/v1/anomalies").principal(() -> "tenant").param("severity", "WARNING", "CRITICAL"))
                .andExpect(status().isBadRequest());
        mvc.perform(get("/api/v1/anomalies").principal(() -> "tenant").param("size", "101"))
                .andExpect(status().isBadRequest());
        verifyNoInteractions(service);
    }

    @Test
    void hidesDatabaseAndTransactionDetails() throws Exception {
        when(service.query(any(), any())).thenThrow(new DataAccessResourceFailureException("secret"))
                .thenThrow(new CannotCreateTransactionException("secret"));
        for (int i = 0; i < 2; i++) {
            mvc.perform(get("/api/v1/anomalies").principal(() -> "tenant"))
                    .andExpect(status().isServiceUnavailable()).andExpect(header().string("Cache-Control", "no-store"))
                    .andExpect(jsonPath("$.detail").value("Anomalies are temporarily unavailable."));
        }
    }
}
