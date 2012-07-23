#!/usr/bin/env ruby
#
# Copyright 2010 Proofpoint, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

if RUBY_VERSION < "1.9" || RUBY_ENGINE != "ruby" then
  puts "MRI Ruby 1.9+ is required. Current version is #{RUBY_VERSION} [#{RUBY_PLATFORM}]"
  exit 99
end

=begin

Options
* start (run as daemon)
* stop (stop gracefully)
* restart (restart gracefully)
* kill (hard stop)
* status (check status of daemon)

Expects config under "etc":
  node.properties
  jvm.config
  config.properties

--config to override config file
--jvm-config to override jvm config file

Logs to var/log/launcher.log when run as daemon
Logs to console when run in foreground, unless log file provided

Libs must be installed under "lib"

Requires java & ruby to be in PATH

=end

require 'fileutils'
require 'optparse'
require 'pathname'
require 'pp'

# loads lines and strips comments
def load_lines(file)
  File.open(file, 'r') do |f|
    f.readlines.
            map { |line| line.strip }.
            select { |line| line !~ /^(\s)*#/ }
  end
end

def load_properties(file)
  entries = load_lines(file).map do |line|
    k, v = line.split('=', 2).map(&:strip)
  end
  Hash[entries]
end

def strip(string)
  space = /(\s+)/.match(string)[1]
  string.gsub(/^#{space}/, '')
end

class Pid
  def initialize(path, options = {})
    raise "Nil path provided" if path.nil?
    @options = options
    @path = path
  end

  def clear()
    File.delete(@path) if File.exists?(@path)
  end

  def alive?
    pid = get
    begin
      !pid.nil? && Process.kill(0, pid) == 1
    rescue Errno::ESRCH
      puts "Process #{pid} not running" if @options[:verbose]
      false
    rescue Errno::EPERM
      puts "Process #{pid} not visible" if @options[:verbose]
      false
    end
  end

  def get
    begin
      File.open(@path) { |f| f.read.to_i }
    rescue Errno::ENOENT
      puts "Can't find pid file #{@path}" if @options[:verbose]
    end
  end
end

class CommandError < RuntimeError
  attr_reader :code
  attr_reader :message
  def initialize(code, message)
    @code = code
    @message = message
  end
end

def merge_node_properties(options)
  properties = {}
  properties = load_properties(options[:node_properties_path]) if File.exists?(options[:node_properties_path])

  options[:system_properties] = properties.merge(options[:system_properties])
  options[:data_dir] = properties['node.data-dir'] unless properties['node.data-dir'].nil?

  options
end

def exec_java(options)
  exec("java", "-jar", "#{options[:install_path]}/lib/launcher.jar", *ORIG_ARGV)
end

def start(options)
  exec_java(options)
end

def stop(options)
  pid_file = Pid.new(options[:pid_file])

  if !pid_file.alive?
    pid_file.clear
    return :success, "Stopped #{pid_file.get}"
  end

  pid = pid_file.get
  Process.kill(Signal.list["TERM"], pid)

  while pid_file.alive? do
    sleep 0.1
  end

  pid_file.clear

  return :success, "Stopped #{pid}"
end

def restart(options)
  code, message = stop(options)
  if code != :success then
    return code, message
  else
    start(options)
  end
end

def kill(options)
  pid_file = Pid.new(options[:pid_file])

  if !pid_file.alive?
    pid_file.clear
    return :success, "foo"
  end

  pid = pid_file.get

  Process.kill(Signal.list["KILL"], pid)

  while pid_file.alive? do
    sleep 0.1
  end

  pid_file.clear

  return :success, "Killed #{pid}"
end

def status(options)
  exec_java(options)
end

commands = [:start, :stop, :restart, :kill, :status]
install_path = Pathname.new(__FILE__).parent.parent.expand_path

legacy_log_properties_file = File.join(install_path, 'etc', 'log.config')
log_properties_file = File.join(install_path, 'etc', 'log.properties')

if (!File.readable?(log_properties_file) && File.readable?(legacy_log_properties_file))
  log_properties_file = legacy_log_properties_file
  warn "Did not find a log.properties, but found a log.config instead.  log.config is deprecated, please use log.properties."
end

# initialize defaults
options = {
        :node_properties_path => File.join(install_path, 'etc', 'node.properties'),
        :jvm_config_path => File.join(install_path, 'etc', 'jvm.config'),
        :config_path => File.join(install_path, 'etc', 'config.properties'),
        :data_dir => install_path,
        :log_levels_path => log_properties_file,
        :install_path => install_path,
        :system_properties => {},
        }

option_parser = OptionParser.new(:unknown_options_action => :collect) do |opts|
  banner = <<-BANNER
    Usage: #{File.basename($0)} [options] <command>

    Commands:
      #{commands.join("\n  ")}

    Options:
  BANNER
  opts.banner = strip(banner)

  opts.on("-v", "--verbose", "Run verbosely") do |v|
    options[:verbose] = true
  end

  opts.on("--node-config FILE", "Defaults to INSTALL_PATH/etc/node.properties") do |v|
    options[:node_properties_path] = Pathname.new(v).expand_path
  end

  opts.on("--jvm-config FILE", "Defaults to INSTALL_PATH/etc/jvm.config") do |v|
    options[:jvm_config_path] = Pathname.new(v).expand_path
  end

  opts.on("--config FILE", "Defaults to INSTALL_PATH/etc/config.properties") do |v|
    options[:config_path] = Pathname.new(v).expand_path
  end

  opts.on("--data DIR", "Defaults to INSTALL_PATH") do |v|
    options[:data_dir] = Pathname.new(v).expand_path
  end

  opts.on("--pid-file FILE", "Defaults to DATA_DIR/var/run/launcher.pid") do |v|
    options[:pid_file] = Pathname.new(v).expand_path
  end

  opts.on("--log-file FILE", "Defaults to DATA_DIR/var/log/launcher.log (daemon only)") do |v|
    options[:log_path] = Pathname.new(v).expand_path
  end

  opts.on("--log-levels-file FILE", "Defaults to INSTALL_PATH/etc/log.config") do |v|
    options[:log_levels_path] = Pathname.new(v).expand_path
  end

  opts.on("-D<name>=<value>", "Sets a Java System property") do |v|
    if v.start_with?("config=") then
      raise("Config can not be passed in a -D argument.  Use --config instead")
    end
    property_key, property_value = v.split('=', 2).map(&:strip)
    options[:system_properties][property_key] = property_value
  end

  opts.on('-h', '--help', 'Display this screen') do
    puts opts
    exit 2
  end
end

ORIG_ARGV = Array.new(ARGV)
option_parser.parse!(ARGV)

options = merge_node_properties(options)

if options[:log_path].nil? then
  options[:log_path] =  File.join(options[:data_dir], 'var', 'log', 'launcher.log')
end

if options[:pid_file].nil? then
  options[:pid_file] =  File.join(options[:data_dir], 'var', 'run', 'launcher.pid')
end

puts options.map { |k, v| "#{k}=#{v}"}.join("\n") if options[:verbose]

status_codes = {
        :success => 0,
}


error_codes = {
        :generic_error => 1,
        :invalid_args => 2,
        :unsupported => 3,
        :config_missing => 6
}

if ARGV.length != 1
  puts option_parser
  puts
  puts "Expected a single command, got '#{ARGV.join(' ')}'"
  exit error_codes[:invalid_args]
end

command = ARGV[0].to_sym

unless commands.include?(command)
  puts option_parser
  puts
  puts "Unsupported command: #{command}"
  exit error_codes[:unsupported]
end

begin
  code, message = send(command, options)
  puts message unless message.nil?
  exit status_codes[code]
rescue CommandError => e
  puts e.message
  puts e.code if options[:verbose]
  exit error_codes[e.code]
end