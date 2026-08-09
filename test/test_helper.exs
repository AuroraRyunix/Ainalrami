# javafo.jar and bbpPairings.exe are third-party binaries not vendored
# into this repo (see OpenPair.Test.Javafo's and OpenPair.Test.Bbppairings'
# moduledocs) — anywhere one isn't present (a fresh checkout without the
# sibling openpairings project, CI), its comparison tests are excluded
# rather than failing outright.
javafo_present? = OpenPair.Test.Javafo.available?()
bbppairings_present? = OpenPair.Test.Bbppairings.available?()

exclude_tags =
  if javafo_present? do
    []
  else
    IO.puts(
      "Skipping JaVaFo-comparison tests: #{OpenPair.Test.Javafo.jar_path()} not present " <>
        "(set JAVAFO_JAR to override)"
    )

    [:javafo]
  end

exclude_tags =
  if bbppairings_present? do
    exclude_tags
  else
    IO.puts(
      "Skipping bbpPairings-comparison tests: #{OpenPair.Test.Bbppairings.exe_path()} not " <>
        "present (set BBPPAIRINGS_EXE to override)"
    )

    [:bbppairings | exclude_tags]
  end

# The failure taxonomy is a diagnostic, not a regression test: it asserts
# nothing unless told what to expect, and its job is to print a breakdown
# of wherever the engine currently disagrees with bbpPairings. Run it on
# demand with `mix test --only taxonomy`.
exclude_tags = [:taxonomy | exclude_tags]

ExUnit.start(exclude: exclude_tags)
