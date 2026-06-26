package com.pulsestream.processor.config;

import org.junit.jupiter.api.Test;
import org.postgresql.Driver;

import java.sql.DriverManager;

import static org.assertj.core.api.Assertions.assertThat;

class JpaDependencyAvailabilityTest {

    @Test
    void springDataJpaAndPostgresqlDriverAreAvailable() throws Exception {
        assertThat(Class.forName("jakarta.persistence.EntityManager")).isNotNull();
        assertThat(Class.forName("org.springframework.data.jpa.repository.JpaRepository")).isNotNull();
        assertThat(Class.forName("org.postgresql.Driver")).isNotNull();
        assertThat(DriverManager.getDriver("jdbc:postgresql:"))
                .isInstanceOf(Driver.class);
    }
}
