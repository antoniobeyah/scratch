require 'time'
require 'openssl'

class SignV4
  def self.sign(context)
    new(
      context.config.credentials,
      context.config.sigv4_name,
      context.config.sigv4_region
    ).sign(context.http_request)
  end

  # @param [Credentials] credentials
  # @param [String] service_name The name used by the service in
  #   signing signature version 4 requests.  This is generally
  #   the endpoint prefix.
  # @param [String] region The region (e.g. 'us-west-1') the request
  #   will be made to.
  def initialize(credentials, service_name, region)
    @service_name = service_name
    @credentials = credentials.credentials
    @region = region
  end

  # @param [Seahorse::Client::Http::Request] req
  # @return [Seahorse::Client::Http::Request] the signed request.
  def sign(req)
    datetime = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
    body_digest = req['X-Amz-Content-Sha256'] || hexdigest(req.body)
    req['X-Amz-Date'] = datetime
    req['Host'] = host(req.uri)
    req['X-Amz-Security-Token'] = @credentials.session_token if
      @credentials.session_token
    req['X-Amz-Content-Sha256'] ||= body_digest
    req['Authorization'] = authorization(req, datetime, body_digest)
    req
  end

  # Generates an returns a presigned URL.
  # @param [Seahorse::Client::Http::Request] request
  # @option options [required, Integer<Seconds>] :expires_in
  # @option options [optional, String] :body_digest The SHA256 hexdigest of
  #   the payload to sign.  For S3, this should be the string literal
  #   `UNSIGNED-PAYLOAD`.
  # @return [String]
  # @api private
  def presigned_url(request, options = {})
    now = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
    body_digest = options[:body_digest] || hexdigest(request.body)

    request['Host'] = host(request.uri)
    request.delete('User-Agent')
    request.delete('accept')
    request.delete('accept-encoding')

    puts request.to_hash

    params = Aws::Query::ParamList.new

    request.to_hash.keys.each do |key|
      if key.match(/^x-amz/i)
        params.set(key, request.delete(key))
      end
    end

    params.set("X-Amz-Algorithm", "AWS4-HMAC-SHA256")
    params.set("X-Amz-Credential", credential(now))
    params.set("X-Amz-Date", now)
    params.set("X-Amz-Expires", options[:expires_in].to_s)
    params.set("X-Amz-SignedHeaders", signed_headers(request))
    params.set('X-Amz-Security-Token', @credentials.session_token) if
      @credentials.session_token

    endpoint = request.uri
    if endpoint.query
      endpoint.query += '&' + params.to_s
    else
      endpoint.query = params.to_s
    end
    endpoint.to_s + '&X-Amz-Signature=' + signature(request, now, body_digest)
  end

  def authorization(request, datetime, body_digest)
    parts = []
    parts << "AWS4-HMAC-SHA256 Credential=#{credential(datetime)}"
    parts << "SignedHeaders=#{signed_headers(request)}"
    parts << "Signature=#{signature(request, datetime, body_digest)}"
    parts.join(', ')
  end

  def credential(datetime)
    "#{@credentials.access_key_id}/#{credential_scope(datetime)}"
  end

  def signature(request, datetime, body_digest)
    k_secret = @credentials.secret_access_key
    k_date = hmac("AWS4" + k_secret, datetime[0,8])
    k_region = hmac(k_date, @region)
    k_service = hmac(k_region, @service_name)
    k_credentials = hmac(k_service, 'aws4_request')
    hexhmac(k_credentials, string_to_sign(request, datetime, body_digest))
  end

  def string_to_sign(request, datetime, body_digest)
    parts = []
    parts << 'AWS4-HMAC-SHA256'
    parts << datetime
    parts << credential_scope(datetime)
    parts << hexdigest(canonical_request(request, body_digest))
    parts.join("\n")
  end

  def credential_scope(datetime)
    parts = []
    parts << datetime[0,8]
    parts << @region
    parts << @service_name
    parts << 'aws4_request'
    parts.join("/")
  end

  def canonical_request(request, body_digest)
    [
      request.method,
      path(request.uri),
      normalized_querystring(request.uri.query || ''),
      canonical_headers(request) + "\n",
      signed_headers(request),
      body_digest
    ].join("\n")
  end

  def path(uri)
    path = uri.path == '' ? '/' : uri.path
    if @service_name == 's3'
      path
    else
      path.gsub(/[^\/]+/) { |segment| Seahorse::Util.uri_escape(segment) }
    end
  end

  def normalized_querystring(querystring)
    params = querystring.split('&')
    params = params.map { |p| p.match(/=/) ? p : p + '=' }
    # We have to sort by param name and preserve order of params that
    # have the same name. Default sort <=> in JRuby will swap members
    # occasionally when <=> is 0 (considered still sorted), but this
    # causes our normalized query string to not match the sent querystring.
    # When names match, we then sort by their original order
    params = params.each.with_index.sort do |a, b|
      a, a_offset = a
      a_name = a.split('=')[0]
      b, b_offset = b
      b_name = b.split('=')[0]
      if a_name == b_name
        a_offset <=> b_offset
      else
        a_name <=> b_name
      end
    end.map(&:first).join('&')
  end

  def signed_headers(request)
    request.to_hash.keys.inject([]) do |signed_headers, header_key|
      header_key = header_key.downcase
      signed_headers << header_key unless header_key == 'authorization'
      signed_headers
    end.sort.join(';')
  end

  def canonical_headers(request)
    headers = []
    request.to_hash.each_pair do |k,v|
      k = k.downcase
      headers << [k,v] unless k == 'authorization'
    end
    headers = headers.sort_by(&:first)
    headers.map{|k,v| "#{k}:#{canonical_header_value(v.to_s)}" }.join("\n")
  end

  def canonical_header_value(value)
    value.match(/^".*"$/) ? value : value.gsub(/\s+/, ' ').strip
  end

  def host(uri)
    if standard_port?(uri)
      uri.host
    else
      "#{uri.host}:#{uri.port}"
    end
  end

  def standard_port?(uri)
    (uri.scheme == 'http' && uri.port == 80) ||
    (uri.scheme == 'https' && uri.port == 443)
  end

  def hexdigest(value)
    digest = OpenSSL::Digest::SHA256.new
    if value.respond_to?(:read)
      chunk = nil
      chunk_size = 1024 * 1024 # 1 megabyte
      digest.update(chunk) while chunk = value.read(chunk_size)
      value.rewind
    else
      digest.update(value)
    end
    digest.hexdigest
  end

  def hmac(key, value)
    OpenSSL::HMAC.digest(OpenSSL::Digest.new('sha256'), key, value)
  end

  def hexhmac(key, value)
    OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'), key, value)
  end

end
