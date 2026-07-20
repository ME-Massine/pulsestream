package com.pulsestream.processor.actuator;

import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.stream.Collectors;

import com.pulsestream.processor.model.DlqReplayStatus;
import com.pulsestream.processor.service.DlqReplayService;
import org.springframework.boot.actuate.endpoint.annotation.Endpoint;
import org.springframework.boot.actuate.endpoint.annotation.ReadOperation;
import org.springframework.boot.actuate.endpoint.annotation.Selector;
import org.springframework.boot.actuate.endpoint.annotation.WriteOperation;
import org.springframework.boot.actuate.endpoint.web.WebEndpointResponse;
import org.springframework.lang.Nullable;
import org.springframework.stereotype.Component;

/**
 * Actuator endpoint that lets an operator trigger and observe <em>selective</em> DLQ event replay
 * (#125).
 * <p>
 * Mapped operations (exposed under {@code management.endpoints.web.base-path}, default
 * {@code /actuator}, on the restricted management interface — see
 * {@code management.server} in {@code application.yml}):
 * <ul>
 *   <li>{@code GET  /actuator/dlqreplay}        &rarr; current listener state and active selection</li>
 *   <li>{@code POST /actuator/dlqreplay/start}  &rarr; replay the selected events; the request body
 *       must supply the {@code eventId}s as a comma-delimited string, e.g.
 *       {@code {"eventIds": "evt-1,evt-2"}} (the actuator web adapter reads the JSON body as
 *       string values, so the selection is passed comma-delimited rather than as a JSON array)</li>
 *   <li>{@code POST /actuator/dlqreplay/stop}   &rarr; stop replaying</li>
 * </ul>
 * The actual start/stop of the underlying Kafka listener lives in {@link DlqReplayService}; this
 * endpoint is the transport that turns an operator request into a trigger. A {@code start} without a
 * non-empty {@code eventIds} selection, or an unrecognised action, returns {@code 400 Bad Request}.
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
    public WebEndpointResponse<Object> control(
            @Selector String action,
            @Nullable List<String> eventIds
    ) {
        String normalizedAction = action == null ? "" : action.toLowerCase(Locale.ROOT);

        return switch (normalizedAction) {
            case ACTION_START -> startReplay(eventIds);
            case ACTION_STOP -> new WebEndpointResponse<>(dlqReplayService.stop());
            default -> badRequest(Map.of(
                    "error", "Unknown action",
                    "allowed", List.of(ACTION_START, ACTION_STOP)
            ));
        };
    }

    private WebEndpointResponse<Object> startReplay(@Nullable List<String> eventIds) {
        if (eventIds == null) {
            return missingSelection();
        }

        Set<String> selection = eventIds.stream()
                .filter(Objects::nonNull)
                .map(String::trim)
                .filter(id -> !id.isEmpty())
                .collect(Collectors.toCollection(LinkedHashSet::new));

        if (selection.isEmpty()) {
            return missingSelection();
        }

        return new WebEndpointResponse<>(dlqReplayService.start(selection));
    }

    private WebEndpointResponse<Object> missingSelection() {
        return badRequest(Map.of("error", "eventIds selection must not be empty"));
    }

    private WebEndpointResponse<Object> badRequest(Map<String, ?> body) {
        return new WebEndpointResponse<>(body, WebEndpointResponse.STATUS_BAD_REQUEST);
    }
}
