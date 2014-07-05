# Before 'make install' is performed this script should be runnable with
# 'make test'. After 'make install' it should work as 'perl gutil-JSON2-XS.t'

#########################

# change 'tests => 1' to 'tests => last_test_to_print';

use strict;
use warnings;

use Test::More tests => 6;
BEGIN { use_ok('JSON::XS::ByteString') };

#########################

# Insert your test code below, the Test::More module is use()ed here so read
# its man page ( perldoc Test::More ) for help writing this test script.

my $data = ['Cindy 好漂亮', { Cindy => '最漂亮了' }];
my $json = JSON::XS::ByteString::encode_json($data);
is($json, '["Cindy 好漂亮",{"Cindy":"最漂亮了"}]', 'encode_json');
my $data2 = JSON::XS::ByteString::decode_json($json);
my $data3 = JSON::XS::ByteString::decode_json_safe($json);
is_deeply($data2, $data, 'decode_json');
is_deeply($data3, $data, 'decode_json');
my $json2 = JSON::XS::ByteString::encode_json_unsafe($data);
is($json2, '["Cindy 好漂亮",{"Cindy":"最漂亮了"}]', 'encode_json');
is_deeply([undef], JSON::XS::ByteString::decode_json(JSON::XS::ByteString::encode_json([undef])), 'encode/decode undef');
