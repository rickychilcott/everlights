require "minitest/autorun"
require "open3"
require "tmpdir"
ENV["TZ"] = "America/New_York"
require_relative "../lib/everlights"
require_relative "fake_bridge"

# In-memory bridge that keeps state, so a test can apply a plan and then plan again.
class MemoryBridge
  attr_reader :log

  def initialize(seqs: [], events: [])
    @seqs, @events, @log = copy(seqs), copy(events), []
  end

  def sequence_list = copy(@seqs)
  def event_list = copy(@events)

  def create_sequence(name, pattern:, effects: {}, id:)
    @log << [:create_sequence, name]
    @seqs << {"id" => id, "alias" => name, "groups" => ["Personal/"],
              "pattern" => Everlights.colors(pattern), "effects" => Everlights.effects(effects)}
  end

  def update_sequence(seq, pattern:, effects: {})
    @log << [:update_sequence, seq["alias"]]
    @seqs.find { _1["id"] == seq["id"] }.merge!("pattern" => Everlights.colors(pattern), "effects" => Everlights.effects(effects))
  end

  def delete_sequence(id)
    @log << [:delete_sequence, @seqs.find { _1["id"] == id }["alias"]]
    @seqs.reject! { _1["id"] == id }
  end

  def create_event(name, sequences:, occurrences:, flags: [], id:, zones: [Everlights::ALL_ZONES])
    @log << [:create_event, name]
    @events << {"id" => id, "alias" => name, "group" => "User Created", "zoneSerials" => zones, "flags" => flags,
                "sequences" => sequences.map { |sid, secs| {"sequenceId" => sid, "duration" => secs} },
                "occurrences" => occurrences.map { |s, e| {"start" => Everlights.stamp(s), "end" => Everlights.stamp(e)} }}
  end

  def update_event(event)
    @log << [:update_event, event["alias"]]
    @events.map! { _1["id"] == event["id"] ? copy(event) : _1 }
  end

  def delete_event(id)
    @log << [:delete_event, @events.find { _1["id"] == id }["alias"]]
    @events.reject! { _1["id"] == id }
  end

  def event(name) = @events.find { _1["alias"] == name }
  def nights(name) = event(name)["occurrences"].map { Time.parse(_1["start"]).localtime }

  private

  def copy(x) = JSON.parse(JSON.generate(x))
end

class SyncTest < Minitest::Test
  NYC = {"lat" => 40.7128, "lon" => -74.0060}
  NOON = Time.new(2026, 11, 1, 12, 0) # a Sunday, just after DST ended
  BUILTINS = [
    {"id" => "00000000-0000-0000-0000-000000000001", "alias" => "Christmas", "pattern" => ["FF0000"], "effects" => []},
    {"id" => "00000000-0000-0000-0000-000000000002", "alias" => "Fall Wave", "pattern" => ["FF6800"], "effects" => []},
    {"id" => "00000000-0000-0000-0000-000000000003", "alias" => "Birthday", "pattern" => ["FFFFFF"], "effects" => []}
  ]

  def setup
    @dir = Dir.mktmpdir
    @state = File.join(@dir, ".sync-state.yml")
  end

  def teardown = FileUtils.rm_rf(@dir)

  def config(schedule, sequences: {}, **extra)
    {"location" => NYC, "horizon_days" => 160, "sequences" => sequences, "schedule" => schedule}.merge(extra.transform_keys(&:to_s))
  end

  def plan(cfg, bridge, now: NOON, adopt: false)
    Everlights::Sync.new(bridge, cfg, state_path: @state, adopt: adopt, now: now).plan
  end

  def bridge(events: []) = MemoryBridge.new(seqs: BUILTINS, events: events)

  # --- which nights ---

  def test_rule_kinds_pick_the_right_nights
    b = bridge
    plan(config([
      {"name" => "Thanksgiving", "on" => "4th Thursday of November", "sequences" => ["Fall Wave"]},
      {"name" => "Valentine", "on" => Date.new(2027, 2, 14), "sequences" => ["Christmas"]},
      {"name" => "Easter", "on" => "Easter", "sequences" => ["Christmas"]},
      {"name" => "Memorial", "on" => "last Monday of May", "sequences" => ["Christmas"]},
      {"name" => "Jan Fridays", "every" => ["Fri"], "from" => "Jan 2", "to" => "Jan 31", "sequences" => ["Christmas"]}
    ]), b).apply!
    assert_equal [Date.new(2026, 11, 26)], b.nights("Thanksgiving").map(&:to_date)
    assert_equal [Date.new(2027, 2, 14)], b.nights("Valentine").map(&:to_date)
    assert_equal [Date.new(2027, 3, 28)], b.nights("Easter").map(&:to_date)
    assert_nil b.event("Memorial"), "May 31 2027 is past the 160-day horizon"
    assert_equal [8, 15, 22, 29], b.nights("Jan Fridays").map(&:day)
  end

  def test_date_offsets_cover_the_church_calendar
    b = bridge
    plan(config([
      {"name" => "Mardi Gras", "on" => "Easter-47", "sequences" => ["Christmas"]},
      {"name" => "Palm Sunday", "on" => "Easter - 7", "sequences" => ["Christmas"]},
      {"name" => "Good Friday", "on" => "Easter-2", "sequences" => ["Christmas"]},
      {"name" => "Easter Week", "from" => "Easter+1", "to" => "Easter+6", "sequences" => ["Christmas"]},
      {"name" => "Black Friday", "on" => "4th Thursday of November+1", "sequences" => ["Christmas"]},
      {"name" => "Dec 31 via Jan 1", "on" => "Jan 1-1", "sequences" => ["Christmas"]},
      {"name" => "Fixed plus", "on" => "2026-12-01+2", "sequences" => ["Christmas"]}
    ]), b).apply!
    assert_equal [Date.new(2027, 2, 9)], b.nights("Mardi Gras").map(&:to_date)
    assert_equal [Date.new(2027, 3, 21)], b.nights("Palm Sunday").map(&:to_date)
    assert_equal [Date.new(2027, 3, 26)], b.nights("Good Friday").map(&:to_date)
    assert_equal (Date.new(2027, 3, 29)..Date.new(2027, 4, 3)).to_a, b.nights("Easter Week").map(&:to_date)
    assert_equal [Date.new(2026, 11, 27)], b.nights("Black Friday").map(&:to_date)
    assert_equal [Date.new(2026, 12, 31)], b.nights("Dec 31 via Jan 1").map(&:to_date)
    assert_equal [Date.new(2026, 12, 3)], b.nights("Fixed plus").map(&:to_date)
  end

  def test_range_with_fixed_dates_and_bad_offset
    b = bridge
    plan(config([{"name" => "Visit", "from" => "2026-12-10", "to" => "2026-12-12", "sequences" => ["Christmas"]}]), b).apply!
    assert_equal [10, 11, 12], b.nights("Visit").map(&:day)
    err = assert_raises(Everlights::Error) { plan(config([{"name" => "X", "on" => "Novembr 3+1", "sequences" => ["Christmas"]}]), bridge) }
    assert_match(/unknown month "Novembr"/, err.message)
  end

  def test_first_rule_wins_a_night_and_ranges_wrap_the_new_year
    b = bridge
    p = plan(config([
      {"name" => "Christmas Day", "on" => "Dec 25", "sequences" => ["Christmas"]},
      {"name" => "Season", "from" => "Dec 1", "to" => "Jan 1", "sequences" => ["Christmas"]}
    ]), b)
    assert_includes p.skips, [Date.new(2026, 12, 25), "Season", "Christmas Day wins this night"]
    p.apply!
    season = b.nights("Season").map(&:to_date)
    assert_equal 31, season.size
    assert_equal [Date.new(2026, 12, 1), Date.new(2027, 1, 1)], [season.first, season.last]
    refute_includes season, Date.new(2026, 12, 25)
  end

  def test_dusk_is_sunset_with_offset_and_end_after_midnight_is_next_morning
    b = bridge
    plan(config([
      {"name" => "Eve", "on" => "Dec 24", "start" => "dusk+15", "end" => "01:00", "sequences" => ["Christmas"]},
      {"name" => "Fixed", "on" => "Dec 23", "start" => "18:30", "sequences" => ["Christmas"]}
    ]), b).apply!
    ev = b.event("Eve")
    s, e = ev["occurrences"][0].values_at("start", "end").map { Time.parse(_1).localtime }
    assert_in_delta Everlights::Sync.sunset(Date.new(2026, 12, 24), NYC["lat"], NYC["lon"]) + 900, s, 1
    assert_equal Time.new(2026, 12, 25, 1, 0), e
    assert_equal ["StartAtDusk"], ev["flags"]
    assert_equal [Time.new(2026, 12, 23, 18, 30)], b.nights("Fixed")
    assert_equal [], b.event("Fixed")["flags"]
  end

def test_evening_end_before_dusk_skips_the_night_instead_of_running_all_day
  # Columbus, OH sunset on Jun 28 is ~21:05; an 20:45 end is before it
  cfg = {"location" => {"lat" => 39.96, "lon" => -83.00}, "horizon_days" => 240,
         "schedule" => [{"name" => "Summer", "on" => "Jun 28", "end" => "20:45", "sequences" => ["Christmas"]}]}
  p = plan(cfg, bridge)
  assert_empty p.actions
  assert_equal [[Date.new(2027, 6, 28), "Summer"]], p.skips.map { _1.take(2) }
  assert_match(/dusk \(21:0\d\) is after its end time/, p.skips[0][2])
end

def test_fixed_times_hold_across_dst_start
    b = bridge
    plan(config([{"name" => "March", "from" => "Mar 13", "to" => "Mar 15", "start" => "18:00", "sequences" => ["Christmas"]}]), b).apply!
    assert_equal [[18, 0]] * 3, b.nights("March").map { [_1.hour, _1.min] }
  end

  def test_tonight_only_if_it_starts_more_than_15_minutes_from_now
    rule = [{"name" => "Nightly", "every" => %w[Sun Mon], "start" => "18:10", "sequences" => ["Fall Wave"]}]
    p = plan(config(rule, horizon_days: 1), bridge, now: Time.new(2026, 11, 1, 18, 0))
    assert_equal [[Date.new(2026, 11, 1), "Nightly", "already started or starts within 15 minutes"]], p.skips
    b = bridge
    plan(config(rule, horizon_days: 1), b, now: Time.new(2026, 11, 1, 17, 50)).apply!
    assert_equal [Date.new(2026, 11, 1), Date.new(2026, 11, 2)], b.nights("Nightly").map(&:to_date)
  end

  def test_nights_held_by_app_made_entries_are_skipped
    app = {"id" => "app-1", "alias" => "Halloween", "group" => "User Created", "flags" => [], "sequences" => [],
           "occurrences" => [{"start" => Time.new(2026, 11, 2, 17).getutc.iso8601, "end" => Time.new(2026, 11, 2, 22).getutc.iso8601}]}
    p = plan(config([{"name" => "Nightly", "every" => %w[Mon Tue], "start" => "18:00", "sequences" => ["Fall Wave"]}], horizon_days: 2),
             bridge(events: [app]))
    assert_equal [[Date.new(2026, 11, 2), "Nightly", "\"Halloween\" (made outside sync) has this night"]], p.skips
  end

  # --- life cycle ---

  def test_apply_then_replan_changes_nothing_and_state_survives
    cfg = config([{"name" => "Bday", "on" => "Dec 14", "sequences" => ["My Birthday:30", "Christmas"]}],
                 sequences: {"My Birthday" => {"colors" => ["#ff1e8c", "FFC400"], "effects" => {"chase" => 60}}})
    b = bridge
    p = plan(cfg, b)
    assert_equal [%i[sequence create], %i[event create]], p.actions.map { [_1.kind, _1.op] }
    p.apply!
    assert_equal [[:create_sequence, "My Birthday"], [:create_event, "Bday"]], b.log
    seq_id = b.sequence_list.find { _1["alias"] == "My Birthday" }["id"]
    assert_equal [{"sequenceId" => seq_id, "duration" => 30}, {"sequenceId" => BUILTINS[0]["id"], "duration" => 20}], b.event("Bday")["sequences"]
    assert_equal({"sequences" => {"My Birthday" => seq_id}, "events" => {"Bday" => b.event("Bday")["id"]}},
                 YAML.safe_load_file(@state))
    assert plan(cfg, b).empty?
  end

  def test_editing_a_rule_and_sequence_updates_in_place
    cfg = config([{"name" => "Bday", "on" => "Dec 14", "sequences" => ["My Birthday"]}],
                 sequences: {"My Birthday" => {"colors" => ["FF1E8C"]}})
    b = bridge
    plan(cfg, b).apply!
    ids = [b.event("Bday")["id"], b.sequence_list.find { _1["alias"] == "My Birthday" }["id"]]
    cfg["schedule"][0]["end"] = "22:00"
    cfg["sequences"]["My Birthday"]["colors"] = ["00FF00"]
    p = plan(cfg, b)
    assert_equal [%i[sequence update], %i[event update]], p.actions.map { [_1.kind, _1.op] }
    p.apply!
    assert_equal ids, [b.event("Bday")["id"], b.sequence_list.find { _1["alias"] == "My Birthday" }["id"]]
    assert_equal 22, Time.parse(b.event("Bday")["occurrences"][0]["end"]).localtime.hour
    assert_equal ["00FF00"], b.sequence_list.find { _1["alias"] == "My Birthday" }["pattern"]
  end

  def test_removing_from_config_deletes_what_sync_made_events_first
    cfg = config([{"name" => "Bday", "on" => "Dec 14", "sequences" => ["My Birthday"]}],
                 sequences: {"My Birthday" => {"colors" => ["FF1E8C"]}})
    b = bridge
    plan(cfg, b).apply!
    b.log.clear
    plan(config([]), b).apply!
    assert_equal [[:delete_event, "Bday"], [:delete_sequence, "My Birthday"]], b.log
    assert_equal({"sequences" => {}, "events" => {}}, YAML.safe_load_file(@state))
    assert plan(config([]), b).empty?
  end

  def test_removed_sequence_still_used_by_an_app_entry_is_kept_and_untracked
    cfg = config([], sequences: {"My Birthday" => {"colors" => ["FF1E8C"]}})
    b = bridge
    plan(cfg, b).apply!
    seq_id = b.sequence_list.find { _1["alias"] == "My Birthday" }["id"]
    b.instance_variable_get(:@events) << {"id" => "app-1", "alias" => "Party", "flags" => [], "occurrences" => [],
                                          "sequences" => [{"sequenceId" => seq_id, "duration" => 20}]}
    p = plan(config([]), b)
    assert_equal [[:untrack, "My Birthday"]], p.actions.map { [_1.op, _1.name] }
    p.apply!
    assert b.sequence_list.any? { _1["id"] == seq_id }
    assert_equal({}, YAML.safe_load_file(@state)["sequences"])
  end

  def test_removing_a_rule_mid_show_keeps_tonight
    cfg = config([{"name" => "Nightly", "every" => %w[Sun Mon], "start" => "18:30", "end" => "22:00", "sequences" => ["Fall Wave"]}], horizon_days: 1)
    b = bridge
    plan(cfg, b, now: Time.new(2026, 11, 1, 12)).apply!
    p = plan(config([]), b, now: Time.new(2026, 11, 1, 19))
    assert_equal [%i[event update]], p.actions.map { [_1.kind, _1.op] }
    p.apply!
    assert_equal [Time.new(2026, 11, 1, 18, 30)], b.nights("Nightly")
    plan(config([]), b, now: Time.new(2026, 11, 2, 9)).apply!
    assert_nil b.event("Nightly")
  end

  def test_past_nights_are_pruned_and_window_rolls_forward
    cfg = config([{"name" => "Nightly", "every" => %w[Sun Mon Tue Wed], "start" => "18:30", "sequences" => ["Fall Wave"]}], horizon_days: 1)
    b = bridge
    plan(cfg, b, now: Time.new(2026, 11, 1, 12)).apply!
    plan(cfg, b, now: Time.new(2026, 11, 3, 12)).apply!
    assert_equal [Date.new(2026, 11, 3), Date.new(2026, 11, 4)], b.nights("Nightly").map(&:to_date)
  end

  # --- validation and adopt ---

  def test_every_config_problem_is_reported_and_nothing_is_written
    cfg = {"schedule" => [
      {"name" => "A", "on" => "Dec 25", "sequences" => ["Nope"]},
      {"name" => "B", "on" => "Dec 25", "every" => ["Fri"], "sequences" => ["Christmas"]},
      {"name" => "C", "on" => "Smarch 3", "sequences" => ["Christmas"]},
      {"name" => "D", "on" => "Dec 1", "sequences" => ["Christmas"]}, # dusk with no location
      {"name" => "E", "on" => "Dec 2", "start" => "7pm", "sequences" => ["Christmas"]},
      {"name" => "a", "on" => "Dec 3", "start" => "18:00", "sequences" => ["Christmas"]}
    ], "sequences" => {"Birthday" => {"colors" => ["FFFFFF"]}, "Mine" => {"colors" => ["red"], "effects" => {"sparkle" => 1}}}}
    b = bridge
    err = assert_raises(Everlights::Error) { plan(cfg, b) }
    [/rule "A": unknown sequence "Nope"/, /rule "B": needs exactly one of/, /rule "C": unknown month "Smarch"/,
     /rule "D": dusk needs `location/, /rule "E": can't read time "7pm"/, /rule names must be unique: a/,
     /sequence "Birthday" has the same name as a built-in/, /sequence "Mine": bad color "red"/,
     /sequence "Mine": unknown effect sparkle/].each { assert_match _1, err.message }
    assert_empty b.log
    refute File.exist?(@state)
  end

  def test_app_made_names_clash_unless_adopted
    app_seq = {"id" => "app-seq", "alias" => "My Birthday", "groups" => ["Personal/"], "pattern" => ["000000"], "effects" => []}
    app_event = {"id" => "app-ev", "alias" => "Bday", "flags" => [], "sequences" => [], "occurrences" => []}
    cfg = config([{"name" => "Bday", "on" => "Dec 14", "sequences" => ["My Birthday"]}],
                 sequences: {"My Birthday" => {"colors" => ["FF1E8C"]}})
    b = MemoryBridge.new(seqs: BUILTINS + [app_seq], events: [app_event])
    err = assert_raises(Everlights::Error) { plan(cfg, b) }
    assert_match(/sequence "My Birthday" already exists.*--adopt/, err.message)
    assert_match(/rule "Bday" has the same name as calendar entry "Bday"/, err.message)

    p = plan(cfg, b, adopt: true)
    assert_equal [%i[sequence adopt], %i[event adopt], %i[sequence update], %i[event update]], p.actions.map { [_1.kind, _1.op] }
    p.apply!
    assert_equal({"sequences" => {"My Birthday" => "app-seq"}, "events" => {"Bday" => "app-ev"}}, YAML.safe_load_file(@state))
    assert_equal ["FF1E8C"], b.sequence_list.find { _1["id"] == "app-seq" }["pattern"]
  end

  def test_unquoted_yaml_time_reads_as_clock_time
    cfg = Everlights::Sync.load_config(File.join(@dir, "c.yml").tap { File.write(_1, <<~YAML) })
      schedule:
        - {name: Fixed, on: Dec 23, start: 18:30, end: 22:00, sequences: [Christmas]}
    YAML
    b = bridge
    plan(cfg, b).apply!
    assert_equal [Time.new(2026, 12, 23, 18, 30)], b.nights("Fixed")
  end

  def test_plan_text
    p = plan(config([{"name" => "Christmas Day", "on" => "Dec 25", "start" => "18:00", "sequences" => ["Christmas"]},
                     {"name" => "Season", "from" => "Dec 24", "to" => "Dec 26", "start" => "18:00", "sequences" => ["Christmas"]}],
                    sequences: {"Mine" => {"colors" => %w[FF0000 00FF00]}}), bridge)
    assert_equal <<~TXT.chomp, p.to_s
      Sequences
        + create  Mine: 2 colors
      Calendar (next 160 days)
        + create  Christmas Day: 1 night, Dec 25, 18:00–23:00
        + create  Season: 2 nights, Dec 24 – Dec 26, 18:00–23:00
      Nights taken by a higher rule
          Season: 1 night to Christmas Day (Dec 25)
    TXT
  end

  # --- CLI ---

  def test_cli_sync_dry_run_reads_host_and_timezone_from_config
    fake = FakeBridge.new("GET /v1/sequences" => BUILTINS, "GET /v1/events" => [])
    path = File.join(@dir, "everlights.yml")
    File.write(path, YAML.dump("bridge" => {"host" => "127.0.0.1:#{fake.port}"}, "timezone" => "America/Los_Angeles",
                               "schedule" => [{"name" => "Fixed", "on" => "Dec 23", "start" => "18:30", "sequences" => ["Christmas"]}]))
    out, err, st = Open3.capture3({"EVERLIGHTS_HOST" => nil, "EVERLIGHTS_CONFIG" => nil},
                                  "ruby", File.expand_path("../exe/everlights", __dir__), "sync", "--dry-run", "--config", path)
    assert st.success?, err
    assert_match(/\+ create  Fixed: 1 night, Dec 23, 18:30–23:00/, out)
    assert_match(/dry run: nothing applied/, out)
    assert_equal %w[GET GET], fake.requests.map(&:first), "dry run must not write"
    refute File.exist?(File.join(@dir, ".sync-state.yml"))
  end

  def test_cli_sync_without_config_explains
    _, err, st = Open3.capture3({"EVERLIGHTS_HOST" => "127.0.0.1:1", "EVERLIGHTS_CONFIG" => nil},
                                "ruby", File.expand_path("../exe/everlights", __dir__), "sync", chdir: @dir)
    refute st.success?
    assert_match(/no config at config\/everlights.yml; copy config\/everlights.example.yml/, err)
  end
end
