# Queries

MongrelDB has two read paths. The **native query** API pushes conditions down
into the server's indexes for fast point and range lookups. The **SQL** path
covers everything else - joins, aggregations, recursive CTEs. Use the native
API when you can; fall back to SQL when you need it.

This document covers the native API only. See [sql.md](sql.md) for the SQL
path.

---

## The basic call

```fortran
character(:), allocatable :: query_body, result_json
call db%query(query_body, result_json, stat, errmsg)
```

The `query_body` is a JSON object posted to `/kit/query`. It has up to four
keys:

- `table` (required) - the table name.
- `conditions` (optional) - an array of condition objects. Empty or absent =
  all rows.
- `projection` (optional) - an array of column ids to return. Omit for all.
- `limit` (optional) - caps the row count.

The response is returned raw in `result_json`. Parse it with `mongreldb_json`
to read the `rows` array and the `truncated` flag.

## Conditions

Build each condition as a one-key JSON object whose key is the condition kind
and whose value is a parameters object. Group them in the `conditions` array.

### Primary-key lookup

```json
{"pk":{"value":42}}
```

Matches the single row whose primary-key column equals `value`.

### Bitmap equality

```json
{"bitmap_eq":{"column_id":2,"value":"Alice"}}
```

Exact equality on any indexed column. `column_id` is the numeric column id,
not the name.

### Range

```json
{"range":{"column_id":3,"lo":100.0,"hi":1000.0,"lo_inclusive":true,"hi_inclusive":false}}
```

A half-open or closed range on an ordered column. `lo`/`hi` bound the range;
the `*_inclusive` flags control endpoint behavior (default inclusive).

### Full-text containment (FM-index)

```json
{"fm_contains":{"column_id":4,"pattern":"hello"}}
```

Substring search over an FM-indexed text column. `pattern` is the search term.

### Null tests

```json
{"is_null":{"column_id":5}}
{"is_not_null":{"column_id":5}}
```

## Combining conditions

List conditions in the `conditions` array. Within one query, conditions are
ANDed together:

```fortran
query_body = '{"table":"orders",' // &
  '"conditions":[' // &
    '{"bitmap_eq":{"column_id":2,"value":"Alice"}},' // &
    '{"range":{"column_id":3,"lo":100.0}}' // &
  '],"projection":[1,2,3],"limit":100}'
```

There is no client-side OR combinator. For OR across columns or complex
predicates, use the SQL path.

## Projection

Projection trims the response to the columns you actually need. The array
holds numeric column ids:

```fortran
! Only columns 1 (id) and 2 (customer) come back.
'"projection":[1,2]'
```

Omit the projection to receive every column.

## Limits and truncation

Pass a limit to cap the response:

```fortran
query_body = '{"table":"orders","limit":100}'
```

The server enforces its own maximum regardless of the limit you pass, so
always check the `truncated` field in the response before assuming the result
is complete:

```fortran
use mongreldb_json
type(json_value) :: doc
call json_parse(result_json, doc, jstat, jmsg)
if (json_object_get(doc, 'truncated')%bool_val) then
  ! Hit the limit - more rows exist on the server.
end if
```

There is no client-side offset; for pagination use SQL with `LIMIT`/`OFFSET`.

## Counting

`count` is the cheap way to count rows - it does not fetch them:

```fortran
n = db%count('orders', stat, errmsg)
```

## Reading the rows

Parse the response and iterate the `rows` array:

```fortran
type(json_value) :: doc, rows, row
integer :: i
call json_parse(result_json, doc, jstat, jmsg)
rows = json_object_get(doc, 'rows')
do i = 1, json_array_len(rows)
  row = json_array_get(rows, i)
  ! row is either a flat cell list or an object, depending on server version.
end do
```

The exact row shape (flat cells vs. keyed object) depends on the server
version and projection. Use the `mongreldb_json` accessors to pull values.

## When to use SQL instead

Reach for the SQL path when you need:

- JOINs across tables.
- GROUP BY / aggregations (SUM, COUNT, AVG).
- ORDER BY on non-indexed columns.
- LIMIT/OFFSET pagination.
- Recursive CTEs or window functions.
- OR predicates, CASE expressions, computed columns.

See [sql.md](sql.md).

## Next steps

- [sql.md](sql.md) - the SQL escape hatch
- [transactions.md](transactions.md) - atomic writes
- [errors.md](errors.md) - error codes for query failures
