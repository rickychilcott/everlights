require "net/http"
require "json"
require "fileutils"

module Everlights
  # The EverLights cloud, for bridges on firmware B5010 and later, which turned off local control.
  # The app server signs in and hands out a token per bridge. The tunnel then serves the bridge's own
  # API under /bridges/{serial}/proxy/v1/. Protocol mapped by github.com/borski/everlightsv3_cloud.
  #
  #   Everlights::Cloud.login("me@example.com", password)   # once; saves tokens, never the password
  #   el = Everlights::Client.new(cloud: Everlights::Cloud.new)
  class Cloud
    API = "https://appserver-v2.myeverlights.com/v1"
    TUNNEL = "https://remote.myeverlights.com/bridges"
    MARGIN = 300 # renew a token this many seconds before it expires
    TIMEOUT = 15

    def self.default_path = ENV["EVERLIGHTS_CLOUD"] || File.join(Dir.home, ".config", "everlights", "cloud.json")

    # Signs in and saves the tokens and the bridge to use: `bridge` (a serial), or the account's first.
    def self.login(email, password, bridge: nil, path: default_path, api: API, tunnel: TUNNEL)
      cloud = new(path, api: api, tunnel: tunnel)
      cloud.grant("grant_type" => "password", "username" => email, "password" => password)
      all = cloud.bridges
      raise Error, "no bridges on this EverLights account" if all.empty?
      pick = bridge ? all.find { _1["serial"] == bridge } : all.first
      raise Error, "no bridge #{bridge} on this account; it has #{all.map { _1["serial"] }.join(", ")}" unless pick
      cloud.data.merge!("email" => email, "bridge" => pick["serial"])
      cloud.save
      [cloud, all]
    end

    attr_reader :tunnel

    def initialize(path = Cloud.default_path, api: API, tunnel: TUNNEL)
      @path, @api, @tunnel = path, api, tunnel
    end

    def logged_in? = File.exist?(@path)
    def logout = FileUtils.rm_f(@path)
    def bridge = data["bridge"]
    def data = @data ||= (logged_in? ? JSON.parse(File.read(@path)) : {})

    def save
      FileUtils.mkdir_p(File.dirname(@path), mode: 0o700)
      File.write(@path, JSON.pretty_generate(data), perm: 0o600)
      File.chmod(0o600, @path) # perm: only applies when the file is new
    end

    # The account's bridges: [{"serial", "name", "firmware"}]
    def bridges
      api(Net::HTTP::Get, "/bridges").reject { _1["unpairedDate"] }.map do |b|
        {"serial" => b["bridgeSerial"], "name" => b["alias"], "firmware" => b.dig("bridge", "firmwareVersion")}
      end
    end

    # The tunnel's token for the bridge, renewed when near expiry or when `fresh`.
    def tunnel_token(fresh: false)
      saved = data["tunnel_token"]
      return saved if saved && !fresh && Time.now.to_i < data["tunnel_expires"].to_i - MARGIN
      token = api(Net::HTTP::Get, "/bridges/#{bridge}/remotetoken")["token"] or raise Error, "no tunnel token in the cloud's reply"
      data.merge!("tunnel_token" => token, "tunnel_expires" => expiry(token))
      save
      token
    end

    def grant(params)
      res = call(Net::HTTP::Post, "#{@api}/oauth/token", body: params)
      raise Error, "EverLights didn't accept the #{params["grant_type"] == "password" ? "email or password" : "saved login; run `everlights login` again"}" if %w[400 401 403].include?(res.code)
      raise Error, "login -> #{res.code}: #{res.body}" unless res.is_a?(Net::HTTPSuccess)
      body = JSON.parse(res.body)
      data.merge!("access_token" => body.fetch("access_token"), "refresh_token" => body["refresh_token"] || data["refresh_token"],
                  "access_expires" => Time.now.to_i + Integer(body["expires_in"] || 3600))
    end

    private

    # ponytail: the refresh token changes on every use. Two processes renewing at the same moment
    # (cron sync while `web` runs) leave one with a dead token; it then asks for `everlights login`.
    def access_token(fresh: false)
      return data["access_token"] if !fresh && Time.now.to_i < data["access_expires"].to_i - MARGIN
      @data = nil # another process may have renewed it since we read the file
      return data["access_token"] if !fresh && Time.now.to_i < data["access_expires"].to_i - MARGIN
      raise Error, "not logged in; run `everlights login`" unless data["refresh_token"]
      grant("grant_type" => "refresh_token", "refresh_token" => data["refresh_token"])
      save
      data["access_token"]
    end

    def api(verb, path)
      res = call(verb, "#{@api}#{path}", token: access_token)
      # the app server answers a stale token with 400 "Authorization failure", not 401
      res = call(verb, "#{@api}#{path}", token: access_token(fresh: true)) if %w[400 401 403].include?(res.code)
      raise Error, "cloud #{verb::METHOD} #{path} -> #{res.code}: #{res.body}" unless res.is_a?(Net::HTTPSuccess)
      JSON.parse(res.body)
    end

    def call(verb, url, token: nil, body: nil)
      uri = URI(url)
      req = verb.new(uri, "Accept" => "application/json", "Content-Type" => "application/json")
      req["Authorization"] = "Bearer #{token}" if token
      req.body = JSON.generate(body) if body
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: TIMEOUT, read_timeout: TIMEOUT) { _1.request(req) }
    end

    # A JWT's exp claim, read without verifying; an hour if it has none
    def expiry(token)
      Integer(JSON.parse(token.split(".")[1].tr("-_", "+/").unpack1("m"))["exp"])
    rescue StandardError
      Time.now.to_i + 3600
    end
  end
end
