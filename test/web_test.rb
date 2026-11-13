require "minitest/autorun"
require "tmpdir"
require_relative "sync_test" # MemoryBridge
require_relative "../lib/everlights/web"

class WebTest < Minitest::Test
  HOST = {"host" => "localhost:4567", "content-type" => "application/json"}.freeze

  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "everlights.yml")
    File.write(@path, <<~YAML)
      # my lights
      location: {lat: 39.96, lon: -83.0}
      sequences:
        Glow: {colors: [FF7A1E], effects: {twinkle: 40}}
      schedule:
        - {name: Christmas, on: Dec 25, start: 18:30, sequences: [Glow]}
        - {name: Nightly, every: [Sun, Mon, Tue, Wed, Thu, Fri, Sat], end: "21:00", sequences: [Glow]}
    YAML
    @bridge = MemoryBridge.new
    @web = Everlights::Web.new(@bridge, @path)
  end

  def teardown = FileUtils.rm_rf(@dir)

  def call(verb, path, body = nil, headers = HOST)
    code, _, out = @web.route(verb, path, headers, body && JSON.generate(body))
    [code, out.start_with?("{") ? JSON.parse(out) : out]
  end

  def test_state_shows_the_plan_and_each_night
    code, s = call("GET", "/api/state")
    assert_equal 200, code
    assert_equal "18:30", s["config"]["schedule"][0]["start"], "unquoted 18:30 comes back as text"
    assert_equal %w[create create create], s["plan"].map { _1["op"] }
    christmas = s["nights"].find { |d, _| d.end_with?("-12-25") }
    assert_equal "Christmas", christmas[1]["rule"]
    assert_equal "18:30", christmas[1]["start"]
  end

  def test_saving_rewrites_the_yaml_and_apply_sends_it
    _, s = call("GET", "/api/state")
    cfg = s["config"]
    cfg["schedule"].reverse!
    code, s = call("PUT", "/api/config", cfg)
    assert_equal 200, code
    assert_equal "Nightly", s["nights"].find { |d, _| d.end_with?("-12-25") }[1]["rule"], "now outranks Christmas"
    text = File.read(@path)
    assert text.start_with?("# my lights\n"), "keeps the header comment"
    assert_includes text, "'on': Dec 25"
    assert File.exist?("#{@path}.bak")
    assert_equal "Nightly", Everlights::Sync.load_config(@path)["schedule"][0]["name"]

    _, s = call("POST", "/api/apply", {})
    assert_equal 2, s["applied"], "Glow and Nightly; Christmas has no nights left"
    assert_empty s["plan"]
  end

  def test_config_problems_are_reported_not_raised
    _, s = call("GET", "/api/state")
    s["config"]["schedule"][0]["sequences"] = ["Nope"]
    code, s = call("PUT", "/api/config", s["config"])
    assert_equal 200, code
    assert_match(/unknown sequence "Nope"/, s["error"])
    assert s.key?("bridge_sequences"), "still lists the bridge's sequences to pick from"
  end

  def test_bad_values_come_back_as_messages
    File.write(@path, File.read(@path) + "horizon_days: lots\n")
    code, s = call("GET", "/api/state")
    assert_equal 200, code
    assert_match(/lots/, s["error"])
    assert s["today"] && s["horizon"], "the page can still draw the calendar"
    code, _, out = @web.respond("POST", "/api/apply", HOST, "{}")
    assert_equal 422, code
    assert_match(/lots/, JSON.parse(out)["error"])
  end

  def test_a_file_edited_elsewhere_is_not_overwritten
    _, s = call("GET", "/api/state")
    File.write(@path, File.read(@path) + "horizon_days: 30\n") # by hand, while the page is open
    code, now = call("PUT", "/api/config", s["config"], HOST.merge("if-match" => s["version"]))
    assert_equal 412, code
    assert_equal 30, now["config"]["horizon_days"], "answers with the file as it is"
    assert_includes File.read(@path), "horizon_days: 30"
    assert_equal 200, call("PUT", "/api/config", now["config"], HOST.merge("if-match" => now["version"]))[0]
  end

  def test_the_backup_is_the_original_and_stays
    original = File.read(@path)
    _, s = call("GET", "/api/state")
    call("PUT", "/api/config", s["config"])
    Everlights::Web.new(@bridge, @path).save(s["config"]) # a later session
    assert_equal original, File.read("#{@path}.bak")
  end

  def test_an_idle_connection_doesnt_hold_up_others
    port = TCPServer.open("127.0.0.1", 0) { _1.addr[1] }
    web = Everlights::Web.new(@bridge, @path, port: port)
    capture_io do
      server = Thread.new { web.start }
      idle = nil # a browser's spare connection: open, nothing sent
      50.times { break if (idle = (TCPSocket.new("127.0.0.1", port) rescue nil)); sleep 0.05 }
      res = Net::HTTP.start("127.0.0.1", port, read_timeout: 3) { _1.get("/api/state") }
      assert_equal "200", res.code
    ensure
      idle&.close
      server&.kill&.join
    end
  end

  def test_refuses_other_sites
    assert_equal 403, call("GET", "/api/state", nil, {"host" => "evil.example"})[0]
    assert_equal 415, call("PUT", "/api/config", {}, {"host" => "localhost:4567", "content-type" => "text/plain"})[0]
  end

  def test_preview_shows_colors_then_hands_back_after_stop_or_silence
    zones = Class.new(MemoryBridge) do
      attr_reader :lights
      def set(*colors, effects: {}) = @lights = [colors, effects]
      def clear = @lights = :calendar
    end.new
    web = Everlights::Web.new(zones, @path)
    post = ->(body) { JSON.parse(web.route("POST", "/api/preview", HOST, JSON.generate(body))[2]) }

    assert post.(colors: ["ff0000"], effects: {chase: 60})["previewing"]
    assert_equal [["FF0000"], [{"effectType" => "chase", "value" => 60}]], zones.lights
    assert post.(ping: true)["previewing"]
    refute post.(stop: true)["previewing"]
    assert_equal :calendar, zones.lights

    post.(colors: ["00ff00"])
    web.expire_preview(Time.now + 5)
    refute_equal :calendar, zones.lights, "still pinged recently"
    web.expire_preview(Time.now + Everlights::Web::PREVIEW_GRACE + 1)
    assert_equal :calendar, zones.lights, "page went quiet"
    refute post.(ping: true)["previewing"], "a late ping doesn't restart it"

    assert_raises(Everlights::Error) { post.(colors: []) } # handle turns it into a 422 with the message
  end

  def test_a_failed_clear_keeps_the_preview_to_retry
    flaky = Class.new(MemoryBridge) do
      attr_accessor :down
      attr_reader :lights
      def set(*colors, effects: {}) = @lights = colors
      def clear = (down ? raise(Errno::EHOSTUNREACH) : (@lights = :calendar))
    end.new
    web = Everlights::Web.new(flaky, @path)
    post = ->(body) { web.respond("POST", "/api/preview", HOST, JSON.generate(body)) }
    post.(colors: ["ff0000"])
    flaky.down = true
    assert_equal 422, post.(stop: true)[0]
    _, err = capture_io { web.expire_preview(Time.now + 60) }
    assert_match(/will retry/, err)
    flaky.down = false
    web.expire_preview(Time.now + 60)
    assert_equal :calendar, flaky.lights
  end

  def test_bridge_info_and_actions
    status = {"serverReachable" => true, "lastServerCheckin" => Everlights.stamp(Time.now), "network" => {"ntp" => true},
              "minFreeHeap" => 20_000, "lastRadioResponse" => Everlights.stamp(Time.now), "rebootCount" => 3, "zones" => []}
    bridge = Class.new(MemoryBridge) do
      attr_reader :did
      define_method(:status) { status }
      def set_time(_) = @did = :time
      def reboot = @did = :reboot
    end.new
    web = Everlights::Web.new(bridge, @path)
    out = JSON.parse(web.route("GET", "/api/bridge", HOST, "")[2])
    assert_equal 3, out["status"]["rebootCount"]
    assert_equal %w[cloud clock memory radio reboots], out["checks"].map { _1["name"] }
    assert(out["checks"].first(4).all? { _1["ok"] == true })

    web.route("POST", "/api/bridge", HOST, JSON.generate(action: "time"))
    assert_equal :time, bridge.did
    web.route("POST", "/api/bridge", HOST, JSON.generate(action: "reboot"))
    assert_equal :reboot, bridge.did
    assert_raises(Everlights::Error) { web.route("POST", "/api/bridge", HOST, JSON.generate(action: "format")) }
  end
end
