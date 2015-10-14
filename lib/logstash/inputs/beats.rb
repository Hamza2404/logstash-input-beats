# encoding: utf-8
require "logstash/inputs/base"
require "logstash/namespace"
require "lumberjack"

# use Logstash provided json decoder
Lumberjack::json = LogStash::Json

# Allow Logstash to receive events from Filebeat
#
# https://github.com/elastic/filebeat[filebeat]
#
class LogStash::Inputs::Beats < LogStash::Inputs::Base
  config_name "beats"

  default :codec, "plain"

  # The IP address to listen on.
  config :host, :validate => :string, :default => "0.0.0.0"

  # The port to listen on.
  config :port, :validate => :number, :required => true

  # Events are by default send in plain text, you can
  # enable encryption by using `ssl` to true and configuring
  # the `ssl_certificate` and `ssl_key` options.
  config :ssl, :validate => :boolean, :default => false

  # SSL certificate to use.
  config :ssl_certificate, :validate => :path

  # SSL key to use.
  config :ssl_key, :validate => :path

  # SSL key passphrase to use.
  config :ssl_key_passphrase, :validate => :password

  # The number of seconds before we raise a timeout,
  # this option is useful to control how much time to wait if something is blocking the pipeline.
  config :congestion_threshold, :validate => :number, :default => 5

  # TODO(sissel): Add CA to authenticate clients with.
  BUFFERED_QUEUE_SIZE = 1
  RECONNECT_BACKOFF_SLEEP = 0.5
  
  def register
    require "lumberjack/server"
    require "concurrent"
    require "logstash/circuit_breaker"
    require "logstash/sized_queue_timeout"

    if !@ssl
      @logger.warn("SSL Certificate will not be used") unless @ssl_certificate.nil?
      @logger.warn("SSL Key will not be used") unless @ssl_key.nil?
    elsif !ssl_configured?
      raise LogStash::ConfigurationError, "Certificate or Certificate Key not configured"
    end

    @logger.info("Starting Beats input listener", :address => "#{@host}:#{@port}")
    @lumberjack = Lumberjack::Server.new(:address => @host, :port => @port,
      :ssl => @ssl, :ssl_certificate => @ssl_certificate, :ssl_key => @ssl_key,
      :ssl_key_passphrase => @ssl_key_passphrase)

    # Create a reusable threadpool, we do not limit the number of connections
    # to the input, the circuit breaker with the timeout should take care 
    # of `blocked` threads and prevent logstash to go oom.
    @threadpool = Concurrent::CachedThreadPool.new(:idletime => 15)

    # in 1.5 the main SizeQueue doesnt have the concept of timeout
    # We are using a small plugin buffer to move events to the internal queue
    @buffered_queue = LogStash::SizedQueueTimeout.new(BUFFERED_QUEUE_SIZE)

    @circuit_breaker = LogStash::CircuitBreaker.new("Beats input",
                            :exceptions => [LogStash::SizedQueueTimeout::TimeoutError])

  end # def register

  def ssl_configured?
    !(@ssl_certificate.nil? || @ssl_key.nil?)
  end

  def run(output_queue)
    start_buffer_broker(output_queue)

    while !stop? do
      # Wrappingu the accept call into a CircuitBreaker
      if @circuit_breaker.closed?
        connection = @lumberjack.accept # call that creates a new connection
        next if connection.nil? # if the connection is nil the connection was close.
        connection = ConnectionDecorator.new(EventDecoration.new,
                                             @codec.clone, connection)
        invoke(connection) do |event|
   	      if stop?
            connection.close
            break
          end

          begin
            @circuit_breaker.execute {
              @buffered_queue.push(event, @congestion_threshold)
            }
          rescue => e
            raise e
          end
        end
      else
        @logger.warn("Beats input: the pipeline is blocked, temporary refusing new connection.")
        sleep(RECONNECT_BACKOFF_SLEEP)
      end
    end
  end # def run

  public
  def stop
    @lumberjack.close
  end

  private
  def invoke(connection, &block)
    @threadpool.post do
      begin
        # If any errors occur in from the events the connection should be closed in the
        # library ensure block and the exception will be handled here
        connection.run(&block)

        # When too many errors happen inside the circuit breaker it will throw
        # this exception and start refusing connection. The bubbling of theses
        # exceptions make sure that the lumberjack library will close the current
        # connection which will force the client to reconnect and restransmit
        # his payload.
      rescue LogStash::CircuitBreaker::OpenBreaker,
             LogStash::CircuitBreaker::HalfOpenBreaker => e
        logger.warn("Beats input: The circuit breaker has detected a slowdown or stall in the pipeline, the input is closing the current connection and rejecting new connection until the pipeline recover.", :exception => e.class)
      rescue => e # If we have a malformed packet we should handle that so the input doesn't crash completely.
        @logger.error("Beats input: unhandled exception", :exception => e, :backtrace => e.backtrace)
      end
    end
  end

  def start_buffer_broker(output_queue)
    @threadpool.post do
      while !stop?
        output_queue << @buffered_queue.pop_no_timeout
      end
    end
  end

  class EventDecoration < LogStash::Inputs::Base
    public
    def decorate(event)
      super(event)
    end
  end # class EventDecoration

  class ConnectionDecorator < SimpleDelegator
    def initialize(event_decoration, codec, connection)
      super(connection)
      @event_decoration = event_decoration
      @codec = codec
    end

    public
    def run(&block)
      super do |type, event|
        case type
        when :json; json_event(event, &block)
        when :data; data_event(event, &block)
        else; raise "unknown event type received"
        end
      end
    end

    private
    def json_event(map, &block)
      if map.is_a?(Array)
        map.each { |item| json_event(item, &block) }
      else
        line = map.delete("line")
        if line.nil?
          event = LogStash::Event.new(map)
          decorate(event)
          yield event
        else
          @codec.decode(line) do |decoded|
            decorate(decoded)
            map.each { |k,v| decoded[k] = v }
            yield decoded
          end
        end
      end
    end

    private
    def data_event(fields)
      line = fields.delete("line")
      @codec.decode(line) do |event|
        begin
          decorate(event)
          fields.each { |k,v| event[k] = v; v.force_encoding(Encoding::UTF_8) }
          yield event
        rescue => e
          raise e
        end
      end
    end

    private
    def decorate(event)
      @event_decoration.decorate(event)
    end
  end # ConnectionDecorator
end # class LogStash::Inputs::Beats