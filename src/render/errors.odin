package render

// Clay's error handler, made real.
//
// # Why this exists
//
// Clay's *default* error handler is literally:
//
//	void Clay__ErrorHandlerFunctionDefault(Clay_ErrorData errorText) { (void) errorText; }
//
// i.e. every layout bug — duplicate ids, arena exhaustion, unbalanced
// open/close — is silently discarded. On a TUI that means a duplicated element id
// renders as missing or garbled UI with no diagnostic at all. T2.3 exists so
// that cannot happen.
//
// # The constraint that shapes this file
//
// Clay calls the handler through `proc "c"`. There is no Odin context at that
// point, therefore **no allocator**: no `make`, no `append`, no string
// formatting, nothing that can fail or re-enter malloc while Clay is mid-layout
// inside its own arena. The handler also runs *while* Clay is walking its data
// structures, so it must be short, allocation-free and cheap.
//
// So messages are composed byte-by-byte into a fixed-size, statically allocated
// store (`proc "contextless"`, which makes the compiler enforce that no context /
// allocator sneaks in). Nothing is allocated, formatted or printed inside the C
// frame.
//
// The application drains it *after* the frame — `errors_latest`,
// `errors_records` — and folds it into its own error state. That boundary is the
// point: the message survives the C frame in a buffer we control, and surfaces as
// readable text out in Odin-land.
//
// Retention is a shift-left window of ERROR_RING_CAPACITY messages (errors are
// rare; shifting a few hundred bytes is nothing). Kept contiguous on purpose:
// draining hands back a plain slice with no allocator and no ring-index math.
//
// # Trap discovered here
//
// `clay.odin`'s `ErrorType` enum stops at `UnbalancedOpenClose` (8), but the
// pinned `clay.h` declares a tenth member,
// `CLAY_ERROR_TYPE_HASH_MAP_CAPACITY_EXCEEDED` (9). A `switch` on the *enum*
// would be handling a value the binding cannot name. We keep the raw ordinal and
// switch on `int`, so an unmapped value degrades to `UnknownError` instead of
// mislabelling or trapping.

import clay "../../clay-odin"

// Capacity of one composed message ("KindName: <clay text>" included).
ERROR_MESSAGE_CAPACITY :: 224

// How many messages are retained. Older ones are evicted once full, but
// `errors_total` keeps counting, so loss is visible instead of silent.
ERROR_RING_CAPACITY :: 8

// One recorded Clay error. Self-contained — the message lives inside the record,
// so a view of it stays valid long after the C frame that produced it is gone,
// and the record can be copied without the view dangling.
Error_Record :: struct {
	code      : int,    // raw Clay error ordinal (see trap note above)
	kind      : string, // human-readable kind, points at static literals
	offset    : int,    // where the composed message starts inside `storage`
	length    : int,    // and how long it is
	truncated : bool, // true when Clay's message did not fit
	storage   : [ERROR_MESSAGE_CAPACITY]u8,
}

Error_Store :: struct {
	records : [ERROR_RING_CAPACITY]Error_Record,
	filled  : int, // records retained, <= ERROR_RING_CAPACITY
	total   : int, // every error ever reported, including evicted ones
	dropped : int, // records evicted to make room
}

// The single storage for Clay errors. Package-level (static) on purpose: the
// handler has no allocator to build one with, and Clay may call it at any point
// during a frame.
errors : Error_Store = {}

// errors_handler is the C-callable handler handed to Clay_Initialize.
//
// No allocation, no formatting, no printing. It composes
// "KindName: <clay message>" straight into a fixed buffer and returns.
errors_handler :: proc "c" (data: clay.ErrorData) {
	// Make room if the window is full: drop the oldest, shift the rest down one.
	if errors.filled == ERROR_RING_CAPACITY {
		shift_left()
		errors.dropped += 1
	}

	record := &errors.records[errors.filled]
	errors.filled += 1
	errors.total += 1

	code := cast(int)(data.errorType)
	kind := error_kind_name(code)

	// Compose "KindName: message" into this record's own storage.
	buf := record.storage[:]
	pos := bounded_append(buf, 0, kind)
	pos = bounded_append(buf, pos, ": ")
	start := pos
	spare := len(buf) - pos
	truncated := false

	text_len := int(data.errorText.length)
	if data.errorText.chars != nil && text_len > 0 {
		n := text_len
		if n > spare {
			n = spare
			truncated = true
		}
		src := data.errorText.chars
		i := 0
		for i < n {
			buf[pos] = src[i]
			pos += 1
			i += 1
		}
	} else {
		pos = bounded_append(buf, pos, "(no message)")
	}

	record.code = code
	record.kind = kind
	record.offset = start
	record.length = pos - start
	record.truncated = truncated
}

// errors_handler_for returns the handler struct Clay_Initialize wants.
errors_handler_for :: proc() -> clay.ErrorHandler {
	return clay.ErrorHandler{
		handler  = errors_handler,
		userData = nil,
	}
}

// ---------------------------------------------------------------------------
// Draining — these run outside the C frame, with a normal Odin context.
// Every one of them is still allocation-free: the text was written once, inside
// the handler, and is handed back as a view.
// ---------------------------------------------------------------------------

// errors_total counts every error Clay has raised since the last clear,
// including ones the retention window already evicted.
errors_total :: proc() -> int {
	return errors.total
}

// errors_dropped counts records evicted to make room for newer ones.
errors_dropped :: proc() -> int {
	return errors.dropped
}

// errors_count returns how many records are retained right now.
errors_count :: proc() -> int {
	return errors.filled
}

// errors_records hands back the retained records, oldest first.
errors_records :: proc() -> []Error_Record {
	return errors.records[0:errors.filled]
}

// errors_messages hands back the composed messages, oldest first.
//
// Views only: no allocation, no byte copying. Backed by a static window sized to
// the retention window, refreshed in place on every call.
errors_messages :: proc() -> []string {
	refresh_views()
	return message_views[0:errors.filled]
}

// errors_latest returns the most recent "KindName: message", or "" when nothing
// has been reported.
errors_latest :: proc() -> string {
	if errors.filled == 0 {
		return ""
	}
	return record_message(&errors.records[errors.filled-1])
}

// errors_at returns the i-th retained message, oldest first.
errors_at :: proc(i: int) -> string {
	if i < 0 || i >= errors.filled {
		return ""
	}
	return record_message(&errors.records[i])
}

// record_message renders nothing — it just views the bytes the handler already
// composed. Works on any copy of a record because the bytes travel with it.
record_message :: proc(record: ^Error_Record) -> string {
	end := record.offset + record.length
	if end > len(record.storage) {
		end = len(record.storage)
	}
	if record.offset > end {
		return ""
	}
	return string(record.storage[record.offset:end])
}

// errors_clear forgets everything retained. Call once the error has been shown so
// a steady-state frame does not keep re-reporting one old problem.
errors_clear :: proc() {
	errors = Error_Store{}
}

// errors_has_new reports whether anything arrived since the last clear.
errors_has_new :: proc() -> bool {
	return errors.total > 0
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

// message_views backs errors_messages. Static, sized to the retention window, so
// handing back string views never allocates.
message_views : [ERROR_RING_CAPACITY]string = {}

refresh_views :: proc() {
	i := 0
	for i < errors.filled {
		message_views[i] = record_message(&errors.records[i])
		i += 1
	}
}

// shift_left drops the oldest record and moves the rest down one slot, leaving the
// last slot free for a new write. Records carry offsets rather than string views,
// so copying them cannot dangle.
shift_left :: proc "contextless" () {
	i: int = 1
	for i < ERROR_RING_CAPACITY {
		errors.records[i-1] = errors.records[i]
		i += 1
	}
	errors.filled -= 1
}

// bounded_append copies s into buf at pos, never past len(buf), returning the new pos.
bounded_append :: proc "contextless" (buf: []u8, start: int, s: string) -> int {
	at := start
	i := 0
	for i < len(s) && at < len(buf) {
		buf[at] = s[i]
		at += 1
		i += 1
	}
	return at
}

// error_kind_name maps Clay's error ordinal to a readable name. It switches on
// the int rather than the enum because the Odin binding does not name all of
// clay.h's members — see the note at the top of this file.
error_kind_name :: proc "contextless" (code: int) -> string {
	switch code {
	case 0: return "TextMeasurementFunctionNotProvided"
	case 1: return "ArenaCapacityExceeded"
	case 2: return "ElementsCapacityExceeded"
	case 3: return "TextMeasurementCapacityExceeded"
	case 4: return "DuplicateId"
	case 5: return "FloatingContainerParentNotFound"
	case 6: return "PercentageOver1"
	case 7: return "InternalError"
	case 8: return "UnbalancedOpenClose"
	case 9: return "HashMapCapacityExceeded"
	}
	return "UnknownError"
}
