#!/usr/bin/env ruby

require File.join(File.dirname(__FILE__), 'sign_v4.rb')
require File.join(File.dirname(__FILE__), 'param_list.rb')
require File.join(File.dirname(__FILE__), 'param.rb')
require 'net/http'
require 'ostruct'

credentials = OpenStruct.new(
  region: 'us-east-1',
  credentials: OpenStruct.new(
    access_key_id: ENV['AWS_ACCESS_KEY_ID'],
    secret_access_key: ENV['AWS_SECRET_ACCESS_KEY']
  )
)

bucket_name = 'beyahdev'

# 88       signer = Signers::V4.new(
#   89         context.config.credentials, 's3',
#   90         context.config.region
#   91       )
#   92       url = signer.presigned_url(
#     93         context.http_request,
#     94         expires_in: expires_in,
#     95         body_digest: "UNSIGNED-PAYLOAD"
#     96       )
# 
#

req = Net::HTTP::Get.new(URI('https://s3.amazonaws.com/' + bucket_name + '/testfile'))
FIFTEEN_MINUTES = 60 * 15

signer = SignV4.new(credentials, 's3', 'us-east-1')
url = signer.presigned_url(req, expires_in: FIFTEEN_MINUTES, body_digest: 'UNSIGNED-PAYLOAD')
puts url

res = Net::HTTP.start('s3.amazonaws.com', 443, use_ssl: true) do |http|
  http.request(signer.sign(req))
end

puts res.body
