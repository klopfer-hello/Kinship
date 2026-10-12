# Kinship

A guild companion for **WoW Forever** that rewards everything that makes a guild a
guild, not just raid loot. Think DKP with a much wider scope.

> **Status: early alpha.** The points system is not built yet. This version contains
> the foundation (messaging between players, logging, diagnostics) and a test that
> measures how addon messages behave on the Forever servers. Testers are very welcome.

## What Kinship will do

- **Deeds are recorded automatically**: boss kills, dungeon clears, time and XP earned
  together with guildies, mentoring lower-level guildies, sharing crafted items
  (trade, mail, guild bank), enchanting, resurrections, raid attendance and being on
  time, kudos, recruiting, guild events.
- **Two currencies**: *Renown* is your lifetime standing in the guild (never spent,
  drives ranks and leaderboards). *Marks* are spent on loot.
- **Loot by buy-in rolls**: pay Marks to join the main-spec roll (off-spec costs half);
  prices are fixed when the raid starts.
- **Fair economy**: weekly caps, diminishing returns for repeating the same thing with
  the same people, a bonus for playing with guildies you rarely group with, a small
  weekly decay on Marks.
- **Encourages playing together**: weekly guild goals, streaks, leaderboards, shout-outs.
- **No website, no external app**: guild members' clients sync with each other
  directly, with as few messages as possible.
- **Works for any guild**: the guild leader sets the rules in game.

## Install

1. Download the repository (**Code → Download ZIP**) or a release.
2. Put the folder into `World of Warcraft\_classic_beta_\Interface\AddOns\` and make
   sure it is named exactly `Kinship` (rename `Kinship-main` if needed).
3. Start the game and enable *Kinship* in the AddOns list.

## Commands

| Command | What it does |
|---|---|
| `/kin` | Status |
| `/kin test` | Runs all measurements automatically (5–10 min), then shows a summary |
| `/kin report [name]` | Without a name: copy a diagnostic report. With a name: send it to that player in game |
| `/kin log` | Shows the log |

## Helping with tests

1. Run `/kin test` and keep playing normally until the summary line (■) appears.
2. If you are in a guild or group with other Kinship users, the test finds them and
   also measures messages between you. Their client answers automatically; they
   don't need to do anything.
3. Type `/reload` and send the report to the developer: `/kin report <name>`, or
   paste the text from `/kin report`.

A report contains Kinship's own log: addon version, game build, character and guild
names, and the test results. It never contains chat messages typed by players.

## License

MIT, see [LICENSE](LICENSE).
