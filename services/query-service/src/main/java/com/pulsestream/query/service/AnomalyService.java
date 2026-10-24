package com.pulsestream.query.service;

import com.pulsestream.query.dto.AnomalyPage;
import com.pulsestream.query.exception.TenantIdentityException;
import com.pulsestream.query.repository.AnomalyRepository;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class AnomalyService {
    private final AnomalyRepository repository;

    public AnomalyService(AnomalyRepository repository) {
        this.repository = repository;
    }

    @Transactional(readOnly = true, timeout = 5)
    public AnomalyPage query(String tenantId, AnomalyQuery query) {
        if (tenantId == null || tenantId.isBlank() || tenantId.length() > 100) {
            throw new TenantIdentityException();
        }
        var rows = repository.find(tenantId, query);
        var page = query.telemetry();
        return new AnomalyPage(rows.subList(0, Math.min(rows.size(), page.size())), page.page(),
                page.size(), rows.size() > page.size());
    }
}
