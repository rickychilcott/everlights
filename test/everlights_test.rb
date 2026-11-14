require "minitest/autorun"
require "open3"
ENV["TZ"] = "America/New_York"
require_relative "../lib/everlights"

require_relative "fake_bridge"

class EverlightsTest < Minitest::Test
  SEQS = [
    {"id" => "seq-1", "alias" => "Hallows Eve", "pattern" => ["FF6800"], "effects" => [{"effectType" => "chase", "value" => 255}]},
    {"id" => "seq-2", "alias" => "Other", "pattern" => ["FFFFFF"], "effects" => []},
    {"id" => "00000000-0000-0000-0000-000000000008", "alias" => "Halloween", "pattern" => ["FF2900"], "effects" => []}
  ]
  EVENT = {"id" => "ev-1", "alias" => "Fall", "sequences" => [{"sequenceId" => "seq-1", "duration" => 20}],
           "occurrences" => [{"start" => "2026-11-01T22:00:00.000000Z", "end" => "2026-11-02T04:00:00.000000Z"},
                             {"start" => "2026-11-02T22:00:00.000000Z", "end" => "2026-11-03T04:00:00.000000Z"}],
           "flags" => [], "zoneSerials" => ["000000000000"]}

  def client(routes = {})
    @bridge = FakeBridge.new({
      "GET /v1" => {"serial" => "b1"},
      "GET /v1/zones" => [{"serial" => "z1"}, {"serial" => "z2"}],
      "GET /v1/zones/z1/sequence" => {"pattern" => ["FF0000"]},
      "GET /v1/sequences" => SEQS,
      "GET /v1/events" => [EVENT]
    }.merge(routes))
    Everlights::Client.new("127.0.0.1:#{@bridge.port}")
  end

  def last_request = @bridge.requests.last

  def test_set_program_normalizes_colors_and_effects
    el = client
    el.set_program("z1", pattern: ["#ff0000", "00ff00"], effects: {chase: 60, twinkle: nil})
    assert_equal ["POST", "/v1/zones/z1/sequence", {"colorMode" => "rgb", "pattern" => %w[FF0000 00FF00],
      "effects" => [{"effectType" => "chase", "value" => 60}, {"effectType" => "twinkle", "value" => 128}]}], last_request
    assert_raises(Everlights::Error) { el.set_program("z1", pattern: ["red"]) }
    assert_raises(Everlights::Error) { el.set_program("z1", pattern: ["FF0000"], effects: {sparkle: 1}) }
  end

  def test_calendar_add_defaults_to_dusk_and_20_seconds
    client.calendar.add(Date.new(2026, 12, 24), "Xmas Eve", ["Hallows Eve", ["Other", 45]])
    _, path, ev = last_request
    assert_equal "/v1/events", path
    assert_equal ["StartAtDusk"], ev["flags"]
    assert_equal [{"sequenceId" => "seq-1", "duration" => 20}, {"sequenceId" => "seq-2", "duration" => 45}], ev["sequences"]
    assert_equal [{"start" => "2026-12-24T22:00:00.000000Z", "end" => "2026-12-25T04:00:00.000000Z"}], ev["occurrences"]
  end

  def test_calendar_remove_one_night_puts_the_rest_and_last_night_deletes
    el = client
    el.calendar.remove("2026-11-01", "fall")
    verb, path, ev = last_request
    assert_equal ["PUT", "/v1/events/ev-1"], [verb, path]
    assert_equal [EVENT["occurrences"][1]], ev["occurrences"]
    assert_raises(Everlights::Error) { el.calendar.remove("2026-12-25", "Fall") }

    el = client("GET /v1/events" => [EVENT.merge("occurrences" => EVENT["occurrences"].take(1))])
    el.calendar.remove("2026-11-01", "Fall")
    assert_equal ["DELETE", "/v1/events/ev-1"], last_request.take(2)
  end

  def test_calendar_list_names_sequences_and_respects_limit
    shows = client.calendar.list(limit: 1, now: Time.new(2026, 11, 1, 12))
    assert_equal [[Date.new(2026, 11, 1), "Fall", [["Hallows Eve", 20]]]], shows.map { _1.values_at(:date, :name, :sequences) }
  end

  def running_event
    now = Time.now
    EVENT.merge("occurrences" => [{"start" => (now - 600).getutc.iso8601, "end" => (now + 600).getutc.iso8601}])
  end

  def test_now_playing_names_sequence_and_show_during_a_show
    el = client("GET /v1/events" => [running_event],
                "GET /v1/zones/z1/sequence" => {"alias" => "Hallows Eve", "pattern" => ["FF6800"],
                                                "effects" => [{"effectType" => "chase", "value" => 255}]},
                "GET /v1/zones/z2/sequence" => {"pattern" => [], "effects" => []})
    playing = el.now_playing
    assert_equal({name: "Hallows Eve", show: "Fall", off: false}, playing["z1"].slice(:name, :show, :off))
    assert_equal({name: nil, show: nil, off: true}, playing["z2"].slice(:name, :show, :off))
  end

  def test_now_playing_matches_manual_colors_to_saved_sequence_or_custom
    el = client("GET /v1/events" => [],
                "GET /v1/zones/z1/sequence" => {"pattern" => ["FFFFFF"], "effects" => []},
                "GET /v1/zones/z2/sequence" => {"pattern" => ["123456"], "effects" => []})
    playing = el.now_playing
    assert_equal({name: "Other", show: nil, off: false}, playing["z1"].slice(:name, :show, :off))
    assert_equal({name: nil, show: nil, off: false, pattern: ["123456"]}, playing["z2"].slice(:name, :show, :off, :pattern))
  end

  def test_off_sends_empty_pattern_to_every_zone
    el = client
    el.off
    assert_equal [["/v1/zones/z1/sequence", []], ["/v1/zones/z2/sequence", []]], @bridge.requests.last(2).map { [_1[1], _1[2]["pattern"]] }
  end

  def test_sequence_update_replaces_colors_and_effects_keeps_identity
    el = client
    el.sequences.update("Other", "#00ff00", effects: {fade: 40})
    verb, path, body = last_request
    assert_equal ["PUT", "/v1/sequences/seq-2"], [verb, path]
    assert_equal ["seq-2", "Other", ["00FF00"], [{"effectType" => "fade", "value" => 40}]], body.values_at("id", "alias", "pattern", "effects")
    assert body["lastChanged"]
    assert_raises(Everlights::Error) { el.sequences.update("Halloween", "00FF00") }
    assert_raises(Everlights::Error) { el.sequences.update("Other", "green") }
  end

  def test_sequence_remove_guards_builtins_and_in_use
    el = client
    assert_raises(Everlights::Error) { el.sequences.remove("Halloween") }
    assert_raises(Everlights::Error) { el.sequences.remove("Hallows Eve") }
    el.sequences.remove("other")
    assert_equal ["DELETE", "/v1/sequences/seq-2"], last_request.take(2)
  end

  def test_cli_calendar_add_spans_dst_and_midnight
    client
    _out, err, st = Open3.capture3(
      {"EVERLIGHTS_HOST" => "127.0.0.1:#{@bridge.port}"},
      "ruby", File.expand_path("../exe/everlights", __dir__),
      "calendar", "add", "2026-10-31", "Fall", "hallows eve:30,", "Other",
      "--start", "17:00", "--end", "00:30", "--until", "2026-11-01"
    )
    assert st.success?, err
    ev = last_request[2]
    assert_equal [], ev["flags"]
    assert_equal [{"sequenceId" => "seq-1", "duration" => 30}, {"sequenceId" => "seq-2", "duration" => 20}], ev["sequences"]
    # 17:00 EDT = 21:00Z on Oct 31; 17:00 EST = 22:00Z on Nov 1 (DST ended)
    assert_equal [
      {"start" => "2026-10-31T21:00:00.000000Z", "end" => "2026-11-01T04:30:00.000000Z"},
      {"start" => "2026-11-01T22:00:00.000000Z", "end" => "2026-11-02T05:30:00.000000Z"}
    ], ev["occurrences"]
  end

  def test_set_play_clear_hit_every_zone_unless_narrowed
    el = client
    el.set("ff0000", effects: {fade: 10})
    assert_equal [["POST", "/v1/zones/z1/sequence"], ["POST", "/v1/zones/z2/sequence"]], @bridge.requests.last(2).map { _1.take(2) }
    el.play("hallows eve")
    assert_equal({"colorMode" => "rgb", "pattern" => ["FF6800"], "effects" => [{"effectType" => "chase", "value" => 255}]}, last_request[2])
    el.clear(zones: ["z2"])
    assert_equal ["DELETE", "/v1/zones/z2/sequence"], last_request.take(2)
    assert_equal 1, @bridge.requests.count { _1[0] == "DELETE" }
  end

  def test_sequence_add_list_and_find
    el = client
    el.sequences.add("Candy Cane", "#ff0000", ["FFFFFF"], effects: {chase: 60})
    verb, path, body = last_request
    assert_equal ["POST", "/v1/sequences"], [verb, path]
    assert_match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/, body["id"])
    assert_equal ["Candy Cane", ["Personal/"], %w[FF0000 FFFFFF], [{"effectType" => "chase", "value" => 60}]],
                 body.values_at("alias", "groups", "pattern", "effects")
    assert_equal ["Hallows Eve", "Halloween"], el.sequences.list("HALL").map { _1["alias"] }
    assert_equal 3, el.sequences.list.size
    assert_equal "Other", el.find_sequence("seq-2")["alias"]
    assert_raises(Everlights::Error) { el.find_sequence("nope") }
  end

  def test_calendar_add_hash_form_fixed_times_and_bad_range
    el = client
    el.calendar.add("2026-12-31", "NYE", {"Other" => 45}, start: "20:00", finish: "01:00")
    ev = last_request[2]
    assert_equal [[], [{"sequenceId" => "seq-2", "duration" => 45}]], ev.values_at("flags", "sequences")
    assert_equal [{"start" => "2027-01-01T01:00:00.000000Z", "end" => "2027-01-01T06:00:00.000000Z"}], ev["occurrences"]
    assert_raises(Everlights::Error) { el.calendar.add("2026-12-31", "x", "Other", through: "2026-12-01") }
  end

  def test_update_event_stamps_last_changed
    el = client
    el.update_event(EVENT.merge("lastChanged" => "old"))
    verb, path, body = last_request
    assert_equal ["PUT", "/v1/events/ev-1"], [verb, path]
    refute_equal "old", body["lastChanged"]
  end

  def test_bridge_error_reply_raises
    err = assert_raises(Everlights::Error) { client("GET /v1/zones" => 500).zones }
    assert_match(%r{GET /v1/zones -> 500}, err.message)
  end

  def test_b5010_firmware_says_local_control_is_off
    _, err, st = cli("play", "Hallows Eve", routes: {"GET /v1/sequences" => 410})
    assert_equal 1, st.exitstatus
    assert_match(/turned off local control.*B5010/, err)
    @bridge = nil # a fresh fake with its own routes
    out, _, st = cli("bridge", "health", routes: {"GET /v1" => healthy_bridge.merge("firmwareVersion" => "B5010", "cloud" => true)})
    assert_equal 2, st.exitstatus
    assert_match(/^WARN  local control +off: firmware B5010/, out)
  end

  # --- CLI, one test per command ---

  def cli(*args, routes: {})
    client(routes) unless @bridge
    Open3.capture3({"EVERLIGHTS_HOST" => "127.0.0.1:#{@bridge.port}"}, "ruby", File.expand_path("../exe/everlights", __dir__), *args)
  end

  def cli!(*args, **kw)
    out, err, st = cli(*args, **kw)
    assert st.success?, "everlights #{args.join(" ")} failed: #{err}"
    out
  end

  BRIDGE = {"serial" => "b1", "firmwareVersion" => "B4042", "radioFirmwareVersion" => "R3052", "localIp" => "10.0.0.9",
            "serverReachable" => true, "lastServerCheckin" => "2026-10-31T21:21:55.000Z", "rebootCount" => 129,
            "network" => {"interface" => "ethernet", "ntp" => true},
            "zones" => [{"serial" => "z1", "firmwareVersion" => "N3063", "configuredLength" => 810, "colorOrder" => "grbw",
                         "active" => true, "rssi" => -101, "snr" => -109, "temperature" => 2302, "voltage" => 1488,
                         "current" => 65521, "rebootCount" => 9,
                         "lastRequestDate" => "2026-10-31T23:34:47.000Z", "lastResponseDate" => "2026-10-31T23:34:48.000Z"}]}

  def test_cli_bridge
    out = cli!("bridge", routes: {"GET /v1" => BRIDGE})
    assert_equal <<~TXT, out
      Bridge b1  firmware B4042, radio R3052
        network  ethernet 10.0.0.9, ntp ok
        cloud    reachable, last check-in 2026-10-31 17:21:55
        reboots  129
      Zone z1  firmware N3063, 810 pixels grbw, active
        signal   rssi -101, snr -109
        sensors  temperature 2302, voltage 1488, current 65521 (raw, units unknown)
        last     request 2026-10-31 19:34:47, response 2026-10-31 19:34:48, reboots 9
    TXT
  end

  def healthy_bridge
    fresh = (Time.now - 120).utc.iso8601
    BRIDGE.merge("lastServerCheckin" => fresh, "lastRadioResponse" => fresh, "radioRebootCount" => 0,
                 "minFreeHeap" => 12376, "resetReason" => 4,
                 "zones" => [BRIDGE["zones"][0].merge("lastResponseDate" => fresh)])
  end

  def test_cli_bridge_health
    out, _, st = cli("bridge", "health", routes: {"GET /v1" => healthy_bridge})
    assert_equal 0, st.exitstatus
    assert_equal <<~TXT, out
      ok    cloud               reachable, checked in 2 min ago
      ok    clock               ntp on
      ok    memory              lowest free since boot 12376 bytes (warn under 10000)
      ok    radio               answered 2 min ago, 0 radio reboots
      ok    zone z1             active, answered 2 min ago, 9 reboots
      info  reboots             129 total, last reset reason 4
    TXT
  end

  def test_cli_bridge_health_warns_and_exits_2
    sick = healthy_bridge.merge("serverReachable" => false, "minFreeHeap" => 7200, "network" => {})
    out, _, st = cli("bridge", "health", routes: {"GET /v1" => sick})
    assert_equal 2, st.exitstatus
    assert_equal ["WARN cloud", "WARN clock", "WARN memory"], out.lines.grep(/^WARN/).map { _1.split.take(2).join(" ") }
  end

  def test_cli_bridge_json
    assert_equal({"serial" => "b1"}, JSON.parse(cli!("bridge", "--json")))
  end

  def test_cli_bridge_time
    assert_match(/bridge clock set to 2026-11-01 12:00:00/, cli!("bridge", "time", "2026-11-01 12:00"))
    assert_equal ["PUT", "/v1/time", {"time" => "2026-11-01T17:00:00.000000Z"}], last_request
  end

  def test_cli_bridge_reboot_needs_yes
    _, err, st = cli("bridge", "reboot")
    refute st.success?
    assert_match(/rerun with --yes/, err)
    assert_empty @bridge.requests.select { _1[1] == "/v1/reboot" }
  end

  def test_cli_bridge_reboot
    assert_match(/rebooting bridge/, cli!("bridge", "reboot", "--yes"))
    assert_equal ["GET", "/v1/reboot"], last_request.take(2)
  end

  def test_cli_off
    assert_match(/^off$/, cli!("off", "--zone", "z2"))
    assert_equal ["POST", "/v1/zones/z2/sequence", {"colorMode" => "rgb", "pattern" => [], "effects" => []}], last_request
  end

  def test_cli_sequence_update
    assert_match(/updated sequence Other/, cli!("sequence", "update", "Other", "00FF00", "--effect", "fade=40"))
    verb, path, body = last_request
    assert_equal ["PUT", "/v1/sequences/seq-2"], [verb, path]
    assert_equal ["Other", ["00FF00"], [{"effectType" => "fade", "value" => 40}]], body.values_at("alias", "pattern", "effects")
  end

  def test_cli_sequence_update_refuses_builtin
    _, err, st = cli("sequence", "update", "Halloween", "00FF00")
    refute st.success?
    assert_match(/error: Halloween is built in/, err)
  end

  def test_cli_zones
    assert_equal %w[z1 z2], JSON.parse(cli!("zones")).map { _1["serial"] }
  end

  def test_cli_show
    out = cli!("show", routes: {"GET /v1/events" => [running_event],
                                "GET /v1/zones/z1/sequence" => {"alias" => "Hallows Eve", "pattern" => ["FF6800"],
                                                                "effects" => [{"effectType" => "chase", "value" => 255}]},
                                "GET /v1/zones/z2/sequence" => {"pattern" => ["123456", "ABCDEF"], "effects" => []}})
    assert_equal "z1  Hallows Eve (Fall show)  chase=255\nz2  custom colors 123456 ABCDEF\n", out
  end

  def test_cli_show_off_and_json
    assert_equal "z1  off\n", cli!("show", "--zone", "z1", routes: {"GET /v1/zones/z1/sequence" => {"pattern" => [], "effects" => []}})
    @bridge = nil
    playing = JSON.parse(cli!("show", "--zone", "z1", "--json", routes: {"GET /v1/events" => []}))
    assert_equal({"name" => nil, "show" => nil, "off" => false, "pattern" => ["FF0000"], "effects" => []}, playing["z1"])
  end

  def test_cli_set
    assert_match(/showing FF0000/, cli!("set", "FF0000", "--effect", "twinkle=100"))
    assert_equal [["POST", "/v1/zones/z1/sequence"], ["POST", "/v1/zones/z2/sequence"]], @bridge.requests.last(2).map { _1.take(2) }
    assert_equal [{"effectType" => "twinkle", "value" => 100}], last_request[2]["effects"]
  end

  def test_cli_set_rejects_unknown_effect
    _, err, st = cli("set", "FF0000", "--effect", "sparkle")
    refute st.success?
    assert_match(/error: unknown effect sparkle/, err)
  end

  def test_cli_play
    assert_match(/playing Hallows Eve/, cli!("play", "hallows", "eve"))
    assert_equal ["FF6800"], last_request[2]["pattern"]
  end

  def test_cli_clear
    assert_match(/cleared/, cli!("clear", "--zone", "z1"))
    assert_equal [["DELETE", "/v1/zones/z1/sequence"]], @bridge.requests.select { _1[0] == "DELETE" }.map { _1.take(2) }
  end

  def test_cli_sequence_list
    out = cli!("sequence", "list", "hall")
    assert_match(/^\* Hallows Eve +1 color   chase=255$/, out)
    assert_match(/^  Halloween +1 color   $/, out)
    refute_match(/Other/, out)
  end

  def test_cli_sequence_list_json
    assert_equal ["Hallows Eve", "Other", "Halloween"], JSON.parse(cli!("sequence", "list", "--json")).map { _1["alias"] }
  end

  def test_cli_sequence_add
    assert_match(/added sequence Candy Cane/, cli!("sequence", "add", "Candy Cane", "FF0000", "FFFFFF", "--effect", "chase=60"))
    assert_equal ["Candy Cane", %w[FF0000 FFFFFF], [{"effectType" => "chase", "value" => 60}]],
                 last_request[2].values_at("alias", "pattern", "effects")
  end

  def test_cli_sequence_remove
    assert_match(/removed sequence Other/, cli!("sequence", "remove", "Other"))
    assert_equal ["DELETE", "/v1/sequences/seq-2"], last_request.take(2)
  end

  def test_cli_sequence_remove_refuses_builtin
    _, err, st = cli("sequence", "remove", "Halloween")
    refute st.success?
    assert_match(/error: Halloween is built in/, err)
  end

  def test_cli_calendar_list
    soon = Time.now + 86_400
    event = EVENT.merge("occurrences" => [{"start" => soon.getutc.iso8601, "end" => (soon + 3600).getutc.iso8601}])
    out = cli!("calendar", "list", "--limit", "2", routes: {"GET /v1/events" => [event]})
    assert_equal "#{soon.strftime("%a %Y-%m-%d")}  #{soon.strftime("%H:%M")}-#{(soon + 3600).strftime("%H:%M")}  Fall  (Hallows Eve:20)\n", out
  end

  def test_cli_calendar_list_json
    soon = Time.now + 86_400
    event = EVENT.merge("occurrences" => [{"start" => soon.getutc.iso8601, "end" => (soon + 3600).getutc.iso8601}])
    shows = JSON.parse(cli!("calendar", "list", "--json", routes: {"GET /v1/events" => [event]}))
    assert_equal [["Fall", [["Hallows Eve", 20]]]], shows.map { _1.values_at("name", "sequences") }
  end

  def test_cli_calendar_list_empty
    assert_match(/nothing scheduled in the next 30 days/, cli!("calendar", "list", "--limit", "30", routes: {"GET /v1/events" => []}))
  end

  def test_cli_calendar_add_defaults
    assert_match(/added Eve on 2026-12-24/, cli!("calendar", "add", "2026-12-24", "Eve", "Other"))
    assert_equal [["StartAtDusk"], [{"sequenceId" => "seq-2", "duration" => 20}]], last_request[2].values_at("flags", "sequences")
  end

  def test_cli_calendar_remove
    assert_match(/removed Fall on 2026-11-01/, cli!("calendar", "remove", "2026-11-01", "Fall"))
    assert_equal ["PUT", "/v1/events/ev-1"], last_request.take(2)
  end

  def test_cli_calendar_remove_nothing_there
    _, err, st = cli("calendar", "remove", "2026-12-25", "Fall")
    refute st.success?
    assert_match(/error: nothing named "Fall" on 2026-12-25/, err)
  end

  def test_cli_unknown_command_prints_usage
    _, err, st = cli("bogus")
    refute st.success?
    assert_match(/Usage:/, err)
  end
end
