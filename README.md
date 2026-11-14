# everlights

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/everlights-dark.png">
    <img src="assets/everlights-light.png" alt="EverLights" width="300">
  </picture>
</p>

A Ruby client and CLI for the EverLights v3 Smart Lights Bridge, with no dependencies outside Ruby's standard library. Bridge firmware B5010 and later only take commands through the EverLights cloud, so it signs in with your EverLights app account. On older firmware it can talk to the bridge directly on your local network, with no account.

Use it to show colors now, manage saved sequences, and put shows on the calendar weeks or months ahead. The bridge stores scheduled shows itself, so they run with no computer on.

> Unofficial. Not affiliated with or endorsed by EverLights. The EverLights name and logo belong to their owner.

## Install

```sh
gem install everlights
everlights login you@example.com      # your EverLights app account; asks for the password
```

`login` saves a login token in `~/.config/everlights/cloud.json` (readable only by you, and never your password), then sends commands to your bridge through the EverLights cloud. It picks the account's first bridge; `--bridge SERIAL` picks another. The password can also come from a pipe, for example from 1Password: `op read "op://Private/EverLights/password" | everlights login you@example.com`. `everlights logout` forgets the token.

On firmware older than B5010 you can skip the login and use the local API: `export EVERLIGHTS_HOST=192.168.1.50` (your bridge's IP, from the EverLights app → device information). Once you're logged in, `--host` still selects the local API for a single command.

Requires Ruby 3.1+.

## CLI

```sh
everlights login you@example.com                   # once; then everything goes through the cloud
everlights bridge                                  # firmware, network, cloud, zone health
everlights bridge health                           # ok/WARN checks; exits 2 on any warning
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
- **Gradients:** anywhere a color goes, `FF7A1E..FF9E3D:4` is 4 colors blended evenly from the first to the last. Middle stops bend it: `FF0000..FFFFFF..0000FF:9`. In the web editor, ↔ blends the colors between a sequence's first and last.
- **Effects:** `bars blink chase fade gradient lightning melt pingPong random reverseChase strobe twinkle wipe`, each with a strength from 0 to 255.
- **JSON:** add `--json` to list commands and `bridge`.
- **Now commands** (`set`, `play`, `off`): during a running show they only last until its next sequence change.
- **Bridge upkeep:** `everlights bridge time [TIME]` sets the clock (default now; the bridge normally syncs via NTP). `everlights bridge reboot --yes` restarts it.

## Sync: your year of shows from one file

Describe your own sequences and a schedule once. `everlights sync` then builds them on the bridge for the months ahead:

```sh
everlights init                                          # writes config/everlights.yml: US holidays, a birthday, a season
everlights sync --dry-run                                # print the plan
everlights sync                                          # apply it
everlights export                                        # what the app made, as config YAML to adopt
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
  - `ics:` takes a calendar feed (an `https://` or `webcal://` URL, or a file), and the show plays on each event's day: a team's games, school events, a shared family calendar. `match: Bobcats` keeps only events whose title contains it. Cancelled events are skipped. A recurring event counts once, on its first date, and a multi-day event on its first day. The feed is read each time sync plans.
- **Times:** `start:` is `dusk`, `dusk+15` or `"18:30"`; `end:` defaults to `"23:00"`. An end earlier than the start means the next morning.
- **Future only:** sync adds only nights that start more than 15 minutes from now. Each rule becomes one calendar entry, and re-running sync rolls the window forward.
- **Leaves your app-made shows alone:** sync only changes or deletes what it created, tracked in `config/.sync-state.yml`. It skips nights an app-made show already covers, and refuses names that clash with built-ins or app-made items. If the state file is lost, `--adopt` takes back items whose names match the config. To bring shows and sequences made in the app under the config, `everlights export` prints them as config YAML: add it to the file, then `sync --adopt`.
- **All or nothing:** every config problem is reported before anything is written.
- **Config location:** `--config` or `$EVERLIGHTS_CONFIG`. The config's `bridge.host` is used by every command unless `--host` or `$EVERLIGHTS_HOST` is set.
- **Time zone:** set `timezone:` in the config, or it uses your machine's.

### In a browser

```sh
everlights web               # http://localhost:4567 (--port to change)
```

The **Calendar** view shows each night ahead as a bulb on a light string, lit with the sequence that plays. Drag rules to set their priority. Drag sequences onto rules, or between them. Rule changes are saved to the config file straight away.

Hover any sequence chip to open its card. For your own sequences you can edit colors and effects there, then **Save** or **Revert**. Built-ins and app-made sequences can be previewed or copied into yours. The **Sequences** view has the same editor for all of your sequences. The **Bridge** view shows health checks (the same as `bridge health`), firmware, network, reboots, and each zone's signal and sensors. It has buttons to set the clock and to reboot; reboot asks you to click twice. **Apply** sends the pending changes to the bridge.

**Preview** (on a sequence, or click a bridge sequence) shows it on the lights now, and edits to it show as you make them. **Stop preview** hands the lights back to the calendar. So does closing the page: the preview is cleared about 20 seconds after the page stops checking in, and also when the server quits. During a running show, a preview only lasts until the show's next sequence change.

The page only listens on localhost. Saving rewrites the YAML, which drops your comments; the first save keeps the original at `everlights.yml.bak`, and that copy is never replaced. If you edit the file by hand while the page is open, the page reloads it instead of overwriting it.

To keep the calendar topped up, run it on a schedule, for example monthly from cron:
`0 9 1 * * cd ~/everlights && everlights sync >> config/sync.log 2>&1`

To only be told when it needs a sync, use `everlights sync --check`. It prints the plan and changes nothing. It exits 0 when the bridge matches the config, 2 when it needs a sync, and 1 on an error.

## Ruby

```ruby
require "everlights"

el = Everlights::Client.new(cloud: Everlights::Cloud.new)   # after `everlights login`; or Everlights::Cloud.login(email, password)
el = Everlights::Client.new("192.168.1.50")                   # local API, firmware before B5010; or ENV["EVERLIGHTS_HOST"]

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

**Firmware B5010 (October 2026) turned off local control.** The bridge updates itself, and on B5010 every endpoint except `GET /v1` answers `410 {"error":"gone","cloud":true}`. Without a login, commands stop with a message saying so, and `bridge health` warns.

The cloud serves the same API through a tunnel, which is how the EverLights app reaches the bridge now:

| | |
|---|---|
| `POST https://appserver-v2.myeverlights.com/v1/oauth/token` | sign in: `{grant_type: "password", username, password}`, or `refresh_token`. The refresh token changes each time it's used |
| `GET …/v1/bridges` | the account's bridges |
| `GET …/v1/bridges/{serial}/remotetoken` | a token for that bridge's tunnel |
| `https://remote.myeverlights.com/bridges/{serial}/proxy/v1/…` | the bridge API above, with `Authorization: Bearer <tunnel token>` |

Writes through the tunnel go out at least 0.25 seconds apart, because the bridge misbehaves when they stack up. B5010 also stopped reporting network and memory in its status, so `bridge health` shows those as info. The cloud is the app's private API: EverLights could change it at any time.

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

To release, bump the version in `everlights.gemspec`, commit, then tag and push (`git tag v1.0.0 && git push origin v1.0.0`). The release workflow tests, then publishes to RubyGems and GitHub Packages and creates a GitHub release with the `.gem` attached.

## Credits

The protocol work builds on [weswitt/everlights3](https://github.com/weswitt/everlights3), whose OpenAPI spec mapped the endpoints, and [theOrakle/everlightsv3](https://github.com/theOrakle/everlightsv3), which is also the source of the logo images. [borski/everlightsv3_cloud](https://github.com/borski/everlightsv3_cloud) mapped the cloud tunnel. There is also a Home Assistant [core integration](https://www.home-assistant.io/integrations/everlights) for the older v2 bridge.

## License

MIT
