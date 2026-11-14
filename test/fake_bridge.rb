require "socket"
require "json"
require "tmpdir"

# Tests never use a real cloud login: point at one that doesn't exist.
ENV["EVERLIGHTS_CLOUD"] = File.join(Dir.tmpdir, "everlights-test-no-login.json")

# Tiny fake bridge: records requests, answers from a canned table, echoes POST bodies.
class FakeBridge
  attr_reader :requests, :auth, :port

  def initialize(routes)
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @requests, @auth = [], []
    Thread.new do
      loop do
        c = @server.accept
        verb, path = c.gets.split
        len, auth = 0, nil
        while (line = c.gets) != "\r\n"
          len = line.split(":")[1].to_i if line.downcase.start_with?("content-length")
          auth = line.split(":", 2)[1].strip if line.downcase.start_with?("authorization")
        end
        body = len.positive? ? JSON.parse(c.read(len)) : nil
        @requests << [verb, path, body]
        @auth << auth
        canned = routes.fetch("#{verb} #{path}") { body }
        canned = canned.call if canned.is_a?(Proc) # a route that answers differently each time
        # Integer route = error status; 410 answers as firmware B5010 does
        code, reply = canned.is_a?(Integer) ? [canned, canned == 410 ? '{"error":"gone","cloud":true}' : "boom"] : [200, JSON.generate(canned)]
        c.write "HTTP/1.1 #{code} X\r\nContent-Type: application/json\r\nContent-Length: #{reply.bytesize}\r\nConnection: close\r\n\r\n#{reply}"
        c.close
      end
    end
  end
end
