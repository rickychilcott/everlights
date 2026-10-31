# Live round trip against a real bridge: every write is confirmed by listing it, then removed and
# confirmed gone. Calendar tests use tomorrow onward and never touch tonight.
# Skips play/clear while a show is running, so it won't interrupt one.
#   EVERLIGHTS_HOST=192.168.1.50 ruby -Ilib test/live_check.rb
require "everlights"

el = Everlights::Client.new
name = "zz everlights live check"
tomorrow = Date.today + 1
check = ->(label, ok) { puts "#{ok ? "PASS" : "FAIL"}  #{label}"; ok or raise "failed: #{label}" }
listed_sequence = -> { el.sequences.list(name).find { _1["alias"] == name } }
listed_nights = -> { el.calendar.list.select { _1[:name] == name }.map { _1[:date] } }

zones = el.zone_serials
before = {events: el.event_list.map { _1["id"] }.sort, sequences: el.sequence_list.map { _1["id"] }.sort}
now = Time.now
show_running = el.calendar.list(limit: 1).any? { _1[:start] <= now && now <= _1[:finish] }

begin
  # bridge info (read only; clock and reboot are deliberately never run here)
  check.("bridge reports firmware and zones", el.status.values_at("firmwareVersion", "zones").all?)

  # sequence add -> list -> it's there
  el.sequences.add(name, "FF00FF", "00FFFF", effects: {chase: 128})
  seq = listed_sequence.()
  check.("sequence add, then listed", seq && seq["pattern"] == %w[FF00FF 00FFFF] &&
                                       seq["effects"] == [{"effectType" => "chase", "value" => 128}])

  # sequence update -> list -> new colors and effects
  el.sequences.update(name, "00FF00", "0000FF", effects: {fade: 64})
  seq = listed_sequence.()
  check.("sequence update, then listed with new colors", seq && seq["pattern"] == %w[00FF00 0000FF] &&
                                                         seq["effects"] == [{"effectType" => "fade", "value" => 64}])

  # play / off / clear (only when no show is running)
  if show_running
    puts "SKIP  play/off/clear: a show is running now"
  else
    el.play(name)
    check.("play, then showing on every zone", zones.all? { el.program(_1)["pattern"] == %w[00FF00 0000FF] })
    sleep 5
    el.off
    check.("off, then every zone dark", zones.all? { el.program(_1)["pattern"].empty? })
    sleep 3
    el.clear
    puts "RAN   clear (can't verify outside a show: off and clear both read back as an empty pattern)"
  end

  # calendar add (3 nights from tomorrow) -> list -> all three there
  el.calendar.add(tomorrow, name, "#{name}:30", through: tomorrow + 2)
  check.("calendar add, then listed (3 nights)", listed_nights.() == [tomorrow, tomorrow + 1, tomorrow + 2])
  check.("listed with sequence and seconds", el.calendar.list.find { _1[:name] == name }[:sequences] == [[name, 30]])

  # sequence remove is refused while the calendar uses it -> still listed
  refused = begin; el.sequences.remove(name); false; rescue Everlights::Error; true; end
  check.("sequence remove refused while in use, still listed", refused && listed_sequence.())

  # calendar remove middle night -> list -> other two remain
  el.calendar.remove(tomorrow + 1, name)
  check.("calendar remove one night, then listed without it", listed_nights.() == [tomorrow, tomorrow + 2])

  # calendar remove the rest -> list -> gone
  el.calendar.remove(tomorrow, name)
  el.calendar.remove(tomorrow + 2, name)
  check.("calendar remove last nights, then not listed", listed_nights.().empty?)

  # sequence remove -> list -> gone
  el.sequences.remove(name)
  check.("sequence remove, then not listed", listed_sequence.().nil?)
ensure
  el.event_list.select { _1["alias"] == name }.each { el.delete_event(_1["id"]) }
  el.sequence_list.select { _1["alias"] == name }.each { el.delete_sequence(_1["id"]) }
  puts "#{el.event_list.map { _1["id"] }.sort == before[:events] ? "PASS" : "FAIL"}  calendar back to how it was"
  puts "#{el.sequence_list.map { _1["id"] }.sort == before[:sequences] ? "PASS" : "FAIL"}  sequences back to how they were"
end
