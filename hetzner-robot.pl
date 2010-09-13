#!/usr/bin/perl
#
# Perl interface for the webservice interface
# provided by Hetzner
#
# by Stefan Tomanek <stefan.tomanek@wertarbyte.de>
#

use strict;

package Hetzner::Robot;
use LWP::UserAgent;
use JSON;
use HTTP::Request;
use URI::Escape;

our $BASEURL = "https://robot-ws.your-server.de";

sub new {
    my ($class, $user, $password) = @_;
    my $self = { user => $user, pass => $password };
    $self->{ua} = new LWP::UserAgent();
    $self->{ua}->env_proxy;
    bless $self, $class;
}
sub req {
    my ($self, $type, $url, $data) = @_;
    my $req = new HTTP::Request($type => $BASEURL.$url);
    $req->authorization_basic($self->{user}, $self->{pass});
    if ($data) {
        my @token = map( { uri_escape($_)."=".uri_escape($data->{$_}) } keys %$data );
        $req->content_type('application/x-www-form-urlencoded');
        $req->content( join("&", @token) );
    }
    my $res = $self->{ua}->request($req);
    if ($res->is_success) {
        if ($res->decoded_content) {
            return from_json($res->decoded_content);
        } else {
            return 1;
        }
    } else {
        die $res->code.": ".$res->message."\n";
        return undef;
    }
}
sub server {
    my ($self, $addr) = @_;
    return Hetzner::Robot::Server->new($self, $addr);
}
1;

package Hetzner::Robot::Item;

sub new {
    my ($class, $robot, $key) = @_;
    my $self = { robot => $robot, key => $key };
    bless $self, $class;
}
sub req {
    my ($self, @params) = @_;
    $self->robot->req(@params);
}
sub robot {
    my ($self) = @_;
    return $self->{robot};
}
sub key {
    my ($self) = @_;
    return $self->{key};
}
1;

package Hetzner::Robot::RDNS;
use base "Hetzner::Robot::Item";

sub addr {
    my ($self) = @_;
    return $self->key;
}

sub ptr {
    my ($self, $val) = @_;
    if (defined $val) {
        return $self->req("POST", "/rdns/".$self->key, { ptr => $val })->{rdns}{ptr};
    } else {
        return $self->req("GET", "/rdns/".$self->key)->{rdns}{ptr};
    }
}

sub del {
    my ($self) = @_;
    return $self->req("DELETE", "/rdns/".$self->key);
}
1;

package Hetzner::Robot::Rescue;
use base "Hetzner::Robot::Item";

sub status {
    my ($self) = @_;
    return $self->req("GET", "/boot/".$self->key);
}

sub active {
    return ( $_[0]->status()->{boot}{rescue}{active} ? 1 : 0 );
}

sub password {
    return $_[0]->status()->{boot}{rescue}{password};
}

sub available_os {
    return @{ $_[0]->status()->{boot}{rescue}{os} };
}

sub available_arch {
    return @{ $_[0]->status()->{boot}{rescue}{arch} };
}

sub enable {
    my ($self, $os, $arch) = @_;
    return $self->req("POST", "/boot/".$self->key."/rescue", {os => $os, arch => $arch});
}

sub disable {
    my ($self) = @_;
    return $self->req("DELETE", "/boot/".$self->key."/rescue");
}
1;

package Hetzner::Robot::Reset;
use base "Hetzner::Robot::Item";

sub available_methods {
    my ($self) = @_;
    return $self->req("GET", "/reset/".$self->key)->{"reset"}{"type"};
}

sub execute {
    my ($self, $method) = @_;
    $method = "sw" unless $method;
    return $self->req("POST", "/reset/".$self->key, {type=>$method});
}
1;

package Hetzner::Robot::WOL;
use base "Hetzner::Robot::Item";

sub execute {
    my ($self) = @_;
    return $self->req("POST", "/wol/".$self->key, {});
}
1;

package Hetzner::Robot::Server;
use base "Hetzner::Robot::Item";

sub wol {
    my ($self) = @_;
    return new Hetzner::Robot::WOL($self->robot, $self->key);
}

sub reset {
    my ($self) = @_;
    return new Hetzner::Robot::Reset($self->robot, $self->key);
}

sub rescue {
    my ($self) = @_;
    return new Hetzner::Robot::Rescue($self->robot, $self->key);
}

1;

##################################

package Hetzner::Robot::RDNS::main;
use Getopt::Long;

sub run {
    my $user = undef;
    my $pass = undef;

    my ($get, $set, $del);
    my ($addr, $name);

    my $batch = 0;

    sub abort {
        my ($msg) = @_;
        print STDERR $msg,"\n" if $msg;
        exit 1;
    }

    GetOptions (
        'username|user|u=s' => \$user,
        'password|pass|p=s' => \$pass,
        'get|g' => \$get,
        'set|s' => \$set,
        'delete|del|d' => \$del,
        'hostname|name|n=s' => \$name,
        'address|addr|a=s' => \$addr,
        'batch' => \$batch
    ) || abort;
# check command line
    abort "No user credentials specified!" unless (defined $user && defined $pass);
    abort "No operation specified!" unless ($get ^ $set ^ $del ^ $batch);
    unless ($batch) {
        abort "No address specified!" if (($get||$set||$del) && !defined $addr);
        abort "No hostname specified!" if ($set && !defined $name);
    }

    my $robot = new Hetzner::Robot($user, $pass);

    sub process {
        my ($addr, $name) = @_;
        my $rdns = new Hetzner::Robot::RDNS($robot, $addr);

        if ($get || $set) {
            if ($set) {
                print STDERR "Setting $addr to $name...\n";
                $rdns->ptr($name);
            }
            print $rdns->addr, "\t", $rdns->ptr, "\n";
        }
        if ($del) {
            print STDERR "Removing RDNS entry for $addr...\n";
            $rdns->del;
        }
    }

    if ($batch) {
        while (<STDIN>) {
            s/[[:space:]]*#.*$//;
            next if (/^$/);
            my ($addr, $name) = split(/[[:space:]]+/);
            my $i = new Hetzner::Robot::RDNS($robot, $addr);
            if ($name ne "") {
                print STDERR "Setting RDNS entry for $addr to $name...\n";
                $i->ptr($name);
            } else {
                print STDERR "Removing RDNS entry for $addr...\n";
                $i->del;
            }
            print $i->addr, "\t", $i->ptr, "\n";
        }
    } else {
        # handle a single change
        process($addr, $name);
    }
}

1;

if( ! (caller(0))[7]) {
    Hetzner::Robot::RDNS::main::run();
}

1;
