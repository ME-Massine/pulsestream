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

FROM eclipse-temurin:25-jre-jammy

WORKDIR /app

RUN groupadd -r spring && useradd -r -g spring spring

COPY --from=builder /app/extracted/dependencies/ ./
COPY --from=builder /app/extracted/snapshot-dependencies/ ./
COPY --from=builder /app/extracted/spring-boot-loader/ ./
COPY --from=builder /app/extracted/application/ ./

RUN chown -R spring:spring /app

USER spring:spring

EXPOSE 8081

ENV JAVA_OPTS="-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0 -XX:+ExitOnOutOfMemoryError"

ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS org.springframework.boot.loader.launch.JarLauncher"]
