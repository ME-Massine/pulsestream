# Container Build Standard

All PulseStream platform services are containerized using a single, shared
Dockerfile convention. Standardizing the build keeps images consistent, easier to
maintain, and ready for Kubernetes deployment.

Every service Dockerfile is identical except for the port it exposes.

---

## Standard Structure

Each service uses a two-stage build:

### Stage 1 — Builder

```dockerfile
FROM eclipse-temurin:25-jdk AS builder

ADD --checksum=sha256:9c1ef9174ef250a5009ed0dec97cbe8699acf7479add4e62bf7b0ea791c0adb5 \
    https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/3.10.1/apache-maven-3.10.1-bin.zip /tmp/apache-maven.zip
RUN mkdir -p /opt/maven \
    && cd /opt/maven \
    && jar -xf /tmp/apache-maven.zip \
    && chmod +x apache-maven-3.10.1/bin/mvn \
    && rm /tmp/apache-maven.zip
ENV MAVEN_HOME=/opt/maven/apache-maven-3.10.1
ENV PATH="${MAVEN_HOME}/bin:${PATH}"

WORKDIR /app

COPY pom.xml .
RUN mvn -B -q -e -DskipTests dependency:go-offline

COPY src ./src
RUN mvn clean package -DskipTests

RUN java -Djarmode=tools -jar target/*.jar extract --layers --launcher --destination extracted
```

* The builder installs Maven 3.10.1 from the same SHA-256-pinned ZIP as the
  service wrappers, using the JDK's `jar` tool. Builds require Docker BuildKit
  with support for [`ADD --checksum`](https://docs.docker.com/reference/dockerfile/#add---checksum).
  A checksum mismatch stops the build. No Maven image tag for Java 26 is used.
* Update the Maven URL, version, and checksum in all three Dockerfiles and
  wrapper properties together. The `maven:3.10.1-eclipse-temurin-25` tag was
  unavailable when this toolchain update was prepared.
* Dependencies are resolved (`dependency:go-offline`) before the source is copied,
  so Docker caches the dependency layer and only rebuilds when `pom.xml` changes.
* The Spring Boot jar is unpacked with the `tools` jar mode (`layertools` was
  removed in Spring Boot 4) into `extracted/`, so its layers can be copied
  individually into the runtime image, maximizing layer reuse across rebuilds.

### Stage 2 — Runtime

```dockerfile
FROM eclipse-temurin:25-jre-jammy

WORKDIR /app

RUN groupadd -r spring && useradd -r -g spring spring

COPY --from=builder /app/extracted/dependencies/ ./
COPY --from=builder /app/extracted/snapshot-dependencies/ ./
COPY --from=builder /app/extracted/spring-boot-loader/ ./
COPY --from=builder /app/extracted/application/ ./

RUN chown -R spring:spring /app

USER spring:spring

EXPOSE <service-port>

ENV JAVA_OPTS="-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0 -XX:+ExitOnOutOfMemoryError"

ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS org.springframework.boot.loader.launch.JarLauncher"]
```

---

## Conventions

| Concern            | Standard                                                                                   |
| ------------------ | ------------------------------------------------------------------------------------------ |
| Base (build) image | `eclipse-temurin:25-jdk` with checksum-pinned Maven 3.10.1                                  |
| Base (runtime) image | `eclipse-temurin:25-jre-jammy` (JRE only, smaller runtime)                                |
| Build strategy     | Multi-stage; Spring Boot layered jar extracted with the `tools` jar mode                    |
| Non-root execution | Dedicated `spring` user/group; `/app` owned by `spring`; `USER spring:spring`              |
| JVM runtime options | `-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0 -XX:+ExitOnOutOfMemoryError`           |
| Entrypoint         | `exec java $JAVA_OPTS org.springframework.boot.loader.launch.JarLauncher`                  |
| Exposed port       | Per-service (see below)                                                                     |

### Production-safe runtime settings

* **`-XX:+UseContainerSupport`** — the JVM honors container CPU/memory limits.
* **`-XX:MaxRAMPercentage=75.0`** — the heap is sized as a percentage of the
  container memory limit rather than a fixed value.
* **`-XX:+ExitOnOutOfMemoryError`** — on `OutOfMemoryError` the JVM terminates
  immediately instead of running in a degraded state, so the orchestrator can
  restart the container.
* **`exec`** — the JVM runs as PID 1, so it receives `SIGTERM` for graceful
  shutdown.
* **Non-root user** — the process runs as the unprivileged `spring` user, which
  is required by Kubernetes `runAsNonRoot` security policies.

### Spring Boot launcher path

Spring Boot 3.2+ moved the launcher to `org.springframework.boot.loader.launch.JarLauncher`.
All services run Spring Boot 4 and must use this path. The pre-3.2 path
`org.springframework.boot.loader.JarLauncher` no longer exists and must not be used.

---

## Exposed Ports

| Service              | Port |
| -------------------- | ---- |
| ingestion-service    | 8081 |
| telemetry-processor  | 8082 |
| query-service        | 8083 |

---

## `.dockerignore`

Every service ships an identical `.dockerignore` so build context stays minimal:

```
target/
.git
.gitignore
node_modules
Dockerfile
README.md
```

---

## Adding a New Service

1. Copy an existing service Dockerfile and `.dockerignore` verbatim.
2. Change only the `EXPOSE` line to the new service's port.
3. Register the port in the table above.
