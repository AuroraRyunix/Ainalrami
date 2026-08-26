# C.04.6 Swiss Team Pairing System - regulation text (effective 1 February 2026)

Verbatim text, captured 2026-08-26 from
https://handbook.fide.com/chapter/SwissTeamPairingSystem202602 (HTML
stripped, whitespace normalised - wording untouched). Kept in the repo so
the implementation in `lib/ainalrami/team_pairing.ex` can cite article
numbers against a stable local copy, the same way the individual engine
cites C.04.3. If FIDE revises the page, diff against this file first.

The reading decisions the implementation makes where the text
underdetermines the algorithm are recorded in
[conformance-c0406-teams.md](conformance-c0406-teams.md).

---

TEAM PAIRING SYSTEM
Approved by the Council on 28/10/2025
Applied from 1st February, 2026
0.      Preface
The Swiss Pairing System Rules specified in the Basic Rules for Swiss Systems and in the Articles 1, 2.4, 2.5, 3 and 4 of the General Handling Rules for Swiss Tournaments are for individuals, but can also be applied mutatis mutandis to teams, with one significant exception: the Articles 6 and 7 of the Basic Rules for Swiss Systems never apply.
In fact, for teams, the colours are less important. This is mainly because individuals in a team can be substituted or shifted between the various boards, and because teams are often composed of an even number of players, resulting in each team having an equal number of players playing with White and Black. That is why the rules presented here display various lower-strength colour preferences than those described in the individual rules, and of different varieties, to facilitate various forms of team competitions. There may be competitions where colours have no importance at all (for instance because each individual plays one game with White and one with Black); other competitions where having a particular colour is not a decisive factor (for instance, because teams have an even number of players and all teams play in the same geographical place); and still others, where the colour is more meaningful (for instance, because the composition of the teams cannot be changed, or teams have an odd-number of players, or having a particular colour may mean a home or a road match). In any case, the colour will never be a factor so decisive as to prevent two teams from playing against each other. Therefore, there are no absolute colour preferences outlined in these regulations.
Articles 2.1-2.3 of the General Handling Rules for Swiss Tournaments, dealing with the initial order of the teams, have been deliberately omitted from the initial list shown above because there are too many variants to take into account to define an appropriate strength for teams, such as only using starters' ratings; including reserves; counting a fixed number of highest ratings; managing unrated players; and so on. In the end, it is preferable to leave any details out of the general rules and let the initial order of teams be determined by the rules of each specific competition.
1.      Introductory Remarks and Definitions
1.1     Tournament Pairing Number ("TPN")
1.1.1      Each team must have a different TPN, from 1 to the TPN corresponding to the number of teams.
1.1.2      The rules of the team competition shall describe how to assign a TPN to each team. Otherwise, it is a decision of the Chief Arbiter.
Note:   This provision overrides Articles 2.1 to 2.3 of the General Handling Rules for Swiss Tournaments.
1.1.3      Once defined, the TPN should not be modified (except as stated in Articles 2.4 and 2.5 of the General Handling Rules for Swiss Tournaments) , unless the Chief Arbiter decides otherwise.
1.2     Score
1.2.1      The rules of the competition shall state which, between "match points" and "game points", is called "primary score" (or, more simply, "score"), and whether the other ("secondary score") is used for colour allocation (see Article 4.2.2).
1.2.2      The default is to use "match points" as the (primary) score and "game points" for colour allocation.
1.3     Scoregroups and Pairing Brackets
1.3.1      A scoregroup is composed of all the teams with the same score.
1.3.2      A (pairing) bracket is an even numbered group of teams all to be paired. It is composed of teams coming from the same scoregroup (called resident teams) and (possibly) of teams coming from lower scoregroups (called upfloaters).
1.4     Pairing-Allocated-Bye (PAB)
Should the number of teams to be paired be odd, one team is not paired. This team receives a pairing-allocated-bye: no opponent, no colour, and as many match points and game points as are rewarded for a draw, unless the regulations of the team competition state otherwise. These numbers of points shall be the same for all pairing-allocated byes (See Article 3 of the Basic Rules for Swiss Systems) .
1.5     Floaters
A floater is a team that plays against an opponent with a different score.
1.6     Colour Difference (CD)
1.6.1      A team is said to have (had) a colour (White or Black) in a match if the match was actually played and the player on the first board was scheduled to play with that colour.
1.6.2      The colour difference of a team is the number of matches where the team had White minus the number of matches where the team had Black.
1.7     Colour Preference
Type A colour preferences are used unless the rules of the team competition specify that either Type B colour preferences shall be used, or colour preferences are not to be used at all.
1.7.1      Type A colour preferences
A team has a simple (Type A) colour preference for White if its CD is less than -1, or, being its CD 0 or -1, the team had Black in the last two played matches.
A team has a simple (Type A) colour preference for Black if its CD is more than +1, or, being its CD 0 or +1, the team had White in the last two played matches.
In all other situations, the team has no (Type A) colour preference.
1.7.2      Type B colour preferences
A team has a strong (Type B) colour preference for White if its CD is less than -1, or, being its CD 0 or -1, the team had Black in the last two played matches.
A team has a strong (Type B) colour preference for Black if its CD is more than +1, or, being its CD 0 or +1, the team had White in the last two played matches.
A team has a mild (Type B) colour preference for White if its CD is -1, or, if it is zero and it is not the last round, the team had Black in the last played match.
A team has a mild (Type B) colour preference for Black if its CD is +1, or, if it is zero and it is not the last round, the team had White in the last played match.
A team has no (Type B) colour preference when it has yet to play a match, or when its CD is zero when pairing for the last round.
2.      Pairing Criteria
2.1     Absolute Criteria
No pairing shall violate the following absolute criteria:
2.1.1      [C1] See the Basic Rules for Swiss, Article 2 (Two participants shall not play against each other more than once) .
2.1.2      [C2] A team that has already received a pairing-allocated bye or won a match by forfeit (or been given a FIDE-deprecated full-point bye) shall not receive the pairing-allocated bye.
2.2     Completion Criterion
2.2.1      [C3] A pairing complying with all the absolute criteria (see Article 2.1) shall always exist for all teams not yet paired.
2.3     Quality Criteria
In order to best pair all teams of the top-scoregroup (see Article 3.2), comply as much as possible with the following criteria, given in descending priority:
2.3.1      [C4] Minimise the number of upfloaters.
2.3.2      [C5] Minimise the score differences (taken in descending order) in the pairs involving upfloaters, i.e. maximise the scores (taken in ascending order) of the upfloaters.
2.3.3      [C6] Unless all the teams in the following scoregroup became or are upfloaters (thus this scoregroup is now empty), choose the set of upfloaters so that criteria [C1], [C3] and [C4] (see Articles 2.1.1, 2.2.1 and 2.3.1) are complied with in the bracket where this (not empty) scoregroup is paired.
Note:    Only the mentioned scoregroup is involved, even though some of the upfloaters come from lower scoregroups.
2.3.4      [C7] With the exception of the last two rounds, minimise the number of upfloaters that were floaters in the previous round (see Article 1.5).
2.3.5      [C8] Minimise the number of teams whose colour preference, if any, is not fulfilled.
2.3.6      [C9] (Type B only) Minimise the number of teams whose strong colour preference, if any, is not fulfilled.
2.3.7      [C10] With the exception of the last two rounds, minimise the number of upfloaters' opponents that were floaters in the previous round (see Article 1.5).
3.      Pairing Definitions and Rules
3.1     Legal Pairing
3.1.1      A pairing is legal when the absolute criteria [C1] and [C2] (see Article 2.1) are complied with.
3.1.2      During the pairing, the completion criterion [C.3] (see Article 2.2) is also to be complied with.
3.2     Top-Scoregroup
During the pairing, it is the group of one or more teams that have the highest score among the teams that are yet to be paired.
3.3     Round-Pairing Outlook
3.3.1      The pairing of a round (called round-pairing) is complete if all the teams (except at most one, which receives the pairing-allocated bye) have been paired and the absolute criteria [C1] and [C2] (see Article 2.1) have been complied with.
3.3.2      The pairing process consists of the following steps:
The first step in the pairing process is the assignment of the pairing-allocated-bye (if needed) by applying Article 3.4.
Then, the top-scoregroup is combined, when needed, with a set of upfloaters (selected according to Article 3.5), to form a bracket that is paired according to Article 3.6.
The previous step-2 is then repeated until the round-pairing is complete.
Colours are then assigned according to Article 4.
3.3.3      If it is impossible to complete a round-pairing, the Chief Arbiter shall decide what to do.
3.4     Pairing-Allocated-Bye Assignment
The pairing-allocated-bye is assigned to the team that:
3.4.1      leaves a legal pairing for all teams
3.4.2      has the lowest score
3.4.3      has played the highest number of matches
3.4.4      has the largest TPN
3.5     Selection of Upfloaters for the Top-Scoregroup
3.5.1      All teams with a lower score than the resident teams of the top-scoregroup are potential upfloaters.
3.5.2      Consider all sets of potential upfloaters that comply with [C4] and [C5] (see Articles 2.3.1 and 2.3.2).
Note:   This somehow determines the number of upfloaters in the set and their scores.
3.5.3      In each set, the potential upfloaters, identified by their TPN, are first sorted by descending score and then, when scores are equal, by ascending TPN.
3.5.4      These sets are then sorted among themselves by the lexicographic order of their TPNs.
Example:   L et's assume that 2,6,8 have 3 points, and 1,3,5 have 2.5 points. [C4] determines that a set of three upfloaters is needed, and [C5] determines that two upfloaters must have 3 points and the other 2.5 points. The possible set of upfloaters are: {2,6,1} < {2,6,3} < {2,6,5} < {2,8,1} < {2,8,3} < {2,8,5} < {6,8,1} < {6,8,3} < {6,8,5}, already sorted in the proper order.
3.5.5      Choose the first set that, together with the top-scoregroup, produces a legal pairing that also complies with criteria [C6] and [C7] (see Articles 2.3.3 and 2.3.4) - besides [C4] and [C5] (see Articles 2.3.1 and 2.3.2), which it complies with by construction.
3.6     Pairing of a Bracket
3.6.1      A pairing is a sequence of pairs that includes all teams in the bracket. For each pair, the team with the smaller TPN is the top member of the pair; the team with the larger TPN is the bottom member of the pair.
3.6.2      A pairing is identified by the TPNs of the top members of each pair sorted in ascending order, followed by the TPNs of the bottom member of the corresponding pair.
Example:    If  11-24  16-6  10-9  8-4 is a pairing, its identifier is 4 6 9 11 8 16 10 24.
3.6.3      Pairings are sorted by the lexicographic order of their identifiers.
3.6.4      Choose the first pairing that also complies with criteria [C1], [C8], [C9] and [C10] (see Articles 2.1.1 and 2.3.5 to 2.3.7 - besides the other criteria, which it complies with by construction).
4.      Colour Allocation Rules
4.1     The initial-colour is the colour determined by drawing of lots before the pairing of the first round.
4.2     The first-team is the team (first that applies):
4.2.1      with the higher primary score; or
4.2.2      with the higher secondary score (unless the rules of the competition state not to use it ); or
4.2.3      with the smaller TPN.
4.3     For each pair apply (with descending priority):
4.3.1      When both teams have yet to play a match, if the first-team has an odd TPN, give it the initial-colour; otherwise, give it the opposite colour.
4.3.2      If only one team has a colour preference, grant it.
4.3.3      If the two teams have opposite colour preferences, grant them.
4.3.4      (Type B only) If only one team has a strong colour preference, grant it.
4.3.5      Give White to the team with the lower colour difference.
Note:   -2 is lower than -1; +1 is lower than +2.
4.3.6      Alternate the colours to the most recent time in which one team had White and the other Black.
Note:   Always consider Article 3.4 of the General Handling Rules for Swiss Tournaments.
4.3.7      Grant the colour preference of the first-team.
4.3.8      Alternate the colour of the first-team from its last played round.
4.3.9      Alternate the colour of the other team from its last played round.
