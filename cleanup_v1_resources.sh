#!/bin/bash

# ZyzyvaTelemetry v1.0 to v2.0 Migration Cleanup Script
# This script removes all SQLite-based resources and artifacts from v1.0

set -e

echo "========================================="
echo "ZyzyvaTelemetry v1.0 Resources Cleanup"
echo "========================================="
echo ""
echo "This script will remove:"
echo "  - SQLite database files"
echo "  - v1.0 module files"
echo "  - Mix task files"
echo "  - Compiled artifacts"
echo ""

# Function to safely remove files/directories
safe_remove() {
    local path="$1"
    local description="$2"

    if [ -e "$path" ]; then
        echo "✓ Removing $description: $path"
        rm -rf "$path"
    else
        echo "  Skipping $description: $path (not found)"
    fi
}

# 1. Remove SQLite database and monitoring directory
echo "1. Removing SQLite databases and monitoring directory..."
echo "----------------------------------------"

# Default SQLite database location
safe_remove "/var/lib/monitoring/events.db" "SQLite database"
safe_remove "/var/lib/monitoring/events.db-shm" "SQLite shared memory"
safe_remove "/var/lib/monitoring/events.db-wal" "SQLite write-ahead log"

# Remove the entire monitoring directory if empty
if [ -d "/var/lib/monitoring" ]; then
    if [ -z "$(ls -A /var/lib/monitoring)" ]; then
        echo "✓ Removing empty monitoring directory: /var/lib/monitoring"
        sudo rmdir /var/lib/monitoring 2>/dev/null || echo "  Note: May need sudo to remove /var/lib/monitoring"
    else
        echo "  Keeping /var/lib/monitoring (contains other files)"
    fi
fi

# Check for any SQLite files in project directory (test/dev environments)
safe_remove "events.db" "local SQLite database"
safe_remove "events.db-shm" "local SQLite shared memory"
safe_remove "events.db-wal" "local SQLite write-ahead log"
safe_remove "test/support/test_events.db" "test SQLite database"

echo ""

# 2. Remove v1.0 module files that were already deleted
echo "2. Verifying v1.0 modules are removed..."
echo "----------------------------------------"

# List of v1.0 modules that should be removed
v1_modules=(
    "lib/zyzyva_telemetry/sqlite_writer.ex"
    "lib/zyzyva_telemetry/monitoring_supervisor.ex"
    "lib/zyzyva_telemetry/error_logger.ex"
    "lib/zyzyva_telemetry/health_reporter.ex"
    "lib/zyzyva_telemetry/test_generator.ex"
    "lib/zyzyva_telemetry/setup.ex"
    "lib/mix/tasks/zyzyva.setup.ex"
    "lib/mix/tasks/zyzyva.test_events.ex"
)

for module in "${v1_modules[@]}"; do
    if [ -e "$module" ]; then
        echo "✓ Removing leftover v1.0 module: $module"
        rm -f "$module"
    else
        echo "  Already removed: $module"
    fi
done

echo ""

# 3. Clean compiled artifacts
echo "3. Cleaning compiled artifacts..."
echo "----------------------------------------"

if [ -d "_build" ]; then
    echo "✓ Removing _build directory..."
    rm -rf _build
    echo "  Cleaned _build"
fi

if [ -d "deps" ]; then
    echo "  Note: deps/ directory exists"
    echo "  Run 'mix deps.clean exqlite' to remove SQLite dependency"
    echo "  Then run 'mix deps.get' to fetch new dependencies"
fi

# Remove any .beam files that might be lingering
if [ -d "ebin" ]; then
    echo "✓ Removing ebin directory..."
    rm -rf ebin
fi

echo ""

# 4. Clean up test artifacts
echo "4. Cleaning test artifacts..."
echo "----------------------------------------"

safe_remove "test/fixtures/test.db" "test fixture database"
safe_remove "test/fixtures/*.db" "test fixture databases"
safe_remove "tmp/*.db" "temporary databases"

echo ""

# 5. Remove any backup files
echo "5. Cleaning backup files..."
echo "----------------------------------------"

for backup in events.db.backup events.db.bak monitoring.db; do
    safe_remove "$backup" "backup file"
    safe_remove "/var/lib/monitoring/$backup" "system backup file"
done

echo ""

# 6. Clean Elixir/Mix artifacts
echo "6. Final cleanup steps..."
echo "----------------------------------------"

# Clean Mix artifacts
if command -v mix &> /dev/null; then
    echo "✓ Running mix clean..."
    mix clean 2>/dev/null || echo "  Note: mix clean failed (might not be in a Mix project)"
fi

echo ""
echo "========================================="
echo "Cleanup Complete!"
echo "========================================="
echo ""
echo "Next steps:"
echo "  1. Run 'mix deps.clean exqlite' to remove the SQLite dependency"
echo "  2. Run 'mix deps.get' to fetch the new dependencies"
echo "  3. Run 'mix compile' to compile with the new v2.0 modules"
echo ""
echo "If using the library in other projects:"
echo "  - Update the dependency to point to v1.0.0"
echo "  - Remove any SQLite database files from those projects"
echo "  - Update application supervision trees as per migration guide"
echo ""

# Check if we're in a git repo and show status
if [ -d ".git" ]; then
    echo "Git status:"
    echo "----------------------------------------"
    git status --short
fi