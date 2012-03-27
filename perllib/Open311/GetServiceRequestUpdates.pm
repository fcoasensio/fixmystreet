package Open311::GetServiceRequestUpdates;

use Moose;
use Open311;
use FixMyStreet::App;

has council_list => ( is => 'ro' );
has system_user => ( is => 'ro' );
has start_date => ( is => 'ro', default => undef );
has end_date => ( is => 'ro', default => undef );

sub update_comments {
    my ( $self, $open311, $council_details ) = @_;

    my @args = ();

    if ( $self->start_date || $self->end_date ) {
        return 0 unless $self->start_date && $self->end_date;

        push @args, $self->start_date;
        push @args, $self->end_date;
    }

    my $requests = $open311->get_service_request_updates( @args );

    return 0 unless $open311->success;

    for my $request (@$requests) {
        my $request_id = $request->{service_request_id};

        # If there's no request id then we can't work out
        # what problem it belongs to so just skip
        next unless $request_id;

        my $problem =
          FixMyStreet::App->model('DB::Problem')
          ->search( {
                  external_id => $request_id,
                  council     => { like => '%' . $council_details->{areaid} . '%' },
          } );

        if (my $p = $problem->first) {
            my $c = $p->comments->search( { external_id => $request->{update_id} } );

            if ( !$c->first ) {
                my $comment = FixMyStreet::App->model('DB::Comment')->new(
                    {
                        problem => $p,
                        user => $self->system_user,
                        external_id => $request->{update_id},
                        text => $request->{description},
                        mark_fixed => 0,
                        mark_open => 0,
                        anonymous => 0,
                        name => $self->system_user->name
                    }
                );
                $comment->confirm;


                if ( $p->is_open and $request->{status} eq 'closed' ) {
                    $p->state( 'fixed - council' );
                    $p->update;

                    $comment->mark_fixed( 1 );
                } elsif ( ( $p->is_closed || $p->is_fixed ) and $request->{status} eq 'open' ) {
                    $p->state( 'confirmed' );
                    $p->update;

                    $comment->mark_open( 1 );
                }

                $comment->insert();
            }
        }
    }

    return 1;
}

1;
