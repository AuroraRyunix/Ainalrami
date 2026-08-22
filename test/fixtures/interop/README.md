# Interop fixtures

Files written by **other implementations**, kept because nothing else in
this project reads one.

The comparison harness runs bbpPairings on every axis, but always on a TRF
that `Ainalrami.Trf.serialize/2` produced. So the whole corpus - 4.3
million tournaments - validates that the two engines agree about *pairing*
and says nothing at all about whether this one can read a file it did not
write.

It could not. See `bbppairings-generated.trf` below.

## `bbppairings-generated.trf`

209 players, five rounds played, produced by bbpPairings 6.0.0's own
generator:

```bash
bbpPairings --dutch -g -o bbppairings-generated.trf -s 42
```

Stored **byte for byte**, which `.gitattributes` enforces with
`test/fixtures/interop/** -text`. Two properties depend on that and would
be quietly destroyed by line-ending normalisation:

- **It is terminated with a bare `\r`** - 212 of them, and not a single
  `\n` in the file. `Ainalrami.Trf.parse/1` split on `~r/\r?\n/`, which
  matches neither, so the entire 29KB parsed as ONE line and returned zero
  players with no error at all. `ainalrami file.trf -p` simply answered
  with an empty pairing.
- **It carries no round count and no `152`.** bbpPairings' generator
  writes neither, which means its own pairer refuses the file it just
  produced (*"The total number of rounds in the tournament must be
  specified"*). The test supplies `XXR` rather than editing the fixture.

Once readable, it is a strong independent check: a field far larger than
the corpus usually reaches, from a different implementation, in a
different byte format. Both engines pair its sixth round identically -
**105 of 105 boards, colours included** - and `-c` replays all five
recorded rounds with every pairing reproduced.

Covered by `test/ainalrami/interop_test.exs`.
