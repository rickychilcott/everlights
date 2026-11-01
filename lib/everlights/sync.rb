require "yaml"

module Everlights
  # Builds sequences and calendar entries on the bridge from a config (see config/everlights.example.yml).
  #
  #   config = Everlights::Sync.load_config("config/everlights.yml")
  #   plan = Everlights::Sync.new(el, config, state_path: "config/.sync-state.yml").plan  # raises Error listing every config problem
  #   puts plan
  #   plan.apply!
  #
  # Sync only creates, changes and deletes what it created itself (tracked in the state file).
  # Times are local: set ENV["TZ"] (the CLI uses the config's `timezone:`) before planning.
  class Sync
    MARGIN = 15 * 60 # never add a night that starts sooner than this
    ORDINALS = {"1st" => 1, "first" => 1, "2nd" => 2, "second" => 2, "3rd" => 3, "third" => 3,
                "4th" => 4, "fourth" => 4, "5th" => 5, "fifth" => 5, "last" => -1}.freeze
    PHASE = {sequence: {adopt: 0, create: 0, update: 0, delete: 2, untrack: 2, forget: 2},
             event: Hash.new(1)}.freeze # sequences exist before events use them; deleted after events stop

    Action = Struct.new(:kind, :op, :name, :detail, :run)

    Plan = Struct.new(:actions, :skips, :horizon, :sync) do
      def empty? = actions.empty?
      def apply! = sync.apply(self)

      def to_s
        mark = {create: "+", update: "~", delete: "-", adopt: "@", untrack: "=", forget: "="}
        out = []
        {sequence: "Sequences", event: "Calendar (next #{horizon} days)"}.each do |kind, title|
          rows = actions.select { _1.kind == kind }
          next if rows.empty?
          out << title
          rows.each { |a| out << "  #{mark[a.op]} #{a.op.to_s.ljust(7)} #{a.name}#{": #{a.detail}" if a.detail}" }
        end
        lost, other = skips.partition { |_, _, why| why.end_with?(" wins this night") }
        dark, other = other.partition { |_, _, why| why.start_with?("dusk (") }
        unless other.empty?
          out << "Skipped"
          other.each { |d, rule, why| out << "    #{d.strftime("%a %Y-%m-%d")}  #{rule}: #{why}" }
        end
        unless dark.empty?
          out << "No show: dusk is after the end time"
          dark.group_by { _2 }.each do |rule, rows|
            out << "    #{rule}: #{nights(rows.map(&:first))} (dusk up to #{rows.map { _3[/\d\d:\d\d/] }.max}, ends #{rows[0][2][/(\d\d:\d\d) end/, 1]})"
          end
        end
        unless lost.empty?
          out << "Nights taken by a higher rule"
          lost.group_by { |_, rule, why| [rule, why.delete_suffix(" wins this night")] }.each do |(rule, winner), rows|
            out << "    #{rule}: #{nights(rows.map(&:first)).sub(", ", " to #{winner} (")})"
          end
        end
        out << "Nothing to change." if empty?
        out.join("\n")
      end

      def nights(days) # "3 nights, Jun 26 – Jun 28"
        span = days.size == 1 ? days[0].strftime("%b %-d") : "#{days[0].strftime("%b %-d")} – #{days[-1].strftime("%b %-d")}"
        "#{days.size} night#{"s" unless days.size == 1}, #{span}"
      end
    end

    def self.load_config(path)
      config = YAML.safe_load_file(path, permitted_classes: [Date]) || {}
      # YAML 1.1 reads the key `on:` as boolean true; put it back
      Array(config["schedule"]).each { |r| r["on"] = r.delete(true) if r.is_a?(Hash) && r.key?(true) }
      config
    rescue Psych::SyntaxError => e
      raise Error, "#{path}: #{e.message}"
    end

    def initialize(client, config, state_path: nil, adopt: false, now: Time.now)
      @c, @cfg, @state_path, @adopt, @now = client, config || {}, state_path, adopt, now
    end

    def plan
      @errors = []
      @state = load_state
      bridge_seqs = @c.sequence_list
      bridge_events = @c.event_list
      actions = @adopt ? adopt(bridge_seqs, bridge_events) : []
      owned_seq_ids = @state["sequences"].values
      owned_event_ids = @state["events"].values
      config_seqs = @cfg["sequences"] || {}

      # Names a rule can use: built-ins and app-made sequences, plus the config's own.
      seq_ids = {}
      bridge_seqs.each { |s| seq_ids[s["alias"].downcase] ||= s["id"] unless owned_seq_ids.include?(s["id"]) }

      config_seqs.each do |name, spec|
        spec ||= {}
        pattern = check("sequence #{name.inspect}") { Everlights.colors(spec["colors"]) }
        effects = check("sequence #{name.inspect}") { Everlights.effects(spec["effects"]) }
        @errors << "sequence #{name.inspect}: needs colors" if pattern&.empty?
        clash = bridge_seqs.find { _1["alias"].casecmp?(name) && !owned_seq_ids.include?(_1["id"]) }
        if clash
          @errors << if clash["id"].start_with?(BUILTIN_PREFIX)
                       "sequence #{name.inspect} has the same name as a built-in; rename it"
                     else
                       "sequence #{name.inspect} already exists on the bridge (made in the app?); rename it or run with --adopt"
                     end
          next
        end
        current = bridge_seqs.find { _1["id"] == @state["sequences"][name] }
        id = current ? current["id"] : SecureRandom.uuid
        seq_ids[name.downcase] = id
        next unless pattern && effects
        if current.nil?
          actions << Action.new(:sequence, :create, name, "#{pattern.size} color#{"s" unless pattern.size == 1}",
                                -> { @c.create_sequence(name, pattern: pattern, effects: effects, id: id); @state["sequences"][name] = id })
        elsif current["pattern"] != pattern || current["effects"] != effects
          actions << Action.new(:sequence, :update, name, "#{pattern.size} color#{"s" unless pattern.size == 1}",
                                -> { @c.update_sequence(current, pattern: pattern, effects: effects) })
        end
      end

      rules = (@cfg["schedule"] || []).each_with_index.filter_map { |r, i| compile_rule(r || {}, i, seq_ids) }
      dupes = Array(@cfg["schedule"]).filter_map { _1["name"].to_s.strip.downcase if _1.is_a?(Hash) }
                                     .reject(&:empty?).tally.select { _2 > 1 }.keys
      @errors << "rule names must be unique: #{dupes.join(", ")}" if dupes.any?
      rules.each do |r|
        clash = bridge_events.find { _1["alias"].casecmp?(r[:name]) && !owned_event_ids.include?(_1["id"]) }
        @errors << "rule #{r[:name].inspect} has the same name as calendar entry #{clash["alias"].inspect} made outside sync; rename it or run with --adopt" if clash
      end
      raise Error, "config problems, nothing applied:\n  - #{@errors.uniq.join("\n  - ")}" if @errors.any?

      # Which rule gets each night, and when it starts and ends.
      horizon = Integer(@cfg["horizon_days"] || 120)
      today = @now.to_date
      others = bridge_events.reject { owned_event_ids.include?(_1["id"]) }.flat_map do |e|
        e["occurrences"].map { |o| [e["alias"], Time.parse(o["start"]), Time.parse(o["end"])] }
      end
      wanted = Hash.new { |h, k| h[k] = [] }
      skips = []
      (today..today + horizon).each do |d|
        winner, *losers = rules.select { _1[:matches].(d) }
        next unless winner
        losers.each { skips << [d, _1[:name], "#{winner[:name]} wins this night"] }
        s, e = window(winner, d)
        if e.nil?
          skips << [d, winner[:name], "dusk (#{s.strftime("%H:%M")}) is after its #{format("%02d:%02d", *winner[:end])} end"]
        elsif s <= @now + MARGIN
          skips << [d, winner[:name], "already started or starts within 15 minutes"]
        elsif (other = others.find { |_, os, oe| os < e && s < oe })
          skips << [d, winner[:name], "#{other[0].inspect} (made outside sync) has this night"]
        else
          wanted[winner[:name]] << [s, e]
        end
      end

      # One calendar entry per rule. Nights already under way stay; ended ones are dropped.
      live = ->(event) { event["occurrences"].select { |o| Time.parse(o["start"]) <= @now + MARGIN && Time.parse(o["end"]) > @now } }
      rules.each do |r|
        nights = wanted[r[:name]]
        current = bridge_events.find { _1["id"] == @state["events"][r[:name]] }
        kept = current ? live.(current).map { [Time.parse(_1["start"]), Time.parse(_1["end"])] } : []
        occurrences = kept + nights
        flags = r[:start][:dusk] ? ["StartAtDusk"] : []
        if current.nil?
          next if nights.empty?
          id = SecureRandom.uuid
          actions << Action.new(:event, :create, r[:name], describe(r, nights), lambda {
            @c.create_event(r[:name], sequences: r[:seqs], occurrences: nights, flags: flags, id: id)
            @state["events"][r[:name]] = id
          })
        elsif occurrences.empty?
          actions << Action.new(:event, :delete, r[:name], "no nights left in the window",
                                -> { @c.delete_event(current["id"]); @state["events"].delete(r[:name]) })
        elsif changed?(current, r[:seqs], occurrences, flags)
          actions << Action.new(:event, :update, r[:name], describe(r, nights), lambda {
            @c.update_event(current.merge("sequences" => r[:seqs].map { |sid, secs| {"sequenceId" => sid, "duration" => secs} },
                                          "occurrences" => occurrences.map { |s, e| {"start" => Everlights.stamp(s), "end" => Everlights.stamp(e)} },
                                          "flags" => flags))
          })
        end
      end

      # Rules removed from the config: delete their entries, but never cut off a show that's under way.
      (@state["events"].keys - rules.map { _1[:name] }).each do |name|
        current = bridge_events.find { _1["id"] == @state["events"][name] }
        if current.nil?
          actions << Action.new(:event, :forget, name, "already gone from the bridge", -> { @state["events"].delete(name) })
        elsif (keep = live.(current)).empty?
          actions << Action.new(:event, :delete, name, "removed from config",
                                -> { @c.delete_event(current["id"]); @state["events"].delete(name) })
        elsif keep != current["occurrences"]
          actions << Action.new(:event, :update, name, "removed from config; keeping tonight's show, deleted next sync",
                                -> { @c.update_event(current.merge("occurrences" => keep)) })
        end
      end

      # Sequences removed from the config: delete, unless something made outside sync still plays them.
      (@state["sequences"].keys - config_seqs.keys).each do |name|
        id = @state["sequences"][name]
        if bridge_seqs.none? { _1["id"] == id }
          actions << Action.new(:sequence, :forget, name, "already gone from the bridge", -> { @state["sequences"].delete(name) })
        elsif (user = bridge_events.find { |e| !owned_event_ids.include?(e["id"]) && e["sequences"].any? { _1["sequenceId"] == id } })
          actions << Action.new(:sequence, :untrack, name, "still used by #{user["alias"].inspect}; keeping it, no longer synced",
                                -> { @state["sequences"].delete(name) })
        else
          actions << Action.new(:sequence, :delete, name, "removed from config",
                                -> { @c.delete_sequence(id); @state["sequences"].delete(name) })
        end
      end

      Plan.new(actions, skips, horizon, self)
    end

    def apply(plan)
      plan.actions.each_with_index.sort_by { |a, i| [PHASE[a.kind][a.op], i] }.each { |a, _| a.run.() }
    ensure
      save_state
    end

    # --- dates ---

    # Anonymous Gregorian algorithm.
    def self.easter(year)
      a, b, c = year % 19, year / 100, year % 100
      d, e = b / 4, b % 4
      g = (b - (b + 8) / 25 + 1) / 3
      h = (19 * a + b - d - g + 15) % 30
      l = (32 + 2 * e + 2 * (c / 4) - h - (c % 4)) % 7
      m = (a + 11 * h + 22 * l) / 451
      Date.new(year, (h + l - 7 * m + 114) / 31, ((h + l - 7 * m + 114) % 31) + 1)
    end

    # n = 1..5, or -1 for last; nil when the month has no such day
    def self.nth_weekday(year, month, wday, n)
      if n.negative?
        last = Date.new(year, month, -1)
        return last - (last.wday - wday) % 7
      end
      first = Date.new(year, month, 1)
      d = first + (wday - first.wday) % 7 + 7 * (n - 1)
      d.month == month ? d : nil
    end

    # NOAA sunrise/sunset algorithm (Almanac for Computers, 1990). Within a minute or two of published times.
    def self.sunset(date, lat, lon)
      rad = Math::PI / 180
      lng_hour = lon / 15.0
      t = date.yday + ((18 - lng_hour) / 24)
      m = 0.9856 * t - 3.289
      l = (m + 1.916 * Math.sin(m * rad) + 0.020 * Math.sin(2 * m * rad) + 282.634) % 360
      ra = (Math.atan(0.91764 * Math.tan(l * rad)) / rad) % 360
      ra = (ra + (l / 90).floor * 90 - (ra / 90).floor * 90) / 15
      sin_dec = 0.39782 * Math.sin(l * rad)
      cos_dec = Math.cos(Math.asin(sin_dec))
      cos_h = (Math.cos(90.833 * rad) - sin_dec * Math.sin(lat * rad)) / (cos_dec * Math.cos(lat * rad))
      raise Error, "no sunset at latitude #{lat} on #{date}" unless cos_h.between?(-1, 1)
      ut = (Math.acos(cos_h) / rad / 15 + ra - 0.06571 * t - 6.622 - lng_hour) % 24
      time = (Time.utc(date.year, date.month, date.day) + ut * 3600).localtime
      time += 86_400 while time.to_date < date # western longitudes: sunset is the next UTC day
      time -= 86_400 while time.to_date > date
      time
    end

    private

    def check(where)
      yield
    rescue Error, ArgumentError, TypeError => e
      @errors << "#{where}: #{e.message}"
      nil
    end

    def load_state
      state = @state_path && File.exist?(@state_path) ? YAML.safe_load_file(@state_path) : nil
      {"sequences" => {}, "events" => {}}.merge(state || {})
    end

    def save_state
      return unless @state_path && @state
      File.write(@state_path, "# Written by `everlights sync`: what it created on the bridge. Don't edit.\n#{YAML.dump(@state)}")
    end

    def adopt(bridge_seqs, bridge_events)
      actions = []
      (@cfg["sequences"] || {}).each_key do |name|
        next if @state["sequences"].key?(name)
        s = bridge_seqs.find { _1["alias"].casecmp?(name) && !_1["id"].start_with?(BUILTIN_PREFIX) }
        next unless s
        @state["sequences"][name] = s["id"]
        actions << Action.new(:sequence, :adopt, name, "now managed by sync", -> {})
      end
      (@cfg["schedule"] || []).each do |r|
        name = r && r["name"].to_s
        next if name.to_s.empty? || @state["events"].key?(name)
        e = bridge_events.find { _1["alias"].casecmp?(name) }
        next unless e
        @state["events"][name] = e["id"]
        actions << Action.new(:event, :adopt, name, "now managed by sync", -> {})
      end
      actions
    end

    def compile_rule(r, i, seq_ids)
      name = r["name"].to_s.strip
      where = name.empty? ? "rule ##{i + 1}" : "rule #{name.inspect}"
      @errors << "#{where}: needs a name" if name.empty?
      defaults = {"start" => "dusk", "end" => "23:00", "seconds" => DEFAULT_SECONDS}.merge(@cfg["defaults"] || {})
      matches = matcher(r, where)
      start = check(where) { parse_start(r.fetch("start", defaults["start"])) }
      finish = check(where) { parse_hm(r.fetch("end", defaults["end"])) }
      if start&.dig(:dusk) && !(@cfg.dig("location", "lat") && @cfg.dig("location", "lon"))
        @errors << "#{where}: dusk needs `location: {lat:, lon:}` in the config"
      end
      seconds = r.fetch("seconds", defaults["seconds"])
      @errors << "#{where}: needs sequences" if Array(r["sequences"]).empty?
      seqs = Array(r["sequences"]).map do |spec|
        ref, secs = spec.to_s.strip.split(/:(?=\d+\z)/)
        id = seq_ids[ref.to_s.downcase]
        @errors << "#{where}: unknown sequence #{ref.inspect}" unless id
        [id, check(where) { Integer(secs || seconds) }]
      end
      return nil if name.empty? || !matches || !start || !finish || seqs.empty? || seqs.flatten.include?(nil)
      {name: name, matches: matches, start: start, end: finish, seqs: seqs}
    end

    def matcher(r, where)
      on, every, range = r["on"], r["every"], r.key?("from") || r.key?("to")
      if [on, every].compact.size + (range && !every ? 1 : 0) != 1
        @errors << "#{where}: needs exactly one of `on:`, `from:`/`to:`, or `every:`"
        return nil
      end
      return check(where) { on_matcher(on) } if on
      in_range = range ? check(where) { range_matcher(r["from"], r["to"]) } : ->(_) { true }
      return in_range unless every && in_range
      days = check(where) { Array(every).map { weekday(_1) } }
      days && ->(d) { days.include?(d.wday) && in_range.(d) }
    end

    def on_matcher(v)
      at = date_expr(v)
      ->(d) { (d.year - 1..d.year + 1).any? { at.(_1) == d } } # offsets can cross a year boundary
    end

    def range_matcher(from, to)
      raise Error, "`from:` and `to:` go together" unless from && to
      first_of, last_of = date_expr(from), date_expr(to)
      lambda do |d|
        (d.year - 1..d.year).any? do |y|
          first, last = first_of.(y), last_of.(y)
          last = last_of.(y + 1) if first && last && last < first # e.g. Dec 1 to Jan 6 wraps the new year
          first && last && d.between?(first, last)
        end
      end
    end

    # A date expression -> lambda(year) -> Date or nil:
    #   "2027-03-14", "Dec 25", "4th Thursday of November", "last Monday of May", "Easter",
    #   each optionally shifted by days: "Easter-47", "4th Thursday of November+1"
    def date_expr(v)
      return ->(_) { v } if v.is_a?(Date)
      text = v.to_s.strip
      begin
        base_expr(text)
      rescue Error => e
        m = text.match(/\A(.*\S)\s*([+-])\s*(\d+)\z/) or raise e
        base = base_expr(m[1]) # with an offset, report what's wrong with the date before it
        days = m[3].to_i * (m[2] == "-" ? -1 : 1)
        ->(y) { base.(y)&.+(days) }
      end
    end

    def base_expr(text)
      case text
      when /\A\d{4}-\d{1,2}-\d{1,2}\z/
        date = Date.parse(text)
        ->(_) { date }
      when /\Aeaster\z/i
        ->(y) { Sync.easter(y) }
      when /\A(\S+)\s+(\S+)\s+of\s+(\S+)\z/i
        ordinal, day_name, month_name = $1, $2, $3
        nth = ORDINALS[ordinal.downcase] or raise Error, "can't read #{text.inspect}; try \"4th Thursday of November\" or \"last Monday of May\""
        wday, mon = weekday(day_name), month(month_name)
        ->(y) { Sync.nth_weekday(y, mon, wday, nth) }
      else
        m = text.match(/\A([A-Za-z]+\.?)\s+(\d{1,2})\z/) or raise Error, "can't read date #{text.inspect}; try \"Dec 25\" or \"Easter-47\""
        mon, day = month(m[1]), m[2].to_i
        raise Error, "no such date #{text.inspect}" unless Date.valid_date?(2024, mon, day)
        ->(y) { Date.valid_date?(y, mon, day) ? Date.new(y, mon, day) : nil } # Feb 29 only in leap years
      end
    end

    # Full name or three-letter abbreviation
    def month(s) = name_index(Date::MONTHNAMES, Date::ABBR_MONTHNAMES, s) || raise(Error, "unknown month #{s.inspect}")
    def weekday(s) = name_index(Date::DAYNAMES, Date::ABBR_DAYNAMES, s) || raise(Error, "unknown weekday #{s.inspect}")
    def name_index(full, abbr, s) = [full, abbr].lazy.filter_map { |names| names.index { _1&.casecmp?(s.to_s.delete_suffix(".")) } }.first

    # "dusk", "dusk+15", "dusk-10" or "HH:MM"
    def parse_start(v)
      return {dusk: true, offset: Integer($1.delete(" "), 10)} if v.to_s.strip =~ /\Adusk\s*([+-]\s*\d+)\z/i
      return {dusk: true, offset: 0} if v.to_s.strip.casecmp?("dusk")
      {dusk: false, hm: parse_hm(v)}
    end

    # YAML reads an unquoted 18:30 as a base-60 number: seconds (66600) in Psych 5+, minutes (1110) before.
    YAML_MINUTE = YAML.safe_load("x: 1:00")["x"] / 60

    # "18:30", or the number YAML made of an unquoted 18:30
    def parse_hm(v)
      return (v / YAML_MINUTE).divmod(60) if v.is_a?(Integer)
      m = v.to_s.strip.match(/\A(\d{1,2}):(\d{2})\z/) or raise Error, "can't read time #{v.inspect}; want HH:MM"
      h, min = m[1].to_i, m[2].to_i
      raise Error, "no such time #{v.inspect}" unless h < 24 && min < 60
      [h, min]
    end

    def window(r, d)
      s = if r[:start][:dusk]
            Sync.sunset(d, @cfg.dig("location", "lat").to_f, @cfg.dig("location", "lon").to_f) + r[:start][:offset] * 60
          else
            at(d, r[:start][:hm])
          end
      s = Time.at(s.to_i) # whole seconds, so re-planning compares equal
      e = at(d, r[:end])
      if e <= s
        return [s, nil] if r[:end][0] >= 12 # an evening end already past dusk: no show, not a 24-hour one
        e = at(d + 1, r[:end]) # "01:00" means the next morning
      end
      [s, e]
    end

    def at(d, (h, m)) = Time.new(d.year, d.month, d.day, h, m) # wall clock, so DST doesn't shift shows

    def changed?(event, seqs, occurrences, flags)
      have = [event["sequences"].map { [_1["sequenceId"], _1["duration"]] },
              event["occurrences"].map { [Time.parse(_1["start"]).to_i, Time.parse(_1["end"]).to_i] },
              event["flags"]]
      have != [seqs, occurrences.map { |s, e| [s.to_i, e.to_i] }, flags]
    end

    def describe(r, nights)
      return "nothing new in the window" if nights.empty?
      s, e = nights.first
      start = r[:start][:dusk] ? "dusk (#{s.strftime("%H:%M")})" : s.strftime("%H:%M")
      span = nights.size == 1 ? s.strftime("%b %-d") : "#{s.strftime("%b %-d")} – #{nights.last[0].strftime("%b %-d")}"
      "#{nights.size} night#{"s" unless nights.size == 1}, #{span}, #{start}–#{e.strftime("%H:%M")}"
    end
  end
end
