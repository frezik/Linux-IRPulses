package Linux::IRPulses;

use v5.14;
use warnings;
use Moose;
use namespace::autoclean;
use Moose::Exporter;

use constant DEBUG => 0;

# ABSTRACT: Parse LIRC pulse data

Moose::Exporter->setup_import_methods(
    as_is => [ 'pulse', 'space', 'pulse_or_space' ],
);
sub pulse ($) {[ 'pulse', $_[0] ]}
sub space ($) {[ 'space', $_[0] ]}
sub pulse_or_space ($) {[ 'either', $_[0] ]}


has 'fh' => (
    is => 'ro',
    required => 1,
);
has 'header' => (
    traits => ['Array'],
    is => 'ro',
    isa => 'ArrayRef[ArrayRef[Str]]',
    required => 1,
    handles => {
        header_length => 'count',
    },
);
has 'zero' => (
    traits => ['Array'],
    is => 'ro',
    isa => 'ArrayRef[ArrayRef[Str]]',
    required => 1,
    handles => {
        zero_length => 'count',
    },
);
has 'one' => (
    traits => ['Array'],
    is => 'ro',
    isa => 'ArrayRef[ArrayRef[Str]]',
    required => 1,
    handles => {
        one_length => 'count',
    },
);
has 'bit_count' => (
    is => 'ro',
    isa => 'Int',
    required => 1,
);
has '_bits' => (
    is => 'rw',
    isa => 'Int',
    default => 0,
);
has 'tolerance' => (
    is => 'ro',
    isa => 'Num',
    required => 1,
    default => 0.20,
);
has 'callback' => (
    is => 'ro',
    isa => 'CodeRef',
    required => 1,
);
has '_do_close_file' => (
    is => 'ro',
    isa => 'Bool',
    default => 0,
);
has '_do_end_loop' => (
    is => 'rw',
    isa => 'Bool',
    default => 0,
);
has '_did_see_header' => (
    is => 'rw',
    isa => 'Bool',
    default => 0,
);
has '_header_index' => (
    traits => ['Number'],
    is => 'rw',
    isa => 'Int',
    default => 0,
    handles => {
        _add_header_index => 'add',
    },
);
has '_bit_count' => (
    traits => ['Number'],
    is => 'rw',
    isa => 'Int',
    default => 0,
    handles => {
        _add_bit_count => 'add',
    },
);
has '_is_maybe_zero' => (
    is => 'rw',
    isa => 'Bool',
    default => 1,
);
has '_is_maybe_one' => (
    is => 'rw',
    isa => 'Bool',
    default => 1,
);
has '_zero_index' => (
    traits => ['Number'],
    is => 'rw',
    isa => 'Int',
    default => 0,
    handles => {
        _add_zero_index => 'add',
    },
);
has '_one_index' => (
    traits => ['Number'],
    is => 'rw',
    isa => 'Int',
    default => 0,
    handles => {
        _add_one_index => 'add',
    },
);


sub BUILDARGS
{
    my ($class, $args) = @_;

    if( exists $args->{dev_file} ) {
        my $file = delete $args->{dev_file};

        open( my $in, '<', $file ) or die "Can't open file '$file': $!\n";
        $args->{fh} = $in;
        $args->{'_do_close_file'} = 1;
    }

    return $args;
}


sub run
{
    my ($self) = @_;
    my $in = $self->fh;

    while(
        (! $self->_do_end_loop) 
        && (my $line = readline($in))
    ) {
        chomp $line;
        my $full_code = $self->_handle_line( $line );
        $self->callback->({
            pulse_obj => $self,
            code => $full_code,
        }) if defined $full_code;
    }

    close $in if $self->_do_close_file;
    return;
}

sub end
{
    my ($self) = @_;
    $self->_do_end_loop( 1 );
    return;
}


sub _handle_line
{
    my ($self, $line) = @_;
    warn "Matching: $line\n" if DEBUG;
    
    if( $self->_did_see_header ) {
        my $is_matched = 0;

        if( $self->_is_maybe_zero() ) {
            if( $self->_match_line( $line, $self->zero->[$self->_zero_index] ) ) {
                $self->_add_zero_index(1);
                if( $self->_zero_index >= $self->zero_length ) {
                    warn "\tWe have a complete zero signal\n" if DEBUG;
                    $self->_zero_index(0);
                    $self->_one_index(0);
                    $self->_is_maybe_zero(1);
                    $self->_is_maybe_one(1);
                    $self->_add_bit_count(1);
                    $self->_bits( $self->_bits() << 1 | 0 );
                    $is_matched = 1;
                }
                else {
                    warn "\tWe might have a zero, but we're not sure so sit tight\n"
                        if DEBUG;
                }
            }
            else {
                warn "\tIt's definately not a zero\n" if DEBUG;
                $self->_is_maybe_zero( 0 );
            }
        }

        if( (! $is_matched) && $self->_is_maybe_one() ) {
            if( $self->_match_line( $line, $self->one->[$self->_one_index] ) ) {
                $self->_add_one_index(1);
                if( $self->_one_index >= $self->one_length ) {
                    # We have a complete one signal, reset state
                    warn "\tWe have a complete one signal\n" if DEBUG;
                    $self->_zero_index(0);
                    $self->_one_index(0);
                    $self->_is_maybe_zero(1);
                    $self->_is_maybe_one(1);
                    $self->_add_bit_count(1);
                    $self->_bits( $self->_bits() << 1 | 1 );
                    $is_matched = 1;
                }
                else {
                    # Might be a one, but we're not sure yet, so sit tight
                    warn "\tWe might have a one, but we're not sure so sit tight\n"
                        if DEBUG;
                }
            }
            else {
                warn "\tIt's definately not a one\n" if DEBUG;
                $self->_is_maybe_one( 0 );
            }
        }

        if( $self->_bit_count >= $self->bit_count ) {
            warn "\tWe met our bit count, so call the callback\n" if DEBUG;
            $self->callback->({
                pulse_obj => $self,
                code => $self->_bits
            });

            $self->_zero_index(0);
            $self->_one_index(0);
            $self->_is_maybe_zero(1);
            $self->_is_maybe_one(1);
            $self->_bit_count(0);
            $self->_did_see_header(0);
            $self->_bits(0);

        }
        elsif( (! $self->_is_maybe_zero) && (! $self->_is_maybe_one) ) {
            warn "\tWe've gotten to a bad state where nothing looks right. Resetting.\n"
                if DEBUG;
            $self->_zero_index(0);
            $self->_one_index(0);
            $self->_is_maybe_zero(1);
            $self->_is_maybe_one(1);
            $self->_bit_count(0);
            $self->_did_see_header(0);
            $self->_bit_count(0);
        }
    }
    else {
        if( $self->_match_line( $line, $self->header->[$self->_header_index] ) ) {
            $self->_add_header_index(1);

            if( $self->_header_index >= $self->header_length ) {
                warn "\tWe have a complete, valid header\n" if DEBUG;
                $self->_did_see_header( 1 );
                $self->_header_index( 0 );
            }
            else {
                warn "\tHave a partial header, sit tight for now\n" if DEBUG;
            }
        }
        else {
            warn "\tThis isn't the part of the header we were expecting. Reset.\n" if DEBUG;
            $self->_did_see_header( 0 );
            $self->_header_index( 0 );
        }
    }

    return;
}

sub _match_line
{
    my ($self, $line, $expect) = @_;
    my ($expect_type, $expect_num) = @{ $expect };
    warn "\tMatching '$line', expecting '$expect_type $expect_num'\n" if DEBUG;
    my ($type, $num) = $line =~ /\A (pulse|space) \s+ (\d+) /x;
    $expect_type = $type if $expect_type eq 'either';

    return (
        $self->_is_value_in_range( $num, $expect_num )
        && ($expect_type eq $type)
    ) ? 1 : 0;
}

sub _is_value_in_range
{
    my ($self, $val, $target_val) = @_;
    my $tolerance = $self->tolerance;
    my $min = $target_val - ($target_val * $tolerance);
    my $max = $target_val + ($target_val * $tolerance);
    warn "\tMatching $min <= $val <= $max\n" if DEBUG;
    return (($min <= $val) && ($val <= $max)) ? 1 : 0;
}


no Moose;
__PACKAGE__->meta->make_immutable;
1;
__END__

