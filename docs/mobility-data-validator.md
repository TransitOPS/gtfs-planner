# MobilityData GTFS Validator

The [MobilityData GTFS Validator](https://github.com/MobilityData/gtfs-validator) is used to validate GTFS feeds. This document describes how to install and configure it for both local development and Docker environments.

## Local Development Setup

### 1. Install Java 21
The validator is a Java application and requires Java 21.

On macOS with Homebrew:
```bash
brew install openjdk@21
```

For the system to find this JDK, you may need to add it to your PATH:
```bash
export PATH="/opt/homebrew/opt/openjdk@21/bin:$PATH"
```

### 2. Download the Validator JAR
Download the validator CLI JAR into the `priv/gtfs_validator` directory. We use version `7.1.0` for consistency with the production environment.

```bash
mkdir -p priv/gtfs_validator
curl -L -o priv/gtfs_validator/gtfs-validator-cli.jar \
  "https://github.com/MobilityData/gtfs-validator/releases/download/v7.1.0/gtfs-validator-7.1.0-cli.jar"
```

## Docker Configuration (Production)

The validator is automatically installed in the Docker image as part of the build process.

- **Installation Path:** `/opt/gtfs-validator/gtfs-validator-cli.jar`
- **Dependency:** `temurin-21-jre` is installed via the Adoptium Debian repository.

## Elixir Configuration

The application uses the `:gtfs_validator_path` configuration key to locate the JAR file. This is configured in `config/runtime.exs` to support different environments seamlessly.

### Configuration Logic
The path is resolved in the following order of priority:

1.  **Environment Variable:** `GTFS_VALIDATOR_JAR` (if set).
2.  **Production Default:** `/opt/gtfs-validator/gtfs-validator-cli.jar` (when `MIX_ENV=prod`).
3.  **Local Default:** `priv/gtfs_validator/gtfs-validator-cli.jar` (relative to the project root).

### Example Usage in Elixir
To get the path in your code:
```elixir
validator_path = Application.get_env(:gtfs_planner, :gtfs_validator_path)
```

To execute the validator:
```elixir
System.cmd("java", ["-jar", validator_path, "--input", "path/to/gtfs.zip", "--output", "path/to/output"])
```
