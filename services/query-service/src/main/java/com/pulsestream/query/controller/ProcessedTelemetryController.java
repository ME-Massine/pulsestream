package com.pulsestream.query.controller;

import com.pulsestream.query.dto.TelemetryPage;
import com.pulsestream.query.exception.TenantIdentityException;
import com.pulsestream.query.service.ProcessedTelemetryService;
import com.pulsestream.query.service.TelemetryQuery;
import java.security.Principal;
import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
import org.springframework.util.MultiValueMap;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/v1/telemetry")
public class ProcessedTelemetryController {
    private final ProcessedTelemetryService service;

    public ProcessedTelemetryController(ProcessedTelemetryService service) {
        this.service = service;
    }

    @GetMapping
    public ResponseEntity<TelemetryPage> query(Principal principal, @RequestParam MultiValueMap<String, String> parameters) {
        if (principal == null) {
            throw new TenantIdentityException();
        }
        var result = service.query(principal.getName(), TelemetryQuery.parse(parameters));
        return ResponseEntity.ok().cacheControl(CacheControl.noStore()).body(result);
    }
}
