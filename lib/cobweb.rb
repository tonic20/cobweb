require 'rubygems'
require 'uri'
require 'resque'
require 'digest/sha1'

Dir[File.dirname(__FILE__) + '/*.rb'].each do |file|
  require [File.dirname(__FILE__), File.basename(file, File.extname(file))].join("/")
end

class CobWeb
  
  def initialize(options = {})
    @options = options
    @options[:follow_redirects] = true if @options[:follow_redirects].nil?
    @options[:redirect_limit] = 10 if @options[:redirect_limit].nil? 
    @options[:processing_queue] = ContentProcessJob if @options[:processing_queue].nil?
    @options[:debug] = false unless @options[:debug]
    
  end
  
  def start(base_url)
    raise ":base_url is required" unless base_url
    request = {
      :crawl_id => Digest::SHA1.hexdigest(Time.now.to_s),
      :url => base_url 
    }  
    
    request.merge!(@options)
  
    Resque.enqueue(CrawlJob, request)
  end


  def get(url, redirect_limit = @options[:redirect_limit])

    raise "url cannot be nil" if url.nil?    
    
    # get the unique id for this request
    unique_id = Digest::SHA1.hexdigest(url)
    
    # connect to redis
    redis = NamespacedRedis.new(Redis.new, "cobweb")
    
    content = {}
  
    # check if it has already been cached
    if redis.get(unique_id) and @options[:cache]
      puts "Cache hit for #{url}" unless @options[:quiet]
      content = JSON.parse(redis.get(unique_id)).deep_symbolize_keys

      content
    else
      # this url is valid for processing so lets get on with it
      print "Retrieving #{url }... " unless @options[:quiet]
      uri = URI.parse(url)
      
      # retrieve data
      http = Net::HTTP.new(uri.host, uri.port)
      if uri.scheme == "https"
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      end 
      request_time = Time.now.to_f
      request = Net::HTTP::Get.new(uri.request_uri)
      response = http.request(request)
  
      if @options[:follow_redirects] and response.code.to_i >= 300 and response.code.to_i < 400
        puts "redirected... " unless @options[:quiet]
        url = response['location']
        redirect_limit = redirect_limit - 1
        content = get(response['location'], redirect_limit)
        content[:url] = uri.to_s
        content[:redirect_through] = [] if content[:redirect_through].nil?
        content[:redirect_through].insert(0, response['location'])
        
        content[:response_time] = Time.now.to_f - request_time
      else
        content[:response_time] = Time.now.to_f - request_time
        
        puts "Retrieved." unless @options[:quiet]
        
        # create the content container
        content[:url] = uri.to_s
        content[:status_code] = response.code.to_i
        content[:content_type] = response.content_type
        charset = response["Content-Type"][response["Content-Type"].index(";")+2..-1  ] if !response["Content-Type"].nil? and response["Content-Type"].include?(";")
        charset = charset[charset.index("=")+1..-1] if charset and charset.include?("=")
        content[:character_set] = charset 
        content[:content_length] = response.content_length
        content[:content_body] = response.body
        content[:location] = response["location"]
        content[:headers] = response.to_hash.symbolize_keys
        
        # parse data for links
        link_parser = ContentLinkParser.new(content[:url], content[:content_body])
        content[:links] = link_parser.link_data
        
        # add content to cache if required
        if @options[:cache]
          redis.set(unique_id, content.to_json)
          redis.expire unique_id, content_request[:cache].to_i
        end
      end
    end
    content  
  end
end

## add symbolize methods to hash
class Hash
  def symbolize_keys
    keys.each do |key|
      if key.instance_of? String
        value = self[key]
        self.delete(key)
        self[key.to_sym] = value        
      end
    end
    self
  end  
  def deep_symbolize_keys
    symbolize_keys
    keys.each do |key|
      if self[key].instance_of? Hash
        self[key].deep_symbolize_keys
      end
    end
    self
  end
end