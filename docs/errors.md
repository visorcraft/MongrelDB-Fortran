# Errors

Every client method that talks to the server reports failure via an
`intent(out) integer :: stat` argument. On success `stat` is `MDB_OK` (0); on
failure it is a negative category code. An optional `errmsg` carries the
human-readable detail.

---

## The code set

| Code | Constant | HTTP status | Cause |
|------|----------|-------------|-------|
| 0  | `MDB_OK` | - | Success. |
| -1 | `MDB_ERR_AUTH` | 401, 403 | Missing, malformed, or rejected `Authorization` header. Bad token or basic-auth credentials. |
| -2 | `MDB_ERR_NOT_FOUND` | 404 | Unknown table name, or a row that does not exist. |
| -3 | `MDB_ERR_CONFLICT` | 409 | Unique constraint violation: duplicate primary key, or a column-level uniqueness/enum violation. |
| -4 | `MDB_ERR_QUERY` | 400, 5xx | Malformed request body, unknown column id, a server-side planner/execution error, or a response that exceeded the size cap. |
| -5 | `MDB_ERR_NETWORK` | - | The HTTP request itself failed: connection refused, DNS error, timeout, broken pipe. |
| -6 | `MDB_ERR_JSON` | - | The server returned a response that could not be decoded as JSON when JSON was expected. |
| -8 | `MDB_ERR_INVALID_ARG` | - | A caller-supplied payload (columns, ops, query body) was not valid JSON. |

## Matching

Use a normal `if`/`select case` on `stat`:

```fortran
call db%put('orders', '[1,1,2,"Alice"]', stat, errmsg)
select case (stat)
case (MDB_ERR_CONFLICT)
  print *, 'duplicate row, skipping: ', trim(errmsg)
case (MDB_ERR_AUTH)
  print *, 'bad credentials: ', trim(errmsg)
  error stop 1
case (MDB_ERR_NETWORK)
  print *, 'daemon unreachable, will retry: ', trim(errmsg)
case (MDB_OK)
  ! success
case default
  print *, 'unexpected: ', trim(errmsg)
end select
```

## Reading the detail

`errmsg` (when present) is set to the server's own error text when the server
produced one:

```
duplicate primary key value
```

For server errors the daemon wraps detail in an envelope
(`{"error":{"message":..., "code":..., "op_index":...}}`). The client
extracts `message` into `errmsg`. `op_index` (when present) identifies which
op in a batch transaction triggered the rollback.

## Recoverable vs not

| Code | Recoverable? | Pattern |
|------|--------------|---------|
| `MDB_ERR_NETWORK` | Yes - retry after backoff | Transient; the daemon may have restarted. |
| `MDB_ERR_CONFLICT` | Sometimes - re-read, reconcile, retry | The data changed under you. Re-fetch and decide. |
| `MDB_ERR_AUTH` | No - fix credentials and reconnect | Stale token, wrong password. |
| `MDB_ERR_NOT_FOUND` | No - check the table/row id | Programming error or race. |
| `MDB_ERR_QUERY` | No - fix the request | Malformed body, bad column id, etc. |
| `MDB_ERR_JSON` | No - protocol mismatch | Likely a server version skew. |

## Retrying safely

For `MDB_ERR_NETWORK`, retry with backoff. If the operation is a write, pass
an idempotency key so a replayed request is deduplicated on the server:

```fortran
do attempt = 1, 3
  call db%transaction(ops_json, results_json, stat, errmsg, &
                      idem_key='put-' // key_suffix)
  if (stat /= MDB_ERR_NETWORK) exit
  call sleep_ms(200 * (2 ** (attempt - 1)))
end do
if (stat /= MDB_OK) error stop 1
```

See [transactions.md](transactions.md) for more on idempotency keys.

## The size cap

The client rejects any response body larger than 256 MiB
(`MDB_MAX_RESPONSE_BYTES`) with a `MDB_ERR_QUERY` error. This is a guard
against runaway queries exhausting memory. If you hit it, narrow your query
(add a `limit`, project fewer columns, or page with SQL `LIMIT`/`OFFSET`).

## Next steps

- [transactions.md](transactions.md) - atomic writes and idempotency
- [queries.md](queries.md) - native conditions and projection
- [auth.md](auth.md) - the `MDB_ERR_AUTH` code in depth
