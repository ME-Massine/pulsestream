package com.pulsestream.processor.actuator;

import java.util.Locale;

import com.pulsestream.processor.model.DlqReplayStatus;
import com.pulsestream.processor.service.DlqReplayService;
import org.springframework.boot.actuate.endpoint.annotation.Endpoint;
import org.springframework.boot.actuate.endpoint.annotation.ReadOperation;
import org.springframework.boot.actuate.endpoint.annotation.Selector;
import org.springframework.boot.actuate.endpoint.annotation.WriteOperation;
import org.springframework.boot.actuate.endpoint.web.WebEndpointResponse;
import org.springframework.stereotype.Component;

/**
 * Actuator endpoint that lets an operator trigger and observe DLQ event replay (#125).
 * <p>
 * Mapped operations (exposed under {@code management.endpoints.web.base-path}, default
 * {@code /actuator}):
 * <ul>
 *   <li>{@code GET  /actuator/dlqreplay}        &rarr; current listener state</li>
 *   <li>{@code POST /actuator/dlqreplay/start}  &rarr; start replaying dead-letter events</li>
 *   <li>{@code POST /actuator/dlqreplay/stop}   &rarr; stop replaying</li>
 * </ul>
 * The actual start/stop of the underlying Kafka listener lives in {@link DlqReplayService}; this
 * endpoint is the transport that turns an operator request into a trigger. An unrecognised action
 * returns {@code 400 Bad Request}.
 */
@Component
@Endpoint(id = "dlqreplay")
public class DlqReplayEndpoint {

    static final String ACTION_START = "start";
    static final String ACTION_STOP = "stop";

    private final DlqReplayService dlqReplayService;

    public DlqReplayEndpoint(DlqReplayService dlqReplayService) {
        this.dlqReplayService = dlqReplayService;
    }

    @ReadOperation
    public DlqReplayStatus status() {
        return dlqReplayService.status();
    }

    @WriteOperation
    public WebEndpointResponse<DlqReplayStatus> control(@Selector String action) {
        String normalizedAction = action == null ? "" : action.toLowerCase(Locale.ROOT);

        return switch (normalizedAction) {
            case ACTION_START -> new WebEndpointResponse<>(dlqReplayService.start());
            case ACTION_STOP -> new WebEndpointResponse<>(dlqReplayService.stop());
            default -> new WebEndpointResponse<>(WebEndpointResponse.STATUS_BAD_REQUEST);
        };
    }
}
