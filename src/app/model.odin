package app

// The session model (T3.2 + T3.3).
//
// # The identity rule this file exists to enforce
//
// **A session is identified by `(device, name)` — never by `name` alone.**
// herdr scopes session names per *(host, unix-user)* and its output carries **no
// host field at all** (verified: `session list --json` yields
// `default / name / running / session_dir / socket_path` and nothing else). Two
// machines can each own a session called `api`; collapsing on `name` would be a
// silent data-integrity bug that no single-host test can see.
//
// `device` is the **exact user-configured ssh target string, verbatim**. It is
// never normalised to a hostname, FQDN or alias, because the same string has to
// travel back out into `herdr --remote <device> …` and into our own
// `ssh -T <device>` fetches. Normalising breaks that return path.
//
// The local device is the literal string `local` (DEVICE_LOCAL below).
//
// # The timestamp, and why it is parsed out of the name (D3)
//
// herdr exposes **no timestamp anywhere** — not in `session list --json`, not in
// the per-session `session.json`. Verified: the JSON has five fields and none of
// them is a time. Rather than pay a `stat` or an extra ssh round-trip per
// session, we parse the timestamp back out of the **name**, because every name
// this project creates carries `herdr-cycle`'s exact `%Y-%m-%d-%H-%M-%S-%3N`
// suffix (D11). That makes the timestamp column free: **zero extra syscalls,
// zero extra ssh calls, no `stat` calls anywhere.**
//
// A name that does not end in that shape (`mydb`, a leftover from an older
// scheme) gets no timestamp: displayed as an em dash and sorted **last** inside
// its own device group.
//
// # Odin note: there is no `?T` in this toolchain
//
// `#maybe` was merged into `union` upstream, so "no timestamp" is a named union
// member (`Unknown_Timestamp`) rather than an optional. That turned out to be a
// benefit: the unknown case has to be handled at every use site instead of
// silently carrying a zero value that looks like 1970-01-01.

import json "core:encoding/json"
import "core:fmt"
import "core:sort"
import "core:time"

//-----------------------------------------------------------------------------
// Device identity
//-----------------------------------------------------------------------------

// DEVICE_LOCAL is the device string for sessions on this machine. It is a literal
// on purpose: it is not an ssh target, so it can never be confused with one, and
// the sort order keys off it to keep local sessions on top.
DEVICE_LOCAL :: "local"

// DEFAULT_SESSION_NAME is herdr's persistent workspace. D12: it is **never**
// listed, attached or deleted — herdr itself refuses to delete it, and
// `herdr-cycle` filters it out too. The filter lives in `parse_session_list` so
// every producer of `[ ]Session` gets it for free and none of them can offer one.
DEFAULT_SESSION_NAME :: "default"

is_default_session_name :: proc(name: string) -> bool {
	return name == DEFAULT_SESSION_NAME
}

is_local_device :: proc(device: string) -> bool {
	return device == DEVICE_LOCAL
}

//-----------------------------------------------------------------------------
// Timestamp (D3)
//-----------------------------------------------------------------------------

// UNKNOWN_TIMESTAMP_MARK is how a name with no parseable timestamp is displayed.
UNKNOWN_TIMESTAMP_MARK :: "—"

// TS_SUFFIX_LEN is the exact width of `%Y-%m-%d-%H-%M-%S-%3N` as rendered:
// "2026-10-18-20-30-45-123".
TS_SUFFIX_LEN :: 23

// Ts is a session timestamp: either a real moment, or explicitly "unknown".
Ts :: union {
	time.Time,
	Unknown_Timestamp,
}

// Unknown_Timestamp is the absence of a timestamp, as a type rather than a magic
// number, so the compiler forces every consumer to decide what to do about it.
Unknown_Timestamp :: struct{}

// I64_MAX stands in for "no timestamp" so an ascending sort drops unknown last.
I64_MAX :: 9223372036854775807

ts_unknown :: proc() -> Ts {
	return Ts(Unknown_Timestamp{})
}

ts_is_known :: proc(t: Ts) -> bool {
	_, ok := t.(time.Time)
	return ok
}

// ts_sort_key orders timestamps ascending with unknown timestamps LAST. The
// sentinel is the maximum i64 so an ascending sort drops it at the end of its
// group; a 0 sentinel would sort *first* and put "—" above real sessions.
ts_sort_key :: proc(t: Ts) -> i64 {
	if v, ok := t.(time.Time); ok {
		return time.time_to_unix_nano(v)
	}
	return I64_MAX // sorts last
}

// ts_display renders the timestamp for the table. Unknown -> em dash.
ts_display :: proc(t: Ts) -> string {
	v, ok := t.(time.Time)
	if !ok { return UNKNOWN_TIMESTAMP_MARK }

	year := time.year(v)
	month := int(time.month(v))
	day := time.day(v)
	hour, minute, second := time.clock(v)
	milli := int((time.time_to_unix_nano(v) / 1_000_000) % 1000)
	return fmt.tprintf("%04d-%02d-%02d %02d:%02d:%02d.%03d",
		year, month, day, hour, minute, second, milli)
}

// ascii_digit checks ASCII digits only. Deliberately not `unicode.IsDigit`: that
// accepts Unicode decimal digits, and we are matching a shape we generated
// ourselves from ASCII.
ascii_digit :: proc(b: byte) -> bool {
	return b >= '0' && b <= '9'
}

// parse_ascii_int folds an all-digit ASCII slice into an int. The caller has
// already proven the digits (ts_tail_shape matches them), so this is a fold, not
// a parser — no error path by construction.
parse_ascii_int :: proc(s: string) -> int {
	n := 0
	for b in s {
		n = n * 10 + int(b - '0')
	}
	return n
}

// Dash offsets inside "YYYY-MM-DD-HH-MM-SS-mmm" (0-based):
//   0123 4 56 7 89 10 11 12 13 14 15 16 17 18 19 20 21 22
//   YYYY - MM - DD - HH - MM - SS - m  m  m
TS_DASH_OFFSETS :: [6]int{ 4, 7, 10, 13, 16, 19 }

// ts_tail_shape_matches reports whether `tail` is exactly
// `%Y-%m-%d-%H-%M-%S-%3N` and returns its components.
//
// An explicit positional check rather than a regexp: the shape has ten fixed
// slots, and being wrong here is visible in the code instead of hidden inside a
// pattern that also matches something else.
ts_tail_shape_matches :: proc(tail: string) -> (y, mo, d, h, mi, s, ms: int, ok: bool) {
	if len(tail) != TS_SUFFIX_LEN {
		return 0, 0, 0, 0, 0, 0, 0, false
	}

	for pos in TS_DASH_OFFSETS {
		if tail[pos] != '-' { return 0, 0, 0, 0, 0, 0, 0, false }
	}
	bs := transmute([]byte)(tail)
	for i in 0..<TS_SUFFIX_LEN {
		b := bs[i]
		if i == 4 || i == 7 || i == 10 || i == 13 || i == 16 || i == 19 {
			continue
		}
		if !ascii_digit(b) { return 0, 0, 0, 0, 0, 0, 0, false }
	}

	return parse_ascii_int(tail[0:4]), // year
	       parse_ascii_int(tail[5:7]),  // month
	       parse_ascii_int(tail[8:10]), // day
	       parse_ascii_int(tail[11:13]),// hour
	       parse_ascii_int(tail[14:16]),// minute
	       parse_ascii_int(tail[17:19]),// second
	       parse_ascii_int(tail[20:23]),// millis
	       true
}

// ts_from_name implements D3: read the timestamp back out of the session name.
//
// Accepts the suffix as the whole name (a bare `herdr-cycle` session,
// `2026-10-18-20-30-45-123`) or after a prefix and a dash (`api-2026-…`, the
// "new session with a name" shape). Requiring the separator stops
// `mydb2026-10-18-20-30-45-123` from being read as a timestamped name.
//
// Calendar validation is delegated to `time.components_to_time`, so a name with
// the right shape but an impossible moment (`2026-13-45-99-99-99-000`) comes
// back as "unknown" rather than silently rolling over into the next month.
ts_from_name :: proc(name: string) -> Ts {
	if len(name) < TS_SUFFIX_LEN { return ts_unknown() }

	tail := name[len(name)-TS_SUFFIX_LEN:]
	if len(name) > TS_SUFFIX_LEN && name[len(name)-TS_SUFFIX_LEN-1] != '-' {
		return ts_unknown()
	}

	y, mo, d, h, mi, s, ms, shaped := ts_tail_shape_matches(tail)
	if !shaped { return ts_unknown() }

	moment, ok := time.components_to_time(y, mo, d, h, mi, s, ms * 1_000_000)
	if !ok { return ts_unknown() }
	return Ts(moment)
}

// format_cycle_timestamp renders D11's exact `%Y-%m-%d-%H-%M-%S-%3N`, the format
// `herdr-cycle.sh` has always used. Sharing one implementation is what makes the
// output of `ts_from_name` round-trip against the names we generate.
format_cycle_timestamp :: proc(t: time.Time) -> string {
	year := time.year(t)
	month := int(time.month(t))
	day := time.day(t)
	hour, minute, second := time.clock(t)
	milli := int((time.time_to_unix_nano(t) / 1_000_000) % 1000)
	return fmt.tprintf("%04d-%02d-%02d-%02d-%02d-%02d-%03d",
		year, month, day, hour, minute, second, milli)
}

// new_session_name builds the name for a session we are about to create (D11):
// `<prefix>-<timestamp>` when a prefix was typed, the bare timestamp otherwise —
// and regenerates the timestamp on collision, exactly like herdr-cycle's
// `while :; do … if session_list | grep -qF "$n"; then continue; fi; done`.
//
// `taken` is the set of names already present for the *same device*: a name free
// on `local` may be busy on a remote host, which is precisely why the caller
// passes the per-device list rather than a global one.
new_session_name :: proc(prefix: string, taken: []string) -> (name: string, ok: bool) {
	// Bounded retry. Regeneration is driven by the clock, so a collision means
	// we are inside the same millisecond as an existing name; a handful of tries
	// covers that, and giving up honestly beats looping forever if the clock is
	// wedged.
	for _ in 0..<8 {
		candidate := format_cycle_timestamp(time.now())
		if prefix != "" {
			candidate = fmt.tprintf("{}-{}", prefix, candidate)
		}
		if index_of_identity_name(taken, candidate) < 0 {
			return candidate, true
		}
		time.sleep(1 * time.Millisecond)
	}
	return "", false
}

// index_of_identity_name finds a bare name within one device's list.
index_of_identity_name :: proc(names: []string, name: string) -> int {
	for n, i in names {
		if n == name { return i }
	}
	return -1
}

//-----------------------------------------------------------------------------
// Session
//-----------------------------------------------------------------------------

// Session is one row of the table, before filtering and paging.
Session :: struct {
	device  : string, // DEVICE_LOCAL, or the VERBATIM configured ssh target
	label   : string, // device display label (registry label, else the target)
	name    : string, // the herdr session name, verbatim as herdr knows it
	running : bool,   // from --json: a LIVE socket connect-probe, not a file check
	ts      : Ts,     // parsed from `name` (D3); unknown -> "—", sorted last
}

// Key is the primary identity of a session. Everything that looks a session up —
// selection across a merge, attach, delete, dedup — goes through this pair.
Key :: proc(s: ^Session) -> (string, string) {
	return s.device, s.name
}

same_identity :: proc(a: ^Session, b: ^Session) -> bool {
	return a.device == b.device && a.name == b.name
}

// index_of_identity finds a session by its (device, name) pair, or -1.
//
// This single function is also `delete`'s existence pre-check (ISC-16), which
// matters because herdr's `delete` answers `{"deleted": true}` with **exit 0**
// for names that never existed. See `herdr.odin`'s `delete_session`.
index_of_identity :: proc(sessions: []Session, device: string, name: string) -> int {
	for s, i in sessions {
		if s.device == device && s.name == name { return i }
	}
	return -1
}

// is_known_session is the existence pre-check phrased the way callers want it.
is_known_session :: proc(sessions: []Session, device: string, name: string) -> bool {
	return index_of_identity(sessions, device, name) >= 0
}

// names_for_device projects one device's names, for collision checks.
names_for_device :: proc(sessions: []Session, device: string) -> []string {
	out := make([dynamic]string, 0, 8)
	for s in sessions {
		if s.device == device { append(&out, s.name) }
	}
	return out[:]
}

// sort_key_of is the table's ordering: local group first, then device string,
// then timestamp ascending (unknown last), then name as the final tiebreak so the
// order is total and a re-sort of equal rows cannot shuffle the display.
session_sort_key :: proc(s: Session) -> (int, string, i64, string) {
	group := 1
	if is_local_device(s.device) { group = 0 }
	return group, s.device, ts_sort_key(s.ts), s.name
}

compare_session :: proc(a, b: Session) -> int {
	ag, adevice, ats, aname := session_sort_key(a)
	bg, bdevice, bts, bname := session_sort_key(b)
	if ag != bg { return ag - bg }
	if adevice != bdevice {
		if adevice < bdevice { return -1 }
		if adevice > bdevice { return 1 }
	}
	if ats != bts { return if_true(ats < bts, -1, 1) }
	if aname != bname {
		if aname < bname { return -1 }
		if aname > bname { return 1 }
	}
	return 0
}

if_true :: proc(cond: bool, yes, no: int) -> int {
	if cond { return yes }
	return no
}

// sort_sessions orders the table in place.
sort_sessions :: proc(sessions: []Session) {
	sort.quick_sort_proc(sessions, compare_session)
}

//-----------------------------------------------------------------------------
// `herdr session list --json` -> [ ]Session  (T3.3)
//-----------------------------------------------------------------------------

// Raw_Session mirrors one element of herdr's `session list --json`.
//
// The `default` key collides with an Odin keyword, so the field is `is_default`
// with a JSON tag. Keys we do not declare are simply not read, which keeps us
// forward-compatible with whatever herdr 0.9 adds instead of failing the list.
Raw_Session :: struct {
	name        : string,
	running     : bool,
	is_default  : bool   `json:"default"`,
	session_dir : string `json:"session_dir"`,
	socket_path : string `json:"socket_path"`,
}

Raw_Session_List :: struct {
	sessions : []Raw_Session,
}

// parse_session_list turns the JSON body of `herdr session list --json` into
// model rows tagged with `device` / `label`.
//
// * `default:true` entries are dropped here (D12), so no caller can offer one.
// * A parse failure returns `ok = false` and no rows: an unexpected payload
//   degrades that device's group instead of bricking the app.
// * `running` is passed through exactly as herdr reports it. It is a **live
//   connect-probe** against the session socket (verified by planting a stray
//   `herdr.sock` for a session that was not running — still reported `false`),
//   so it means "a server is answering on the other end", not "a file exists".
parse_session_list :: proc(payload: []byte, device: string, label: string) -> (sessions: []Session, ok: bool) {
	raw : Raw_Session_List = {}
	if err := json.unmarshal(payload, &raw); err != nil {
		return nil, false
	}

	out := make([dynamic]Session, 0, len(raw.sessions))
	for r in raw.sessions {
		if r.is_default || is_default_session_name(r.name) { continue } // D12
		append(&out, Session{
			device  = device,
			label   = label,
			name    = r.name,
			running = r.running,
			ts      = ts_from_name(r.name),
		})
	}
	return out[:], true
}

// has_sessions_field is the shape probe used before trusting a payload: a JSON
// object carrying a `sessions` array. Kept separate from parsing so a caller can
// report "herdr answered, but not in a shape we know" as its own condition —
// which is also the whole basis of the `machine` feature gate in `remotes.odin`.
has_sessions_field :: proc(payload: []byte) -> bool {
	v, err := json.parse_bytes(payload)
	if err != nil { return false }
	obj, is_obj := v.(json.Object)
	if !is_obj { return false }
	arr, has := obj["sessions"]
	if !has { return false }
	_, is_arr := arr.(json.Array)
	return is_arr
}

//-----------------------------------------------------------------------------
// Per-device fetch state
//-----------------------------------------------------------------------------

// Device_Status is one device's health in the fan-out. A host's failure degrades
// only that host's row group, so the status has to be per-device rather than a
// single app-level error. The labels for the status column are Phase 4's job —
// this enum only carries the distinction.
Device_Status :: enum {
	pending,      // spawned, no answer yet
	ok,           // list parsed, rows merged
	timed_out,    // our own deadline fired
	unreachable,  // ssh could not connect (ConnectTimeout / no route)
	no_herdr,     // ssh connected; `herdr` is not installed there (exit 127)
	auth_failed,  // ssh refused to authenticate (BatchMode fast-fail)
	failed,       // answered, but not with something we understand
}

// Device is one row-group's header: which host, what we call it, how it went.
Device :: struct {
	target : string, // VERBATIM ssh target ("local" for this machine)
	label  : string,
	status : Device_Status,
	detail : string, // why, for the status column / error pane
}


