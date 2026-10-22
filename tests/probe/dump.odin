package probe

import "core:fmt"
import "core:os"

hex_of :: proc(b: []u8) -> string {
	out : [dynamic]u8
	for x in b {
		append(&out, "0123456789abcdef"[x >> 4])
		append(&out, "0123456789abcdef"[x & 0xf])
	}
	return string(out[:])
}

// dump_wire writes the capture to a file and prints its length + a hex head/tail
// so the byte streams from different sessions can be compared directly.
dump_wire :: proc(name: string) {
	b := wire_bytes()
	f, err := os.create(fmt.tprintf("/tmp/u2_w_{}.bin", name))
	if err == .None {
		f.write(b)
		os.close(f)
	}
	fmt.eprintln("[DUMP] {} = {} bytes", name, len(b))
	fmt.eprintln("[DUMP]   head {}", hex_of(b[0:min(64, len(b))]))
	fmt.eprintln("[DUMP]   tail {}", hex_of(b[max(0, len(b)-64):]))
}
