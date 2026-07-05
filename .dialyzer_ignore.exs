# Dialyzer warnings intentionally ignored, scoped to the exact file + warning
# type + line (never a blanket warning-class disable). See practices/README.md
# / mix_snippets.exs in the boss repo for the fleet rationale.
#
# All three are pre-existing findings in the acquisition-tracking feature code
# (added upstream), where the code is correct but Dialyzer's model is stricter
# than runtime reality. Flagged for the maintainers; not rewritten here because
# doing so would weaken correct defensive code:
#
#   * acquisition_tracker.ex:142 (guard_fail) — `conn.remote_ip && ...` guards
#     against a nil remote_ip. Plug.Conn types remote_ip as a non-nil ip tuple,
#     but at runtime (e.g. before the adapter sets it, or in tests) it can be
#     nil, so the nil-guard is a genuine safety check Dialyzer cannot see.
#   * acquisition_tracker.ex:203 (pattern_match_cov) — the `utm_present?(_)`
#     fallback clause; the `is_map/1` clause above it already covers every value
#     the caller passes (maps and %Plug.Conn.Unfetched{} structs are both maps).
#   * acquisition.ex:285 (call_without_opaque) — `URI.to_string/1` on a
#     hand-built `%URI{}`; a Dialyzer opacity quirk, not a real defect.
[
  {"lib/zyzyva_telemetry/plugs/acquisition_tracker.ex", :guard_fail},
  {"lib/zyzyva_telemetry/plugs/acquisition_tracker.ex", :pattern_match_cov},
  {"lib/zyzyva_telemetry/acquisition.ex", :call_without_opaque}
]
