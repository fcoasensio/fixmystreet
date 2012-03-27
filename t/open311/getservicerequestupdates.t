#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;
use CGI::Simple;

use FindBin;
use lib "$FindBin::Bin/../perllib";
use lib "$FindBin::Bin/../commonlib/perllib";

use_ok( 'Open311' );

use_ok( 'Open311::GetServiceRequestUpdates' );
use DateTime;
use FixMyStreet::App;

my $user = FixMyStreet::App->model('DB::User')->find_or_create(
    {
        email => 'system_user@example.com'
    }
);

my $requests_xml = qq{<?xml version="1.0" encoding="utf-8"?>
<service_requests_updates>
<request_update>
<update_id>638344</update_id>
<service_request_id>1</service_request_id>
<service_request_id_ext>1</service_request_id_ext>
<status>open</status>
<description>This is a note</description>
UPDATED_DATETIME
</request_update>
</service_requests_updates>
};


my $dt = DateTime->now;

# basic xml -> perl object tests
for my $test (
    {
        desc => 'basic parsing - element missing',
        updated_datetime => '',
        res => { update_id => 638344, service_request_id => 1, service_request_id_ext => 1, 
                status => 'open', description => 'This is a note' },
    },
    {
        desc => 'basic parsing - empty element',
        updated_datetime => '<updated_datetime />',
        res =>  { update_id => 638344, service_request_id => 1, service_request_id_ext => 1, 
                status => 'open', description => 'This is a note', updated_datetime => {} } ,
    },
    {
        desc => 'basic parsing - element with no content',
        updated_datetime => '<updated_datetime></updated_datetime>',
        res =>  { update_id => 638344, service_request_id => 1, service_request_id_ext => 1, 
                status => 'open', description => 'This is a note', updated_datetime => {} } ,
    },
    {
        desc => 'basic parsing - element with content',
        updated_datetime => sprintf( '<updated_datetime>%s</updated_datetime>', $dt ),
        res =>  { update_id => 638344, service_request_id => 1, service_request_id_ext => 1, 
                status => 'open', description => 'This is a note', updated_datetime => $dt } ,
    },
) {
    subtest $test->{desc} => sub {
        my $local_requests_xml = $requests_xml;
        $local_requests_xml =~ s/UPDATED_DATETIME/$test->{updated_datetime}/;

        my $o = Open311->new( jurisdiction => 'mysociety', endpoint => 'http://example.com', test_mode => 1, test_get_returns => { 'update.xml' => $local_requests_xml } );

        my $res = $o->get_service_request_updates;
        is_deeply $res->[0], $test->{ res }, 'result looks correct';

    };
}

my $problem_rs = FixMyStreet::App->model('DB::Problem');
my $problem = $problem_rs->new(
    {
        postcode     => 'EH99 1SP',
        latitude     => 1,
        longitude    => 1,
        areas        => 1,
        title        => '',
        detail       => '',
        used_map     => 1,
        user_id      => 1,
        name         => '',
        state        => 'confirmed',
        service      => '',
        cobrand      => 'default',
        cobrand_data => '',
        user         => $user,
        created      => DateTime->now()->subtract( days => 1 ),
        lastupdate   => DateTime->now()->subtract( days => 1 ),
        anonymous    => 1,
        external_id  => time(),
        council      => 2482,
    }
);

$problem->insert;

for my $test (
    {
        desc => 'element with content',
        updated_datetime => sprintf( '<updated_datetime>%s</updated_datetime>', $dt ),
        description => 'This is a note',
        external_id => 638344,
        start_state => 'confirmed',
        close_comment => 0,
        mark_fixed=> 0,
        mark_open => 0,
        end_state => 'confirmed',
    },
    {
        desc => 'comment closes report',
        updated_datetime => sprintf( '<updated_datetime>%s</updated_datetime>', $dt ),
        description => 'This is a note',
        external_id => 638344,
        start_state => 'confirmed',
        close_comment => 1,
        mark_fixed=> 1,
        mark_open => 0,
        end_state => 'fixed - council',
    },
    {
        desc => 'comment re-opens fixed report',
        updated_datetime => sprintf( '<updated_datetime>%s</updated_datetime>', $dt ),
        description => 'This is a note',
        external_id => 638344,
        start_state => 'fixed - user',
        close_comment => 0,
        mark_fixed => 0,
        mark_open => 1,
        end_state => 'confirmed',
    },
    {
        desc => 'comment re-opens closed report',
        updated_datetime => sprintf( '<updated_datetime>%s</updated_datetime>', $dt ),
        description => 'This is a note',
        external_id => 638344,
        start_state => 'closed',
        close_comment => 0,
        mark_fixed => 0,
        mark_open => 1,
        end_state => 'confirmed',
    },
    {
        desc => 'comment leaves report closed',
        updated_datetime => sprintf( '<updated_datetime>%s</updated_datetime>', $dt ),
        description => 'This is a note',
        external_id => 638344,
        start_state => 'closed',
        close_comment => 1,
        mark_fixed => 0,
        mark_open => 0,
        end_state => 'closed',
    },
) {
    subtest $test->{desc} => sub {
        my $local_requests_xml = $requests_xml;
        $local_requests_xml =~ s/UPDATED_DATETIME/$test->{updated_datetime}/;
        $local_requests_xml =~ s#<service_request_id>\d+</service_request_id>#<service_request_id>@{[$problem->external_id]}</service_request_id>#;
        $local_requests_xml =~ s#<service_request_id_ext>\d+</service_request_id_ext>#<service_request_id_ext>@{[$problem->id]}</service_request_id_ext>#;
        $local_requests_xml =~ s#<status>\w+</status>#<status>closed</status># if $test->{close_comment};

        my $o = Open311->new( jurisdiction => 'mysociety', endpoint => 'http://example.com', test_mode => 1, test_get_returns => { 'update.xml' => $local_requests_xml } );

        $problem->comments->delete;
        $problem->state( $test->{start_state} );
        $problem->update;

        my $council_details = { areaid => 2482 };
        my $update = Open311::GetServiceRequestUpdates->new( system_user => $user );
        $update->update_comments( $o, $council_details );

        is $problem->comments->count, 1, 'comment count';
        $problem->discard_changes;

        my $c = FixMyStreet::App->model('DB::Comment')->search( { external_id => $test->{external_id} } )->first;
        ok $c, 'comment exists';
        is $c->text, $test->{description}, 'text correct';
        is $c->mark_fixed, $test->{mark_fixed}, 'mark_closed correct';
        is $c->mark_open, $test->{mark_open}, 'mark_open correct';
        is $problem->state, $test->{end_state}, 'correct problem state';
    };
}

my $problem2 = $problem_rs->new(
    {
        postcode     => 'EH99 1SP',
        latitude     => 1,
        longitude    => 1,
        areas        => 1,
        title        => '',
        detail       => '',
        used_map     => 1,
        user_id      => 1,
        name         => '',
        state        => 'confirmed',
        service      => '',
        cobrand      => 'default',
        cobrand_data => '',
        user         => $user,
        created      => DateTime->now(),
        lastupdate   => DateTime->now(),
        anonymous    => 1,
        external_id  => $problem->external_id,
        council      => 2651,
    }
);

$problem2->insert();
$problem->comments->delete;
$problem2->comments->delete;

for my $test (
    {
        desc => 'identical external_ids on problem resolved using council',
        updated_datetime => sprintf( '<updated_datetime>%s</updated_datetime>', $dt ),
        external_id => 638344,
        area_id => 2651,
        request_id => $problem2->external_id,
        request_id_ext => $problem2->id,
        p1_comments => 0,
        p2_comments => 1,
    },
    {
        desc => 'identical external_ids on comments resolved',
        updated_datetime => sprintf( '<updated_datetime>%s</updated_datetime>', $dt ),
        external_id => 638344,
        area_id => 2482,
        request_id => $problem->external_id,
        request_id_ext => $problem->id,
        p1_comments => 1,
        p2_comments => 1,
    },
) {
    subtest $test->{desc} => sub {
        my $local_requests_xml = $requests_xml;
        $local_requests_xml =~ s/UPDATED_DATETIME/$test->{updated_datetime}/;
        $local_requests_xml =~ s#<service_request_id>\d+</service_request_id>#<service_request_id>$test->{request_id}</service_request_id>#;
        $local_requests_xml =~ s#<service_request_id_ext>\d+</service_request_id_ext>#<service_request_id_ext>$test->{request_id_ext}</service_request_id_ext>#;

        my $o = Open311->new( jurisdiction => 'mysociety', endpoint => 'http://example.com', test_mode => 1, test_get_returns => { 'update.xml' => $local_requests_xml } );


        my $council_details = { areaid => $test->{area_id} };
        my $update = Open311::GetServiceRequestUpdates->new( system_user => $user );
        $update->update_comments( $o, $council_details );

        is $problem->comments->count, $test->{p1_comments}, 'comment count for first problem';
        is $problem2->comments->count, $test->{p2_comments}, 'comment count for second problem';
    };
}

subtest 'using start and end date' => sub {
    my $local_requests_xml = $requests_xml;
    my $o = Open311->new( jurisdiction => 'mysociety', endpoint => 'http://example.com', test_mode => 1, test_get_returns => { 'update.xml' => $local_requests_xml } );

    my $start_dt = DateTime->now();
    $start_dt->subtract( days => 1 );
    my $end_dt = DateTime->now();


    my $update = Open311::GetServiceRequestUpdates->new( 
        system_user => $user,
        start_date => $start_dt,
    );

    my $res = $update->update_comments( $o );
    is $res, 0, 'returns 0 if start but no end date';

    $update = Open311::GetServiceRequestUpdates->new( 
        system_user => $user,
        end_date => $end_dt,
    );

    $res = $update->update_comments( $o );
    is $res, 0, 'returns 0 if end but no start date';

    $update = Open311::GetServiceRequestUpdates->new( 
        system_user => $user,
        start_date => $start_dt,
        end_date => $end_dt,
    );

    my $council_details = { areaid => 2482 };
    $update->update_comments( $o, $council_details );

    my $start = $start_dt . '';
    my $end = $end_dt . '';

    my $uri = URI->new( $o->test_uri_used );
    my $c = CGI::Simple->new( $uri->query );

    is $c->param('start_date'), $start, 'start date used';
    is $c->param('end_date'), $end, 'end date used';
};

$problem2->comments->delete();
$problem->comments->delete();
$problem2->delete;
$problem->delete;
$user->comments->delete;
$user->problems->delete;
$user->delete;

done_testing();
