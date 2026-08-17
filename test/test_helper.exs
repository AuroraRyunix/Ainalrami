# javafo.jar and bbpPairings.exe are third-party binaries not vendored
# into this repo (see Ainalrami.Test.Javafo's and Ainalrami.Test.Bbppairings'
# moduledocs) — anywhere one isn't present (a fresh checkout without the
# sibling openpairings project, CI), its comparison tests are excluded
# rather than failing outright.
javafo_present? = Ainalrami.Test.Javafo.available?()
bbppairings_present? = Ainalrami.Test.Bbppairings.available?()

exclude_tags =
  if javafo_present? do
    []
  else
    IO.puts(
      "Skipping JaVaFo-comparison tests: #{Ainalrami.Test.Javafo.jar_path()} not present " <>
        "(set JAVAFO_JAR to override)"
    )

    [:javafo]
  end

exclude_tags =
  if bbppairings_present? do
    exclude_tags
  else
    IO.puts(
      "Skipping bbpPairings-comparison tests: #{Ainalrami.Test.Bbppairings.exe_path()} not " <>
        "present (set BBPPAIRINGS_EXE to override)"
    )

    [:bbppairings | exclude_tags]
  end

# The failure taxonomy is a diagnostic, not a regression test: it asserts
# nothing unless told what to expect, and its job is to print a breakdown
# of wherever the engine currently disagrees with bbpPairings. Run it on
# demand with `mix test --only taxonomy`.
exclude_tags = [:taxonomy | exclude_tags]

# The three-way comparison needs Gacrux (Otto Milvang's pairingchecker.py
# from the FIDE Tie Break Server, located via GACRUX_DIR) and is ~35x the
# cost of the two-way harness, since Gacrux is a Python script at roughly
# 750ms a round. Excluded by default and run on demand with
# `mix test --only three_way`.
unless Ainalrami.Test.Gacrux.available?() do
  IO.puts(
    "Three-way comparison unavailable: #{Ainalrami.Test.Gacrux.script_path()} not present " <>
      "(set GACRUX_DIR to override)"
  )
end

exclude_tags = [:three_way | exclude_tags]

ExUnit.start(exclude: exclude_tags)
