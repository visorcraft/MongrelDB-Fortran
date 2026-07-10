!> Minimal JSON parser and serializer for the MongrelDB Fortran client.
!>
!> Provides a discriminated-union `json_value` type that can represent any JSON
!> node (null, bool, int, real, string, array, object), a recursive-descent
!> parser, and a serializer. The parser is strict about structure and rejects
!> malformed input with a non-zero `stat` rather than reading out of bounds.
!>
!> This module is self-contained (no external dependencies) and exists because
!> Fortran has no standard-library JSON support.
module mongreldb_json
  use iso_fortran_env, only: int64, real64
  implicit none
  private

  public :: json_value
  public :: JSON_NULL, JSON_BOOL, JSON_INT, JSON_REAL, JSON_STRING, &
            JSON_ARRAY, JSON_OBJECT
  public :: json_parse, json_serialize
  public :: json_object_get, json_object_has, json_array_get, json_array_len
  public :: json_make_null, json_make_bool, json_make_int, json_make_real, &
            json_make_string
  public :: json_make_object, json_object_set, json_object_set_int, &
            json_object_set_str, json_object_set_bool
  public :: json_make_array, json_array_push

  !> Discriminator constants for `json_value%kind`.
  integer, parameter :: JSON_NULL   = 0
  integer, parameter :: JSON_BOOL   = 1
  integer, parameter :: JSON_INT    = 2
  integer, parameter :: JSON_REAL   = 3
  integer, parameter :: JSON_STRING = 4
  integer, parameter :: JSON_ARRAY  = 5
  integer, parameter :: JSON_OBJECT = 6

  !> A JSON value. The `kind` field selects which `*_val` member is meaningful.
  !> For arrays, `children` holds the elements. For objects, `keys` and
  !> `children` are parallel arrays (key i -> children(i)).
  type :: json_value
    integer :: kind = JSON_NULL
    logical :: bool_val = .false.
    integer(int64) :: int_val = 0_int64
    real(real64) :: real_val = 0.0_real64
    character(:), allocatable :: str_val
    type(json_value), allocatable :: children(:)
    character(:), allocatable :: keys(:)
  end type json_value

contains

  ! ---- Constructors -------------------------------------------------------

  function json_make_null() result(v)
    type(json_value) :: v
    v%kind = JSON_NULL
  end function

  function json_make_bool(b) result(v)
    logical, intent(in) :: b
    type(json_value) :: v
    v%kind = JSON_BOOL
    v%bool_val = b
  end function

  function json_make_int(i) result(v)
    integer(int64), intent(in) :: i
    type(json_value) :: v
    v%kind = JSON_INT
    v%int_val = i
  end function

  function json_make_real(r) result(v)
    real(real64), intent(in) :: r
    type(json_value) :: v
    v%kind = JSON_REAL
    v%real_val = r
  end function

  function json_make_string(s) result(v)
    character(*), intent(in) :: s
    type(json_value) :: v
    v%kind = JSON_STRING
    v%str_val = s
  end function

  function json_make_object() result(v)
    type(json_value) :: v
    v%kind = JSON_OBJECT
    allocate(v%keys(0), source=[character(0)::])
    allocate(v%children(0))
  end function

  function json_make_array() result(v)
    type(json_value) :: v
    v%kind = JSON_ARRAY
    allocate(v%children(0))
  end function

  ! ---- Object builders ----------------------------------------------------

  !> Append a key/value pair to an object. Grows the parallel arrays by one.
  subroutine json_object_set(obj, key, val)
    type(json_value), intent(inout) :: obj
    character(*), intent(in) :: key
    type(json_value), intent(in) :: val
    type(json_value), allocatable :: tmp_c(:)
    character(:), allocatable :: tmp_k(:)
    integer :: n
    n = size(obj%keys)
    allocate(tmp_c(n+1))
    ! Allocate the parallel keys array using source= so each element is a
    ! deferred-length allocatable string (assignment below sizes each one).
    allocate(tmp_k(n+1), source=[character(0)::])
    if (n > 0) then
      tmp_c(1:n) = obj%children
      tmp_k(1:n) = obj%keys
    end if
    tmp_c(n+1) = val
    tmp_k(n+1) = key
    call move_alloc(tmp_c, obj%children)
    call move_alloc(tmp_k, obj%keys)
  end subroutine

  subroutine json_object_set_int(obj, key, val)
    type(json_value), intent(inout) :: obj
    character(*), intent(in) :: key
    integer(int64), intent(in) :: val
    call json_object_set(obj, key, json_make_int(val))
  end subroutine

  subroutine json_object_set_str(obj, key, val)
    type(json_value), intent(inout) :: obj
    character(*), intent(in) :: key
    character(*), intent(in) :: val
    call json_object_set(obj, key, json_make_string(val))
  end subroutine

  subroutine json_object_set_bool(obj, key, val)
    type(json_value), intent(inout) :: obj
    character(*), intent(in) :: key
    logical, intent(in) :: val
    call json_object_set(obj, key, json_make_bool(val))
  end subroutine

  ! ---- Array builders -----------------------------------------------------

  subroutine json_array_push(arr, val)
    type(json_value), intent(inout) :: arr
    type(json_value), intent(in) :: val
    type(json_value), allocatable :: tmp(:)
    integer :: n
    n = size(arr%children)
    allocate(tmp(n+1))
    if (n > 0) tmp(1:n) = arr%children
    tmp(n+1) = val
    call move_alloc(tmp, arr%children)
  end subroutine

  ! ---- Accessors ----------------------------------------------------------

  !> Look up a key in an object. Returns .true. if found.
  function json_object_has(obj, key) result(found)
    type(json_value), intent(in) :: obj
    character(*), intent(in) :: key
    logical :: found
    integer :: i
    found = .false.
    if (obj%kind /= JSON_OBJECT) return
    do i = 1, size(obj%keys)
      if (obj%keys(i) == key) then
        found = .true.
        exit
      end if
    end do
  end function

  !> Get a value by key from an object. Returns null if absent or not an object.
  function json_object_get(obj, key) result(out)
    type(json_value), intent(in) :: obj
    character(*), intent(in) :: key
    type(json_value) :: out
    integer :: i
    out = json_make_null()
    if (obj%kind /= JSON_OBJECT) return
    do i = 1, size(obj%keys)
      if (obj%keys(i) == key) then
        out = obj%children(i)
        return
      end if
    end do
  end function

  !> Get element i (1-based) from an array. Returns null if out of bounds.
  function json_array_get(arr, i) result(out)
    type(json_value), intent(in) :: arr
    integer, intent(in) :: i
    type(json_value) :: out
    out = json_make_null()
    if (arr%kind == JSON_ARRAY) then
      if (i >= 1 .and. i <= size(arr%children)) out = arr%children(i)
    end if
  end function

  function json_array_len(arr) result(n)
    type(json_value), intent(in) :: arr
    integer :: n
    if (arr%kind == JSON_ARRAY) then
      n = size(arr%children)
    else
      n = 0
    end if
  end function

  ! ---- Parser -------------------------------------------------------------

  !> Parse a JSON document string into a value tree.
  !> On success `stat` is 0. On failure `stat` is non-zero and `errmsg`
  !> describes the problem.
  subroutine json_parse(text, val, stat, errmsg)
    character(*), intent(in) :: text
    type(json_value), intent(out) :: val
    integer, intent(out) :: stat
    character(*), intent(out) :: errmsg
    integer :: pos

    pos = 1
    stat = 0
    errmsg = ''
    call skip_ws
    if (pos > len(text)) then
      stat = 1
      errmsg = 'empty JSON input'
      return
    end if
    call parse_value(val)
    if (stat /= 0) return
    call skip_ws
    if (pos <= len(text)) then
      stat = 1
      write(errmsg, '(A,I0)') 'trailing data at position ', pos
    end if

  contains

    subroutine skip_ws
      do while (pos <= len(text))
        select case (text(pos:pos))
        case (' ', char(9), char(10), char(13))
          pos = pos + 1
        case default
          exit
        end select
      end do
    end subroutine

    subroutine fail(msg)
      character(*), intent(in) :: msg
      if (stat == 0) then
        stat = 1
        errmsg = msg
      end if
    end subroutine

    subroutine parse_value(v)
      type(json_value), intent(out) :: v
      character :: c
      if (pos > len(text)) then
        call fail('unexpected end of input')
        return
      end if
      c = text(pos:pos)
      select case (c)
      case ('{')
        call parse_object(v)
      case ('[')
        call parse_array(v)
      case ('"')
        call parse_string_val(v)
      case ('t', 'f')
        call parse_bool_val(v)
      case ('n')
        call parse_null_val(v)
      case ('-', '0':'9')
        call parse_number_val(v)
      case default
        write(errmsg, '(A,I0,A)') 'unexpected character at position ', pos, ''
        stat = 1
      end select
    end subroutine

    subroutine parse_object(v)
      type(json_value), intent(out) :: v
      character(:), allocatable :: key
      type(json_value) :: elem
      v = json_make_object()
      pos = pos + 1  ! consume '{'
      call skip_ws
      if (pos <= len(text)) then
        if (text(pos:pos) == '}') then
          pos = pos + 1
          return
        end if
      end if
      do
        call skip_ws
        if (pos > len(text) .or. text(pos:pos) /= '"') then
          call fail('expected string key')
          return
        end if
        call parse_string_raw(key)
        if (stat /= 0) return
        call skip_ws
        if (pos > len(text) .or. text(pos:pos) /= ':') then
          call fail('expected '':'' in object')
          return
        end if
        pos = pos + 1
        call skip_ws
        call parse_value(elem)
        if (stat /= 0) return
        call json_object_set(v, key, elem)
        call skip_ws
        if (pos > len(text)) then
          call fail('unterminated object')
          return
        end if
        select case (text(pos:pos))
        case (',')
          pos = pos + 1
          cycle
        case ('}')
          pos = pos + 1
          exit
        case default
          call fail('expected '','' or ''}''')
          return
        end select
      end do
    end subroutine

    subroutine parse_array(v)
      type(json_value), intent(out) :: v
      type(json_value) :: elem
      v = json_make_array()
      pos = pos + 1  ! consume '['
      call skip_ws
      if (pos <= len(text)) then
        if (text(pos:pos) == ']') then
          pos = pos + 1
          return
        end if
      end if
      do
        call skip_ws
        call parse_value(elem)
        if (stat /= 0) return
        call json_array_push(v, elem)
        call skip_ws
        if (pos > len(text)) then
          call fail('unterminated array')
          return
        end if
        select case (text(pos:pos))
        case (',')
          pos = pos + 1
          cycle
        case (']')
          pos = pos + 1
          exit
        case default
          call fail('expected '','' or '']''')
          return
        end select
      end do
    end subroutine

    subroutine parse_string_val(v)
      type(json_value), intent(out) :: v
      character(:), allocatable :: s
      call parse_string_raw(s)
      if (stat /= 0) return
      v = json_make_string(s)
    end subroutine

    !> Parse a quoted string into `out` (a deferred-length allocatable).
    !> Builds the string by concatenation; uses a local helper.
    subroutine parse_string_raw(out)
      character(:), allocatable, intent(out) :: out
      character :: c
      integer :: hexval, j
      character :: h
      out = ''
      pos = pos + 1  ! consume opening '"'
      do
        if (pos > len(text)) then
          call fail('unterminated string')
          return
        end if
        c = text(pos:pos)
        if (c == '"') then
          pos = pos + 1
          exit
        else if (c == '\') then
          pos = pos + 1
          if (pos > len(text)) then
            call fail('unterminated escape')
            return
          end if
          c = text(pos:pos)
          select case (c)
          case ('"');  out = out // '"'
          case ('\');  out = out // '\'
          case ('/');  out = out // '/'
          case ('n');  out = out // char(10)
          case ('t');  out = out // char(9)
          case ('r');  out = out // char(13)
          case ('b');  out = out // char(8)
          case ('f');  out = out // char(12)
          case ('u')
            hexval = 0
            do j = 1, 4
              pos = pos + 1
              if (pos > len(text)) then
                call fail('incomplete \u escape')
                return
              end if
              h = text(pos:pos)
              select case (h)
              case ('0':'9')
                hexval = hexval * 16 + (ichar(h) - ichar('0'))
              case ('a':'f')
                hexval = hexval * 16 + (ichar(h) - ichar('a') + 10)
              case ('A':'F')
                hexval = hexval * 16 + (ichar(h) - ichar('A') + 10)
              case default
                call fail('invalid hex digit in \u escape')
                return
              end select
            end do
            call append_codepoint(out, hexval)
          case default
            call fail('invalid escape character')
            return
          end select
          pos = pos + 1
        else
          out = out // c
          pos = pos + 1
        end if
      end do
    end subroutine

    subroutine parse_bool_val(v)
      type(json_value), intent(out) :: v
      if (pos + 3 <= len(text)) then
        if (text(pos:pos+3) == 'true') then
          v = json_make_bool(.true.)
          pos = pos + 4
          return
        end if
      end if
      if (pos + 4 <= len(text)) then
        if (text(pos:pos+4) == 'false') then
          v = json_make_bool(.false.)
          pos = pos + 5
          return
        end if
      end if
      call fail('invalid literal')
    end subroutine

    subroutine parse_null_val(v)
      type(json_value), intent(out) :: v
      if (pos + 3 <= len(text)) then
        if (text(pos:pos+3) == 'null') then
          v = json_make_null()
          pos = pos + 4
          return
        end if
      end if
      call fail('invalid literal')
    end subroutine

    subroutine parse_number_val(v)
      type(json_value), intent(out) :: v
      integer :: start, ios
      logical :: is_real
      character :: c
      integer(int64) :: iv
      real(real64) :: rv
      start = pos
      is_real = .false.
      if (pos <= len(text)) then
        if (text(pos:pos) == '-') pos = pos + 1
      end if
      do while (pos <= len(text))
        c = text(pos:pos)
        select case (c)
        case ('0':'9')
          pos = pos + 1
        case ('.', 'e', 'E', '+', '-')
          is_real = .true.
          pos = pos + 1
        case default
          exit
        end select
      end do
      if (is_real) then
        read(text(start:pos-1), *, iostat=ios) rv
        if (ios /= 0) then
          call fail('invalid number')
          return
        end if
        v = json_make_real(rv)
      else
        read(text(start:pos-1), *, iostat=ios) iv
        if (ios /= 0) then
          ! Fallback: parse as real if the integer overflows.
          read(text(start:pos-1), *, iostat=ios) rv
          if (ios /= 0) then
            call fail('invalid number')
            return
          end if
          v = json_make_real(rv)
        else
          v = json_make_int(iv)
        end if
      end if
    end subroutine

  end subroutine

  !> Append a Unicode codepoint to a deferred-length string as UTF-8 bytes.
  subroutine append_codepoint(s, cp)
    character(:), allocatable, intent(inout) :: s
    integer, intent(in) :: cp
    if (cp < 128) then
      s = s // char(cp)
    else if (cp < 2048) then
      s = s // char(ishft(cp,-6) + 192)
      s = s // char(iand(cp,63) + 128)
    else
      s = s // char(ishft(cp,-12) + 224)
      s = s // char(iand(ishft(cp,-6),63) + 128)
      s = s // char(iand(cp,63) + 128)
    end if
  end subroutine

  ! ---- Serializer ---------------------------------------------------------

  !> Serialize a value tree to a JSON string.
  function json_serialize(v) result(s)
    type(json_value), intent(in) :: v
    character(:), allocatable :: s
    s = serialize_val(v)
  end function

  recursive function serialize_val(v) result(s)
    type(json_value), intent(in) :: v
    character(:), allocatable :: s
    character(64) :: buf
    integer :: i
    s = ''
    select case (v%kind)
    case (JSON_NULL)
      s = 'null'
    case (JSON_BOOL)
      if (v%bool_val) then
        s = 'true'
      else
        s = 'false'
      end if
    case (JSON_INT)
      write(buf, '(I0)') v%int_val
      s = trim(buf)
    case (JSON_REAL)
      ! Use enough precision for round-trip fidelity.
      write(buf, '(ES25.16E3)') v%real_val
      s = trim(buf)
    case (JSON_STRING)
      s = '"' // escape_string(v%str_val) // '"'
    case (JSON_ARRAY)
      s = '['
      do i = 1, size(v%children)
        if (i > 1) s = s // ','
        s = s // serialize_val(v%children(i))
      end do
      s = s // ']'
    case (JSON_OBJECT)
      s = '{'
      do i = 1, size(v%keys)
        if (i > 1) s = s // ','
        s = s // '"' // escape_string(v%keys(i)) // '":'
        s = s // serialize_val(v%children(i))
      end do
      s = s // '}'
    end select
  end function

  function escape_string(s) result(out)
    character(*), intent(in) :: s
    character(:), allocatable :: out
    integer :: i
    character :: c
    out = ''
    do i = 1, len(s)
      c = s(i:i)
      select case (c)
      case ('"')
        out = out // '\"'
      case ('\')
        out = out // '\\'
      case (char(10))
        out = out // '\n'
      case (char(9))
        out = out // '\t'
      case (char(13))
        out = out // '\r'
      case (char(8))
        out = out // '\b'
      case (char(12))
        out = out // '\f'
      case (char(0):char(7), char(11), char(14):char(31))
        ! Control characters: emit as \uXXXX.
        out = out // unicode_escape(ichar(c))
      case default
        out = out // c
      end select
    end do
  end function

  function unicode_escape(cp) result(s)
    integer, intent(in) :: cp
    character(6) :: s
    write(s, '("\u",Z4.4)') cp
  end function

end module
