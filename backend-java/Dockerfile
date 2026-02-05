# Build args used in FROM must be declared before the first FROM.
ARG BASE_IMAGE_JDK=eclipse-temurin:17-jdk
ARG BASE_IMAGE_JRE=eclipse-temurin:17-jre

# ---- Build stage ----
FROM ${BASE_IMAGE_JDK} AS build
WORKDIR /app

# Leverage Docker layer cache for Maven dependencies
COPY pom.xml ./

# Download deps first (fast rebuilds)
RUN mvn -q -DskipTests dependency:go-offline

# Now copy sources and build
COPY src src
RUN mvn -q -DskipTests package \
  && ls -1 target/backend-*.jar | grep -v '\\.original$' | head -n 1 > /tmp/jar_path

# ---- Runtime stage ----
FROM ${BASE_IMAGE_JRE}
WORKDIR /app

COPY --from=build /tmp/jar_path /tmp/jar_path
COPY --from=build /app/target/backend-*.jar /app/

# Pick the non-original fat jar
RUN set -euo pipefail; \
  JAR="$(cat /tmp/jar_path)"; \
  cp "/app/${JAR#target/}" /app/app.jar

EXPOSE 8000

# Common overrides for deployments:
# - APP_DB_PATH=/data/flutterai.db
# - APP_UPLOADS_DIR=/data/uploads
# - APP_AI_ENABLED=true/false
ENV SERVER_PORT=8000

ENTRYPOINT ["java","-jar","/app/app.jar"]
