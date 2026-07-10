!> Basic CRUD example for the MongrelDB Fortran client.
!>
!> Creates a table with unique name, inserts and reads rows, cleans up on exit.
program basic_crud
  use, non_intrinsic :: mongreldb
  use, non_intrinsic :: mongreldb_json
  use iso_fortran_env, only: int64
  implicit none

  type(mongreldb_client) :: db
  integer :: stat
  character(512) :: errmsg
  character(:), allocatable :: table, cols_json
  character(:), allocatable :: url
  character(256) :: envbuf

  ! Resolve the server URL.
  call get_environment_variable('MONGRELDB_URL', envbuf)
  if (len_trim(envbuf) > 0) then
    url = trim(envbuf)
  else
    url = MDB_DEFAULT_URL
  end if

  ! Unique table name so repeated runs do not collide.
  table = 'demo_crud_' // make_suffix()

  call db%connect(url, stat, errmsg)
  if (stat /= MDB_OK) then
    write(*, '(A,A)') 'connect failed: ', trim(errmsg)
    error stop 1
  end if
  if (.not. db%health()) then
    write(*, '(A)') 'daemon not reachable'
    error stop 1
  end if

  cols_json = '[' // &
    '{"id":1,"name":"id","ty":"int64","primary_key":true,"nullable":false},' // &
    '{"id":2,"name":"customer","ty":"varchar","primary_key":false,"nullable":false},' // &
    '{"id":3,"name":"amount","ty":"float64","primary_key":false,"nullable":true}' // &
    ']'

  call db%create_table(table, cols_json, stat, errmsg)
  if (stat /= MDB_OK) call die('create_table failed: ' // trim(errmsg))

  write(*, '(A)') 'Created table ' // table

  ! Insert two rows.
  call db%put(table, '[1,1,2,"Alice",3,99.5]', stat, errmsg)
  if (stat /= MDB_OK) call die('put 1 failed: ' // trim(errmsg))
  call db%put(table, '[1,2,2,"Bob",3,150.0]', stat, errmsg)
  if (stat /= MDB_OK) call die('put 2 failed: ' // trim(errmsg))

  write(*, '(A)') 'Inserted 2 rows'

  ! Count them.
  block
    integer(int64) :: n
    n = db%count(table, stat, errmsg)
    if (stat /= MDB_OK) call die('count failed: ' // trim(errmsg))
    write(*, '(A,I0)') 'Row count: ', n
  end block

  ! Upsert: update Alice's amount.
  call db%upsert(table, '[1,1,2,"Alice",3,200.0]', stat=stat, errmsg=errmsg)
  if (stat /= MDB_OK) call die('upsert failed: ' // trim(errmsg))
  write(*, '(A)') 'Upserted Alice (amount -> 200.0)'

  ! Delete by primary key.
  call db%delete_by_pk(table, '2', stat, errmsg)
  if (stat /= MDB_OK) call die('delete_by_pk failed: ' // trim(errmsg))
  write(*, '(A)') 'Deleted Bob'

  ! Clean up: drop the table before exiting.
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
    ! Best-effort: ignore failure on cleanup.
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
