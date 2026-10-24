package com.pulsestream.query.exception;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataAccessException;
import org.springframework.http.HttpStatus;
import org.springframework.http.CacheControl;
import org.springframework.http.ProblemDetail;
import org.springframework.http.ResponseEntity;
import org.springframework.transaction.TransactionException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

@RestControllerAdvice
public class QueryExceptionHandler {
    private static final Logger log = LoggerFactory.getLogger(QueryExceptionHandler.class);

    @ExceptionHandler(InvalidQueryException.class)
    public ResponseEntity<ProblemDetail> invalidQuery(InvalidQueryException ex) {
        return problem(HttpStatus.BAD_REQUEST, ex.getMessage());
    }

    @ExceptionHandler(TenantIdentityException.class)
    public ResponseEntity<ProblemDetail> missingIdentity(TenantIdentityException ex) {
        return problem(HttpStatus.UNAUTHORIZED, ex.getMessage());
    }

    @ExceptionHandler({DataAccessException.class, TransactionException.class})
    public ResponseEntity<ProblemDetail> databaseUnavailable(Exception ex) {
        log.warn("Processed telemetry database access failed", ex);
        return problem(HttpStatus.SERVICE_UNAVAILABLE, "Processed telemetry is temporarily unavailable.");
    }

    private ResponseEntity<ProblemDetail> problem(HttpStatus status, String detail) {
        return ResponseEntity.status(status).cacheControl(CacheControl.noStore())
                .body(ProblemDetail.forStatusAndDetail(status, detail));
    }
}
