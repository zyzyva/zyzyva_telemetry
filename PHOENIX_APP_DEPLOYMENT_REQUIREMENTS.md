# Phoenix App Deployment Requirements

> **Note**: This document is copied from the provisioner application for convenience. The ZyzyvaTelemetry library provides ready-to-use health endpoint implementations that fully comply with these requirements.

## Overview
This document outlines the requirements for Phoenix applications to be compatible with the infrastructure automation deployment system. Applications must follow these conventions to ensure successful automated blue-green deployments.

---

## 📋 Required Application Structure

### 1. **Health Endpoint**
**Requirement**: Your Phoenix app MUST expose a `/health` endpoint that returns HTTP 200 when the application is fully operational.

**Implementation with ZyzyvaTelemetry**:
```elixir
# IMPORTANT: ZyzyvaTelemetry.HealthController is a Plug, not a Phoenix controller
# Use Plug syntax (verified working):
get "/health", ZyzyvaTelemetry.HealthController, []
```

**Manual Implementation** (if not using ZyzyvaTelemetry):
```elixir
# In your router.ex
scope "/", YourAppWeb do
  get "/health", HealthController, :index
end

# Create lib/your_app_web/controllers/health_controller.ex
defmodule YourAppWeb.HealthController do
  use YourAppWeb, :controller

  def index(conn, _params) do
    # Verify all critical services are operational
    with :ok <- check_database_connection(),
         :ok <- check_rabbitmq_connection(),
         :ok <- check_external_dependencies() do
      
      json(conn, %{
        status: "healthy",
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        version: Application.spec(:your_app, :vsn),
        checks: %{
          database: "connected",
          rabbitmq: "connected",
          external_services: "available"
        }
      })
    else
      {:error, service} ->
        conn
        |> put_status(503)
        |> json(%{
          status: "unhealthy", 
          failed_service: service,
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
        })
    end
  end

  defp check_database_connection do
    case Ecto.Adapters.SQL.query(YourApp.Repo, "SELECT 1", []) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, "database"}
    end
  end

  defp check_rabbitmq_connection do
    # Add your RabbitMQ health check logic
    :ok
  end

  defp check_external_dependencies do
    # Check any external APIs your app depends on
    :ok
  end
end
```

### 2. **Environment Configuration**
**Requirement**: Your app MUST read all configuration from environment variables, not hardcoded values.

**Environment File Structure** (`.env` in your app root):
```bash
# Database Configuration
DATABASE_URL="postgresql://user:password@postgres.example.com:5432/your_app_prod"

# RabbitMQ Configuration  
RABBITMQ_URL="amqp://user:password@rabbitmq.example.com:5672/your_app_vhost"

# Application Configuration
SECRET_KEY_BASE="your-secret-key-base-64-chars-minimum"
PHX_HOST="your-app.com"
PORT=4000

# External Service Credentials (if needed)
EXTERNAL_API_KEY="your-api-key"
EXTERNAL_SERVICE_URL="https://api.example.com"

# Feature Flags
ENABLE_FEATURE_X=true
DEBUG_MODE=false
```

### 3. **Runtime Configuration**
**Requirement**: Use `config/runtime.exs` to read environment variables at runtime.

**Implementation**:
```elixir
# config/runtime.exs
import Config

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
    raise """
    environment variable DATABASE_URL is missing.
    For example: postgresql://USER:PASS@HOST/DATABASE
    """

  config :your_app, YourApp.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: [:inet6]

  rabbitmq_url =
    System.get_env("RABBITMQ_URL") ||
    raise """
    environment variable RABBITMQ_URL is missing.
    For example: amqp://USER:PASS@HOST:PORT/VHOST
    """

  config :your_app, :rabbitmq,
    url: rabbitmq_url

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
    raise """
    environment variable SECRET_KEY_BASE is missing.
    You can generate one by calling: mix phx.gen.secret
    """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :your_app, YourAppWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base
end
```

**For applications using SQLite**, add DATABASE_PATH configuration:
```elixir
# Additional configuration for SQLite repos
database_path =
  System.get_env("DATABASE_PATH") ||
  raise """
  environment variable DATABASE_PATH is missing.
  For example: /opt/phoenix-data/sqlite/your_app/database.db
  """

config :your_app, YourApp.SQLiteRepo,
  adapter: Ecto.Adapters.SQLite3,
  database: database_path,
  pool_size: 5
```

**SQLite Database Path Convention:**
All SQLite databases in production follow a standardized path structure:
- **Location**: `/opt/phoenix-data/sqlite/{app_name}/`
- **Example**: `/opt/phoenix-data/sqlite/representation4us/database.db`
- **Benefits**: Centralized data location, simplified backups, consistent permissions
- **Infrastructure**: The deployment system automatically creates this directory structure

### 4. **Release Configuration & Migration Support**
**Requirement**: Your app MUST be configured for Elixir releases AND have migration scripts generated.

**Step 1: Generate Release Files**
Run this command to generate the required release configuration and migration scripts:
```bash
mix phx.gen.release
```

This command creates:
- `lib/your_app/release.ex` - Migration runner module
- `rel/overlays/bin/migrate` - Executable migration script
- `rel/overlays/bin/server` - Server start script with PHX_SERVER=true
- `rel/env.sh.eex` - Environment configuration script

**Step 2: Update `mix.exs`** (if not already done by generator):
```elixir
def project do
  [
    app: :your_app,
    version: "0.1.0",
    elixir: "~> 1.18",
    # ... other config
    releases: [
      your_app: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent],
        steps: [:assemble, :tar],
        overlays: ["rel/overlays"]  # Important for migration scripts
      ]
    ]
  ]
end
```

**Step 3: Migration Module** (`lib/your_app/release.ex`):
```elixir
defmodule YourApp.Release do
  @moduledoc """
  Used for executing DB migrations when run in production without Mix.
  """
  @app :your_app

  def migrate do
    load_app()

    for repo <- repos() do
      # Create SQLite database if it doesn't exist (for SQLite repos only)
      if sqlite_repo?(repo) do
        ensure_sqlite_database_exists(repo)
      end
      
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end

  # SQLite database creation and configuration
  defp sqlite_repo?(repo) do
    config = repo.config()
    config[:adapter] == Ecto.Adapters.SQLite3
  end

  defp ensure_sqlite_database_exists(repo) do
    config = repo.config()
    db_path = config[:database]
    
    unless File.exists?(db_path) do
      # Create parent directory
      File.mkdir_p!(Path.dirname(db_path))
      
      # Create database with WAL mode enabled
      {:ok, conn} = :sqlite3.open(String.to_charlist(db_path))
      :sqlite3.exec(conn, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
      :sqlite3.close(conn)
    end
  end
end
```

**Step 4: Migration Script** (`rel/overlays/bin/migrate`):
```bash
#!/bin/sh
set -eu

cd -P -- "$(dirname -- "$0")"
exec ./your_app eval "YourApp.Release.migrate()"
```

Make the script executable:
```bash
chmod +x rel/overlays/bin/migrate
```

**Why This Is Required:**
The infrastructure worker needs to run database migrations automatically during deployment. It executes:
```bash
/opt/your_app/bin/migrate
```
This ensures your database schema is updated before the new version starts serving traffic.

**For PostgreSQL apps:** The provisioner creates the database, and migrations run against the existing database.

**For SQLite apps:** The migration script creates the database file if it doesn't exist (including WAL mode configuration), then runs migrations. This handles the complete SQLite database lifecycle during deployment.

**SQLite Database Management:**
- **Standard Location**: All SQLite databases are created in `/opt/phoenix-data/sqlite/{app_name}/`
- **WAL Mode**: Automatically configured for better concurrency and performance
- **Backup Strategy**: The entire `/opt/phoenix-data/sqlite/` directory is backed up regularly by system-level processes
- **Permissions**: Managed by deployment system to ensure `deploy` user access

---

## 🔧 Deployment Integration

### 1. **Systemd Service Compatibility**
Your app will be deployed as a systemd service. Ensure:

- App starts with `./bin/your_app start`
- App stops gracefully with `./bin/your_app stop`
- App responds to standard signals (SIGTERM for graceful shutdown)

### 2. **Port Management**
- Your app will be assigned ports automatically (e.g., 4010/4011 for blue-green)
- Read the `PORT` environment variable for the assigned port
- Don't hardcode port numbers in your application

### 3. **File Permissions**
- App files will be owned by `deploy` user
- Ensure your app doesn't require root permissions
- Log files should write to `/var/log/your_app/` (will be created)


## 📁 Project File Requirements

### 1. **Required Files**
Your repository MUST include:
```
your_app/
├── .env.example          # Template showing required environment variables
├── mix.exs              # With proper release configuration
├── config/runtime.exs   # Runtime environment configuration
├── lib/
│   ├── your_app/
│   │   └── release.ex   # Migration runner module (generated by mix phx.gen.release)
│   └── your_app_web/
│       └── controllers/
│           └── health_controller.ex  # Health endpoint (or use ZyzyvaTelemetry)
└── rel/
    ├── env.sh.eex       # Environment setup (generated by mix phx.gen.release)
    └── overlays/
        └── bin/
            ├── migrate  # Migration script (generated by mix phx.gen.release)
            └── server   # Server start script (generated by mix phx.gen.release)
```

### 2. **`.env.example` Template**
Create a template showing all required environment variables:
```bash
# Database Configuration
DATABASE_URL=postgresql://user:password@host:5432/database

# RabbitMQ Configuration
RABBITMQ_URL=amqp://user:password@host:5672/vhost

# Application Configuration
SECRET_KEY_BASE=generate_with_mix_phx_gen_secret
PHX_HOST=your-domain.com
PORT=4000

# External Services (if applicable)
EXTERNAL_API_KEY=your-api-key

# Feature Flags (if applicable)
ENABLE_FEATURE_X=true
```

### 3. **Documentation**
Include a `DEPLOYMENT.md` file with:
- Description of your app's purpose
- List of required environment variables
- Any special deployment considerations
- Health check endpoint behavior
- External dependencies

---

## 🚀 Deployment Process

### 1. **What Happens During Deployment**
1. **Git Clone**: Your repository is cloned to the deployment server
2. **Dependencies**: `mix deps.get --only prod` is executed
3. **Assets**: Assets are compiled if present (`mix assets.deploy`)
4. **Release**: `MIX_ENV=prod mix release` creates the release
5. **Database Migration**: `/opt/your_app/bin/migrate` is executed to update the database schema
6. **Service**: Systemd service is created and started
7. **Health Check**: Infrastructure worker calls your `/health` endpoint
8. **Traffic Switch**: nginx routes traffic to your app only after health checks pass

### 2. **Environment Setup**
Your `.env` file will be created by the infrastructure team with:
- Production database credentials
- Production RabbitMQ credentials  
- Domain-specific configuration
- Generated secrets (SECRET_KEY_BASE, etc.)

### 3. **Blue-Green Deployment**
- Your app will run on two ports (e.g., 4010 and 4011)
- New deployments go to the inactive port
- Traffic switches only after health checks pass
- Old version remains available for quick rollback

---

## ✅ Pre-Deployment Checklist

Before requesting deployment, ensure your app:

- [ ] **Health Endpoint**: Responds with 200 when healthy, 503 when unhealthy (✅ automatic with ZyzyvaTelemetry)
- [ ] **Environment Variables**: All configuration read from environment, no hardcoded values
- [ ] **Runtime Config**: Uses `config/runtime.exs` for production configuration
- [ ] **Release Configuration**: Has run `mix phx.gen.release` to generate migration scripts
- [ ] **Migration Scripts**: Contains `rel/overlays/bin/migrate` executable script
- [ ] **Release Module**: Has `lib/your_app/release.ex` with migration functions
- [ ] **Release Ready**: Can be built with `MIX_ENV=prod mix release`
- [ ] **Database Independence**: Doesn't assume specific database host/credentials
- [ ] **Port Flexibility**: Reads PORT environment variable for HTTP server
- [ ] **Graceful Shutdown**: Handles SIGTERM for clean shutdowns
- [ ] **No Root Required**: Runs under unprivileged user account
- [ ] **Documentation**: Includes `.env.example` and deployment docs
- [ ] **Testing**: Health endpoint tested with actual dependencies

---

## 🔍 Testing Your App

### Local Testing
Test your app's deployment readiness:

```bash
# 1. Test with environment variables
export DATABASE_URL="postgresql://localhost/your_app_test"
export PORT=4001
export SECRET_KEY_BASE=$(mix phx.gen.secret)

# 2. Build release
MIX_ENV=prod mix release

# 3. Test migration script
_build/prod/rel/your_app/bin/migrate

# 4. Start the release
_build/prod/rel/your_app/bin/server

# 5. Test health endpoint
curl http://localhost:4001/health

# 6. Verify response
# Should return 200 with {"status": "healthy", ...}
```

### Health Endpoint Testing
```bash
# Test healthy state
curl -i http://localhost:4001/health

# Expected response:
# HTTP/1.1 200 OK
# {"status":"healthy","timestamp":"2025-09-04T15:30:00Z",...}

# Test unhealthy state (stop database, etc.)
# Expected response:
# HTTP/1.1 503 Service Unavailable
# {"status":"unhealthy","failed_service":"database",...}
```

---

## 🛠️ Troubleshooting

### Common Issues

1. **Health Check Fails**
   - Verify `/health` endpoint returns 200 when all services are operational
   - Check database and RabbitMQ connections in health endpoint
   - Ensure app starts on the assigned PORT

2. **Migration Script Missing or Fails**
   - Ensure you ran `mix phx.gen.release` to generate the scripts
   - Verify `rel/overlays/bin/migrate` is executable (`chmod +x`)
   - Check that `lib/your_app/release.ex` exists with migrate function
   - Test migrations locally: `_build/prod/rel/your_app/bin/migrate`
   - Ensure DATABASE_URL is set correctly in production

3. **Environment Variables**
   - Use `config/runtime.exs` instead of compile-time config
   - Provide `.env.example` with all required variables
   - Test with various environment configurations

4. **Release Build Fails**
   - Ensure all dependencies are compatible with releases
   - Check that assets compile correctly
   - Verify `mix.exs` has proper release configuration
   - Confirm `overlays: ["rel/overlays"]` is in release config

5. **Service Won't Start**
   - Check systemd logs: `journalctl -u your_app`
   - Verify file permissions for deploy user
   - Ensure no hardcoded paths or dependencies
   - Check migration ran successfully before service start

6. **Traffic Not Routing**
   - Health endpoint must return 200 consistently
   - Check nginx configuration and port assignments
   - Verify app binds to `0.0.0.0`, not `localhost`

---

## 📞 Support

If you encounter issues with deployment:

1. **Check health endpoint**: Ensure it works locally first
2. **Review logs**: Application logs will be in `/var/log/your_app/`
3. **Verify environment**: Compare your `.env` with `.env.example`
4. **Test release**: Build and test the release locally before deployment

For infrastructure issues, contact the DevOps team with:
- App name and version
- Health endpoint test results
- Local release build confirmation
- Specific error messages from deployment

This standardized approach ensures reliable, secure, and maintainable deployments across all Phoenix applications in the infrastructure.

---

## 🎯 ZyzyvaTelemetry Integration

**When using ZyzyvaTelemetry in your Phoenix app, the health endpoint requirements are automatically satisfied:**

1. **Add to your supervision tree:**
```elixir
children = [
  # ... other children
  {ZyzyvaTelemetry.MonitoringSupervisor,
   service_name: "my_app",
   repo: MyApp.Repo,
   broadway_pipelines: [MyApp.Pipeline.Broadway]}
]
```

2. **Add health endpoint to router:**
```elixir
# ZyzyvaTelemetry.HealthController is a Plug (verified working)
get "/health", ZyzyvaTelemetry.HealthController, []
```

3. **Health checks are automatically included:**
   - Database connectivity (if repo provided)
   - Memory usage and thresholds
   - Process count monitoring  
   - Custom health checks (RabbitMQ, external APIs)
   - Proper HTTP status codes (200/503)
   - RFC-compliant JSON responses

**The ZyzyvaTelemetry library handles all health endpoint complexity for you, ensuring full compliance with deployment requirements.**