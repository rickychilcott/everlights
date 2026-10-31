require "net/http"
require "json"
require "securerandom"
require "time"

# Client for the EverLights Smart Lights Bridge local HTTP API (no auth, port 80).
# Endpoints from github.com/weswitt/everlights3 OpenAPI spec, verified on firmware B4042.
#
#   el = Everlights::Client.new("192.168.1.50")
#   el.play "Hallows Eve"
#   el.sequences.add "Candy Cane", "FF0000", "FFFFFF", effects: {chase: 60}
#   el.calendar.add "2026-12-01", "Christmas", "Candy Cane:30,Christmas", through: "2027-01-01"
#   el.calendar.list(limit: 30)
#   el.calendar.remove "2026-12-25", "Christmas"
module Everlights
  Error = Class.new(StandardError)

  ALL_ZONES = "000000000000" # what the app writes into zoneSerials for "every zone"
  PERSONAL_GROUP = "Personal/" # where the app files user-made sequences
  BUILTIN_PREFIX = "00000000-0000-0000-0000-" # ids of EverLights' stock sequences
  DEFAULT_SECONDS = 20
  EFFECTS = %w[bars blink chase fade gradient lightning melt pingPong random reverseChase strobe twinkle wipe].freeze

  class Client
    def initialize(host = nil, timeout: 10)
      host ||= ENV["EVERLIGHTS_HOST"]
      raise Error, "no host: pass one or set EVERLIGHTS_HOST" unless host
      uri = URI("http://#{host}")
      @http = Net::HTTP.new(uri.host, uri.port)
      @http.open_timeout = @http.read_timeout = timeout
    end

    def sequences = Sequences.new(self)
    def calendar = Calendar.new(self)

    def status = get("/v1")
    def zones = get("/v1/zones")
    def zone_serials = zones.map { _1["serial"] }

    # Show something right now. During a running show this lasts only until the show's next sequence change.
    def set(*colors, effects: {}, zones: nil)
      (zones || zone_serials).each { set_program(_1, pattern: colors.flatten, effects: effects) }
    end

    def play(name, zones: nil)
      seq = find_sequence(name)
      (zones || zone_serials).each { set_program(_1, pattern: seq["pattern"], effects: seq["effects"]) }
      seq
    end

    # Hands control back to the calendar.
    def clear(zones: nil) = (zones || zone_serials).each { clear_program(_1) }

    # Lights dark: an empty pattern, as theOrakle/everlightsv3 does. A running show resumes at its next change.
    def off(zones: nil) = (zones || zone_serials).each { set_program(_1, pattern: []) }

    # What each zone shows right now:
    #   {serial => {name:, show:, off:, pattern:, effects:}}
    # name: the sequence (the bridge names it during a show; otherwise matched by colors+effects), nil = custom colors
    # show: the running calendar entry it belongs to, if any
    def now_playing(zones: nil)
      seqs = sequence_list
      now = Time.now
      running = calendar.list(limit: 1, now: now).select { _1[:start] <= now && now <= _1[:finish] }
      (zones || zone_serials).to_h do |zone|
        prog = program(zone) || {}
        pattern, effects = prog["pattern"] || [], prog["effects"] || []
        name = prog["alias"] || seqs.find { _1["pattern"] == pattern && _1["effects"] == effects }&.fetch("alias")
        name = nil if pattern.empty?
        show = name && running.find { |s| s[:sequences].any? { |seq_name, _| seq_name == name } }&.fetch(:name)
        [zone, {name: name, show: show, off: pattern.empty?, pattern: pattern, effects: effects}]
      end
    end

    # --- raw endpoints ---

    def program(zone) = get("/v1/zones/#{zone}/sequence")

    def set_program(zone, pattern:, effects: {})
      request(Net::HTTP::Post, "/v1/zones/#{zone}/sequence",
              colorMode: "rgb", pattern: colors(pattern), effects: effects_body(effects))
    end

    def clear_program(zone) = request(Net::HTTP::Delete, "/v1/zones/#{zone}/sequence")

    def sequence_list = get("/v1/sequences")

    def find_sequence(name_or_id)
      sequence_list.find { _1["id"] == name_or_id || _1["alias"].casecmp?(name_or_id.to_s.strip) } ||
        raise(Error, "no sequence named #{name_or_id.inspect}")
    end

    def create_sequence(name, pattern:, effects: {})
      request(Net::HTTP::Post, "/v1/sequences",
              id: SecureRandom.uuid, alias: name, groups: [PERSONAL_GROUP], colorMode: "rgb",
              pattern: colors(pattern), effects: effects_body(effects), lastChanged: stamp(Time.now))
    end

    # seq: a hash from #sequence_list; pattern and effects replace its own
    def update_sequence(seq, pattern:, effects: {})
      request(Net::HTTP::Put, "/v1/sequences/#{seq["id"]}",
              seq.merge("pattern" => colors(pattern), "effects" => effects_body(effects), "lastChanged" => stamp(Time.now)))
    end

    def delete_sequence(id) = request(Net::HTTP::Delete, "/v1/sequences/#{id}")

    def event_list = get("/v1/events")

    # sequences: [[sequence_id, seconds], ...]  occurrences: [[start_time, end_time], ...]
    def create_event(name, sequences:, occurrences:, zones: [ALL_ZONES], flags: [])
      request(Net::HTTP::Post, "/v1/events",
              id: SecureRandom.uuid, alias: name, group: "User Created",
              sequences: sequences.map { |id, secs| {sequenceId: id, duration: secs} },
              zoneSerials: zones,
              occurrences: occurrences.map { |s, e| {start: stamp(s), end: stamp(e)} },
              flags: flags, lastChanged: stamp(Time.now))
    end

    # event: a hash from #event_list, edited
    def update_event(event)
      request(Net::HTTP::Put, "/v1/events/#{event["id"]}", event.merge("lastChanged" => stamp(Time.now)))
    end

    def delete_event(id) = request(Net::HTTP::Delete, "/v1/events/#{id}")

    def set_time(time = Time.now) = request(Net::HTTP::Put, "/v1/time", time: stamp(time))
    def reboot = get("/v1/reboot")

    private

    def get(path) = request(Net::HTTP::Get, path)

    def request(verb, path, body = nil)
      req = verb.new(path, "Content-Type" => "application/json")
      req.body = JSON.generate(body) if body
      res = @http.request(req)
      raise Error, "#{verb::METHOD} #{path} -> #{res.code}: #{res.body}" unless res.is_a?(Net::HTTPSuccess)
      res.body.to_s.empty? ? nil : JSON.parse(res.body)
    end

    def colors(pattern)
      pattern.map do |c|
        hex = c.to_s.delete_prefix("#").upcase
        raise Error, "bad color #{c.inspect}, want RRGGBB" unless hex.match?(/\A\h{6}\z/)
        hex
      end
    end

    # {chase: 100} or the API's [{"effectType" => "chase", "value" => 100}]
    def effects_body(effects)
      effects.map do |e|
        type, value = e.is_a?(Hash) ? e.values_at("effectType", "value") : e
        raise Error, "unknown effect #{type}, want one of: #{EFFECTS.join(" ")}" unless EFFECTS.include?(type.to_s)
        {effectType: type.to_s, value: Integer(value || 128)}
      end
    end

    def stamp(t) = (t.is_a?(Time) ? t : Time.parse(t.to_s)).getutc.iso8601(6)
  end

  class Sequences
    def initialize(client) = @c = client

    def list(filter = nil) = @c.sequence_list.select { _1["alias"].downcase.include?(filter.to_s.downcase) }

    def add(name, *colors, effects: {}) = @c.create_sequence(name, pattern: colors.flatten, effects: effects)

    # Replaces its colors and effects; calendar entries using it keep working.
    def update(name, *colors, effects: {}) = @c.update_sequence(own(name), pattern: colors.flatten, effects: effects)

    def remove(name)
      seq = own(name)
      users = @c.event_list.select { |e| e["sequences"].any? { _1["sequenceId"] == seq["id"] } }
      raise Error, "#{seq["alias"]} is used by: #{users.map { _1["alias"] }.join(", ")}" if users.any?
      @c.delete_sequence(seq["id"])
    end

    private

    def own(name)
      seq = @c.find_sequence(name)
      raise Error, "#{seq["alias"]} is built in, leaving it" if seq["id"].start_with?(BUILTIN_PREFIX)
      seq
    end
  end

  class Calendar
    def initialize(client) = @c = client

    # Upcoming shows, one hash per night, soonest first.
    def list(limit: 365, now: Time.now)
      names = @c.sequence_list.to_h { [_1["id"], _1["alias"]] }
      horizon = now + limit * 86_400
      @c.event_list.flat_map do |e|
        e["occurrences"].filter_map do |o|
          s, f = Time.parse(o["start"]).localtime, Time.parse(o["end"]).localtime
          next if f < now || s > horizon
          {date: s.to_date, start: s, finish: f, dusk: e["flags"].include?("StartAtDusk"),
           name: e["alias"], event_id: e["id"],
           sequences: e["sequences"].map { [names.fetch(_1["sequenceId"], _1["sequenceId"]), _1["duration"]] }}
        end
      end.sort_by { _1[:start] }
    end

    # sequences: "A:20,B:30" or {"A" => 20, "B" => 30} or ["A", "B"]; seconds default to 20.
    # No start: means start at dusk. finish earlier than start means the next morning.
    def add(date, name, sequences, start: nil, finish: "23:00", through: nil)
      first = to_date(date)
      last = through ? to_date(through) : first
      raise Error, "through (#{last}) is before #{first}" if last < first
      seqs = parse_sequences(sequences).map { |ref, secs| [@c.find_sequence(ref)["id"], secs] }
      start_hm = start ? hm(start) : [17, 0] # ponytail: placeholder; the StartAtDusk flag moves it
      end_hm = hm(finish)
      occurrences = (first..last).map do |d|
        s, f = at(d, start_hm), at(d, end_hm)
        [s, f <= s ? at(d + 1, end_hm) : f]
      end
      @c.create_event(name, sequences: seqs, occurrences: occurrences, flags: start ? [] : ["StartAtDusk"])
    end

    # Drops that night from every event with this name; deletes events left empty.
    def remove(date, name)
      day = to_date(date)
      removed = 0
      @c.event_list.select { _1["alias"].casecmp?(name) }.each do |e|
        keep, drop = e["occurrences"].partition { Time.parse(_1["start"]).localtime.to_date != day }
        next if drop.empty?
        removed += drop.size
        keep.empty? ? @c.delete_event(e["id"]) : @c.update_event(e.merge("occurrences" => keep))
      end
      raise Error, "nothing named #{name.inspect} on #{day}" if removed.zero?
      removed
    end

    private

    def parse_sequences(seqs)
      pairs = case seqs
              when String then seqs.split(",").map { _1.strip.split(/:(?=\d+\z)/) }
              else seqs.map { Array(_1) } # Hash yields pairs, Array yields names or pairs
              end
      pairs.map { |ref, secs| [ref, Integer(secs || DEFAULT_SECONDS)] }
    end

    def to_date(d) = d.respond_to?(:to_date) ? d.to_date : Date.parse(d.to_s)
    def hm(t) = t.to_s.split(":").map { Integer(_1, 10) }
    def at(d, h_m) = Time.new(d.year, d.month, d.day, *h_m) # wall clock, so DST doesn't shift shows
  end
end
