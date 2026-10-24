# ADR 0006: Use Java 25 LTS as the runtime baseline

## Status
Accepted

Supersedes the Java 17 runtime baseline stated in [ADR 0002](./0002-use-spring-boot.md).

## Context

ADR 0002 set Java 17 as the runtime baseline. Since then, the services moved to
Spring Boot 4, which supports Java 17 through 25, and Dependabot started proposing
container image updates that mixed toolchains: a Java 26 Maven builder image with
a Java 25 runtime image, while the POMs, CI, and CodeQL still compiled and tested
on Java 17.

Running different Java versions for compilation, CI verification, and the
container runtime means the tested bytecode and JVM are not the ones that ship.
Java 26 is a non-LTS release with a six-month support window, which does not suit
a platform runtime.

## Decision

Java 25, the current LTS release, is the single Java version for the platform
services:

- `java.version` is `25` in every service POM, so `maven-compiler-plugin` compiles
  with `--release 25`.
- CI service verification and CodeQL builds run on Temurin 25.
- Container images build on `maven:3.10.0-eclipse-temurin-25`, matching the Maven
  version of the committed wrapper, and run on `eclipse-temurin:25-jre-jammy`.

Non-LTS Java releases are not adopted for builds or runtimes.

## Consequences

### Positive
- Compilation, tests, coverage, static analysis, and the shipped runtime use the
  same JVM.
- The platform stays on a supported LTS line well beyond Java 17's end of public
  updates.

### Negative
- Bytecode targets Java 25, so the services no longer run on older JVMs. Local
  development requires a JDK 25.
- Future Java upgrades remain a coordinated change across POMs, workflows, images,
  and documentation.

## Notes

Dependabot keeps proposing newer non-LTS builder images. Those updates are
declined in favour of the next LTS release, delivered as one coordinated change.
