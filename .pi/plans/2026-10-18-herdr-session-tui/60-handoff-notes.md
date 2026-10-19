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
