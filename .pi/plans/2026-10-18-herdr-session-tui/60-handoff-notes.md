# Handoff Notes — verified Odin facts for the remaining phases

Read this before writing state-machine or executor code. These were **empirically verified in this
project's own `pkgs.odin` (dev-2026-09)** on 2026-10-19, specifically because the Phase 5b attempt
**stalled ~11 hours** probing exactly this and produced zero files.

---

## O10 — `Command` is a TAGGED STRUCT, not a union  ← use this

The plan's sketch (`Command :: union { None, LaunchLocal : LaunchSpec, … }`) is **invalid in this Odin**
and the valid forms have a **silent trap**. Use a tagged struct instead. Verified compiling:

```odin
Cmd_Kind :: enum { none, launch_local, launch_remote, attach, delete,
                  set_theme, show_error, clear_filter, clear_field, quit }

Command :: struct {
    kind   : Cmd_Kind,
    device : string,   // "local" or the VERBATIM ssh target
    name   : string,   // session name
    value  : string,   // theme name / error message
}

no_cmd   :: proc() -> Command { return Command{ kind = .none } }
launch   :: proc(d, n: string) -> Command { return Command{ kind = .launch_local, device = d, name = n } }
attach_c :: proc(d, n: string) -> Command { return Command{ kind = .attach, device = d, name = n } }
quit_cmd :: proc() -> Command { return Command{ kind = .quit } }
```

**Why this beats the union here:**
- The zero value is an **explicit, matchable `.none`** (`z.kind == .none` → `true`).
- Exhaustiveness checking still works (`switch c.kind { case .none: … }`).
- Trivially assertable in tests: `cmd.kind == .attach and cmd.device == "127.0.0.1"`.
- No pattern-matching syntax pitfalls anywhere near the hot path.
- Still satisfies the plan's requirement that the state machine be **side-effect-free and return a Command**.
  The `union` was a sketch, not a requirement.

---

## The union traps, documented so nobody re-derives them

Verified in dev-2026-09:

1. **Named-variant syntax with a colon is a syntax error.**
   ```odin
   Command :: union { None, LaunchLocal : LaunchSpec }   // ✗ Expected '}', got ':'
   ```
2. **A union CAN be declared as a bare type list** — `union { None, Quit, Spec }` — constructed with
   `Command{}`, `Command(Quit{})`, `Command(Spec{…})`, and matched with `switch v in c { case T: … }`.
3. **🚨 THE SILENT TRAP: the zero value of a union is a NULL union with NO variant.**
   ```odin
   z := U{}                    // U = union { None, Quit, Spec }
   switch v in z {
   case None: …                // ✗ DOES NOT FIRE
   case:    …                  // ✓ the zero value falls to DEFAULT
   }
   ```
   So a `Command{}` meaning "no command" would **silently miss** `case None:` and fall through.
   In a state machine that is a bug that only shows up at runtime, in the default path.
4. **A type-switch without a binding is rejected as ambiguous**:
   `switch u { case None: … }` → *"'None' is not an expression but a type, in this context it is ambiguous"*.
5. `switch` over a union **without a `case:`** reports unhandled cases — but that does **not** protect
   against trap #3, since the default case *is* how the null value is handled.

---

## Other verified-in-passing facts

- **`odin run x.odin` needs `-file`**: `odin run p.odin -file`. Without it: *"takes a package/directory as
  its first argument"*.
- **`import "core:intrinsics"` is deprecated** → `base:intrinsics`.
- Odin binary in the store for ad-hoc probes: `/nix/store/4p3p3dbyygl9xj2j4rspdz7j0hw65s5c-odin-dev-2026-07a/bin/odin`
  (reports `odin version dev-2026-09`).

---

## Process note for the remaining phases

The previous Phase 5b run consumed **~12 hours and produced no files**, spending its time in
`/tmp/probe7`, `probe8`, etc. probing the union semantics above. That is why:
- **This phase is being split in two** (state machine first, executor + poll loop second), and
- **The blocking semantic question is answered up front, with compiling code.**

If a syntax question turns into more than ~3 throwaway probes, **stop and record the finding** rather than
continuing to iterate silently.

---

# T6 additions — `encoding/json`, permissions, and the traps that cost real time

All of these were paid for during T6.1/T6.2 on **odin dev-2026-09**, against the
**current** `core:encoding/json` (whose API is *not* the older
`json.parse_bytes` + `json.to_object` shape some notes assume).

## `encoding/json` in this build

- `Value` is a **union**: `Null | Integer(i64) | Float(f64) | Boolean | String |
  Array | Object`, with `Object :: distinct map[string]Value` and
  `Array :: distinct [dynamic]Value`. There is **no** `json.to_object`,
  `json.to_string`, `json.object_get` or `json.new_string_value` — use type
  assertions (`v.(json.Object)`), indexing (`o["theme"]`), and constructors
  (`json.String("x")`, `json.Array(dv)`).
- `parse_bytes(data, spec, parse_integers)` returns a **`json.Error` enum**, not
  a union: test `err != json.Error.None`. The enum name renders readably through
  `%v` (`Expected_Colon_After_Key`), which is good enough for a user-facing
  warning line.
- `DEFAULT_SPECIFICATION` is **JSON5**: `// comments`, `/* comments */` and a
  trailing comma all load. Asserted rather than assumed.
- `marshal` options that matter here: `pretty`, `use_spaces`, `spaces`,
  `sort_maps_by_key` — sorted + pretty is what makes a hand-edited config
  diffable.
- Passing `parse_integers=false` means `5` round-trips as
  `5.0000000000000000`. We pass `true`.

## Three bugs that produced no error message

1. **`json.Object{}` is a NIL map.** `doc_set_string` into it *succeeded* and
   wrote `{}`. A first-run theme change vanished silently. `make(json.Object)`
   is mandatory.
2. **`cast(map[string]json.Value)obj^` writes into a detached copy.** Compiles,
   runs, `len` never grows, key never reaches the document — the same `{}`
   symptom via a different cause. `obj^[key] = v` is the form that mutates.
   (Both were found by asserting on the *file contents* rather than the return
   code. The return code was `true` for both broken versions.)
3. **A directory created without `+x` cannot have files created inside it.**
   `Permissions_Read_All + Permissions_Write_All` made every save fail with
   `permission denied` **on a directory we had just created ourselves**.
   `CONFIG_DIR_MODE = Read_All + Write_All + Execute_All`.

## Language / stdlib

- **Procedure literals capture nothing.** The natural
  `restore := proc() { …saved_var… }` for a temp-env helper does not compile
  against the caller's locals. Return a struct (`Cfg_Saved`) and restore with
  an explicit `end_cfg_home(&saved)`.
- **`fmt` has no `{x}` hex verb.** `{x}` / `{x:06x}` render
  `%!(MISSING CLOSE BRACE)}`. Use `%x`, `%06x`, `%08x` — and do not mix `{}`
  and `%` verbs in one format string (the existing arg-scrambling trap).
- **`os.get_env` is an overload group** (`get_env_alloc` / `get_env_buf`); for
  the found-flag use `os.lookup_env(key, alloc)`. **`os.getpid` does not
  exist** → `posix.getpid`.
- **`mem.free(ptr, allocator)`**, not `(allocator, ptr)`; for a slice use
  `mem.free_bytes(bytes, allocator)`.
- **Odins struct fields still need the comma BEFORE a trailing line comment**
  (`name : string, // note`) — a field followed only by a newline-terminated
  comment parses as an expression and reports *"Expected a comma, got a
  newline"*.
- **Shadowing is a hard build error** in this project's nix flags, including
  reusing `ok`/`s` across an `else if` chain.
- **Directory listing** is `os.read_directory(f: ^File, n, alloc) ->
  ([]File_Info, Error)`; there is no `os.directory_entries`.

## Test-design notes worth carrying forward

- **An unprivileged box cannot construct "file exists but is unreadable".**
  The chmod that makes `open` refuse also makes `os.is_file` return false —
  which is the *missing* branch. Report which branch ran rather than faking the
  unreachable one with root.
- **Assert on the artifact, not the return value.** Every one of the three
  silent bugs above returned `true`. The file's bytes are the ground truth.
- **Config-touching tests must own their `XDG_CONFIG_HOME`.** `os.user_config_dir`
  is the real resolver, so a temp `XDG_CONFIG_HOME` is what keeps the
  developer's `~/.config` out of it — fingerprint it before and after and
  assert equality.
- **The picker's `Enter` on `sel == -1` is a no-op by design**, so a filter
  that hides the currently-applied theme leaves nothing to apply. Drive Down
  then Enter when testing "apply the other one".
