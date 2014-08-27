# Before 'make install' is performed this script should be runnable with
# 'make test'. After 'make install' it should work as 'perl gutil-JSON2-XS.t'

#########################

# change 'tests => 1' to 'tests => last_test_to_print';

use strict;
use warnings;

use Test::More tests => 15;
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
is_deeply(JSON::XS::ByteString::decode_json(JSON::XS::ByteString::encode_json([undef])), [undef], 'encode/decode undef');

{
    my $o = [1];
    $o->[0] = undef;
    is_deeply(JSON::XS::ByteString::decode_json(JSON::XS::ByteString::encode_json($o)), [undef], 'encode/decode dirty undef');
}

is(JSON::XS::ByteString::encode_json({"Cindy 好漂亮"=>1}), '{"Cindy 好漂亮":"1"}', 'encode utf8 hash key');
is_deeply(JSON::XS::ByteString::decode_json('{"Cindy 好漂亮":1}'), {"Cindy 好漂亮"=>1}, 'decode utf8 hash key');

{
    my $data = ["\x80"];
    is(JSON::XS::ByteString::encode_json($data), qq(["?"]), 'encode wrongly utf8');
    is_deeply($data, ["\x80"], 'wrongly utf8 back');
}

{
    my $data = ["\x43\x69\x6E\x64\x79\x20\x{597D}\x{6F02}\x{4EAE}"];
    JSON::XS::ByteString::encode_utf8($data);
    is_deeply($data, ["Cindy 好漂亮"], 'encode_utf8');

    JSON::XS::ByteString::decode_utf8($data);
    is_deeply($data, ["\x43\x69\x6E\x64\x79\x20\x{597D}\x{6F02}\x{4EAE}"], 'encode_utf8');
}

is(JSON::XS::ByteString::encode_json([join '', map { chr hex $_ } qw(C0 A2)]), '["??"]', "codepoint shoud be shorter");
is(JSON::XS::ByteString::encode_json([join '', map { chr hex $_ } qw(F5 84 81 B9)]), '["????"]', "codepoint after U+10FFFF");
