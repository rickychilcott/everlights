---
name: everlights
description: Control EverLights permanent outdoor lights through the local bridge using the `everlights` CLI. Use when the user wants to change the house lights now, design a color sequence, or schedule a light show for a date or holiday ("put up Christmas lights for December", "make the roofline orange tonight", "what's scheduled?").
---

# EverLights

The `everlights` CLI talks to the bridge on the LAN (no auth). It needs `EVERLIGHTS_HOST` (bridge IP) or `--host`. Lists print text (add `--json` for JSON); `status`, `zones` and `show` print JSON.

## Before you write anything

1. Run `everlights calendar list` and `everlights show` (names what's playing and which show it's from) first (`everlights bridge` if something seems broken). Report what's already scheduled or showing.
2. Confirm before every write: `set`, `play`, `off`, `clear`, `sequence add/update/remove`, `calendar add/remove` and `bridge time`. These change real lights on a real house, so state the exact command you'll run.
3. Only run `bridge reboot --yes` when the user explicitly asks; it interrupts the lights. The CLI refuses to remove built-in sequences, or sequences an event still uses.

## Concepts

- **Zone**: one run of pixels, identified by serial. `everlights zones` lists them. Commands default to all zones; `--zone SERIAL` narrows one.
- **Sequence**: a saved pattern of hex colors (`RRGGBB`, repeated along the run) plus up to a few effects. The bridge has about 96 built-ins (`everlights sequence list xmas` searches by name; `*` marks user-made ones). Sequences added here show up in the EverLights app under Personal. Built-in names include "Birthday", so give personal sequences distinct names (e.g. "My Birthday").
- **Effect**: `--effect TYPE=N`, N 0-255 (default 128; higher seems faster). Types: bars blink chase fade gradient lightning melt pingPong random reverseChase strobe twinkle wipe. Built-ins often stack two, e.g. `fade` + `reverseChase`.
- **Manual program** (`set`/`play`): shows immediately. During a scheduled show, it only lasts until the show's next sequence change (about 20 seconds). Outside a show it stays. `clear` hands control back to the calendar.
- **Calendar entry**: a scheduled show. It cycles its sequences (`NAME:SECONDS`, default 20) during each night's window. The bridge stores it, so it runs with no computer on. Default window: dusk to 23:00.

## Recipes

```sh
everlights play "Hallows Eve"                     # built-in sequence now
everlights set FF0000 00FF00 --effect twinkle=100 # ad-hoc colors now
everlights off                                    # dark
everlights clear                                  # back to the calendar

everlights sequence add "Candy Cane" FF0000 FF0000 FFFFFF FFFFFF --effect chase=60
everlights sequence update "Candy Cane" FF0000 00FF00 --effect chase=60
everlights sequence remove "Candy Cane"

everlights calendar list --limit 30               # next 30 days (default 365)
everlights calendar add 2026-12-01 Christmas "Candy Cane:30,Christmas" --until 2027-01-01
everlights calendar add 2026-12-31 "New Year" "New Year's" --start 20:00 --end 01:00
everlights calendar remove 2026-12-24 Christmas   # one night; removes the entry if it was the last
```

Dates and times use the machine's local time zone. An `--end` earlier than the start means the next morning. `--until` repeats nightly and stays correct across DST changes. Add `--json` to `list` commands for machine-readable output.

### Ruby (same operations)

```ruby
require "everlights"
el = Everlights::Client.new("192.168.1.50")   # or ENV["EVERLIGHTS_HOST"]
el.play "Hallows Eve"; el.set "FF0000", "00FF00", effects: {twinkle: 100}; el.clear
el.sequences.list("xmas"); el.sequences.add("Candy Cane", "FF0000", "FFFFFF", effects: {chase: 60}); el.sequences.remove("Candy Cane")
el.calendar.list(limit: 30)                    # [{date:, start:, finish:, dusk:, name:, event_id:, sequences: [[name, secs]]}]
el.calendar.add "2026-12-01", "Christmas", "Candy Cane:30,Christmas", through: "2027-01-01"  # or {"Candy Cane" => 30}
el.calendar.add "2026-12-31", "New Year", ["New Year's"], start: "20:00", finish: "01:00"
el.calendar.remove "2026-12-24", "Christmas"
```

## Sync (planning shows months ahead)

When the user wants a recurring or seasonal plan ("Christmas every December", "Fridays in football season"), edit `config/everlights.yml` rather than adding calendar entries one by one. The format reference is `config/everlights.example.yml`.

1. Edit `sequences:` or `schedule:`. Rules higher in the list win nights they share.
2. Run `everlights sync --dry-run` and show the user the plan, including the Skipped and No show sections. `everlights sync --check` is the same plan, but exits 2 when anything would change.
3. Run `everlights sync` only after they confirm.

Sync only changes what it created itself. Config problems abort before anything is written; fix every one it lists. Use `--adopt` only when the user says the state file was lost.

## Unverified
 (tell the user if it matters)

- Whether "dusk" shows really start at dusk. The bridge stores a 17:00 placeholder, so they may start at 17:00. Use `--start` when the exact time matters.
- What N means for each effect.
- Whether a calendar entry overlapping another replaces it or conflicts. Check `calendar list` afterwards.
- `calendar remove` on a night that isn't an entry's last edits the event with a PUT. The API spec has it; not yet tried on the bridge.
