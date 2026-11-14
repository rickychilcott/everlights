require "minitest/autorun"
require "tmpdir"
require "base64"
require_relative "../lib/everlights"
require_relative "fake_bridge"

# One fake server plays both the app server (/v1/...) and the tunnel (/bridges/...).
class CloudTest < Minitest::Test
  SEQS = [{"id" => "s1", "alias" => "Pinks", "pattern" => ["FF00FF"], "effects" => []}]

  def setup = @dir = Dir.mktmpdir
  def teardown = FileUtils.rm_rf(@dir)

  def jwt(exp) = "x.#{Base64.urlsafe_encode64(JSON.generate(exp: exp), padding: false)}.sig"

  def server(routes = {})
    @fake = FakeBridge.new({
      "POST /v1/oauth/token" => {"access_token" => "acc1", "refresh_token" => "ref1", "expires_in" => 86_400},
      "GET /v1/bridges" => [{"bridgeSerial" => "old", "unpairedDate" => "2025-01-01T00:00:00Z"},
                            {"bridgeSerial" => "br1", "alias" => "House", "unpairedDate" => nil, "bridge" => {"firmwareVersion" => "B5010"}},
                            {"bridgeSerial" => "br2", "alias" => "Barn", "unpairedDate" => nil}],
      "GET /v1/bridges/br1/remotetoken" => {"token" => jwt(Time.now.to_i + 3600)},
      "GET /bridges/br1/proxy/v1/sequences" => SEQS,
      "GET /bridges/br1/proxy/v1/" => {"serial" => "br1", "cloud" => true, "zones" => []}
    }.merge(routes))
  end

  def path = File.join(@dir, "everlights", "cloud.json")
  def urls = {api: "http://127.0.0.1:#{@fake.port}/v1", tunnel: "http://127.0.0.1:#{@fake.port}/bridges"}
  def login(**kw) = Everlights::Cloud.login("me@example.com", "hunter2", path: path, **urls, **kw)

  def test_login_saves_tokens_not_the_password
    server
    cloud, bridges = login
    assert_equal %w[br1 br2], bridges.map { _1["serial"] } # unpaired bridges left out
    assert_equal "br1", cloud.bridge
    assert_equal({"grant_type" => "password", "username" => "me@example.com", "password" => "hunter2"}, @fake.requests[0][2])
    assert_equal "Bearer acc1", @fake.auth[1]
    saved = File.read(path)
    refute_includes saved, "hunter2"
    assert_equal "ref1", JSON.parse(saved)["refresh_token"]
    assert_equal 0o600, File.stat(path).mode & 0o777
    assert_equal "br2", login(bridge: "br2")[0].bridge
    assert_raises(Everlights::Error) { login(bridge: "nope") }
  end

  def test_bad_password
    server("POST /v1/oauth/token" => 400)
    err = assert_raises(Everlights::Error) { login }
    assert_match(/didn't accept the email or password/, err.message)
    refute File.exist?(path)
  end

  def test_client_goes_through_the_tunnel
    server
    login
    el = Everlights::Client.new(cloud: Everlights::Cloud.new(path, **urls))
    assert el.cloud?
    assert_equal SEQS, el.sequence_list
    assert_equal ["GET", "/bridges/br1/proxy/v1/sequences", nil], @fake.requests.last
    assert_match(/\ABearer x\./, @fake.auth.last)
    assert_equal "br1", el.status["serial"] # the bridge's root needs its trailing slash on the tunnel
    # the tunnel token is saved and reused by the next process
    count = @fake.requests.size
    Everlights::Client.new(cloud: Everlights::Cloud.new(path, **urls)).sequence_list
    assert_equal 1, @fake.requests.size - count
  end

  def test_expired_login_renews_with_the_refresh_token
    server
    login
    File.write(path, JSON.generate(JSON.parse(File.read(path)).merge("access_expires" => 0, "tunnel_expires" => 0)))
    server("POST /v1/oauth/token" => {"access_token" => "acc2", "refresh_token" => "ref2", "expires_in" => 86_400})
    Everlights::Client.new(cloud: Everlights::Cloud.new(path, **urls)).sequence_list
    assert_equal({"grant_type" => "refresh_token", "refresh_token" => "ref1"}, @fake.requests[0][2])
    assert_equal %w[acc2 ref2], JSON.parse(File.read(path)).values_at("access_token", "refresh_token")
  end

  def test_tunnel_turning_a_token_away_gets_one_retry_with_a_fresh_one
    answers = [401, SEQS]
    server("GET /bridges/br1/proxy/v1/sequences" => -> { answers.shift || 401 })
    login
    assert_equal SEQS, Everlights::Client.new(cloud: Everlights::Cloud.new(path, **urls)).sequence_list
    assert_equal 2, @fake.requests.count { _1[1] == "/v1/bridges/br1/remotetoken" }
  end

  def test_health_through_the_cloud
    b5010 = {"firmwareVersion" => "B5010", "cloud" => true, "serverReachable" => true, "zones" => [],
             "lastServerCheckin" => Everlights.stamp(Time.now), "lastRadioResponse" => Everlights.stamp(Time.now)}
    local = Everlights.health(b5010)
    assert_equal [false, "local control"], local[0].first(2)
    assert_match(/everlights login/, local[0][2])
    cloud = Everlights.health(b5010, via_cloud: true)
    assert_equal [:info, "local control"], cloud[0].first(2)
    assert_equal [[:info, "clock"], [:info, "memory"]], cloud.select { _1[2].start_with?("not reported") }.map { _1.first(2) }
    assert(cloud.all? { _1[0] })
  end
end
