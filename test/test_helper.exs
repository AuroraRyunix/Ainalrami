# javafo.jar is a third-party binary not vendored into this repo (see
# OpenPair.Test.Javafo's moduledoc) — anywhere it isn't present (a fresh
# checkout without the sibling openpairings project, CI), the
# javafo-comparison tests are excluded rather than failing outright.
javafo_present? = OpenPair.Test.Javafo.available?()

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

ExUnit.start(exclude: exclude_tags)
