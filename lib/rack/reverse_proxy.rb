require 'net/http'
require 'net/https'
require "rack-proxy"
require "rack/reverse_proxy_matcher"
require "rack/exception"
require "rack/reverse_proxy/http_streaming_response"
require 'skylight'
module Rack
  class ReverseProxy
    include NewRelic::Agent::Instrumentation::ControllerInstrumentation if defined? NewRelic
    include Skylight::Helpers

    def initialize(app = nil, &b)
      @app = app || lambda {|env| [404, [], []] }
      @matchers = []
      @global_options = {:preserve_host => true, :x_forwarded_host => true, :matching => :all, :replace_response_host => false}
      instance_eval(&b) if block_given?
    end

    instrument_method title: 'ReverseProxy call'
    def call(env)
      rackreq = Rack::Request.new(env)
      matcher = get_matcher(rackreq.fullpath, Proxy.extract_http_request_headers(rackreq.env), rackreq)
      return @app.call(env) if matcher.nil?

      if @global_options[:newrelic_instrumentation]
        action_name = "#{rackreq.path.gsub(/\/\d+/,'/:id').gsub(/^\//,'')}/#{rackreq.request_method}" # Rack::ReverseProxy/foo/bar#GET
        perform_action_with_newrelic_trace(:name => action_name, :request => rackreq) do
          proxy(env, rackreq, matcher)
        end
      else
        proxy(env, rackreq, matcher)
      end
    end

    private

    instrument_method title: 'ReverseProxy proxy'
    def proxy(env, source_request, matcher)
      uri = matcher.get_uri(source_request.fullpath,env)
      if uri.nil?
        return @app.call(env)
      end
      options = @global_options.dup.merge(matcher.options)

      # Initialize request
      target_request = Net::HTTP.const_get(source_request.request_method.capitalize).new(uri.request_uri)

      # Setup headers
      target_request_headers = Proxy.extract_http_request_headers(source_request.env)

      if options[:preserve_host]
        if uri.port == uri.default_port
          target_request_headers['HOST'] = uri.host
        else
          target_request_headers['HOST'] = "#{uri.host}:#{uri.port}"
        end
      end

      if options[:x_forwarded_host]
        target_request_headers['X-Forwarded-Host'] = source_request.host
        target_request_headers['X-Forwarded-Port'] = "#{source_request.port}"
      end

      target_request.initialize_http_header(target_request_headers)

      # Basic auth
      target_request.basic_auth options[:username], options[:password] if options[:username] and options[:password]

      # Setup body
      if target_request.request_body_permitted? && source_request.body
        source_request.body.rewind
        target_request.body_stream    = source_request.body
      end

      target_request.content_length = source_request.content_length || 0
      target_request.content_type   = source_request.content_type if source_request.content_type

      # Create a streaming response (the actual network communication is deferred, a.k.a. streamed)
      target_response = HttpStreamingResponse.new(target_request, uri.host, uri.port)

      # pass the timeout configuration through
      target_response.set_read_timeout(options[:timeout]) if options[:timeout].to_i > 0

      target_response.use_ssl = "https" == uri.scheme

      # Let rack set the transfer-encoding header
      response_headers = Rack::Utils::HeaderHash.new Proxy.normalize_headers(format_headers(target_response.headers))
      response_headers.delete('Transfer-Encoding')
      response_headers.delete('Status')

      # Replace the location header with the proxy domain
      if response_headers['Location'] && options[:replace_response_host]
        response_location = URI(response_headers['location'])
        response_location.host = source_request.host
        response_location.port = source_request.port
        response_headers['Location'] = response_location.to_s
      end

      [target_response.status, response_headers, target_response.body]
    end

    def get_matcher(path, headers, rackreq)
      matches = @matchers.select do |matcher|
        matcher.match?(path, headers, rackreq)
      end

      if matches.length < 1
        nil
      elsif matches.length > 1 && @global_options[:matching] != :first
        raise AmbiguousProxyMatch.new(path, matches)
      else
        matches.first
      end
    end

    def reverse_proxy_options(options)
      @global_options=options
    end

    def reverse_proxy(matcher, url=nil, opts={})
      raise GenericProxyURI.new(url) if matcher.is_a?(String) && url.is_a?(String) && URI(url).class == URI::Generic
      @matchers << ReverseProxyMatcher.new(matcher,url,opts)
    end

    def format_headers(headers)
      headers.reduce({}) do |acc, (key, val)|
        formated_key = key.split('-').map(&:capitalize).join('-')
        acc[formated_key] = Array(val)
	acc
      end
    end
  end
end
