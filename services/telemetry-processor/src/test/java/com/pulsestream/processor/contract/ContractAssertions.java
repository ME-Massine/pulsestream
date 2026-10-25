package com.pulsestream.processor.contract;

import com.networknt.schema.InputFormat;
import com.networknt.schema.SchemaLocation;
import com.networknt.schema.SchemaRegistry;
import com.networknt.schema.SpecificationVersion;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;

import static org.assertj.core.api.Assertions.assertThat;

/** Reads the language-neutral contracts shared by independently built services. */
public final class ContractAssertions {

    private static final SchemaRegistry SCHEMAS =
            SchemaRegistry.withDefaultDialect(SpecificationVersion.DRAFT_2020_12);

    private ContractAssertions() {
    }

    public static String resource(String name) throws IOException {
        try (var input = ContractAssertions.class.getResourceAsStream("/contracts/" + name)) {
            assertThat(input).as("shared contract resource %s", name).isNotNull();
            return new String(input.readAllBytes(), StandardCharsets.UTF_8);
        }
    }

    public static void valid(String schema, String json) {
        assertThat(SCHEMAS.getSchema(SchemaLocation.of("classpath:contracts/" + schema))
                .validate(json, InputFormat.JSON, context -> context.executionConfig(
                        config -> config.formatAssertionsEnabled(true))))
                .as("event must satisfy %s", schema).isEmpty();
    }

    public static void invalid(String schema, String json) {
        assertThat(SCHEMAS.getSchema(SchemaLocation.of("classpath:contracts/" + schema))
                .validate(json, InputFormat.JSON, context -> context.executionConfig(
                        config -> config.formatAssertionsEnabled(true))))
                .as("invalid event must fail %s", schema).isNotEmpty();
    }

    public static JsonNode fixtures() throws IOException {
        var fixtures = JsonMapper.builder().build().readTree(resource("fixtures.json"));
        for (var fixture : fixtures) {
            assertThat(SCHEMAS.getSchema(SchemaLocation.of("https://json-schema.org/draft/2020-12/schema"))
                    .validate(resource(fixture.path("schema").asText()), InputFormat.JSON))
                    .as("schema must satisfy the Draft 2020-12 meta-schema").isEmpty();
        }
        return fixtures;
    }
}
