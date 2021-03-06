package SerialDevice;

use strict;
use warnings;

use SerialPort;

use POSIX;
use IO::Handle;
use IO::Select;

use List::Util;

use Data::Dumper;

my $debug = 0;

my $max_queue = 4;

sub new {
	my $class = shift;
	my $port  = shift;
	my $baud  = shift;
	
	my $self = {
		device => $port,
		baud => $baud,
		queue => [],
		queues => {},
		queuesorder => [],
		lastqueue => 0,
		maxqueue => 4,
		rxbuffer => "",
		buffer_size => 256,
		token => 0,
		maxtoken => 1,
		readselect => undef,
		writeselect => undef,
		errorselect => undef,
		error => 0,
		listeners => {},
	};
	
	print STDERR "Open $port @ $baud\n" if $debug;
	
	$self->{port} = new Device::SerialPort($port) or die "cannot open port $port: $!";
	$self->{port}->databits(8);
	$self->{port}->baudrate(115200);
	$self->{port}->parity("none");
	$self->{port}->stopbits(1);
	$self->{port}->handshake("xoff"); # some firmwares support XON/XOFF, the gcode send/receive protocol does not allow for XON/XOFF characters in standard messages.
	$self->{port}->write_settings() or die "could not set $port options: $!";
	$self->{port}->read_const_time(0);
	$self->{port}->read_char_time(0);

	bless $self, $class;
	return $self;
}

sub add_listener {
	my $self = shift;
	my $listener = shift;
	$self->{listeners}->{$listener} = $listener;
}

sub remove_listener {
	my $self = shift;
	my $listener = shift;
	delete $self->{listeners}->{$listener};
}

sub canread {
	my $self = shift;
	if (length $self->{rxbuffer}) {
		if ($self->{rxbuffer} =~ /\n/) {
			return 1;
		}
	}
	return 0;
}

sub canwrite {
	my $self = shift;
	return $self->{token};
}

sub readline {
	my $self = shift;
	if (length $self->{rxbuffer}) {
	}
}

sub error {
	my $self = shift;
	$self->{error};
}

sub canenqueue {
	my $self = shift;
	my $queue = shift;
	if (!exists $self->{queues}->{Dumper \$queue}) {
		push @{$self->{queuesorder}}, Dumper\ $queue;
		$self->{queues}->{Dumper \$queue} = [];
	}
	return $max_queue - scalar @{$self->{queues}->{Dumper \$queue}};
}

sub enqueue {
	my $self = shift;
	my $queue = shift;
	if (!exists $self->{queues}->{Dumper \$queue}) {
		push @{$self->{queuesorder}}, Dumper\ $queue;
		$self->{queues}->{Dumper \$queue} = [];
	}
	printf STDERR "Enqueue: @_\n" if $debug;
	my $items = push @{$self->{queues}->{Dumper \$queue}}, @_;
	printf STDERR "Enqueued $items lines\n" if $debug;
	if ($self->{token}) {
		$self->{writeselect}->add($self->{port}->{HANDLE});
		#if (IO::Select::select(undef, $self->{writeselect}, undef, 0)) {
		#	select_canwrite();
		#}
	}
}

sub closequeue {
	my $self = shift;
	my $queue = shift;

	my $index = List::Util::first { $_ eq $queue } @{$self->{queuesorder}};
	if (defined $index) {
		splice @{$self->{queuesorder}}, $index, 1;

		delete $self->{queues}->{Dumper \$queue}
			if exists $self->{queues}->{Dumper \$queue};
	}
}

sub funnelqueues {
	my $self = shift;

	my $queuecount = 0;
	
	foreach (@{$self->{queuesorder}}) {
		$queuecount += scalar @{$self->{queues}->{$_}};
	}
	
	my $i = $self->{lastqueue} + 1;
	$i = 0 if $i >= scalar @{$self->{queuesorder}};
	while (scalar @{$self->{queue}} < $max_queue && $queuecount > 0) {
		
		my $queue = $self->{queuesorder}->[$i];
		
		printf "checking queue %d which has %d items\n", $i, scalar @{$self->{queues}->{$queue}} if $debug;
		
		if (@{$self->{queues}->{$queue}}) {
			push @{$self->{queue}}, shift @{$self->{queues}->{$queue}};
			$self->{lastqueue} = $i;
			$queuecount--;
		}
		
		$i++;
		$i = 0 if $i >= scalar @{$self->{queuesorder}};
	}
	return $queuecount;
}

sub select {
	my ($self, $readselect, $writeselect, $errorselect) = @_;
	$readselect->add($self->{port}->{HANDLE});
	$writeselect->add($self->{port}->{HANDLE})
		if $self->{token};
	$self->{readselect} = $readselect;
	$self->{writeselect} = $writeselect;
	$self->{errorselect} = $errorselect;
}

sub onselect {
	my ($self, $canread, $canwrite, $error) = @_;
	if (ref $error eq 'ARRAY') {
		for (@{$error}) {
			if ($_ == $self->{port}->{HANDLE}) {
				$self->select_error();
			}
		}
	}
	if (ref $canread eq 'ARRAY') {
		for (@{$canread}) {
			if ($_ == $self->{port}->{HANDLE}) {
				$self->select_canread();
			}
		}
	}
	if (ref $canwrite eq 'ARRAY') {
		for (@{$canwrite}) {
			if ($_ == $self->{port}->{HANDLE}) {
				$self->select_canwrite();
			}
		}
	}
}

sub select_ishandle {
	my ($self, $handle) = @_;
	return $self->{port}->{HANDLE} == $handle;
}

sub select_canread {
	my $self = shift;
	my ($count, $data) = $self->{port}->read(256);
	printf STDERR "read %d: %s\n", $count, $data if $debug && $count;
	if ((! defined $data) || $count == 0) {
		select_error();
	}
	else {
		$self->{rxbuffer} .= $data;
		while ($self->{rxbuffer} =~ s/^(.*?)\r?\n//s) {
			my $line = $1;
			printf STDERR "\tREAD '%s'\n", $line if $debug;
			for (keys %{$self->{listeners}}) {
				my $listener = $self->{listeners}->{$_};
				printf STDERR "\t found a %s\n", (ref $listener) if $debug;
				if (ref $listener eq 'CODE') {
					$listener->($self, $line);
				}
				elsif (ref $listener eq 'GLOB') {
					$listener->write("$line\n");
				}
				elsif ((ref $listener) =~ /^IO::Socket/) {
					$listener->write("$line\n");
					printf STDERR "\t\tWROTE %s to %s\n", $line, $listener if $debug;
				}
				elsif (ref $listener eq 'HASH' && exists $listener->{txqueue}) {
					push @{$listener->{txqueue}}, $line;
					if (exists $listener->{socket}) {
						$self->{writeselect}->add($listener->{socket});
					}
					if (exists $listener->{HANDLE}) {
						$self->{writeselect}->add($listener->{HANDLE});
					}
				}
			}
			if ($line =~ /ok/i || $line =~ /^start/i) {
				if ($line =~ /^start/i) {
					$self->{token} = 1;
				}
				elsif ($self->{token} < $self->{maxtoken}) {
					$self->{token}++;
				}
				$self->funnelqueues();
				printf STDERR "TOKEN: %d, QUEUE: %d\n", $self->{token}, scalar @{$self->{queue}} if $debug;
				if (@{$self->{queue}}) {
					$self->{writeselect}->add($self->{port}->{HANDLE});
				}
			}
		}
		printf STDERR "\t\tRXBUFFER has %d bytes: '%s'\n", length $self->{rxbuffer}, $self->{rxbuffer} if $debug;
	}
}

sub select_canwrite {
	my $self = shift;
	
	my $queuecount = $self->funnelqueues();
	
	if ($self->{token}) {
		if (@{$self->{queue}}) {
			my $line = shift @{$self->{queue}};
			printf STDERR "> %s\n", $line;
			$self->{port}->write($line."\n") or die "write failed: $!";
			$self->{token}--;
			printf STDERR "WROTE \"%s\", TOKEN %d, QUEUE %d\n", $line, $self->{token}, scalar @{$self->{queue}} if $debug;
			if ($self->{token} == 0) {
				$self->{writeselect}->remove($self->{port}->{HANDLE});
			}
		}
		elsif ($queuecount == 0) {
			$self->{writeselect}->remove($self->{port}->{HANDLE});
		}
	}
}

sub select_error {
	my $self = shift;
	$self->{error} = 1;
	undef $self->{port};
}

1;
