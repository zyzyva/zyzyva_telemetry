# ZyzyvaTelemetry Built-in Metrics

## Overview
These metrics should be automatically collected by the zyzyva_telemetry library for all applications that use it, requiring zero configuration from the application developer.

## 1. Automatic Repo Instrumentation

### Database Query Metrics (via Ecto Telemetry)
The library should automatically attach to Ecto telemetry events when a repo is provided:

**Automatic events to capture:**
- Query execution time for all queries
- Query queue time (time waiting for connection)
- Connection pool exhaustion events
- Transaction duration and nesting depth
- Rollback events with reasons
- Migration execution times

**Metadata captured:**
- Query type (select, insert, update, delete)
- Table/source name
- Row count (from result)
- Whether query used prepared statement
- Connection pool size at query time
- Transaction ID for correlation

**Smart filtering:**
- Auto-identify slow queries based on configurable threshold (default 100ms)
- Separate metrics for read vs write operations
- Identify N+1 query patterns
- Track queries without indexes (via EXPLAIN when detected slow)

## 2. HTTP/Phoenix Metrics

### Request Lifecycle (via Phoenix Telemetry)
When a Phoenix router is provided, automatically track:

**Request metrics:**
- Request duration (full request/response cycle)
- Response status code distribution
- Request payload size
- Response payload size
- Time to first byte
- Request queuing time

**Routing metrics:**
- Route hit frequency
- 404 rate and paths
- Method distribution (GET, POST, etc.)
- Static vs dynamic request ratio

**Error tracking:**
- 4xx error rate by route
- 5xx error rate by route
- Exception types and frequency
- Error rate trends

## 3. LiveView Metrics

### Automatic LiveView Instrumentation
When Phoenix.LiveView is detected:

**Connection metrics:**
- WebSocket connection establishment time
- Connection drop rate and reasons
- Reconnection success rate
- Message round-trip time
- Concurrent connection count

**Process metrics:**
- LiveView process spawn time
- Memory per LiveView process
- Message queue length
- Process crash rate
- Zombie process detection

**Performance metrics:**
- Mount callback duration
- Handle_event callback duration by event name
- Render time per update
- Diff size per update
- Number of components per view

## 4. System Health Metrics

### BEAM/OTP Metrics
Always collected, no configuration needed:

**Memory metrics:**
- Total memory usage
- Process memory
- Binary memory
- ETS memory
- Atom table size
- Code memory

**Process metrics:**
- Total process count
- Process limit usage percentage
- Scheduler utilization per core
- Run queue lengths
- Port count and limit

**GC metrics:**
- GC run frequency
- GC pause duration
- Memory reclaimed per GC
- Major vs minor GC ratio

## 5. Application Lifecycle Events

### Automatic application events:
- Application start time and duration
- Configuration loading time
- Supervision tree initialization
- Graceful shutdown duration
- Crash/restart events
- Hot code reload events

## 6. Background Job Metrics

### GenServer/Task/Agent Metrics
Automatically instrument all OTP behaviors:

**GenServer metrics:**
- Call duration by function
- Cast processing time
- Message queue depth
- Timeout frequency
- Crash frequency and reasons

**Task metrics:**
- Task spawn time
- Task completion time
- Task failure rate
- Async vs await usage

**Registry metrics:**
- Process registration/deregistration
- Name conflicts
- Lookup performance

## 7. External Service Call Tracking

### HTTP Client Metrics
Automatically instrument Finch/Hackney/HTTPoison:

**Request metrics:**
- External API call duration
- Response status distribution
- Timeout rate
- Retry attempts
- DNS resolution time
- SSL handshake time

**Circuit breaker metrics:**
- Circuit state changes
- Request rejection rate
- Success rate after recovery

## 8. Error & Crash Reporting

### Automatic error capture:
- Process crash with full stacktrace
- Supervisor restart events
- Logger error/critical messages
- Uncaught exceptions
- Pattern match failures in critical paths
- ETS/DETS errors
- File system errors

**Context included:**
- Process dictionary at crash time
- Supervisor restart intensity
- Memory state at crash
- Message queue contents (sanitized)
- Recent telemetry events (breadcrumbs)

## 9. Dependency Health

### Library metrics:
- Dependency initialization time
- Version conflicts detected
- Native dependency compilation time
- NIF crashes
- Port driver failures

## 10. Correlation & Tracing

### Automatic correlation:
- Request ID propagation through all events
- Parent-child span relationships
- Cross-service correlation (via headers)
- Async task correlation
- Background job correlation to originating request

## Configuration Interface

The library should provide simple configuration to control automatic instrumentation:

```elixir
config :zyzyva_telemetry,
  auto_instrument: [
    ecto: true,           # Auto-instrument Repo queries
    phoenix: true,        # Auto-instrument HTTP requests
    live_view: true,      # Auto-instrument LiveView
    otp: true,           # Auto-instrument GenServers/Tasks
    http_client: true,    # Auto-instrument external HTTP
    slow_query_ms: 100,  # Threshold for slow query tracking
    large_payload_kb: 100 # Threshold for large payload warning
  ],
  sampling: [
    traces: 0.1,         # Sample 10% of traces
    metrics: 1.0,        # Collect all metrics
    errors: 1.0          # Collect all errors
  ]
```

## Privacy & Security Built-in

### Automatic PII Protection:
- Parameter filtering for passwords, tokens, keys
- Email masking in logs and events
- Credit card number detection and masking
- SSN/ID number pattern detection
- IP address anonymization option
- User ID hashing option

### Automatic sensitive path filtering:
- Don't log parameters for /auth, /login, /session routes
- Skip body logging for /payment, /checkout routes
- Redact authorization headers
- Skip cookie values

## Performance Optimization

### Smart batching and sampling:
- Batch telemetry events before sending
- Adaptive sampling based on load
- Automatic back-pressure handling
- Circular buffer for high-frequency events
- Aggregation for counter-style metrics

### Resource limits:
- Max memory for telemetry buffering
- Max telemetry events per second
- Automatic degradation under load
- Priority queue for critical events

## Developer Experience

### Automatic features that help developers:
- Development environment dashboard at /_telemetry
- Slow query warnings in development logs
- N+1 query detection and warnings
- Memory leak detection
- Process leak detection
- Automatic performance regression detection

### Testing helpers:
- Telemetry assertions for tests
- Mock telemetry collector for testing
- Performance benchmarking helpers
- Load testing metric collection

## Deployment & Operations

### Automatic deployment tracking:
- Deploy start/end events
- Migration run telemetry
- Configuration changes
- Feature flag changes
- Blue-green deployment metrics
- Canary deployment health

### Kubernetes/Container metrics (when detected):
- Pod lifecycle events
- Resource limit approaching
- Health check latency
- Readiness probe results
- Container restart events

## Summary

By implementing these metrics at the library level, every application using zyzyva_telemetry gets:

1. **Zero-configuration observability** - Works out of the box
2. **Best practices by default** - Slow query detection, error tracking, etc.
3. **Performance insights** - Without manual instrumentation
4. **Privacy protection** - Built-in PII filtering
5. **Smart resource usage** - Adaptive sampling and batching
6. **Developer productivity** - Warnings and insights in development

The application developer can then focus on adding business-specific telemetry while getting comprehensive infrastructure and performance monitoring automatically.