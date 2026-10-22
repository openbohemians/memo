require "http/server"
require "http/web_socket"
require "json"

# A minimal Arcana bus for specs: the server side of arcana-core's Client
# protocol, nothing more. A client joins with `{"type":"join","address":…}`
# and sends `{"type":"send","envelope":…}`; the relay forwards each
# envelope (as JSON) to whoever joined as its `to`. Envelopes for an
# address nobody has joined are dropped. `GET /directory/<address>` answers
# 200 for a joined address or one added with `list`, and 404 otherwise.
class BusRelay
  getter port : Int32

  def initialize
    @sockets = {} of String => HTTP::WebSocket
    @listings = Set(String).new
    @mutex = Mutex.new
    handler = HTTP::WebSocketHandler.new do |ws, _ctx|
      address = nil.as(String?)
      ws.on_message do |message|
        frame = JSON.parse(message)
        case frame["type"]?.try(&.as_s)
        when "join"
          joined = frame["address"].as_s
          address = joined
          @mutex.synchronize { @sockets[joined] = ws }
        when "send"
          envelope = frame["envelope"]
          target = @mutex.synchronize { @sockets[envelope["to"].as_s]? }
          target.try(&.send(envelope.to_json))
        end
      end
      ws.on_close { |_, _| address.try { |a| @mutex.synchronize { @sockets.delete(a) } } }
    end
    @server = HTTP::Server.new([handler]) do |ctx|
      address = ctx.request.path.lchop?("/directory/")
      if address && @mutex.synchronize { @sockets.has_key?(address) || @listings.includes?(address) }
        ctx.response.content_type = "application/json"
        ctx.response.print({address: address}.to_json)
      else
        ctx.response.status = HTTP::Status::NOT_FOUND
      end
    end
    @port = @server.bind_tcp("127.0.0.1", 0).port
    spawn { @server.listen }
  end

  # List an address no one has joined, as the bus does after a restart
  def list(address : String) : Nil
    @mutex.synchronize { @listings << address }
  end

  def close : Nil
    @server.close
  end
end
