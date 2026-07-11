!> HTTP transport for the MongrelDB Fortran client.
!>
!> Shells out to the system `curl` binary. This avoids a libcurl C-binding
!> dependency and the associated linking complexity, at the cost of one process
!> per request. For a Tier-2 client issuing low-frequency control-plane and
!> single-op transaction calls, the overhead is negligible.
!>
!> Security properties (mirror the other MongrelDB clients):
!>   - `curl` is invoked with `--noproxy '*'` (never honors proxy env vars).
!>   - `--max-redirs 0` -> redirects are never followed, so an
!>     `Authorization` header cannot leak to a redirect target.
!>   - `--max-filesize` caps the response body at the configured limit.
!>   - `--connect-timeout` / `--max-time` bound request duration.
!>   - The request body is passed via a temp file (not the command line) so
!>     large payloads and arbitrary bytes are handled safely.
module mongreldb_http
  use iso_fortran_env, only: int64
  implicit none
  private

  public :: http_response
  public :: http_request

  !> A parsed HTTP response. `status` is the HTTP status code (0 on transport
  !> failure). `body` holds the response payload. `err` is a transport-level
  !> error description (empty on success).
  type :: http_response
    integer :: status = 0
    character(:), allocatable :: body
    character(:), allocatable :: err
  end type http_response

contains

  !> Perform an HTTP request.
  !>
  !> @param url           Full URL including scheme and path.
  !> @param method        HTTP verb: GET, POST, DELETE, etc.
  !> @param payload       Request body. If unallocated, no body is sent.
  !> @param auth_header   Value of the Authorization header. If unallocated,
  !>                       no auth header is sent.
  !> @param max_bytes     Response body size cap in bytes (default 256 MiB).
  !> @param curl          Path to the curl binary (default: 'curl').
  function http_request(url, method, payload, auth_header, max_bytes, curl) &
      result(resp)
    character(*), intent(in) :: url
    character(*), intent(in) :: method
    character(:), allocatable, intent(in) :: payload
    character(:), allocatable, intent(in) :: auth_header
    integer(int64), intent(in), optional :: max_bytes
    character(*), intent(in), optional :: curl
    type(http_response) :: resp

    character(:), allocatable :: curl_bin
    integer(int64) :: cap
    character(:), allocatable :: cmd, args
    character(:), allocatable :: tmp_req, tmp_resp, tmp_hdr, tmp_err
    integer :: u, stat, exitstat
    character(16) :: code_str
    logical :: have_body

    ! Resolve optional arguments.
    curl_bin = 'curl'
    if (present(curl)) curl_bin = curl
    cap = 256_int64 * 1024_int64 * 1024_int64
    if (present(max_bytes)) cap = max_bytes

    have_body = allocated(payload)

    ! Create temp file paths. Each gets a unique suffix via a saved counter.
    call make_temp_path('mdb_req_', tmp_req)
    call make_temp_path('mdb_resp_', tmp_resp)
    call make_temp_path('mdb_code_', tmp_hdr)
    call make_temp_path('mdb_err_', tmp_err)

    ! Write the request body to its temp file (if any).
    if (have_body) then
      open(newunit=u, file=tmp_req, status='replace', action='write', &
           form='unformatted', access='stream', iostat=stat)
      if (stat /= 0) then
        resp%err = 'failed to open request temp file'
        return
      end if
      write(u, iostat=stat) payload
      close(u)
      if (stat /= 0) then
        resp%err = 'failed to write request temp file'
        return
      end if
    end if

    ! Build the curl argument vector. We write args into a shell-quoted string.
    ! --noproxy '*' defeats proxy env vars; --max-redirs 0 disables redirect
    ! following so an Authorization header cannot leak to a redirect target.
    args = ' --silent --show-error' // &
           ' --noproxy ''*''' // &
           ' --max-redirs 0' // &
           ' --connect-timeout 30 --max-time 120' // &
           ' --max-filesize ' // int64_str(cap) // &
           ' -X ' // trim(method)

    if (allocated(auth_header)) then
      args = args // ' -H ' // shell_quote('Authorization: ' // auth_header)
    end if
    args = args // ' -H ''Content-Type: application/json'''

    ! Write the HTTP status code to the code file via -w '%{http_code}'.
    ! The response body goes to tmp_resp via -o.
    args = args // ' -o ' // shell_quote(tmp_resp) // &
           ' -w ''%{http_code}'''
    args = args // ' ' // shell_quote(url)

    if (have_body) then
      args = args // ' --data-binary @' // shell_quote(tmp_req)
    end if

    cmd = shell_quote(curl_bin) // args // ' > ' // shell_quote(tmp_hdr) // &
          ' 2> ' // shell_quote(tmp_err)

    ! Execute curl.
    call execute_command_line(cmd, exitstat=exitstat)

    ! Read the status code (stdout = the %{http_code} write-out).
    call read_text_file(tmp_hdr, code_str, stat)
    if (stat /= 0) code_str = '0'
    read(code_str, *, iostat=stat) resp%status
    if (stat /= 0) resp%status = 0

    ! Read the response body (may be empty).
    call read_text_file_alloc(tmp_resp, resp%body, stat)
    if (.not. allocated(resp%body)) allocate(character(0) :: resp%body)

    ! On transport failure (curl exited non-zero AND we have no HTTP status),
    ! capture the curl stderr for diagnostics.
    if (exitstat /= 0 .and. resp%status == 0) then
      call read_text_file_alloc(tmp_err, resp%err, stat)
      if (.not. allocated(resp%err)) allocate(character(0) :: resp%err)
      if (len(resp%err) == 0) then
        resp%err = 'curl failed with exit code ' // int_str(exitstat)
      end if
    else
      allocate(character(0) :: resp%err)
    end if

    ! Clean up temp files.
    call safe_unlink(tmp_req)
    call safe_unlink(tmp_resp)
    call safe_unlink(tmp_hdr)
    call safe_unlink(tmp_err)
  end function

  ! ---- Helpers ------------------------------------------------------------

  !> Generate a temp file path under TMPDIR or /tmp.
  subroutine make_temp_path(prefix, path)
    character(*), intent(in) :: prefix
    character(:), allocatable, intent(out) :: path
    character(len=4096) :: dirbuf
    integer :: dirlen
    character(64) :: pid, cnt
    integer, save :: counter = 0
    counter = counter + 1
    call get_environment_variable('TMPDIR', dirbuf, length=dirlen)
    if (dirlen <= 0) then
      path = '/tmp/' // trim(prefix)
    else
      path = dirbuf(1:dirlen) // '/' // trim(prefix)
    end if
    write(pid, '(I0)') get_pid()
    write(cnt, '(I0)') counter
    path = path // trim(pid) // '_' // trim(cnt)
  end subroutine

  !> A pseudo-pid for unique temp-file naming (best effort).
  function get_pid() result(pid)
    integer :: pid
    integer :: ticks
    call system_clock(ticks)
    pid = iand(ticks, 1000000)
  end function

  !> Single-quote a path for safe shell interpolation. Doubles any embedded
  !> single quotes (the standard Bourne-shell escaping rule).
  function shell_quote(s) result(q)
    character(*), intent(in) :: s
    character(:), allocatable :: q
    integer :: i
    q = ''''
    do i = 1, len(s)
      if (s(i:i) == '''') then
        q = q // ''''''
      else
        q = q // s(i:i)
      end if
    end do
    q = q // ''''
  end function

  !> Read a small file into a fixed-length buffer (for status-code files).
  subroutine read_text_file(path, buf, stat)
    character(*), intent(in) :: path
    character(*), intent(out) :: buf
    integer, intent(out) :: stat
    integer :: u
    logical :: exists
    buf = ''
    stat = 0
    inquire(file=path, exist=exists)
    if (.not. exists) then
      stat = 1
      return
    end if
    open(newunit=u, file=path, status='old', action='read', iostat=stat)
    if (stat /= 0) return
    read(u, '(A)', iostat=stat) buf
    close(u)
    if (is_iostat_end(stat)) stat = 0
  end subroutine

  !> Read a file into a deferred-length allocatable string using stream
  !> (binary) access. This reads the exact bytes without line-buffer
  !> truncation or trim() side-effects, which is essential for JSON bodies
  !> that may be long single lines or contain values with trailing spaces.
  subroutine read_text_file_alloc(path, buf, stat)
    character(*), intent(in) :: path
    character(:), allocatable, intent(out) :: buf
    integer, intent(out) :: stat
    integer :: u, filesize, i
    logical :: exists
    character(1), allocatable :: chars(:)

    stat = 0
    buf = ''
    inquire(file=path, exist=exists)
    if (.not. exists) return
    ! Open in stream mode to get byte-accurate reading.
    open(newunit=u, file=path, status='old', action='read', &
         form='unformatted', access='stream', iostat=stat)
    if (stat /= 0) return
    ! Determine file size by seeking to end.
    filesize = 0
    inquire(unit=u, size=filesize, iostat=stat)
    if (stat /= 0 .or. filesize <= 0) then
      close(u)
      stat = 0
      return
    end if
    allocate(chars(filesize))
    rewind(u)
    read(u, iostat=stat) chars
    close(u)
    if (stat /= 0) then
      stat = 0
      return
    end if
    ! Build the string from the byte array.
    buf = ''
    do i = 1, filesize
      buf = buf // chars(i)
    end do
  end subroutine

  subroutine safe_unlink(path)
    character(*), intent(in) :: path
    integer :: exitstat
    call execute_command_line('rm -f ' // shell_quote(path), exitstat=exitstat)
  end subroutine

  function int64_str(i) result(s)
    integer(int64), intent(in) :: i
    character(32) :: s
    write(s, '(I0)') i
  end function

  function int_str(i) result(s)
    integer, intent(in) :: i
    character(16) :: s
    write(s, '(I0)') i
  end function

end module
