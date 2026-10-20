# frozen_string_literal: true

require "ipaddr"
require "openssl"
require "socket"
require "uri"

# Two listeners for sandboxed containers:
# - forward (3128): CONNECT tunnels to allowed hosts only. A host entry allows port 443; "host:port"
#   allows another one; "*" is any host. The TLS ClientHello must name the CONNECT host (SNI) and
#   must not offer Encrypted Client Hello, so a tunnel to an allowed host on a shared CDN cannot
#   reach another site there. Private, loopback,
#   and link-local addresses are refused whatever the list says. Plain http is refused.
# - reverse (8080): plain http in, https out to the Anthropic API with the credential added, for the
#   allowed routes only ("METHOD /path", or "*"), so the credential never enters the sandbox.
#   Exactly one request per connection: the body is forwarded by Content-Length, nothing after it.
#   Without a credential it answers 503.
class SandboxProxy
  HOP_HEADERS = /\A(?:connection|keep-alive|proxy-[\w-]+):/i
  CLIENT_AUTH_HEADERS = /\A(?:host|authorization|x-api-key|anthropic-beta):/i
  REQUEST_LINE = %r{\A[A-Z]+ [!-~]+ HTTP/1\.[01]\z}
  HEADER_LINE = /\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+:[\t -~]*\z/
  CONNECT_TARGET = /\A([a-z0-9.-]+):(\d{1,5})\z/i
  OAUTH_BETA = "oauth-2025-04-20"
  MAX_HEAD_SIZE = 65_536
  MAX_TLS_RECORD = 16_384
  ECH_EXTENSIONS = [ 0xfe0d, 0xffce ].freeze
  # OrbStack maps host.docker.internal into 0.0.0.0/8.
  RESERVED_RANGES = %w[0.0.0.0/8 100.64.0.0/10 192.0.0.0/24 198.18.0.0/15 224.0.0.0/3 ::/127 64:ff9b::/96 ff00::/8]
    .map { IPAddr.new(it) }

  def initialize(hosts, upstream:, routes: [ "*" ], oauth_token: nil, api_key: nil,
    forward_port: 3128, reverse_port: 8080, head_timeout: 30, idle_timeout: 600)
    @hosts = hosts.map(&:downcase)
    @upstream = URI(upstream)
    @routes = routes
    @oauth_token = oauth_token
    @api_key = api_key
    @forward_port = forward_port
    @reverse_port = reverse_port
    @head_timeout = head_timeout
    @idle_timeout = idle_timeout
  end

  def run
    $stdout.sync = true
    Thread.report_on_exception = false
    servers = { forward: TCPServer.new("0.0.0.0", @forward_port), reverse: TCPServer.new("0.0.0.0", @reverse_port) }
    puts "forward on #{@forward_port}: #{@hosts.any? ? @hosts.join(", ") : "no hosts"}"
    puts "reverse on #{@reverse_port}: #{@upstream} (#{credential_name}), routes: #{@routes.join(", ")}"
    servers.map { |mode, server| Thread.new { loop { Thread.new(server.accept) { handle(it, mode) } } } }.each(&:join)
  end

  private

  def credential_name
    return "oauth token" if @oauth_token
    return "api key" if @api_key

    "no credential: answers 503"
  end

  def handle(client, mode)
    client.binmode
    client.timeout = @head_timeout
    head = client.gets("\r\n\r\n", MAX_HEAD_SIZE) or return
    return reject(client, "431 Request Header Fields Too Large") unless head.end_with?("\r\n\r\n")

    request_line, *headers = head.split("\r\n")
    unless request_line.match?(REQUEST_LINE) && headers.all? { it.match?(HEADER_LINE) }
      return reject(client, "400 Bad Request")
    end

    client.timeout = @idle_timeout
    verb, target, version = request_line.split(" ")

    case mode
    when :reverse then reverse(client, verb, target, version, headers)
    when :forward
      verb == "CONNECT" ? tunnel(client, target) : deny(client, "#{verb} #{target} (plain http)")
    end
  rescue IO::TimeoutError
    reject(client, "408 Request Timeout") rescue nil # rubocop:disable Style/RescueModifier
  rescue SystemCallError, IOError, SocketError, URI::Error, OpenSSL::SSL::SSLError
    reject(client, "502 Bad Gateway") rescue nil # rubocop:disable Style/RescueModifier
  ensure
    drain(client)
    client.close
  end

  # The 200 goes out before the upstream connection: the ClientHello comes only after it.
  def tunnel(client, target)
    match = target.match(CONNECT_TARGET) or return reject(client, "400 Bad Request")
    host, port = match[1], match[2].to_i
    return deny(client, target) unless allowed?(host, port)

    client.write("HTTP/1.1 200 Connection Established\r\n\r\n")
    hello = client_hello(client)
    name = hello && server_name(hello)
    return puts("deny #{target} (sni: #{name || "none"})") unless name&.downcase == host.downcase

    upstream = connect_public(host, port) or return puts("deny #{target} (private address)")
    puts "connect #{target}"
    upstream.write(hello)
    pump(client, upstream)
  end

  def reverse(client, verb, target, version, headers)
    return reject(client, "400 Bad Request") unless target.start_with?("/")

    lengths = headers.grep(/\Acontent-length:/i).map { it.split(":", 2).last.strip }
    if headers.any?(/\Atransfer-encoding:/i) || lengths.size > 1 || !lengths.all?(/\A\d+\z/)
      return reject(client, "400 Bad Request")
    end

    route = "#{verb} #{target.split("?", 2).first}"
    unless @routes.include?("*") || @routes.include?(route)
      puts "deny api #{route}"
      return api_error(client, "403 Forbidden", "sandbox proxy: route not allowed: #{route}")
    end

    puts "api #{verb} #{target}"
    return api_error(client, "503 Service Unavailable", "sandbox proxy: no credential") unless @oauth_token || @api_key

    upstream = tls(@upstream.host, @upstream.port)
    headers = [ "Host: #{@upstream.host}", *headers.grep_v(HOP_HEADERS).grep_v(CLIENT_AUTH_HEADERS),
      *credential_headers(headers), "Connection: close" ]
    upstream.write("#{verb} #{target} #{version}\r\n#{headers.join("\r\n")}\r\n\r\n")
    copy_body(client, upstream, lengths.first.to_i)
    copy(upstream, client)
  ensure
    upstream&.close
  end

  def credential_headers(headers)
    betas = headers.grep(/\Aanthropic-beta:/i).flat_map { it.split(":", 2).last.split(",").map(&:strip) }
    return [ "x-api-key: #{@api_key}", *("anthropic-beta: #{betas.join(",")}" if betas.any?) ] unless @oauth_token

    [ "Authorization: Bearer #{@oauth_token}", "anthropic-beta: #{(betas | [ OAUTH_BETA ]).join(",")}" ]
  end

  def allowed?(host, port)
    [ host.downcase, "*" ].any? { @hosts.include?("#{it}:#{port}") || (port == 443 && @hosts.include?(it)) }
  end

  # One whole TLS record holding a ClientHello; anything else (a split hello, not TLS) is refused.
  def client_hello(client)
    client.timeout = @head_timeout
    header = client.read(5) or return
    type, _version, length = header.unpack("Cnn")
    return unless type == 22 && length <= MAX_TLS_RECORD

    body = client.read(length)
    client.timeout = @idle_timeout
    header + body if body&.bytesize == length
  end

  # Strict: every length must add up exactly, one server_name extension holding one host name.
  # Encrypted Client Hello hides the real server name, so a hello offering it is refused.
  def server_name(record)
    hello = record.byteslice(5..)
    return unless hello.getbyte(0) == 1 && (hello.unpack1("N") & 0xFFFFFF) + 4 == hello.bytesize

    pos = 4 + 2 + 32
    pos += 1 + hello.getbyte(pos)
    pos += 2 + hello.byteslice(pos, 2).unpack1("n")
    pos += 1 + hello.getbyte(pos)
    extensions_end = pos + 2 + hello.byteslice(pos, 2).unpack1("n")
    return unless extensions_end == hello.bytesize

    pos += 2
    names = []
    while pos < extensions_end
      type, length = hello.byteslice(pos, 4).unpack("nn")
      pos += 4
      return if ECH_EXTENSIONS.include?(type) || pos + length > extensions_end

      if type.zero?
        list_length, name_type, name_length = hello.byteslice(pos, 5).unpack("nCn")
        return unless names.empty? && list_length == length - 2 && name_type.zero? && name_length == list_length - 3

        names << hello.byteslice(pos + 5, name_length)
      end
      pos += length
    end
    names.first if pos == extensions_end
  rescue NoMethodError, TypeError, ArgumentError
    nil
  end

  # Connects to the address that was checked, so a second DNS answer cannot point elsewhere.
  def connect_public(host, port)
    address = Addrinfo.getaddrinfo(host, port, nil, :STREAM).map(&:ip_address).find { public_address?(it) }
    connect(address, port) if address
  end

  def public_address?(address)
    ip = IPAddr.new(address).native
    !(ip.private? || ip.loopback? || ip.link_local? || RESERVED_RANGES.any? { it.family == ip.family && it.include?(ip) })
  rescue IPAddr::InvalidAddressError
    false
  end

  def connect(host, port)
    Socket.tcp(host, port, connect_timeout: 10).tap { it.timeout = @idle_timeout }
  end

  def tls(host, port)
    context = OpenSSL::SSL::SSLContext.new
    context.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER)
    socket = OpenSSL::SSL::SSLSocket.new(connect(host, port), context)
    socket.hostname = host
    socket.sync_close = true
    socket.connect
    socket
  end

  def deny(client, target)
    puts "deny #{target}"
    reject(client, "403 Forbidden")
  end

  def reject(client, status)
    client.write("HTTP/1.1 #{status}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
  end

  def api_error(client, status, message)
    body = %({"type":"error","error":{"type":"api_error","message":"#{message}"}})
    client.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\n" \
                 "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
  end

  def copy_body(from, to, length)
    while length.positive?
      chunk = from.readpartial([ length, 65_536 ].min)
      to.write(chunk)
      length -= chunk.bytesize
    end
  end

  def pump(client, upstream)
    Thread.new { copy(client, upstream) }
    copy(upstream, client)
  ensure
    upstream.close
  end

  # readpartial drains what gets already buffered, so a request body is not lost.
  def copy(from, to)
    loop { to.write(from.readpartial(65_536)) }
  rescue EOFError, IOError, SystemCallError, OpenSSL::SSL::SSLError
    nil
  ensure
    to.close_write rescue nil # rubocop:disable Style/RescueModifier
  end

  # Unread client bytes would turn the close into a reset and cut off the response.
  def drain(client, limit: 1_048_576)
    client.close_write
    client.timeout = 1
    limit -= client.readpartial(65_536).bytesize while limit.positive?
  rescue EOFError, IOError, SystemCallError
    nil
  end
end

if $PROGRAM_NAME == __FILE__
  env = ->(name) { ENV[name].then { it unless it.to_s.strip.empty? } }
  routes = env.("PROXY_API_ROUTES") || "POST /v1/messages POST /v1/messages/count_tokens"
  routes = routes.split.then { it == [ "*" ] ? it : it.each_slice(2).map { |pair| pair.join(" ") } }

  SandboxProxy.new(ENV.fetch("PROXY_ALLOW_HOSTS", "").split,
    upstream: env.("PROXY_UPSTREAM") || "https://api.anthropic.com",
    routes:,
    oauth_token: env.("CLAUDE_CODE_OAUTH_TOKEN"),
    api_key: env.("ANTHROPIC_API_KEY")).run
end
