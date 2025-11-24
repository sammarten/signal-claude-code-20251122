# Database Migration Reset Instructions

The migrations have been updated to fix PostgreSQL/TimescaleDB best practice warnings:
- Changed `:string` to `:text` (avoids `character varying` warning)
- Changed `:utc_datetime_usec` to `:timestamptz` (avoids `timestamp without time zone` warning)

## What Was Fixed

### Before (with warnings):
```elixir
add :symbol, :string, null: false           # Creates character varying ⚠️
add :bar_time, :utc_datetime_usec, ...      # Creates timestamp without time zone ⚠️
add :trend, :string                          # Creates character varying ⚠️
add :timeframe, :string, null: false        # Creates character varying ⚠️
```

### After (no warnings):
```elixir
add :symbol, :text, null: false             # Creates text ✅
add :bar_time, :timestamptz, ...            # Creates timestamp with time zone ✅
add :trend, :text                            # Creates text ✅
add :timeframe, :text, null: false          # Creates text ✅
```

## How to Reset Database

### Option 1: Development Database (Fastest)

```bash
# Drop, recreate, and migrate
mix ecto.reset

# Verify migrations ran cleanly
mix ecto.migrate
```

### Option 2: Manual Reset (More Control)

```bash
# 1. Drop the database
mix ecto.drop

# 2. Create fresh database
mix ecto.create

# 3. Run all migrations
mix ecto.migrate
```

You should see no warnings now!

### Option 3: Production-Style Migration (If you have data to preserve)

If you need to preserve existing data:

```bash
# Create a new migration to alter the column types
mix ecto.gen.migration fix_column_types

# Then edit the migration file to:
# ALTER TABLE key_levels ALTER COLUMN symbol TYPE text;
# ALTER TABLE market_structure ALTER COLUMN symbol TYPE text;
# etc.
```

## After Reset

If you had loaded historical data, you'll need to reload it:

```bash
# Reload recent data
mix signal.load_data --symbols AAPL,TSLA,NVDA --year 2024

# Or reload all data
mix signal.load_data
```

## Verification

After running migrations, you can verify they're clean:

```bash
# Should see no warnings
mix ecto.migrate

# Check migration status
mix ecto.migrations
```

Expected output (no warnings):
```
Compiling 1 file (.ex)
Generated signal app

[info] == Running ... Signal.Repo.Migrations.CreateKeyLevels.up/0 forward

[info] create table key_levels
[info] execute "ALTER TABLE key_levels..."
...
[info] == Migrated ... in 0.5s
```

## Files Updated

- `priv/repo/migrations/20251122221434_create_market_bars.exs` - Fixed symbol and bar_time
- `priv/repo/migrations/20251124000001_create_key_levels.exs` - Fixed symbol
- `priv/repo/migrations/20251124000002_create_market_structure.exs` - Fixed symbol, timeframe, bar_time, trend, swing_type

Schema files (`lib/signal/technicals/*.ex`) don't need updating - they use `:string` and `:utc_datetime_usec` which are correct for Ecto schemas.

## Notes

- The schema definitions use `:string` (Ecto type)
- The migrations now use `:text` (PostgreSQL type)
- Both map to PostgreSQL `text` type, which is best practice
- `text` has better performance in PostgreSQL than `character varying`
- No functional changes, just following best practices
