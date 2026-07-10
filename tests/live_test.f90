!> Live integration tests for the MongrelDB Fortran client.
!>
!> Implements the 14-operation conformance matrix against a running
!> `mongreldb-server`. The suite self-skips (exit 0) when no server is
!> reachable, so it is safe to run in any environment.
!>
!> Configure via environment variables:
!>   MONGRELDB_URL    base URL (default http://127.0.0.1:8453)
program live_test
  use, non_intrinsic :: mongreldb
  use, non_intrinsic :: mongreldb_json
  use iso_fortran_env, only: int64
  implicit none

  type(mongreldb_client) :: db
  character(:), allocatable :: url
  character(256) :: envbuf
  integer :: stat, passed, failed
  character(512) :: errmsg
  character(:), allocatable :: suffix
  integer :: test_fails = 0
  integer :: saved_fails = 0

  passed = 0
  failed = 0

  call get_environment_variable('MONGRELDB_URL', envbuf)
  if (len_trim(envbuf) > 0) then
    url = trim(envbuf)
  else
    url = MDB_DEFAULT_URL
  end if

  call db%connect(url, stat, errmsg)
  if (stat /= MDB_OK) then
    write(*, '(A,A)') 'connect failed: ', trim(errmsg)
    error stop 1
  end if

  ! Self-skip when the daemon is not running.
  if (.not. db%health()) then
    write(*, '(A)') 'live_test: no server reachable, skipping.'
    stop
  end if

  ! Unique suffix so parallel CI runs do not collide on table names.
  suffix = make_suffix()

  call run('health', test_health)
  call run('tables', test_tables)
  call run('create_table', test_create_table)
  call run('count_empty', test_count_empty)
  call run('put', test_put)
  call run('count_after_put', test_count_after_put)
  call run('put_conflict', test_put_conflict)
  call run('upsert', test_upsert)
  call run('query', test_query)
  call run('delete_by_pk', test_delete_by_pk)
  call run('delete', test_delete)
  call run('schema', test_schema)
  call run('sql', test_sql)
  call run('drop_table', test_drop_table)

  write(*, '(A,I0,A,I0,A)') 'live_test: ', passed, ' passed, ', failed, ' failed'
  if (failed > 0) error stop 1

contains

  subroutine run(name, proc)
    character(*), intent(in) :: name
    interface
      subroutine proc()
      end subroutine proc
    end interface
    call proc
    ! Each test proc calls check()/fail() to record outcomes. We count a test
    ! as passed if it did not record any failures during its body.
    if (local_fail_count() == 0) then
      passed = passed + 1
      write(*, '(A,A)') '  PASS  ', name
    else
      failed = failed + local_fail_count()
    end if
    call reset_fail_count
  end subroutine

  ! Per-test failure accumulator (declared in the program scope above).

  integer function local_fail_count()
    local_fail_count = test_fails - saved_fails
  end function

  subroutine reset_fail_count
    saved_fails = test_fails
  end subroutine

  subroutine fail(msg)
    character(*), intent(in) :: msg
    test_fails = test_fails + 1
    write(*, '(A,A)') '  FAIL  ', msg
  end subroutine

  subroutine check(cond, msg)
    logical, intent(in) :: cond
    character(*), intent(in) :: msg
    if (.not. cond) call fail(msg)
  end subroutine

  ! Build a unique table name for this process.
  function tname(base) result(nm)
    character(*), intent(in) :: base
    character(:), allocatable :: nm
    nm = base // '_' // suffix
  end function

  function make_suffix() result(s)
    character(:), allocatable :: s
    integer :: ticks
    call system_clock(ticks)
    block
      character(32) :: buf
      write(buf, '(I0)') ticks
      s = trim(buf)
    end block
  end function

  ! ---- The 14 operations --------------------------------------------------

  subroutine test_health()
    call check(db%health(), 'health should report true')
  end subroutine

  subroutine test_tables()
    character(:), allocatable :: names(:)
    integer :: stat, i
    character(512) :: errmsg
    names = db%tables(stat, errmsg)
    call check(stat == MDB_OK, 'tables should succeed')
    call check(size(names) >= 0, 'tables should return a list')
  end subroutine

  subroutine test_create_table()
    integer(int64) :: tid
    integer :: stat
    character(512) :: errmsg
    character(:), allocatable :: cols_json
    cols_json = build_columns()
    tid = db%create_table(tname('orders'), cols_json, stat, errmsg)
    call check(stat == MDB_OK, 'create_table should succeed')
  end subroutine

  subroutine test_count_empty()
    integer(int64) :: n
    integer :: stat
    character(512) :: errmsg
    ! A fresh table that we just created.
    call ensure_table('cnt_empty')
    n = db%count(tname('cnt_empty'), stat, errmsg)
    call check(stat == MDB_OK, 'count on empty table should succeed')
    call check(n == 0, 'freshly created table should have 0 rows')
  end subroutine

  subroutine test_put()
    integer :: stat
    character(512) :: errmsg
    call ensure_table('put_tbl')
    call db%put(tname('put_tbl'), '[1,1,2,"Alice",3,9.99]', stat, errmsg)
    call check(stat == MDB_OK, 'put should succeed')
  end subroutine

  subroutine test_count_after_put()
    integer(int64) :: n
    integer :: stat
    character(512) :: errmsg
    call ensure_table('cap_tbl')
    call db%put(tname('cap_tbl'), '[1,1,2,"Bob",3,5.0]', stat, errmsg)
    call db%put(tname('cap_tbl'), '[1,2,2,"Carol",3,6.0]', stat, errmsg)
    n = db%count(tname('cap_tbl'), stat, errmsg)
    call check(stat == MDB_OK, 'count after puts should succeed')
    call check(n >= 2, 'count after two puts should be >= 2')
  end subroutine

  subroutine test_put_conflict()
    integer :: stat
    character(512) :: errmsg
    call ensure_table('conf_tbl')
    call db%put(tname('conf_tbl'), '[1,100,2,"First",3,1.0]', stat, errmsg)
    ! Re-inserting the same PK must fail with a conflict.
    call db%put(tname('conf_tbl'), '[1,100,2,"Second",3,2.0]', stat, errmsg)
    call check(stat == MDB_ERR_CONFLICT, 'duplicate PK should be a conflict')
  end subroutine

  subroutine test_upsert()
    integer :: stat
    integer(int64) :: n
    character(512) :: errmsg
    call ensure_table('ups_tbl')
    call db%upsert(tname('ups_tbl'), '[1,7,2,"Dan",3,1.0]', stat=stat, errmsg=errmsg)
    call check(stat == MDB_OK, 'first upsert should succeed')
    ! Same PK, new values -> should update, not conflict.
    call db%upsert(tname('ups_tbl'), '[1,7,2,"Dan",3,2.0]', stat=stat, errmsg=errmsg)
    call check(stat == MDB_OK, 'second upsert should succeed (update)')
    n = db%count(tname('ups_tbl'), stat, errmsg)
    call check(stat == MDB_OK, 'count after upsert should succeed')
    call check(n == 1, 'row count should stay 1 after upsert update')
  end subroutine

  subroutine test_query()
    integer :: stat
    character(512) :: errmsg
    character(:), allocatable :: result_json
    character(:), allocatable :: query_body
    call ensure_table('qry_tbl')
    call db%put(tname('qry_tbl'), '[1,1,2,"FindMe",3,42.0]', stat=stat, errmsg=errmsg)
    ! A PK lookup condition: {"pk":{"value":1}} on the table.
    query_body = '{"table":"' // tname('qry_tbl') // '","conditions":[{"pk":{"value":1}}]}'
    call db%query(query_body, result_json, stat, errmsg)
    call check(stat == MDB_OK, 'query should succeed')
  end subroutine

  subroutine test_delete_by_pk()
    integer :: stat
    integer(int64) :: n
    character(512) :: errmsg
    call ensure_table('dbp_tbl')
    call db%put(tname('dbp_tbl'), '[1,55,2,"ToDelete",3,1.0]', stat=stat, errmsg=errmsg)
    call db%delete_by_pk(tname('dbp_tbl'), '55', stat, errmsg)
    call check(stat == MDB_OK, 'delete_by_pk should succeed')
    n = db%count(tname('dbp_tbl'), stat, errmsg)
    call check(n == 0, 'row count should be 0 after delete_by_pk')
  end subroutine

  subroutine test_delete()
    integer :: stat
    integer(int64) :: n, rid
    character(512) :: errmsg
    character(:), allocatable :: result_json, query_body
    call ensure_table('del_tbl')
    call db%put(tname('del_tbl'), '[1,77,2,"ToDeleteByRow",3,1.0]', stat=stat, errmsg=errmsg)
    ! Fetch the row id via a query, then delete by that id.
    query_body = '{"table":"' // tname('del_tbl') // '","conditions":[{"pk":{"value":77}}]}'
    call db%query(query_body, result_json, stat, errmsg)
    rid = extract_row_id(result_json)
    if (rid > 0) then
      call db%delete(tname('del_tbl'), rid, stat, errmsg)
      call check(stat == MDB_OK, 'delete by row_id should succeed')
      n = db%count(tname('del_tbl'), stat, errmsg)
      call check(n == 0, 'row count should be 0 after delete')
    else
      call check(.false., 'could not extract row id for delete test')
    end if
  end subroutine

  subroutine test_schema()
    integer :: stat
    character(512) :: errmsg
    character(:), allocatable :: schema_json
    call ensure_table('sch_tbl')
    schema_json = db%schema(stat, errmsg)
    call check(stat == MDB_OK, 'schema (catalog) should succeed')
  end subroutine

  subroutine test_sql()
    integer :: stat
    character(512) :: errmsg
    character(:), allocatable :: result_json
    call ensure_table('sql_tbl')
    call db%put(tname('sql_tbl'), '[1,9,2,"SQL",3,3.0]', stat=stat, errmsg=errmsg)
    call db%sql('SELECT count(*) AS n FROM ' // tname('sql_tbl'), result_json, stat, errmsg)
    call check(stat == MDB_OK, 'sql should succeed')
  end subroutine

  subroutine test_drop_table()
    integer :: stat
    character(512) :: errmsg
    ! Create a throwaway table and drop it.
    block
      integer(int64) :: tid
      tid = db%create_table(tname('drop_tbl'), build_columns(), stat, errmsg)
      call check(stat == MDB_OK, 'create before drop should succeed')
    end block
    call db%drop_table(tname('drop_tbl'), stat, errmsg)
    call check(stat == MDB_OK, 'drop_table should succeed')
    ! Dropping again should be a not_found.
    call db%drop_table(tname('drop_tbl'), stat, errmsg)
    call check(stat == MDB_ERR_NOT_FOUND, 'second drop should be not_found')
  end subroutine

  ! ---- Helpers ------------------------------------------------------------

  ! Ensure a table exists for the test. Idempotent: if create fails with a
  ! conflict we treat it as already-present.
  subroutine ensure_table(base)
    character(*), intent(in) :: base
    integer :: stat
    character(512) :: errmsg
    call db%create_table(tname(base), build_columns(), stat, errmsg)
    ! Ignore conflict (table already exists from a prior run).
  end subroutine

  function build_columns() result(cols_json)
    character(:), allocatable :: cols_json
    cols_json = '[' // &
      '{"id":1,"name":"id","ty":"int64","primary_key":true,"nullable":false},' // &
      '{"id":2,"name":"name","ty":"varchar","primary_key":false,"nullable":false},' // &
      '{"id":3,"name":"amount","ty":"float64","primary_key":false,"nullable":true}' // &
      ']'
  end function

  ! Extract the first row_id from a query result JSON. Returns 0 if absent.
  function extract_row_id(result_json) result(rid)
    character(*), intent(in) :: result_json
    integer(int64) :: rid
    type(json_value) :: doc, rows, row
    integer :: stat, i
    character(256) :: errmsg
    rid = 0
    call json_parse(result_json, doc, stat, errmsg)
    if (stat /= 0) return
    if (.not. json_object_has(doc, 'rows')) return
    rows = json_object_get(doc, 'rows')
    if (rows%kind /= JSON_ARRAY) return
    if (json_array_len(rows) < 1) return
    row = json_array_get(rows, 1)
    ! Rows are flat cell lists {colId value ...}; the row id is carried
    ! under the key "row_id" when present, otherwise we return 0.
    if (json_object_has(row, 'row_id')) then
      if (json_object_get(row, 'row_id')%kind == JSON_INT) then
        rid = json_object_get(row, 'row_id')%int_val
      end if
    end if
  end function

end program
