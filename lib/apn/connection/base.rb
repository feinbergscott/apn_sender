require 'socket'
require 'openssl'
require 'resque'

module APN
  module Connection
    # APN::Connection::Base takes care of all the boring certificate loading, socket creating, and logging
    # responsibilities so APN::Sender and APN::Feedback and focus on their respective specialties.
    module Base
      attr_accessor :opts, :logger

      def initialize(opts = {})
        @opts = opts             
	
	# should have already taken care of this earlier
        #@opts[:environment] ||= Rails.env if defined?(Rails.env)
        
        setup_logger
        log(:info, "APN::Sender initializing for app = #{@opts[:app]} for environgment = #{@opts[:environment]}. Establishing connections first...") if @opts[:verbose]

	#log(:info, "setup_paths")
        setup_paths

	#puts "super start"
	#puts "determines queuename monitored"
	qname = "apn_" + "#{@opts[:app]}.#{@opts[:environment]}" 
	log(:info, "monitoring redis queue: #{qname}")
        super( qname ) if self.class.ancestors.include?(Resque::Worker)
	#puts "super end"
      end

      # Lazy-connect the socket once we try to access it in some way
      def socket
        setup_connection unless @socket
        return @socket
      end

      protected

      # Default to Rails or Merg logger, if available
      def setup_logger
	# HiroProt changed from ::Merb::Logger to Merb::Logger, so I'm taking his word for it
        @logger = if defined?(Merb::Logger)
          Merb.logger
        elsif defined?(Rails.logger)
          Rails.logger
        end
      end

      # Log message to any logger provided by the user (e.g. the Rails logger).
      # Accepts +log_level+, +message+, since that seems to make the most sense,
      # and just +message+, to be compatible with Resque's log method and to enable
      # sending verbose and very_verbose worker messages to e.g. the rails logger.
      #
      # Perhaps a method definition of +message, +level+ would make more sense, but
      # that's also the complete opposite of what anyone comming from rails would expect.
      alias_method(:resque_log, :log) if defined?(log)
      def log(level, message = nil)
        level, message = 'info', level if message.nil? # Handle only one argument if called from Resque, which expects only message

        #STDOUT.puts message + "!L!"
        return false unless self.logger && self.logger.respond_to?(level)
        #STDOUT.puts "after false" + "!L!"
	# not sure why logger isn't getting setup properly
        #self.logger.send(level, "#{Time.now}: #{message}")
        #STDOUT.puts "after time" + "!L!"
      end

      # Log the message first, to ensure it reports what went wrong if in daemon mode.
      # Then die, because something went horribly wrong.
      def log_and_die(msg)
        log(:fatal, msg)
        raise msg
      end

      def apn_production?
        @opts[:environment] && @opts[:environment] != '' && :production == @opts[:environment].to_sym
      end

      # Get a fix on the .pem certificate we'll be using for SSL
      def setup_paths
        log(:info, "setup_paths start! #{@opts}")
        # Set option defaults
        @opts[:environment] ||= Rails.env if defined?(Rails.env)
        log(:info, ":environment #{@opts[:environment]}!")



        cert_name = apn_production? ? "apn_production.pem" : "apn_development.pem"

        #@opts[:cert_path] ||= File.join(File.expand_path(::Rails.root.to_s), "config", "certs") if defined?(::Rails.root.to_s)
        @opts[:cert_path] ||= File.join(File.expand_path(@opts[:base_dir]), "config", "certs") 
	if defined?(@opts[:base_dir])
		if defined?(@opts[:app])
			cert_path = File.join(@opts[:cert_path], @opts[:app], cert_name)
		else
			cert_path = File.join(@opts[:cert_path], cert_name)
		end
	else
		log_and_die("base_dir is not set")
	end
        

        @apn_cert = File.exists?(cert_path) ? File.read(cert_path) : nil
        log(:info, "Cert path is #{cert_path}")

	if @apn_cert
		log(:info, "Cert found") 
	else
		log_and_die("Missing apple push notification certificate in #{cert_path}") unless @apn_cert
	end
      end

      # Open socket to Apple's servers
      def setup_connection
        log_and_die("Missing apple push notification certificate") unless @apn_cert
        return true if @socket && @socket_tcp
        log_and_die("Trying to open half-open connection") if @socket || @socket_tcp

        ctx = OpenSSL::SSL::SSLContext.new
        ctx.cert = OpenSSL::X509::Certificate.new(@apn_cert)
        
        if @opts[:cert_pass]
          ctx.key = OpenSSL::PKey::RSA.new(@apn_cert, @opts[:cert_pass])
        else
          ctx.key = OpenSSL::PKey::RSA.new(@apn_cert)
        end

        @socket_tcp = TCPSocket.new(apn_host, apn_port)
        @socket = OpenSSL::SSL::SSLSocket.new(@socket_tcp, ctx)
        @socket.sync = true
        @socket.connect
      rescue SocketError => error
        log_and_die("Error with connection to #{apn_host}: #{error}")
      end

      # Close open sockets
      def teardown_connection
        log(:info, "Closing connections...") if @opts[:verbose]

        begin
          @socket.close if @socket
        rescue Exception => e
          log(:error, "Error closing SSL Socket: #{e}")
        end

        begin
          @socket_tcp.close if @socket_tcp
        rescue Exception => e
          log(:error, "Error closing TCP Socket: #{e}")
        end
      end

    end
  end
end
