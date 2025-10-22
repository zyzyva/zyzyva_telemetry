# Built-in Metrics Implementation Plan
## Implementing the Vision from BUILT_IN_METRICS.md

**Status:** Planning Phase
**Target Completion:** TBD
**Priority:** High (enables zero-config observability for all ecosystem apps)

---

## Current State Analysis

### What PromEx Already Provides (via Standard Plugins)

#### ✅ Ecto Plugin (Basic)
- Query execution time (as histogram)
- Query count
- Repo pool checkout duration
- Repo pool queue time
- Connection count

**Missing from BUILT_IN_METRICS.md wishlist:**
- ❌ Slow query threshold detection (>100ms)
- ❌ N+1 query pattern detection
- ❌ Query type classification (read vs write)
- ❌ Transaction rollback tracking
- ❌ Automatic EXPLAIN for slow queries

#### ✅ Phoenix Plugin (Basic)
- Request duration
- Request count by status code
- Request count by route

**Missing from wishlist:**
- ❌ Request payload size tracking
- ❌ Response payload size tracking
- ❌ Static vs dynamic request ratio
- ❌ 404 rate and path tracking

#### ✅ Phoenix LiveView Plugin (Basic)
- Mount duration
- Handle event duration
- Handle info duration
- Render duration

**Missing from wishlist:**
- ❌ WebSocket connection establishment time
- ❌ Connection drop rate and reasons
- ❌ Message queue length per LiveView process
- ❌ Diff size per update
- ❌ Zombie process detection

#### ✅ BEAM Plugin (Comprehensive)
- Memory metrics (all types)
- Process count
- Scheduler utilization
- Run queue lengths

**Status:** Already matches BUILT_IN_METRICS.md spec ✅

---

## Implementation Phases

### Phase 1: Enhanced Ecto Monitoring (Priority: HIGH)

**Goal:** Add intelligent query monitoring beyond basic metrics

#### 1.1 Slow Query Detection
**Files to create:**
- `lib/zyzyva_telemetry/plugins/enhanced_ecto.ex`
- `test/zyzyva_telemetry/plugins/enhanced_ecto_test.exs`

**Implementation:**
- Attach to `:ecto.repo.query` telemetry events
- Track queries exceeding configurable threshold (default 100ms)
- Emit custom events: `[:zyzyva, :ecto, :slow_query]`
- Include metadata: source table, query type, duration, stacktrace location
- Create Prometheus counter for slow queries by source
- Optionally log slow queries to Tower with context

**Configuration:**
```elixir
config :zyzyva_telemetry, :ecto,
  slow_query_threshold_ms: 100,
  log_slow_queries: true
```

#### 1.2 Query Type Classification
**Implementation:**
- Parse Ecto query `command` metadata (`:select`, `:insert`, `:update`, `:delete`)
- Add `query_type` tag to all Ecto metrics
- Create separate histograms for read vs write operations
- Track read/write ratios as Prometheus gauges

#### 1.3 Transaction Tracking
**Implementation:**
- Attach to transaction telemetry events
- Track transaction duration
- Count rollbacks vs commits
- Identify nested transactions
- Emit `[:zyzyva, :ecto, :transaction, :rollback]` with reason

#### 1.4 N+1 Query Detection (Optional - Complex)
**Implementation approach:**
- Track queries within same process grouped by time window (50ms)
- Detect repeated similar queries (same table, different params)
- Emit warning event when pattern detected
- Log to Tower with parent query context

**Configuration:**
```elixir
config :zyzyva_telemetry, :ecto,
  detect_n_plus_1: true,
  n_plus_1_window_ms: 50,
  n_plus_1_threshold: 5  # queries with same source
```

---

### Phase 2: Enhanced Phoenix Monitoring (Priority: MEDIUM)

#### 2.1 Payload Size Tracking
**Files to modify:**
- `lib/zyzyva_telemetry/plugins/enhanced_phoenix.ex` (new)

**Implementation:**
- Create a Phoenix plug to measure request/response sizes
- Use `Phoenix.Controller` lifecycle hooks
- Track as Prometheus histograms with route labels
- Alert on large payloads (>1MB configurable)

**Plug implementation:**
```elixir
defmodule ZyzyvaTelemetry.Plugs.PayloadTracker do
  def call(conn, _opts) do
    start_time = System.monotonic_time()

    conn
    |> Plug.Conn.register_before_send(fn conn ->
      duration = System.monotonic_time() - start_time
      :telemetry.execute(
        [:zyzyva, :phoenix, :payload],
        %{
          request_size: get_content_length(conn),
          response_size: calculate_response_size(conn),
          duration: duration
        },
        %{route: phoenix_route(conn)}
      )
      conn
    end)
  end
end
```

#### 2.2 Static vs Dynamic Tracking
**Implementation:**
- Inspect route pattern
- Tag requests as `:static` or `:dynamic` based on path
- Create separate counters for each type
- Calculate ratios in Prometheus queries

---

### Phase 3: Enhanced LiveView Monitoring (Priority: MEDIUM)

#### 3.1 WebSocket Connection Metrics
**Files to create:**
- `lib/zyzyva_telemetry/plugins/enhanced_live_view.ex`

**Implementation:**
- Attach to Phoenix LiveView socket telemetry
- Track `[:phoenix, :live_view, :mount]` with connection type
- Track connection establishment time
- Count connection drops via `[:phoenix, :channel, :terminated]`
- Measure reconnection success rate

#### 3.2 LiveView Process Health
**Implementation:**
- Use `:telemetry_poller` to periodically check LiveView processes
- Measure message queue length via `Process.info(pid, :message_queue_len)`
- Track memory per LiveView process
- Detect "zombie" processes (long-lived with no activity)
- Emit `[:zyzyva, :live_view, :process, :zombie]` events

**Poller setup:**
```elixir
:telemetry_poller.start_link(
  measurements: [
    {ZyzyvaTelemetry.LiveViewMonitor, :measure_health, []}
  ],
  period: :timer.seconds(30)
)
```

#### 3.3 Diff Size Tracking
**Implementation:**
- Wrap LiveView render callback
- Calculate diff size from rendered result
- Track as histogram
- Alert on large diffs (>100KB)

---

### Phase 4: HTTP Client Instrumentation (Priority: HIGH)

#### 4.1 Finch Telemetry
**Files to create:**
- `lib/zyzyva_telemetry/plugins/finch.ex`
- `test/zyzyva_telemetry/plugins/finch_test.exs`

**Implementation:**
- Attach to Finch telemetry events
- Track request duration by host
- Track response status distribution
- Measure DNS resolution time
- Measure SSL handshake time
- Count timeouts and retries
- Create Prometheus histograms for all metrics

**Events to attach:**
- `[:finch, :request, :start]`
- `[:finch, :request, :stop]`
- `[:finch, :request, :exception]`
- `[:finch, :response, :start]`
- `[:finch, :response, :stop]`

---

### Phase 5: Automatic PII Protection (Priority: HIGH)

#### 5.1 Parameter Filtering
**Files to create:**
- `lib/zyzyva_telemetry/pii_filter.ex`
- `test/zyzyva_telemetry/pii_filter_test.exs`

**Implementation:**
- Create centralized PII filter module
- Automatically redact known patterns:
  - Passwords (any field with "password" in name)
  - Tokens (any field with "token", "api_key", "secret")
  - Email addresses (mask format: `j***@example.com`)
  - Credit cards (detect via Luhn algorithm)
  - SSN/ID numbers (pattern matching)
- Apply to all telemetry metadata before emission
- Make filter patterns configurable

**Configuration:**
```elixir
config :zyzyva_telemetry, :pii,
  filter_patterns: [:password, :token, :api_key, :secret],
  mask_email: true,
  mask_phone: true,
  detect_credit_cards: true,
  custom_patterns: [~r/custom_sensitive_field/]
```

**Filter module:**
```elixir
defmodule ZyzyvaTelemetry.PIIFilter do
  def filter_metadata(metadata) do
    metadata
    |> filter_passwords()
    |> filter_tokens()
    |> mask_emails()
    |> detect_and_mask_credit_cards()
    |> filter_custom_patterns()
  end

  def mask_email(email) when is_binary(email) do
    # Implementation from TelemetryHelper
  end
end
```

#### 5.2 Route-Based Filtering
**Implementation:**
- Automatically skip parameter logging for sensitive routes
- Default sensitive routes: `/auth`, `/login`, `/session`, `/payment`, `/checkout`
- Skip request/response bodies for these routes
- Still track metrics (duration, status) but omit payload data

---

### Phase 6: Development Tools (Priority: LOW)

#### 6.1 Development Dashboard
**Files to create:**
- `lib/zyzyva_telemetry_web/live/dashboard_live.ex`
- `lib/zyzyva_telemetry_web/router.ex`

**Features:**
- Live dashboard at `/_telemetry` (dev only)
- Show real-time metrics
- Slow query log viewer
- N+1 query warnings
- Memory leak detection
- Process leak detection

---

## Testing Strategy

### Unit Tests
Each new plugin/module requires:
- Test telemetry event emission
- Test metric value calculations
- Test configuration options
- Test edge cases (nil values, missing metadata)

### Integration Tests
- Test in contacts4us with real traffic
- Verify metrics appear in Prometheus
- Verify Tower error reporting includes telemetry context
- Load testing to ensure minimal overhead (<1% latency)

### Performance Tests
- Benchmark telemetry overhead
- Ensure sampling works correctly
- Test back-pressure handling
- Memory usage under load

---

## Configuration Architecture

### Opt-In vs Opt-Out
Most features should be **opt-in** initially, then migrate to **opt-out** once stable:

```elixir
config :zyzyva_telemetry,
  auto_instrument: [
    enhanced_ecto: false,        # Slow query, N+1 detection (opt-in)
    enhanced_phoenix: false,     # Payload tracking (opt-in)
    enhanced_live_view: false,   # Process health (opt-in)
    finch: true,                 # HTTP client (opt-out)
    pii_filter: true             # PII protection (opt-out, enabled by default)
  ]
```

### Per-Feature Configuration
Each feature should have granular controls:

```elixir
config :zyzyva_telemetry, :ecto,
  slow_query_threshold_ms: 100,
  log_slow_queries: true,
  detect_n_plus_1: false,
  n_plus_1_window_ms: 50

config :zyzyva_telemetry, :phoenix,
  track_payload_size: false,
  large_payload_threshold_kb: 1000

config :zyzyva_telemetry, :live_view,
  track_process_health: false,
  poll_interval_ms: 30_000,
  detect_zombies: false
```

---

## Documentation Updates Required

1. **BUILT_IN_METRICS.md** - Update with "Implemented" vs "Planned" status
2. **README.md** - Add new configuration options
3. **Upgrade Guide** - How to enable new features
4. **Contacts4us Integration** - Update instrumentation plan to remove manual work

---

## Success Criteria

### Phase 1 (Enhanced Ecto) Complete When:
- ✅ Slow queries automatically logged
- ✅ Query type metrics separated (read/write)
- ✅ Transaction rollbacks tracked
- ✅ Tests cover all scenarios
- ✅ Works in contacts4us without manual configuration

### Phase 4 (Finch) Complete When:
- ✅ External API call duration tracked
- ✅ DNS and SSL times measured
- ✅ Timeout/retry rates visible
- ✅ Dashboards show per-host metrics

### Phase 5 (PII Filter) Complete When:
- ✅ No PII leaks in any telemetry event
- ✅ Filter catches emails, passwords, tokens, credit cards
- ✅ Configurable patterns work
- ✅ Performance impact <0.1ms per event

---

## Timeline Estimate

| Phase | Effort | Priority |
|-------|--------|----------|
| Phase 1: Enhanced Ecto | 3-4 days | HIGH |
| Phase 2: Enhanced Phoenix | 2 days | MEDIUM |
| Phase 3: Enhanced LiveView | 2-3 days | MEDIUM |
| Phase 4: Finch Instrumentation | 2 days | HIGH |
| Phase 5: PII Protection | 2 days | HIGH |
| Phase 6: Dev Dashboard | 3-4 days | LOW |

**Total:** ~14-17 days for all phases
**MVP (Phases 1, 4, 5):** ~7-8 days

---

## Next Steps

1. ✅ Create this implementation plan
2. Get approval on scope and priorities
3. Start with Phase 1: Enhanced Ecto (highest value)
4. Test in zyzyva_telemetry test suite
5. Integrate and verify in contacts4us
6. Iterate through remaining phases
