package unit

// ─────────────────────────────────────────────────────────────────────────────
// app_fmt_test.odin — T10 port of the three `assert_formatted` calls that ran
// over `$BIN app-unit`, `$BIN app-live` and `$BIN fetch-unit` in the old
// driver (dev/app-smoke.sh).
//
// WHY IT RENDERS INSTEAD OF SCANNING THE LIVE LOG
//
// The old guard shelled out to the section driver and scanned its whole log.
// Under `core:testing` the sections are individual tests and the runner
// SHUFFLES them (ODIN_TEST_RANDOM_SEED), so a guard that scans "everything
// so far" can pass simply by running early — an assertion that cannot fail,
// which is worse than no assertion.
//
// So each guard re-runs its OWN group's sections in render mode: t is nil,
// nothing is tallied, and the detail strings land in a builder the guard then
// scans. Same text, produced by the same code that produces it on the live
// path, deterministic regardless of test order.
//
// THREE GUARDS BECAUSE THE THREE LOGS FAIL DIFFERENTLY
//   · app-unit  — tprintf meeting the model's optional types
//   · app-live  — tprintf meeting raw subprocess stdout/stderr
//   · fetch     — tprintf meeting the parsed JSON envelope
// A single guard over all of it would report "something" and nothing else.
//
// The battery lists below are mechanically complete: every section proc in the
// group is invoked, so adding a section without adding it here leaves the new
// section unguarded but the omission visible in the count.
// ─────────────────────────────────────────────────────────────────────────────

import "core:testing"

import support "../support"

@(test)
afu_app_unit_transcript_is_formatted :: proc(t: ^testing.T) {
	au_guard(t, "app-unit", proc(c: ^AU_Ctx) {
	app_argv_battery_app_argv_launch_and_attach(c)
	app_argv_battery_app_argv_control_commands_are_json(c)
	app_argv_battery_app_argv_ssh_fetch_uses_the_same_device_string(c)
	app_argv_battery_app_argv_invalid_name_builds_nothing(c)
	app_argv_battery_app_argv_delete_precheck_refuses_without_spawning(c)
	app_argv_battery_app_p1_remote_cleanup_wraps_ssh_with_the_rows_device(c)
	app_argv_battery_app_p1_local_cleanup_is_bare_herdr(c)
	app_argv_battery_app_p1_remote_cleanup_is_not_the_bare_local_argv(c)
	app_argv_battery_app_p1_numeric_device_and_labels(c)
	app_cleanup_battery_app_cleanup_default_policy(c)
	app_cleanup_battery_app_cleanup_should_run_table(c)
	app_cleanup_battery_app_cleanup_policy_seam_is_reversible(c)
	app_diag_trunc_battery_app_diag_trunc_first_line_only(c)
	app_diag_trunc_battery_app_diag_trunc_cap_is_marked_not_silent(c)
	app_diag_trunc_battery_app_diag_trunc_never_splits_a_rune(c)
	app_diag_trunc_battery_app_diag_trunc_no_width_breaks_utf8(c)
	app_diag_trunc_battery_app_diag_trunc_empty_stays_empty(c)
	app_env_battery_app_scrub_live_env_has_no_herdr_keys(c)
	app_env_battery_app_scrub_synthetic_namespace_boundary(c)
	app_exit_battery_app_exit_code_table(c)
	app_exit_battery_app_exit_panic_is_never_an_envelope(c)
	app_exit_battery_app_exit_codes_map_to_distinct_meanings(c)
	app_exit_battery_app_tty_herdr_0_8_2_panic_path(c)
	app_exit_battery_app_tty_herdr_0_9_5_message_path(c)
	app_exit_battery_app_tty_exit_one_with_envelope_stays_herdr_error(c)
	app_exit_battery_app_tty_other_exit_one_shapes(c)
	app_exit_battery_app_tty_unknown_and_distinct_kinds(c)
	app_failure_shapes_battery_app_missing_herdr_each_shape_maps_to_a_status(c)
	app_failure_shapes_battery_app_missing_herdr_never_says_answered_when_nothing_spawned(c)
	app_failure_shapes_battery_app_control_budget_is_derived_from_ssh_not_from_a_literal(c)
	app_failure_shapes_battery_app_control_budget_worst_case_is_bounded(c)
	app_failure_shapes_battery_app_p24_stopped_session_is_attachable(c)
	app_failure_shapes_battery_app_p24_unknown_name_still_fails_closed(c)
	app_failure_shapes_battery_app_p24_refresh_predicate_is_narrow(c)
	app_gate_battery_app_gate_shape_not_exit_code(c)
	app_gate_battery_app_gate_accepts_only_the_registry_shape(c)
	app_gate_battery_app_gate_registry_entries_parse_verbatim(c)
	app_gate_battery_app_gate_registry_plus_config_merges(c)
	app_gate_battery_app_gate_fallback_when_registry_absent(c)
	app_gate_battery_app_gate_empty_registry_does_not_suppress_config(c)
	app_gate_battery_app_gate_o13_bare_array_registry(c)
	app_gate_battery_app_gate_bare_array_with_entries_merges(c)
	app_gate_battery_app_gate_disabled_and_empty_set(c)
	app_gate_battery_app_gate_table_groups_local_first(c)
	app_identity_battery_app_identity_pair_not_name(c)
	app_identity_battery_app_identity_key_accessors(c)
	app_identity_battery_app_identity_sort_groups_are_contiguous(c)
	app_identity_battery_app_identity_names_for_device_is_scoped(c)
	app_inject_battery_app_inject_leading_dash_device_is_refused(c)
	app_inject_battery_app_inject_class_does_not_swallow_legal_targets(c)
	app_inject_battery_app_inject_discovery_drops_the_option_shaped_remote(c)
	app_inject_battery_app_inject_config_parser_warns_rather_than_skipping(c)
	app_inject_battery_app_inject_argv_terminator_holds_with_validation_bypassed(c)
	app_inject_battery_app_inject_terminator_is_structural(c)
	app_names_battery_app_names_charset_table(c)
	app_names_battery_app_names_length_boundary(c)
	app_parse_battery_app_parse_real_payload(c)
	app_parse_battery_app_parse_default_flag_not_default_name(c)
	app_parse_battery_app_parse_bad_payloads_degrade(c)
	app_parse_battery_app_parse_unknown_fields_are_ignored(c)
	app_ts_battery_app_ts_parses_from_the_name(c)
	app_ts_battery_app_ts_rejects_near_misses(c)
	app_ts_battery_app_ts_sorts_ascending_unknown_last(c)
	app_ts_battery_app_ts_new_session_name_generates_parseably(c)
	app_ts_battery_app_ts_generated_names_never_collide(c)
	})
}

@(test)
afu_app_live_transcript_is_formatted :: proc(t: ^testing.T) {
	au_guard(t, "app-live", proc(c: ^AU_Ctx) {
	app_orphan_battery_aor_scrub_is_load_bearing_nesting_differential(c)
	app_orphan_battery_aor_baseline_is_read_live_by_prefix(c)
	app_orphan_battery_aor_no_terminal_launch_is_a_verdict_not_an_error(c)
	app_orphan_battery_aor_guards_refuse_and_fork_nothing(c)
	app_orphan_battery_aor_run_leaves_no_scratch_behind(c)
	app_spawn_battery_alu_child_sees_no_herdr_namespace(c)
	app_spawn_battery_alu_streams_stay_split(c)
	app_spawn_battery_alu_real_exit_codes_contract(c)
	app_spawn_battery_alu_unspawnable_and_ssh_failure(c)
	app_spawn_battery_alu_herdr_delete_lies_our_model_refuses(c)
	app_spawn_battery_alu_machine_gate_probe_agrees_with_its_payload(c)
	app_spawn_battery_alu_o13_real_registry_never_drops_the_configured_remote(c)
	app_spawn_battery_alu_our_timeout_kills_and_reaps(c)
	})
}

@(test)
afu_fetch_unit_transcript_is_formatted :: proc(t: ^testing.T) {
	au_guard(t, "fetch-unit", proc(c: ^AU_Ctx) {
	app_fetch_identity_battery_afu_merge_identity_is_the_pair(c)
	app_fetch_identity_battery_afu_merge_isolation_refreshing_a_leaves_b(c)
	app_fetch_identity_battery_afu_merge_reinsert_keeps_identity(c)
	app_fetch_identity_battery_afu_merge_order_local_first_then_device_then_ts(c)
	app_fetch_identity_battery_afu_selection_tracks_identity_not_index(c)
	app_fetch_status_battery_afu_ssh_failure_status_reads_ssh_own_words(c)
	app_fetch_status_battery_afu_device_status_labels_are_all_distinct(c)
	app_fetch_status_battery_afu_outcome_kind_maps_to_status(c)
	app_fetch_status_battery_afu_failed_fetch_degrades_only_its_own_host(c)
	app_fetch_status_battery_afu_registry_lifecycle_local_standins(c)
	app_fetch_status_battery_afu_reap_debt_is_repaid_by_the_real_reaper(c)
	app_fetch_status_battery_afu_deadline_ordering_ssh_bound_is_the_first_line(c)
	app_fetch_status_battery_afu_fetch_argv_is_the_mandatory_ssh_form(c)
	})
}
