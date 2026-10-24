package com.pulsestream.query.service;

import com.pulsestream.query.dto.TelemetryPage;
import com.pulsestream.query.exception.TenantIdentityException;
import com.pulsestream.query.repository.ProcessedTelemetryRepository;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class ProcessedTelemetryService {
    private final ProcessedTelemetryRepository repository;

    public ProcessedTelemetryService(ProcessedTelemetryRepository repository) {
        this.repository = repository;
    }

    @Transactional(readOnly = true, timeout = 5)
    public TelemetryPage query(String tenantId, TelemetryQuery query) {
        if (tenantId == null || tenantId.isBlank() || tenantId.length() > 100) {
            throw new TenantIdentityException();
        }
        var rows = repository.find(tenantId, query);
        return new TelemetryPage(rows.subList(0, Math.min(rows.size(), query.size())), query.page(),
                query.size(), rows.size() > query.size());
    }
}
