# Quencher

Tracks **Rune of the Firelord douses in Molten Core** and keeps the progress per raid ID.
Quencher is a fork of [Tattler](https://github.com/MarcelineVQ/Tattler) by MarcelineVQ, reduced to the Molten Core douse feature and extended with SQLite history and a progress command.

## Features

- Announces every douse to raid chat, e.g. `[Name] has doused a Rune of the Firelord 3/7`.
- Progress is tied to your Molten Core **raid ID** (saved-instance lockout) and resets automatically when the lockout changes or expires.
- Progress is saved in two places:
  - **WTF** (SavedVariables, as in Tattler): the current raid ID and douse count.
  - **SQLite** (via HearthDB): full history per raid ID, including who doused and when.
- Old raids are removed from the database automatically (14 days by default).
- Check progress at any time with a slash command or a raid chat message.

## Requirements

| Requirement | Needed for |
|---|---|
| Turtle WoW / 1.12 client | Required |
| [SuperWoW](https://github.com/balakethelock/SuperWoW) | Required (cast events); the addon refuses to load without it |
| [HearthDB](https://github.com/copypasteonly/HearthDB) (`HearthDB.dll`) | Optional. Without it Quencher only uses the WTF file and the history features are unavailable |

## Installation

1. Copy the `Quencher` folder to `Interface/AddOns/` so you have `Interface/AddOns/Quencher/Quencher.toc` and `Quencher.lua`.
2. Make sure SuperWoW (and optionally HearthDB) is installed next to `WoW.exe`.
3. Restart the game and enable **Quencher** on the character select screen.
4. Disable the original **Tattler** if you have it, otherwise douses will be announced twice.

The database file is created automatically at `CustomData/Quencher.db` inside your WoW folder.

## Usage

Everyone in the raid who runs Quencher records douses. Only one client announces each douse (the one with the alphabetically lowest name), and the clients sync their counts with each other.

### Slash commands

`/quencher` (alias `/qn`)

| Command | What it does |
|---|---|
| `/quencher` or `/quencher status` | Shows the current progress (`n/7`) and who doused each rune, only to you |
| `/quencher say` | Posts the progress to raid chat (party chat if you are not in a raid) |
| `/quencher history` | Lists the last 10 stored raids from the database |
| `/quencher retention <days>` | Sets how many days raids are kept (default 14); without a number it shows the current value |
| `/quencher purge` | Deletes expired raids right now |
| `/quencher debug` | Toggles debug messages (SQL errors, douses seen without a lockout) |

### Chat command

Type `!douse` (or `!douses`) in raid, raid leader or raid warning chat. Quencher replies with the current progress in raid chat. It only reacts to messages **you** send yourself, so it will not spam the raid when several people use the addon.

## How raid IDs work

Quencher uses the Molten Core lockout ID shown in your saved instances. A douse is only counted when you have a Molten Core lockout; this is the same behavior as Tattler. After boss kills Quencher refreshes the raid info automatically. If all lockouts disappear, the counter is reset.

## Data and cleanup

- WTF: `WTF/Account/<account>/SavedVariables/Quencher.lua` stores `QuencherDB.douse_tracking = { id, count }` and your retention setting.
- SQLite: tables `raid` (raid ID, created, updated, count) and `douse` (raid ID, sequence number, caster, timestamp).
- On every login, raids not updated within the retention period are deleted together with their douses.

## Limitations

- The runes themselves are not distinguished: Quencher counts douses in order and remembers who did them, but not which of the seven runes it was.
- If two players douse at almost the same moment, the order can differ between clients; counts are reconciled to the highest value.
- Each player keeps their own database; the history is not shared between players.

## Troubleshooting

- *"requires SuperWoW to operate"*: SuperWoW is not loaded; check your launcher or `WoW.exe` setup.
- *Nothing is stored in SQL*: HearthDB is not loaded or could not open the database. Turn on `/quencher debug` and reload the UI.
- *Douse is not counted*: you have no Molten Core lockout yet.

## Credits and license

Based on **Tattler** by MarcelineVQ. Licensed under the **GNU LGPL v2.1**, same as the original.
