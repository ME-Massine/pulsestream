package com.pulsestream.query.controller;

import com.pulsestream.query.dto.AnomalyPage;
import com.pulsestream.query.exception.TenantIdentityException;
import com.pulsestream.query.service.AnomalyQuery;
import com.pulsestream.query.service.AnomalyService;
import java.security.Principal;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataAccessException;
import org.springframework.http.CacheControl;
import org.springframework.http.HttpStatus;
import org.springframework.http.ProblemDetail;
import org.springframework.http.ResponseEntity;
import org.springframework.transaction.TransactionException;
import org.springframework.util.MultiValueMap;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/v1/anomalies")
public class AnomalyController {
    private static final Logger log = LoggerFactory.getLogger(AnomalyController.class);
    private final AnomalyService service;

    public AnomalyController(AnomalyService service) {
        this.service = service;
    }

    @GetMapping
    public ResponseEntity<AnomalyPage> query(Principal principal, @RequestParam MultiValueMap<String, String> parameters) {
        if (principal == null) {
            throw new TenantIdentityException();
        }
        var result = service.query(principal.getName(), AnomalyQuery.parse(parameters));
        return ResponseEntity.ok().cacheControl(CacheControl.noStore()).body(result);
    }

    @ExceptionHandler({DataAccessException.class, TransactionException.class})
    public ResponseEntity<ProblemDetail> databaseUnavailable(Exception ex) {
        log.warn("Anomaly database access failed", ex);
        return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).cacheControl(CacheControl.noStore())
                .body(ProblemDetail.forStatusAndDetail(HttpStatus.SERVICE_UNAVAILABLE, "Anomalies are temporarily unavailable."));
    }
}
