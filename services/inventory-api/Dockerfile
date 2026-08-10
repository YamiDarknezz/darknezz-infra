# inventory-api — multi-stage build (ARM64 compatible)
# Compila el jar desde el repo público y lo corre en un runtime JRE.

FROM eclipse-temurin:21-jdk AS build
WORKDIR /src
RUN git clone --depth 1 https://github.com/YamiDarknezz/inventory-api.git .
RUN ./mvnw -q package -DskipTests

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /src/target/inventory-api-*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
