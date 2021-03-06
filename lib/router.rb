# Copyright (c) 2009-2011 VMware, Inc.
require 'fileutils'
require 'optparse'
require 'socket'
require 'yaml'
require 'openssl'
require 'set'
require 'zlib'

require 'rubygems'
require 'bundler/setup'

require 'nats/client'
require 'http/parser'

require 'vcap/common'
require 'vcap/component'
require 'vcap/logging'
require 'vcap/rolling_metric'

$:.unshift(File.dirname(__FILE__))

require 'router/const'
require 'router/router'
require 'router/router_uls_server'

config_path = ENV["CLOUD_FOUNDRY_CONFIG_PATH"] || File.join(File.dirname(__FILE__), '../config')
config_file = File.join(config_path, 'router.yml')
port, inet = nil, nil

options = OptionParser.new do |opts|
  opts.banner = 'Usage: router [OPTIONS]'
  opts.on("-p", "--port [ARG]", "Network port") do |opt|
    port = opt.to_i
  end
  opts.on("-i", "--interface [ARG]", "Network Interface") do |opt|
    inet = opt
  end
  opts.on("-c", "--config [ARG]", "Configuration File") do |opt|
    config_file = opt
  end
  opts.on("-h", "--help", "Help") do
    puts opts
    exit
  end
end
options.parse!(ARGV.dup)

begin
  config = File.open(config_file) do |f|
    YAML.load(f)
  end
rescue => e
  puts "Could not read configuration file:  #{e}"
  exit
end

# Placeholder for Component reporting
config['config_file'] = File.expand_path(config_file)

port = config['port'] unless port
inet = config['inet'] unless inet

EM.epoll

EM.run do

  trap("TERM") { Router.stop() }
  trap("INT")  { Router.stop() }

  Router.config(config)
  Router.log.info "Starting VCAP Router (#{Router.version})"
  Router.log.info "Listening on: #{inet}:#{port}" if inet && port

  Router.inet = inet || VCAP.local_ip(config['local_route'])
  Router.port = port

  # If the sock paramater is set, this will override the inet/port
  # for unix domain sockets
  if fn = config['sock']
    File.unlink(fn) if File.exists?(fn)
    Router.log.info "Listening on unix domain socket: '#{fn}'"
  end

  # Hack for running on BVTs on Macs which default to 256 FDs per process
  if RUBY_PLATFORM =~ /darwin/
    begin
      Process.setrlimit(Process::RLIMIT_NOFILE, 4096)
    rescue => e
      Router.log.info "Failed to modify the socket limit: #{e}"
    end
  end

  EM.set_descriptor_table_size(32768) # Requires Root privileges
  Router.log.info "Socket Limit:#{EM.set_descriptor_table_size}"

  Router.log.info "Pid file: %s" % config['pid']
  begin
    Router.pid_file = VCAP::PidFile.new(config['pid'])
  rescue => e
    Router.log.fatal "Can't create router pid file: #{e}"
    exit 1
  end

  NATS.on_error do |e|
    if e.kind_of? NATS::ConnectError
      Router.log.error("EXITING! NATS connection failed: #{e}")
      exit!
    else
      Router.log.error("NATS problem, #{e}")
    end
  end

  EM.error_handler do |e|
    Router.log.error "Eventmachine problem, #{e}"
    Router.log.error("#{e.backtrace.join("\n")}")
  end

  begin
    # TCP/IP Socket
    Router.server = Thin::Server.new(inet, port, RouterULSServer, :signals => false) if inet && port
    Router.local_server = Thin::Server.new(fn, RouterULSServer, :signals => false) if fn

    Router.server.start if Router.server
    Router.local_server.start if Router.local_server
  rescue => e
    Router.log.fatal "Problem starting server, #{e}"
    exit
  end

  # Allow nginx to access..
  FileUtils.chmod(0777, fn) if fn

  # Override reconnect attempts in NATS until the proper option
  # is available inside NATS itself.
  begin
    sv, $-v = $-v, nil
    NATS::MAX_RECONNECT_ATTEMPTS = 150 # 5 minutes total
    NATS::RECONNECT_TIME_WAIT    = 2   # 2 secs
    $-v = sv
  end

  NATS.start(:uri => config['mbus'])

  # Create the register/unregister listeners.
  Router.setup_listeners

  # Register ourselves with the system
  status_config = config['status'] || {}
  VCAP::Component.register(:type => 'Router',
                           :host => VCAP.local_ip(config['local_route']),
                           :index => config['index'],
                           :config => config,
                           :port => status_config['port'],
                           :user => status_config['user'],
                           :password => status_config['password'],
                           :logger => Router.log)

  # Setup some of our varzs..
  VCAP::Component.varz[:requests] = 0
  VCAP::Component.varz[:bad_requests] = 0
  VCAP::Component.varz[:latency] = VCAP::RollingMetric.new(60)
  VCAP::Component.varz[:responses_2xx] = 0
  VCAP::Component.varz[:responses_3xx] = 0
  VCAP::Component.varz[:responses_4xx] = 0
  VCAP::Component.varz[:responses_5xx] = 0
  VCAP::Component.varz[:responses_xxx] = 0
  VCAP::Component.varz[:bad_requests] = 0
  VCAP::Component.varz[:urls] = 0
  VCAP::Component.varz[:droplets] = 0

  VCAP::Component.varz[:tags] = {}

  @router_id = VCAP.secure_uuid
  @hello_message = { :id => @router_id, :version => Router::VERSION }.to_json.freeze

  # This will check on the state of the registered urls, do maintenance, etc..
  Router.setup_sweepers

  # Setup a start sweeper to make sure we have a consistent view of the world.
  EM.next_tick do
    # Announce our existence
    NATS.publish('router.start', @hello_message)

    # Don't let the messages pile up if we are in a reconnecting state
    EM.add_periodic_timer(START_SWEEPER) do
      unless NATS.client.reconnecting?
        NATS.publish('router.start', @hello_message)
      end
    end
  end

end
