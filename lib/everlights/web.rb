require "socket"
require "io/wait"
require "json"
require "digest"
require "fileutils"
require_relative "../everlights"

module Everlights
  # `everlights web`: a page on localhost for editing the sync config and applying it.
  #   GET  /             the page
  #   GET  /api/state    config and its version, bridge sequences, the night-by-night schedule, the plan
  #   PUT  /api/config   save the whole config (JSON) to the YAML file, then GET /api/state. Send If-Match: <version>
  #                      and a file edited since then is left alone: 412, with the state as it is on disk.
  #   POST /api/apply    run the plan against the bridge
  #   GET  /api/bridge   status, health checks
  #   POST /api/bridge   {action: "time"} sets the bridge clock to now; {action: "reboot"} restarts it
  #   POST /api/preview  {colors:, effects:} on the lights now; {stop: true} hands back to the calendar;
  #                      {ping: true} keeps it up. With no ping for PREVIEW_GRACE seconds the preview is cleared.
  # ponytail: a thread per connection but one request at a time under a lock; a slow bridge call holds up the next request.
  class Web
    PAGE = File.join(__dir__, "web.html")
    PREVIEW_GRACE = 20
    IDLE = 10 # seconds a connection may sit before sending a request; browsers open spare ones
    # A bad config or an unreachable bridge: the page shows the message.
    FAILURES = [Error, IndexError, ArgumentError, TypeError, Date::Error, JSON::ParserError,
                SystemCallError, Net::OpenTimeout, Net::ReadTimeout].freeze

    def initialize(client, config_path, port: 4567)
      @c, @path, @port = client, config_path, port
      @state_path = Sync.state_path(config_path)
      @lock = Mutex.new
    end

    def start
      server = TCPServer.new("127.0.0.1", @port)
      puts "everlights web: http://localhost:#{@port}  (editing #{@path}; ctrl-c to stop)"
      loop do
        ready = IO.select([server], nil, nil, 5) # wake up now and then to drop an abandoned preview
        expire_preview
        Thread.new(server.accept) { handle(_1) } if ready
      end
    rescue Interrupt
      puts
    ensure
      server&.close
      begin
        @lock.synchronize { stop_preview }
      rescue StandardError => e
        warn "web: couldn't clear the preview: #{e.message}"
      end
    end

    # A bridge error leaves the preview in place, to try again on the next wake-up.
    def expire_preview(now = Time.now)
      @lock.synchronize { stop_preview if @preview_until && now > @preview_until }
    rescue StandardError => e
      warn "web: couldn't clear the preview, will retry: #{e.message}"
    end

    def stop_preview
      return unless @preview_until
      @c.clear
      @preview_until = nil
    end

    def handle(conn)
      return unless conn.wait_readable(IDLE)
      verb, path = conn.gets&.split
      return unless path
      headers = {}
      while (line = conn.gets) && line != "\r\n"
        k, v = line.split(":", 2)
        headers[k.downcase] = v.to_s.strip
      end
      body = conn.read(headers["content-length"].to_i)
      code, type, out = @lock.synchronize { respond(verb, path, headers, body) }
      conn.write "HTTP/1.1 #{code} X\r\nContent-Type: #{type}; charset=utf-8\r\nContent-Length: #{out.bytesize}\r\n" \
                 "Cache-Control: no-store\r\nConnection: close\r\n\r\n#{out}"
    rescue SystemCallError, IOError
      nil # the browser hung up
    ensure
      conn.close
    end

    def respond(verb, path, headers, body)
      route(verb, path, headers, body)
    rescue *FAILURES => e
      [422, "application/json", JSON.generate(error: e.message)]
    rescue StandardError => e
      warn "web: #{e.class}: #{e.message}\n  #{Array(e.backtrace).first(3).join("\n  ")}"
      [500, "application/json", JSON.generate(error: "#{e.class}: #{e.message}")]
    end

    def route(verb, path, headers, body)
      # Another site open in the browser can reach localhost: refuse foreign Host headers (DNS rebinding),
      # and require JSON on writes so cross-site forms can't post without a CORS preflight we never answer.
      return [403, "text/plain", "forbidden"] unless headers["host"].to_s.match?(/\A(localhost|127\.0\.0\.1)(:\d+)?\z/)
      write = verb != "GET"
      return [415, "text/plain", "send JSON"] if write && !headers["content-type"].to_s.start_with?("application/json")

      case [verb, path.split("?").first]
      when %w[GET /] then [200, "text/html", File.read(PAGE)]
      when %w[GET /api/state] then [200, "application/json", JSON.generate(state)]
      when %w[PUT /api/config]
        saved = save(JSON.parse(body), headers["if-match"])
        [saved ? 200 : 412, "application/json", JSON.generate(state)]
      when %w[POST /api/apply]
        plan = Sync.new(@c, load, state_path: @state_path).plan
        plan.apply!
        [200, "application/json", JSON.generate(state.merge(applied: plan.actions.size))]
      when %w[GET /api/bridge]
        status = @c.status
        [200, "application/json", JSON.generate(status: status, now: Everlights.stamp(Time.now),
                                                checks: Everlights.health(status, via_cloud: @c.is_a?(Client) && @c.cloud?).map { |ok, name, text| {ok: ok, name: name, text: text} })]
      when %w[POST /api/bridge]
        case JSON.parse(body)["action"]
        when "time" then @c.set_time(Time.now)
        when "reboot" then @c.reboot
        else raise Error, "unknown action"
        end
        [200, "application/json", JSON.generate(ok: true)]
      when %w[POST /api/preview]
        req = JSON.parse(body)
        if req["stop"] then stop_preview
        elsif req["ping"] then @preview_until &&= Time.now + PREVIEW_GRACE
        else
          colors = Everlights.colors(req["colors"])
          raise Error, "nothing to preview: no colors" if colors.empty?
          @c.set(*colors, effects: Everlights.effects(req["effects"]))
          @preview_until = Time.now + PREVIEW_GRACE
        end
        [200, "application/json", JSON.generate(previewing: !!@preview_until)]
      else [404, "text/plain", "not found"]
      end
    end

    def load
      config = Sync.load_config(@path)
      ENV["TZ"] = config["timezone"] if config["timezone"]
      # an unquoted 18:30 loads as a number; show and save it as "18:30"
      hm = ->(v) { v.is_a?(Integer) ? format("%02d:%02d", *(v / Sync::YAML_MINUTE).divmod(60)) : v }
      [config["defaults"], *config["schedule"]].each do |r|
        %w[start end].each { r[_1] = hm.(r[_1]) if r.is_a?(Hash) && r.key?(_1) }
      end
      config
    end

    def version = Digest::SHA256.file(@path).hexdigest

    # False, writing nothing, when the file isn't at `version` any more (edited by hand); no version skips the check.
    def save(config, version = nil)
      raise Error, "config must be an object" unless config.is_a?(Hash)
      text = File.read(@path)
      return false if version && version != Digest::SHA256.hexdigest(text)
      # ponytail: one backup, never replaced: the file as it was before the page first saved it.
      # Comments added by hand after that are lost on the next save; dated backups if that bites.
      bak = "#{@path}.bak"
      FileUtils.cp(@path, bak) unless File.exist?(bak)
      header = text[/\A(?:#.*\n|[ \t]*\n)*/]
      File.write(@path, header + Web.dump(config))
      true
    end

    # YAML like a person writes it: lists of plain values and small maps on one line.
    def self.dump(config)
      doc = YAML.parse_stream(YAML.dump(config))
      doc.each do |n|
        leaves = n.respond_to?(:children) && n.children&.all?(Psych::Nodes::Scalar)
        n.style = Psych::Nodes::Sequence::FLOW if n.is_a?(Psych::Nodes::Sequence) && leaves
        n.style = Psych::Nodes::Mapping::FLOW if n.is_a?(Psych::Nodes::Mapping) && leaves && n.children.size <= 4
      end
      doc.to_yaml.delete_prefix("---\n")
    end

    def state
      config = load
      out = {config: config, version: version, effects: EFFECTS, today: Date.today.iso8601,
             horizon: Integer(config["horizon_days"] || 120, exception: false) || 120, host: (@c.to_s if @c.is_a?(Client))}
      sync = Sync.new(@c, config, state_path: @state_path)
      plan = begin
        sync.plan
      rescue *FAILURES => e
        out[:error] = e.message
        nil
      end
      if (bridge = sync.bridge_seqs) # read by the plan, even one that found config problems
        mine = (config["sequences"] || {}).keys.map(&:downcase)
        out[:bridge_sequences] = bridge.reject { mine.include?(_1["alias"].downcase) }.sort_by { _1["alias"].downcase }
                                       .map { {name: _1["alias"], colors: _1["pattern"], effects: _1["effects"], builtin: _1["id"].start_with?(BUILTIN_PREFIX)} }
      end
      return out unless plan

      nights = {}
      plan.shows.each do |rule, list|
        list.each { |s, e| nights[s.to_date.iso8601] = {rule: rule, start: s.strftime("%H:%M"), end: e.strftime("%H:%M")} }
      end
      plan.skips.each do |d, rule, why|
        next if why.end_with?(" wins this night")
        nights[d.iso8601] ||= {rule: rule, note: why} # tonight's show, once under way, is in shows and stays
      end
      out.merge(nights: nights, plan: plan.actions.map { {kind: _1.kind, op: _1.op, name: _1.name, detail: _1.detail} })
    rescue *FAILURES => e
      (out || {config: config}).merge(error: e.message)
    end
  end
end
