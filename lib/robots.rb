require "open-uri"
require "uri"
require "rubygems"
require "timeout"

class Robots

  DEFAULT_TIMEOUT = 3

  class ParsedRobots
    # We changed the argument list to now take an extra io object of the robots.txt file
    # Since we don't want to hit the domain to grab the robots.txt file on every request,
    # we will be caching robots.txt in redis and supplying that here to check if the url is allowed
    def initialize(uri, user_agent, robots_file_io=nil)
      @last_accessed = Time.at(1)

      # check for the presence of a locally cached robots.txt file io object that is passed in
      # if it looks valid, then use it, if not do what the gem did before of reaching for it from the domain
      if robots_file_io && robots_file_io.content_type == "text/plain" && robots_file_io.status == ["200", "OK"]
        io = robots_file_io
      else
        io = Robots.get_robots_txt(uri, user_agent)

        if !io || io.content_type != "text/plain" || io.status != ["200", "OK"]
          io = StringIO.new("User-agent: *\nAllow: /\n")
        end
      end

      @other = {}
      @disallows = {}
      @allows = {}
      @delays = {} # added delays to make it work
      agent = /.*/
      io.each do |line|
        next if line =~ /^\s*(#.*|$)/
        arr = line.split(":")
        key = arr.shift
        value = arr.join(":").strip
        value.strip!
        case key
        when "User-agent"
          agent = to_regex(value)
        when "Allow"
          @allows[agent] ||= []
          @allows[agent] << to_regex(value)
        when "Disallow"
          @disallows[agent] ||= []
          @disallows[agent] << to_regex(value)
        when "Crawl-delay"
          @delays[agent] = value.to_i
        else
          @other[key] ||= []
          @other[key] << value
        end
      end

      @parsed = true
    end

    def allowed?(uri, user_agent)
      return true unless @parsed
      allowed = true
      path = uri.request_uri

      @disallows.each do |key, value|
        if user_agent =~ key
          value.each do |rule|
            if path =~ rule
              allowed = false
            end
          end
        end
      end

      @allows.each do |key, value|
        unless allowed
          if user_agent =~ key
            value.each do |rule|
              if path =~ rule
                allowed = true
              end
            end
          end
        end
      end

      if allowed && @delays[user_agent]
        sleep @delays[user_agent] - (Time.now - @last_accessed)
        @last_accessed = Time.now
      end

      return allowed
    end

    def other_values
      @other
    end

  protected

    def to_regex(pattern)
      return /should-not-match-anything-123456789/ if pattern.strip.empty?
      pattern = Regexp.escape(pattern)
      pattern.gsub!(Regexp.escape("*"), ".*")
      Regexp.compile("^#{pattern}")
    end
  end

  def self.get_robots_txt(uri, user_agent)
    begin
      Timeout::timeout(Robots.timeout) do
        io = URI.join(uri.to_s, "/robots.txt").open("User-Agent" => user_agent) rescue nil
      end
    rescue Timeout::Error
      STDERR.puts "robots.txt request timed out"
    end
  end

  def self.timeout=(t)
    @timeout = t
  end

  def self.timeout
    @timeout || DEFAULT_TIMEOUT
  end

  # We changed the argument list to now take an extra io object of the robots.txt file
  def initialize(user_agent, robots_file_io=nil)
    @user_agent = user_agent
    @parsed = {}
    @robots_file_io = robots_file_io
  end

  def allowed?(uri)
    uri = URI.parse(uri.to_s) unless uri.is_a?(URI)
    host = uri.host
    # We changed the argument list to now take an extra io object of the robots.txt file
    @parsed[host] ||= ParsedRobots.new(uri, @user_agent, @robots_file_io)
    @parsed[host].allowed?(uri, @user_agent)
  end

  def other_values(uri)
    uri = URI.parse(uri.to_s) unless uri.is_a?(URI)
    host = uri.host
    @parsed[host] ||= ParsedRobots.new(uri, @user_agent)
    @parsed[host].other_values
  end
end
