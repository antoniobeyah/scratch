#!/usr/bin/env ruby

require File.join(File.dirname(__FILE__), 'sign_v4.rb')
require 'net/http'
require 'ostruct'

credentials = OpenStruct.new(
  region: 'us-east-1',
  credentials: OpenStruct.new(
    access_key_id: ENV['AWS_ACCESS_KEY_ID'],
    secret_access_key: ENV['AWS_SECRET_ACCESS_KEY']
  )
)

signer = SignV4.new(credentials, 's3', 'us-east-1')

bucket_name = 'beyahdev'


res = Net::HTTP.start('s3.amazonaws.com', 443, use_ssl: true) do |http|
  req = Net::HTTP::Get.new(URI('https://s3.amazonaws.com/' + bucket_name + '/testfile'))
  http.request(signer.sign(req))
end

puts res.body
