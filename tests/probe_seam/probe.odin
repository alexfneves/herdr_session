package probe_seam

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

rel :: proc(root: string, fullpath: string) -> string {
	normalized := fullpath
	if strings.has_prefix(normalized, "src/") { return normalized }
	marker := fmt.tprintf("{}/{}", root, "")
	if strings.has_prefix(normalized, marker) {
		rr := normalized[len(marker):]
		for len(rr) > 0 && rr[0] == '/' { rr = rr[1:] }
		return fmt.tprintf("src/{}", rr)
	}
	i := strings.last_index(normalized, "/src/")
	if i >= 0 { return normalized[i+1:] }
	return normalized
}

@(test) w :: proc(t: ^testing.T) {
	wp : os.Walker = {}
	os.walker_init_path(&wp, "src")
	defer os.walker_destroy(&wp)
	for info in os.walker_walk(&wp) {
		if info.type != .Directory {
			fmt.println("REL=[{}]", rel("src", string(info.fullpath)))
		}
	}
}
