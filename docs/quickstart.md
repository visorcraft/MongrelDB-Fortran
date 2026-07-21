# Quickstart

Zero to a running MongrelDB Fortran program in ten minutes. This guide walks
through installing the toolchain, starting the daemon, and writing, running,
and understanding a complete program.

---

## 1. Prerequisites

You need a Fortran 2018 compiler, the `curl` binary, fpm, and a
`mongreldb-server` daemon.

### Install the Fortran toolchain

On Debian/Ubuntu:

```sh
sudo apt install gfortran curl
```

Then install [fpm](https://fpm.fortran-lang.org):

```sh
# From the GitHub release (or your distribution's package manager).
FPM_VERSION="0.10.1"
curl -fsSL -o ~/bin/fpm \
  "https://github.com/fortran-lang/fpm/releases/download/v${FPM_VERSION}/fpm-${FPM_VERSION}-linux-x86_64"
chmod +x ~/bin/fpm
export PATH="$HOME/bin:$PATH"
fpm --version
```

Verify the compiler:

```sh
gfortran --version   # >= 11
```

### Install mongreldb-server

Fetch a prebuilt server binary from the
[MongrelDB releases](https://github.com/visorcraft/MongrelDB/releases):

```sh
mkdir -p bin
curl -fsSL -o bin/mongreldb-server \
  https://github.com/visorcraft/MongrelDB/releases/download/v0.62.0/mongreldb-server-linux-x64
chmod +x bin/mongreldb-server
```

## 2. Start the daemon

By default `mongreldb-server` listens on `http://127.0.0.1:8453` and stores
data in the directory you pass as its first argument.

```sh
mkdir -p /tmp/mdb-data
./bin/mongreldb-server /tmp/mdb-data --port 8453
```

In another terminal, sanity-check it:

```sh
curl http://127.0.0.1:8453/health
# ok
```

## 3. Build the library

From the repository root:

```sh
fpm build --profile release
```

## 4. Write your first program

Create `demo.f90` in a scratch directory:

```fortran
program demo
  use mongreldb
  use iso_fortran_env, only: int64
  implicit none
  type(mongreldb_client) :: db
  integer :: stat
  character(256) :: errmsg
  integer(int64) :: n

  ! 1. Connect to the daemon.
  call db%connect('http://127.0.0.1:8453', stat, errmsg)

  ! 2. Health check before doing anything else.
  if (.not. db%health()) then
    print *, 'daemon not reachable'
    error stop 1
  end if

  ! 3. Create a table. The columns JSON is the on-wire shape.
  call db%create_table('orders', '[' // &
    '{"id":1,"name":"id","ty":"int64","primary_key":true,"nullable":false},' // &
    '{"id":2,"name":"customer","ty":"varchar","primary_key":false,"nullable":false},' // &
    '{"id":3,"name":"amount","ty":"float64","primary_key":false,"nullable":true,"default_value":0.0},' // &
    '{"id":4,"name":"active","ty":"bool","primary_key":false,"nullable":true,"default_value":false}' // &
    ']', stat, errmsg)

  ! `default_value` preserves the JSON type you provide: numbers, booleans,
  ! explicit null, and literal strings such as "now" are all valid. Dynamic
  ! defaults use the separate `default_expr` field ("now" or "uuid").

  ! 4. Insert rows. cells is a flat [colId, value, ...] JSON array.
  call db%put('orders', '[1,1,2,"Alice",3,99.5]', stat, errmsg)
  call db%put('orders', '[1,2,2,"Bob",3,150.0]', stat, errmsg)

  ! 5. Query with a native index condition (range on amount, project id/customer).
  block
    character(:), allocatable :: result
    call db%query('{"table":"orders",' // &
                  '"conditions":[{"range":{"column_id":3,"lo":100.0}}],' // &
                  '"projection":[1,2],"limit":100}', result, stat, errmsg)
    print *, 'query result: ', trim(result)
  end block

  ! 6. Count the rows.
  n = db%count('orders', stat, errmsg)
  print *, 'total rows: ', n
end program
```

Run it via fpm (with this repo as a dependency), or compile directly against
the built module files. The simplest path is to drop `demo.f90` into the
`app/` directory of a project that depends on `mongreldb`, then:

```sh
fpm run
```

You should see the row count of 2.

## 5. What each part does

| Code | What it does |
|------|--------------|
| `db%connect` | Builds a client targeting one daemon. |
| `db%health` | GET `/health`; returns `.true.` when the daemon answers. |
| `db%create_table` | POST `/kit/create_table`. Column `id`s are the on-wire identifiers. |
| `default_value` | Optional static JSON scalar: string, number, boolean, explicit `null`, or a literal string such as `"now"`. |
| `default_expr` | Optional dynamic default: only `"now"` or `"uuid"`. Not an alias for `default_value`; set one or the other. |
| `db%put` | Single-op transaction: POST `/kit/txn` with one `put` op. |
| `db%query` | Builds a `/kit/query` body. Conditions push down to native indexes. |
| `projection [1,2]` | Server returns only those column ids, saving bandwidth. |
| `limit 100` | Caps the result; check the response `truncated` field afterward. |
| `db%count` | GET `/tables/{name}/count`. |

## 6. History retention

MongrelDB keeps a configurable number of recent commit epochs. The getters
`history_retention_epochs` and `earliest_retained_epoch` read the current
window and floor; `set_history_retention_epochs` changes the window. You can
query older versions with `AS OF EPOCH`:

```fortran
integer(int64) :: epochs, earliest, old_epoch
character(:), allocatable :: result

call db%set_history_retention_epochs(10000_int64, epochs, earliest, stat, errmsg)
call db%history_retention_epochs(epochs, stat, errmsg)
call db%earliest_retained_epoch(earliest, stat, errmsg)

! old_epoch must be >= earliest.
call db%sql('SELECT * FROM orders AS OF EPOCH 5', result, stat, errmsg)
```

Lowering retention advances the earliest retained epoch; raising it again does
not restore history that was already pruned.

## 7. Common pitfalls

**Using the column name instead of the column id.** Every on-wire API uses the
numeric `id` from `create_table`, never the `name`. Conditions take the numeric
`column_id`, not the string name.

**Treating a single `put` as non-transactional.** `put` is a one-op
transaction. A unique constraint violation surfaces as a `MDB_ERR_CONFLICT`
(HTTP 409), not as a silent no-op.

**Forgetting to build the module path.** The `mongreldb` module depends on
`mongreldb_json` and `mongreldb_http`. fpm handles this automatically; if you
compile by hand, build all three source files together.

**Pointing at a daemon that requires auth.** If the daemon was started with
`--auth-token` or `--auth-users`, every call fails with `MDB_ERR_AUTH`
unless you use `connect_with_token` or `connect_with_basic_auth`. See
[auth.md](auth.md).

## Next steps

- [transactions.md](transactions.md) - atomic batches, idempotency, retries
- [queries.md](queries.md) - every native index condition
- [sql.md](sql.md) - recursive CTEs, window functions, `CREATE TABLE AS SELECT`
- [auth.md](auth.md) - bearer tokens, basic auth, user/role management
- [errors.md](errors.md) - the full error code set and recovery patterns
