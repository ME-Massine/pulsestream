package com.pulsestream.processor.config;

import java.util.concurrent.Executor;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.scheduling.annotation.EnableAsync;
import org.springframework.scheduling.concurrent.ThreadPoolTaskExecutor;

@Configuration
@EnableAsync
public class AsyncConfiguration {

    private static final Logger log = LoggerFactory.getLogger(AsyncConfiguration.class);

    @Bean(name = "persistenceExecutor")
    public Executor persistenceExecutor() {
        ThreadPoolTaskExecutor executor = new ThreadPoolTaskExecutor();
        executor.setCorePoolSize(2);
        executor.setMaxPoolSize(4);
        executor.setQueueCapacity(500);
        executor.setThreadNamePrefix("telemetry-persist-");
        executor.setRejectedExecutionHandler((r, pool) ->
                log.warn("Persistence task rejected — executor queue full; event will not be persisted to DB"));
        executor.initialize();
        return executor;
    }
}
