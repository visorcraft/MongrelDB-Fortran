<p align="center">
  <img src="assets/mongrel.png" alt="MongrelDB logo" width="250" />
</p>

<h1 align="center">MongrelDB Fortran Client</h1>

<p align="center">
  <b>Modern Fortran 2018 HTTP client for MongrelDB - embedded+server database with SQL, vector search, full-text search, and AI-native retrieval.</b>
  <br />
  Built on the system <code>curl</code> binary and a bundled JSON parser. No external Fortran libraries required. Builds with <a href="https://fpm.fortran-lang.org">fpm</a>.
</p>

<p align="center">
  <a href="https://github.com/visorcraft/MongrelDB-Fortran/actions/workflows/ci.yml"><img src="https://github.com/visorcraft/MongrelDB-Fortran/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <a href="https://github.com/visorcraft/MongrelDB/releases"><img src="https://img.shields.io/badge/server-v0.46.2-blue.svg" alt="MongrelDB server" /></a>
  <a href="#license"><img src="https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue.svg" alt="License" /></a>
</p>

## Package

| Surface | Package | Install |
|---|---|---|
| Fortran client | `MongrelDB-Fortran` | build from source with fpm + gfortran |

History retention: type-bound `history_retention` and
`set_history_retention_epochs` procedures.

## Requirements

- **A Fortran 2018 compiler** (gfortran 11+, ifort/flang also work)
- **The `curl` binary** on your PATH (the HTTP transport)
- **[fpm](https://fpm.fortran-lang.org)** (the Fortran Package Manager, to build)
- A running [`mongreldb-server`](https://github.com/visorcraft/MongrelDB) daemon

## What It Provides

- **Typed CRUD** over the Kit transaction endpoint: `put`, `upsert` (insert-or-update on PK conflict), `delete` by row id or primary key, with idempotency keys for safe retries.
- **Query builder** that pushes conditions down to the engine's specialized indexes for sub-millisecond lookups: bitmap equality, learned-range, null checks, and FM-index full-text search. Conditions are AND-ed.
- **Idempotent batch transactions** - all operations committed atomically, with the engine enforcing unique, foreign key, and check constraints at commit time. Idempotency keys return the original response on duplicate commits, even after a crash.
- **Full SQL access** through the DataFusion-backed `/sql` endpoint: recursive CTEs, window functions, `CREATE TABLE AS SELECT`, materialized views, and multi-statement execution.
- **Schema management**: typed table creation, full schema catalog, and per-table descriptors.
- **Typed error codes**: `MDB_ERR_AUTH` (401/403), `MDB_ERR_NOT_FOUND` (404), `MDB_ERR_CONFLICT` (409), `MDB_ERR_QUERY` (400/5xx), plus `MDB_ERR_NETWORK`, `MDB_ERR_JSON`, and `MDB_ERR_INVALID_ARG`.
- **Zero external Fortran dependencies**: JSON is handled by a bundled parser (`mongreldb_json`), and HTTP rides on the system `curl` binary - no C bindings or libcurl-link complexity.

## Examples

Runnable, commented examples live in `examples/`:

- [Quickstart](docs/quickstart.md) - install, start the daemon, write and run a complete program.
- [Transactions](docs/transactions.md) - batch commits, idempotency keys, constraint handling.
- [Queries](docs/queries.md) - every native condition type and the index it pushes down to.
- [SQL](docs/sql.md) - recursive CTEs, window functions, advanced SQL.
- [Authentication](docs/auth.md) - bearer token, HTTP Basic, and open modes.
- [Errors](docs/errors.md) - error codes, the HTTP-status mapping, and recovery patterns.

## Quick Example

```fortran
program demo
  use mongreldb
  implicit none
  type(mongreldb_client) :: db
  integer :: stat
  character(256) :: errmsg

  ! Connect to a running mongreldb-server daemon.
  call db%connect('http://127.0.0.1:8453', stat, errmsg)

  ! Create a table. Column ids are stable on-wire identifiers.
  call db%create_table('orders', '[' // &
    '{"id":1,"name":"id","ty":"int64","primary_key":true,"nullable":false},' // &
    '{"id":2,"name":"customer","ty":"varchar","primary_key":false,"nullable":false},' // &
    '{"id":3,"name":"amount","ty":"float64","primary_key":false,"nullable":true}]', &
    stat, errmsg)

  ! Insert a row. cells is a flat [colId, value, ...] JSON array.
  call db%put('orders', '[1,1,2,"Alice",3,99.5]', stat, errmsg)

  ! Query by primary key.
  block
    character(:), allocatable :: result
    call db%query('{"table":"orders","conditions":[{"pk":{"value":1}}]}', &
                  result, stat, errmsg)
    print *, trim(result)
  end block
end program
```

Column JSON can include `enum_variants`, scalar `default_value`, and dynamic
`default_expr` (`"now"` or `"uuid"`). Native table
CHECKs use the optional `constraints_json` argument:

```fortran
call db%create_table('orders', columns_json, stat, errmsg, &
  constraints_json='{"checks":[{"id":1,"name":"amount_nonneg","expr":' // &
    '{"Ge":[{"Col":3},{"Lit":{"Float64":0.0}}]}}]}')
```

## Build

```sh
fpm build --profile release
```

The library builds two internal modules:

- `mongreldb_json` - a self-contained JSON parser and serializer.
- `mongreldb_http` - a `curl`-backed HTTP transport.

and the public `mongreldb` module that ties them together.

## Test

```sh
# Offline unit tests (no server needed) - JSON, encoding, error mapping.
fpm test wire_shape

# Live integration suite (requires mongreldb-server on MONGRELDB_URL).
MONGRELDB_URL=http://127.0.0.1:8453 fpm test live_conformance
```

The live suite implements the full 14-operation conformance matrix and
self-skips when no server is reachable.

## API Reference

All methods are bound to the `mongreldb_client` derived type. Every method
takes an `intent(out) integer :: stat` that is `MDB_OK` on success and a
category code on failure. Most accept an optional `errmsg` for the detail.

### Connection

| Method | Description |
|---|---|
| `connect(url, stat, errmsg)` | Connect with no auth. |
| `connect_with_token(url, token, stat, errmsg)` | Connect with a bearer token. |
| `connect_with_basic_auth(url, user, pass, stat, errmsg)` | Connect with HTTP Basic. |

### Operations

| Method | Endpoint | Notes |
|---|---|---|
| `health()` | `GET /health` | Returns logical; never errors. |
| `tables(stat, errmsg)` | `GET /tables` | Returns list of names. |
| `create_table(name, columns_json, stat, errmsg[, table_id, constraints_json])` | `POST /kit/create_table` | Returns table id; optional `constraints_json` forwards native table constraints. |
| `drop_table(name, stat, errmsg)` | `DELETE /tables/{name}` | |
| `count(table, stat, errmsg)` | `GET /tables/{name}/count` | Returns row count. |
| `put(table, cells_json, stat, errmsg)` | `POST /kit/txn` | Single-op put. |
| `upsert(table, cells_json, update_json, stat, errmsg)` | `POST /kit/txn` | Insert-or-update. |
| `delete(table, row_id, stat, errmsg)` | `POST /kit/txn` | Delete by row id. |
| `delete_by_pk(table, pk_json, stat, errmsg)` | `POST /kit/txn` | Delete by PK value. |
| `transaction(ops_json, results_json, stat, errmsg, idem_key)` | `POST /kit/txn` | Atomic batch. |
| `query(query_json, result_json, stat, errmsg)` | `POST /kit/query` | Native index query. |
| `sql(statement, result_json, stat, errmsg)` | `POST /sql` | Raw SQL (format:json). |
| `schema(stat, errmsg)` | `GET /kit/schema` | Returns catalog JSON. |
| `schema_for(table, stat, errmsg)` | `GET /kit/schema/{name}` | Returns descriptor JSON. |

### Cells format

Row cells are flat JSON arrays in `[col_id, value, col_id, value, ...]` order.
The column id is the numeric `id` from `create_table`, not the `name`. Example:

```
[1,42,2,"alice@example.com",3,true]
```

### Error codes

| Constant | HTTP | Meaning |
|---|---|---|
| `MDB_OK` (0) | - | Success. |
| `MDB_ERR_AUTH` (-1) | 401, 403 | Bad or missing credentials. |
| `MDB_ERR_NOT_FOUND` (-2) | 404 | Unknown table or row. |
| `MDB_ERR_CONFLICT` (-3) | 409 | Unique constraint violation. |
| `MDB_ERR_QUERY` (-4) | 400, 5xx | Malformed request or server error. |
| `MDB_ERR_NETWORK` (-5) | - | Transport failure. |
| `MDB_ERR_JSON` (-6) | - | Response was not valid JSON. |
| `MDB_ERR_INVALID_ARG` (-8) | - | Caller-supplied payload was malformed. |

## Security

- Table names are URL-percent-encoded into path segments.
- Auth credentials are validated to reject CR/LF (header-injection guard).
- The `curl` transport never follows redirects and never honors proxy env vars.
- Response bodies are capped at 256 MiB (`MDB_MAX_RESPONSE_BYTES`).

See [SECURITY.md](SECURITY.md) for the full model.

## License

Dual-licensed under [MIT](LICENSE-MIT) OR [Apache-2.0](LICENSE-APACHE). Pick
either. Contributions are accepted under the same terms.
