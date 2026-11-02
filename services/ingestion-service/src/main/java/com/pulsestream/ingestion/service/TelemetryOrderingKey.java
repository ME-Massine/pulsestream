package com.pulsestream.ingestion.service;

import java.nio.charset.StandardCharsets;
import java.util.Base64;
import org.springframework.util.Assert;

/** v1:base64url(UTF-8 tenant):base64url(UTF-8 device), without padding. */
public final class TelemetryOrderingKey {
    private TelemetryOrderingKey() { }

    public static String of(String tenantId, String deviceId) {
        Assert.hasText(tenantId, "tenantId is required for the ordering key");
        Assert.hasText(deviceId, "deviceId is required for the ordering key");
        var encoder = Base64.getUrlEncoder().withoutPadding();
        return "v1:" + encoder.encodeToString(tenantId.trim().getBytes(StandardCharsets.UTF_8))
                + ":" + encoder.encodeToString(deviceId.trim().getBytes(StandardCharsets.UTF_8));
    }
}
