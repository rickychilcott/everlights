# everlights

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/everlights-dark.png">
    <img src="assets/everlights-light.png" alt="EverLights" width="300">
  </picture>
</p>

A Ruby client and CLI for the EverLights v3 Smart Lights Bridge. It talks to the bridge directly on your local network: no cloud, no account, and no dependencies outside Ruby's standard library.

Use it to show colors now, manage saved sequences, and put shows on the calendar weeks or months ahead. The bridge stores scheduled shows itself, so they run with no computer on.

> Unofficial. Not affiliated with or endorsed by EverLights. The EverLights name and logo belong to their owner.

## Install

```sh
gem install everlights
export EVERLIGHTS_HOST=192.168.1.50   # your bridge's IP (EverLights app → device information)
```

Requires Ruby 3.1+.

## CLI

```sh
everlights bridge                                  # firmware, network, cloud, zone health
everlights show                                    # what's playing, e.g. "Halloween Fade (Halloween show)"

everlights play "Hallows Eve"                      # a saved sequence, now
everlights set FF0000 00FF00 --effect twinkle=100  # ad-hoc colors, now
everlights off                                     # lights dark
everlights clear                                   # hand control back to the calendar

everlights sequence list fall                      # * marks sequences you created
everlights sequence add "Candy Cane" FF0000 FFFFFF --effect chase=60
everlights sequence update "Candy Cane" FF0000 00FF00 FFFFFF   # replace colors/effects
everlights sequence remove "Candy Cane"

everlights calendar list --limit 30                # upcoming shows (default 365 days)
everlights calendar add 2026-12-01 Christmas "Candy Cane:30,Christmas" --until 2027-01-01
everlights calendar add 2026-12-31 "New Year" "New Year's" --start 20:00 --end 01:00
everlights calendar remove 2026-12-24 Christmas    # one night
```

- **Calendar defaults:** a show starts at dusk and ends at 23:00. Each sequence plays for 20 seconds unless you write `name:seconds`.
- **Times** use your machine's local time zone. An end time earlier than the start means the next morning. `--until` repeats the show nightly and stays correct across DST changes.
- **Effects:** `bars blink chase fade gradient lightning melt pingPong random reverseChase strobe twinkle wipe`, each with a strength from 0 to 255.
- **JSON:** add `--json` to list commands and `bridge`.
- **Now commands** (`set`, `play`, `off`): during a running show they only last until its next sequence change.
- **Bridge upkeep:** `everlights bridge time [TIME]` sets the clock (default now; the bridge normally syncs via NTP). `everlights bridge reboot --yes` restarts it.

## Sync: your year of shows from one file

Describe your own sequences and a schedule once. `everlights sync` then builds them on the bridge for the months ahead:

```sh
cp config/everlights.example.yml config/everlights.yml   # gitignored; edit the IP, location and schedule
everlights sync --dry-run                                # print the plan
everlights sync                                          # apply it
```

```yaml
bridge: {host: 192.168.1.50}
location: {lat: 40.0, lon: -83.0}   # dusk = sunset, calculated per night
horizon_days: 120
sequences:
  My Birthday: {colors: [FF1E8C, FFC400, 00A8FF], effects: {chase: 60, twinkle: 180}}
schedule:                           # higher in the list wins a shared night
  - {name: Christmas Day, on: Dec 25, sequences: [Christmas, "Candy Cane Lane:30"], end: "01:00"}
  - {name: Christmas Season, from: Dec 1, to: Jan 1, sequences: [Christmas, Winter]}
  - {name: Thanksgiving, on: 4th Thursday of November, sequences: [Thanksgiving]}
  - {name: Easter, on: Easter, sequences: [Easter]}
  - {name: Fall Weekends, every: [Friday, Saturday], from: Sep 15, to: Nov 20, start: dusk+15, sequences: [Fall Wave]}
```

- **When a rule applies:**
  - `on:` takes a date (`2027-03-14`), a yearly date (`Dec 25`), `Nth Weekday of Month`, `last Monday of May`, or `Easter`.
  - `from:`/`to:` repeats nightly, every year, and can cross New Year.
  - `every:` takes weekdays, optionally limited by `from:`/`to:`.
- **Times:** `start:` is `dusk`, `dusk+15` or `"18:30"`; `end:` defaults to `"23:00"`. An end earlier than the start means the next morning.
- **Future only:** sync adds only nights that start more than 15 minutes from now. Each rule becomes one calendar entry, and re-running sync rolls the window forward.
- **Leaves your app-made shows alone:** sync only changes or deletes what it created, tracked in `config/.sync-state.yml`. It skips nights an app-made show already covers, and refuses names that clash with built-ins or app-made items. If the state file is lost, `--adopt` takes back items whose names match the config.
- **All or nothing:** every config problem is reported before anything is written.
- **Config location:** `--config` or `$EVERLIGHTS_CONFIG`. The config's `bridge.host` is used by every command unless `--host` or `$EVERLIGHTS_HOST` is set.
- **Time zone:** set `timezone:` in the config, or it uses your machine's.

To keep the calendar topped up, run it on a schedule, for example monthly from cron:
`0 9 1 * * cd ~/everlights && everlights sync >> config/sync.log 2>&1`

To only be told when it needs a sync, use `everlights sync --check`. It prints the plan and changes nothing. It exits 0 when the bridge matches the config, 2 when it needs a sync, and 1 on an error.

## Ruby

```ruby
require "everlights"

el = Everlights::Client.new("192.168.1.50")    # or ENV["EVERLIGHTS_HOST"]

el.play "Hallows Eve"
el.set "FF0000", "00FF00", effects: {twinkle: 100}
el.off
el.clear
el.status                      # bridge info hash; el.set_time, el.reboot
el.now_playing                 # {zone => {name:, show:, off:, pattern:, effects:}}

el.sequences.list("fall")
el.sequences.add "Candy Cane", "FF0000", "FFFFFF", effects: {chase: 60}
el.sequences.update "Candy Cane", "FF0000", "00FF00"
el.sequences.remove "Candy Cane"

el.calendar.list(limit: 30)  # => [{date:, start:, finish:, dusk:, name:, event_id:, sequences: [[name, secs]]}]
el.calendar.add "2026-12-01", "Christmas", {"Candy Cane" => 30, "Christmas" => 20}, through: "2027-01-01"
el.calendar.add "2026-12-31", "New Year", ["New Year's"], start: "20:00", finish: "01:00"
el.calendar.remove "2026-12-24", "Christmas"

config = Everlights::Sync.load_config("config/everlights.yml")
plan = Everlights::Sync.new(el, config, state_path: "config/.sync-state.yml").plan
puts plan
plan.apply!
```

`Client` also exposes the raw endpoints: `status`, `zones`, `program`, `set_program`, `sequence_list`, `create_event`, `update_event` and so on.

## AI agent skill

`skills/everlights/SKILL.md` teaches an AI agent, such as Claude Code, to drive the CLI: what to check first, confirming before any change to the lights, and recipes. To install it:

```sh
ln -s "$(pwd)/skills/everlights" ~/.claude/skills/everlights
```

## Protocol

The bridge (an ESP32) serves plain JSON over HTTP on port 80, with no authentication:

| Endpoint | |
|---|---|
| `GET /v1` | bridge status, including zones |
| `GET /v1/zones` | zones (pixel runs) |
| `GET POST DELETE /v1/zones/{serial}/sequence` | what a zone shows right now |
| `GET POST /v1/sequences`, `PUT DELETE /v1/sequences/{id}` | saved sequences |
| `GET POST /v1/events`, `PUT DELETE /v1/events/{id}` | calendar |
| `PUT /v1/time`, `GET /v1/reboot` | clock; reboot (note: a GET) |

Verified against bridge firmware B4042, radio R3052 and zone firmware N3063. Firmware updates arrive over the air from EverLights' cloud; there is no local update endpoint.

Not yet confirmed:
- What each effect's 0–255 value does.
- How the bridge handles overlapping calendar entries.
- **Dusk:** the bridge stores the 17:00 placeholder start as given; the EverLights app writes the actual dusk time. It's unclear whether the bridge honors `StartAtDusk` on its own, so a "dusk" show may start at 17:00.

Observed on the bridge (`ruby -Ilib test/live_check.rb` repeats the round trip):
- Sequence durations are seconds.
- Sequences you add are filed in the app's `Personal/` group and appear in the EverLights app under Personal.
- During a show, `set`/`play` only lasts until the show's next sequence change. `clear` briefly blanks the zone, then the show resumes.
- `GET /v1/zones/{serial}/sequence` reports what's on the lights, including what a running show is playing.

## Development

```sh
ruby -Ilib -e 'Dir["test/*_test.rb"].each { require "./#{_1}" }'
```

The tests run against a fake bridge, so no hardware is needed. CI runs them on every push and pull request.

To release, bump the version in `everlights.gemspec`, commit, then tag and push (`git tag v0.2.0 && git push origin v0.2.0`). The release workflow tests, then publishes to RubyGems and GitHub Packages and creates a GitHub release with the `.gem` attached.

## Credits

The protocol work builds on [weswitt/everlights3](https://github.com/weswitt/everlights3), whose OpenAPI spec mapped the endpoints, and [theOrakle/everlightsv3](https://github.com/theOrakle/everlightsv3), which is also the source of the logo images. There is also a Home Assistant [core integration](https://www.home-assistant.io/integrations/everlights) for the older v2 bridge.

## License

MIT
