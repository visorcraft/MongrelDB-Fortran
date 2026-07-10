# Transactions

Transactions stage and commit a batch of put / upsert / delete / delete-by-pk
operations atomically. Either every op in the batch is applied, or none are.

This document covers:

- the single-op helpers (`put`, `upsert`, `delete`, `delete_by_pk`),
- multi-op batches via `transaction`,
- the cells wire format,
- idempotency keys for safe retries,
- the per-op result envelope.

---

## Single-op helpers

Each helper is sugar over a one-op transaction posted to `/kit/txn`. They set
`stat` to `MDB_OK` on success and an error code on failure.

| Method | Op shape | Notes |
|---------|----------|-------|
| `put(table, cells_json, stat, errmsg)` | `put` | Insert a row. PK conflict sets `MDB_ERR_CONFLICT`. |
| `upsert(table, cells_json, update_json, stat, errmsg)` | `upsert` | Insert-or-update on PK match. `update_json` are the columns to overwrite when the row exists. |
| `delete(table, row_id, stat, errmsg)` | `delete` | Delete by the internal numeric row id returned in query results. |
| `delete_by_pk(table, pk_json, stat, errmsg)` | `delete_by_pk` | Delete by the primary-key column value. |

Cells are a **flat JSON array** of `[col_id, value, col_id, value, ...]`:

```fortran
call db%put('orders', '[1,1,2,"Alice",3,99.5]', stat, errmsg)
!             column id ---^^^^ ^--- value
```

## Multi-op batches

`transaction` posts a list of ops as one atomic commit. Every op shares the
same all-or-nothing guarantee: a single failure rolls back the entire batch.

```fortran
character(:), allocatable :: ops_json, results_json
ops_json = '[' // &
  '{"put":{"table":"orders","cells":[1,1,2,"Alice",3,9.99]}},' // &
  '{"put":{"table":"orders","cells":[1,2,2,"Bob",3,14.50]}},' // &
  '{"upsert":{"table":"orders","cells":[1,3,2,"Carol",3,7.00]}},' // &
  '{"delete_by_pk":{"table":"orders","pk":4}}' // &
  ']'
call db%transaction(ops_json, results_json, stat, errmsg)
```

Each op is a one-key object whose key is the op type (`put`, `upsert`,
`delete`, `delete_by_pk`) and whose value is the op body. This mirrors the
wire shape exactly.

The command returns the full response body in `results_json`, which contains
a per-op `results` array - one entry per input op, in order. Parse it with the
`mongreldb_json` module to read individual op outcomes.

## The cells format

Cells are flattened into the wire array. The order does not matter on the
server side (it indexes by column id), but emitting them in ascending column
order keeps the request deterministic:

```fortran
! Two columns, ascending by id
call db%put('users', '[1,42,2,"alice@example.com"]', stat, errmsg)
```

For `upsert`, the optional `update_json` are the columns to overwrite when
the row already exists:

```fortran
call db%upsert('users', '[1,42,2,"new@example.com"]', &
               '[2,"new@example.com"]', stat, errmsg)
```

## Idempotency keys

Network retries can replay a transaction. To make retries safe, pass an
idempotency key: the server deduplicates any request that carries the same
key within its retention window.

```fortran
call db%transaction(ops_json, results_json, stat, errmsg, &
                    idem_key='checkout-' // suffix)
! Safe to retry on timeout: the server applies this exactly once.
```

Pick a key that is unique to the logical operation (a request id, a checkout
id, a content hash). Do **not** reuse keys across logically distinct
transactions - the second request will be deduplicated as a replay and its
ops silently dropped.

## Per-op results

`transaction` returns the raw response body in `results_json`. Parse it to
get the per-op result array:

```fortran
use mongreldb_json
type(json_value) :: doc, results
integer :: jstat
character(256) :: jmsg
call json_parse(results_json, doc, jstat, jmsg)
results = json_object_get(doc, 'results')
do i = 1, json_array_len(results)
  ! process json_array_get(results, i)
end do
```

The exact keys depend on the op type and the server version. Treat the result
as informational; do not gate correctness on a specific field being present.

## Error handling

A failed batch sets `stat` to an error code. Check the category and read the
detail from `errmsg`:

```fortran
call db%transaction(ops_json, results_json, stat, errmsg)
if (stat == MDB_ERR_CONFLICT) then
  ! A unique constraint (PK or column-level) was violated.
  print *, 'conflict: ', trim(errmsg)
else if (stat == MDB_ERR_QUERY) then
  ! Malformed op, unknown table, or a server-side planner error.
  print *, 'query error: ', trim(errmsg)
end if
```

For a batch failure the server reports which op index caused the rollback
when available; it appears in the error detail. See [errors.md](errors.md)
for the full category set.

## When to batch

- **Atomic multi-row writes.** Inserting a parent and children that must
  succeed together belongs in one transaction.
- **Throughput.** One round trip for N ops is cheaper than N round trips.
- **Idempotent retries.** A batch with an idempotency key can be retried
  safely after a timeout.

Do **not** batch when:

- The ops are independent and either can fail without affecting the other -
  use separate `put` calls.
- You need per-op error isolation - the server rolls back the whole batch on
  the first error.

## Next steps

- [queries.md](queries.md) - read paths and native index conditions
- [errors.md](errors.md) - the full error code set
- [sql.md](sql.md) - escaping the query builder when you need full SQL
