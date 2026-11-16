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
- Container images build on `eclipse-temurin:25-jdk` with SHA-256-pinned Maven
  3.10.1, matching the version and ZIP checksum of the committed wrappers,
  and run on `eclipse-temurin:25-jre-jammy`.

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

The Docker configuration in `.github/dependabot.yml` retains an ignore rule for
the `maven` image in all three service directories. Current builders install
Maven directly from its verified Apache distribution because the matching
`maven:3.10.1-eclipse-temurin-25` tag was unavailable. The container build
standard documents the checksum-enforced bootstrap. Maven distribution updates,
including fixes on Java 25, require a coordinated change to the Dockerfile
bootstrap and Maven wrappers.
Dependabot's Docker version constraints compare the numeric release rather than
the Java suffix, so they cannot selectively exclude Java 26 tags while retaining
Java 25 tags for the same Maven release. Other Docker images and Maven library
updates remain enabled. Review the builder image and wrapper together during
dependency maintenance and remove or revise the ignore rule with the next
coordinated toolchain upgrade.

References: [Dependabot ignore options](https://docs.github.com/en/code-security/reference/supply-chain-security/dependabot-options-reference#ignore)
and [Docker requirement comparison](https://github.com/dependabot/dependabot-core/blob/main/docker/lib/dependabot/docker/requirement.rb).
