require "socket"
require "json"

# Tiny fake bridge: records requests, answers from a canned table, echoes POST bodies.
class FakeBridge
  attr_reader :requests, :port

  def initialize(routes)
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @requests = []
    Thread.new do
      loop do
        c = @server.accept
        verb, path = c.gets.split
        len = 0
        while (line = c.gets) != "\r\n"
          len = line.split(":")[1].to_i if line.downcase.start_with?("content-length")
        end
        body = len.positive? ? JSON.parse(c.read(len)) : nil
        @requests << [verb, path, body]
        canned = routes.fetch("#{verb} #{path}") { body }
        code, reply = canned.is_a?(Integer) ? [canned, "boom"] : [200, JSON.generate(canned)] # Integer route = error status
        c.write "HTTP/1.1 #{code} X\r\nContent-Type: application/json\r\nContent-Length: #{reply.bytesize}\r\nConnection: close\r\n\r\n#{reply}"
        c.close
      end
    end
  end
end
