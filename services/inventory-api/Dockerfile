# inventory-api — multi-stage build (ARM64 compatible)
# Compila el jar desde el repo público y lo corre en un runtime JRE.

FROM eclipse-temurin:21-jdk AS build
ARG INVENTORY_SHA=main
WORKDIR /src
RUN apt-get update -qq && apt-get install -y -qq git >/dev/null 2>&1 && rm -rf /var/lib/apt/lists/*
RUN git init -q . \
    && git remote add origin https://github.com/YamiDarknezz/inventory-api.git \
    && git fetch -q --depth 1 origin ${INVENTORY_SHA} \
    && git checkout -q FETCH_HEAD
RUN ./mvnw -q package -DskipTests

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /src/target/inventory-api-*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
