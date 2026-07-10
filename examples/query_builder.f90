!> Query builder example for the MongrelDB Fortran client.
!>
!> Demonstrates building a native index condition (range) and a projection,
!> running a query, and reading the result rows. Cleans up on exit.
program query_builder
  use, non_intrinsic :: mongreldb
  use, non_intrinsic :: mongreldb_json
  use iso_fortran_env, only: int64
  implicit none

  type(mongreldb_client) :: db
  integer :: stat
  character(512) :: errmsg
  character(:), allocatable :: table, cols_json, query_body, result_json, url
  character(256) :: envbuf
  integer :: i, nrows
  type(json_value) :: doc, rows, row

  call get_environment_variable('MONGRELDB_URL', envbuf)
  if (len_trim(envbuf) > 0) then
    url = trim(envbuf)
  else
    url = MDB_DEFAULT_URL
  end if

  table = 'demo_qry_' // make_suffix()

  call db%connect(url, stat, errmsg)
  if (stat /= MDB_OK) call die('connect failed: ' // trim(errmsg))
  if (.not. db%health()) call die('daemon not reachable')

  cols_json = '[' // &
    '{"id":1,"name":"id","ty":"int64","primary_key":true,"nullable":false},' // &
    '{"id":2,"name":"customer","ty":"varchar","primary_key":false,"nullable":false},' // &
    '{"id":3,"name":"amount","ty":"float64","primary_key":false,"nullable":true}' // &
    ']'
  call db%create_table(table, cols_json, stat, errmsg)
  if (stat /= MDB_OK) call die('create_table failed: ' // trim(errmsg))

  ! Seed a few rows.
  call db%put(table, '[1,1,2,"Alice",3,50.0]', stat, errmsg)
  call db%put(table, '[1,2,2,"Bob",3,150.0]', stat, errmsg)
  call db%put(table, '[1,3,2,"Carol",3,250.0]', stat, errmsg)
  call db%put(table, '[1,4,2,"Dave",3,350.0]', stat, errmsg)
  if (stat /= MDB_OK) call die('seed put failed: ' // trim(errmsg))

  ! Build a range query: amount >= 100, projecting columns id (1) and customer (2).
  ! On the wire this is a /kit/query body:
  !   { "table": ..., "conditions": [{"range":{"column_id":3,"lo":100.0}}],
  !     "projection": [1,2], "limit": 100 }
  query_body = '{"table":"' // table // '",' // &
               '"conditions":[{"range":{"column_id":3,"lo":100.0}}],' // &
               '"projection":[1,2],"limit":100}'

  call db%query(query_body, result_json, stat, errmsg)
  if (stat /= MDB_OK) call die('query failed: ' // trim(errmsg))

  ! Parse and print the rows. Rows may be flat cell lists or objects depending
  ! on server version; we print the raw JSON for illustration here.
  call json_parse(result_json, doc, stat, errmsg)
  if (stat /= 0) call die('could not parse query result')
  if (json_object_has(doc, 'rows')) then
    rows = json_object_get(doc, 'rows')
    nrows = json_array_len(rows)
    write(*, '(A,I0)') 'rows in range (amount >= 100): ', nrows
    do i = 1, nrows
      row = json_array_get(rows, i)
      write(*, '(A,A)') '  ', json_serialize(row)
    end do
  else
    write(*, '(A)') 'no rows key in response'
  end if

  call cleanup()

contains

  subroutine die(msg)
    character(*), intent(in) :: msg
    write(*, '(A)') msg
    call cleanup()
    error stop 1
  end subroutine

  subroutine cleanup()
    integer :: s
    character(512) :: m
    call db%drop_table(table, s, m)
  end subroutine

  function make_suffix() result(s)
    character(:), allocatable :: s
    integer :: ticks
    character(32) :: buf
    call system_clock(ticks)
    write(buf, '(I0)') ticks
    s = trim(buf)
  end function

end program
