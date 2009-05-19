package IPC::Open3::Utils;

use strict;
use warnings;

$IPC::Open3::Utils::VERSION = 0.5;
require Exporter;
@IPC::Open3::Utils::EXPORT    = qw(run_cmd put_cmd_in);
@IPC::Open3::Utils::ISA       = qw(Exporter);
@IPC::Open3::Utils::EXPORT_OK = qw(
    run_cmd                 put_cmd_in              
    child_error_ok          child_error_failed_to_execute 
    child_error_exit_signal child_error_seg_faulted 
    child_error_core_dumped child_error_exit_value
    create_ipc_open3_utils_wrap_script
);
%IPC::Open3::Utils::EXPORT_TAGS = (
    'all' => \@IPC::Open3::Utils::EXPORT_OK,
    'cmd' => [qw(run_cmd put_cmd_in)],
    'err' => [qw(
        child_error_ok          child_error_failed_to_execute 
        child_error_exit_signal child_error_seg_faulted 
        child_error_core_dumped child_error_exit_value
    )],
);

require IO::Select;
require IPC::Open3;
require IO::Handle;

sub run_cmd {
    my @cmd = @_;
    my $arg_hr = ref $cmd[-1] eq 'HASH' ? pop(@cmd) : {};

    if ( ref $arg_hr->{'handler'} ne 'CODE') {
        $arg_hr->{'handler'} = sub {
            my ($cur_line, $stdin, $is_stderr, $is_open3_err, $short_circuit_loop_sr) = @_;
            if ($is_stderr) {
                print STDERR $cur_line;
            }
            else {
                print $cur_line;
            }
            
            return 1;
        };
    }

    if ($arg_hr->{'child_error'}) {
     
        $? = 0;
        $! = 0;
        if (!exists $arg_hr->{'child_error_uniq'}) {
            $arg_hr->{'child_error_uniq'} = rand();
        }
        
        if (!exists $arg_hr->{'child_error_wrapper'}) {
            $arg_hr->{'child_error_wrapper'} = 'ipc_open3_utils_wrap';
            if (-x "./$arg_hr->{'child_error_wrapper'}") {
                $arg_hr->{'child_error_wrapper'} = "./$arg_hr->{'child_error_wrapper'}";
            }
        }

        unshift @cmd, $arg_hr->{'child_error_wrapper'}, $arg_hr->{'child_error_uniq'};
    }

    
    my $stdout = IO::Handle->new();
    my $stderr = IO::Handle->new(); # TODO ? $arg_hr->{'combine_fhs'} ? $stdout : IO::Handle->new(); && then  no select()
    my $stdin  = IO::Handle->new();
    my $sel    = IO::Select->new();

    if (ref $arg_hr->{'autoflush'} eq 'HASH') {
        $stdout->autoflush(1) if $arg_hr->{'autoflush'}{'stdout'}; 
        $stderr->autoflush(1) if $arg_hr->{'autoflush'}{'stderr'};
        $stdin->autoflush(1)  if $arg_hr->{'autoflush'}{'stdin'};        
    }
    
    # this is kind of a hack so we don't have to wrap the 
    # open3() call in an eval {} (eval { open3() } can make funny things happen)
    if(!@cmd) {
        $! = 22;
        
        if (ref $arg_hr->{'open3_error'} eq 'SCALAR') {
            ${$arg_hr->{'open3_error'}} = "$!";
        }
        else {
            $arg_hr->{'open3_error'} = "$!";
        }

        if ( $arg_hr->{'carp_open3_errors'}) {
            require Carp;
            Carp::carp("$!");
        }
        
        return;
    }
    
    # this is a hack to work around an exit-before-use race condition
    local $SIG{'PIPE'} = exists $SIG{'PIPE'} && defined $SIG{'PIPE'} ? $SIG{'PIPE'} : '';
    my $current_sig_pipe = $SIG{'PIPE'};
    if (exists $arg_hr->{'pre_read_print_to_stdin'}) {
         $SIG{'PIPE'} = sub {
             # my $oserr = $!;
             # my $cherr = $?;
             $stdin->close;
             $stdout->close;
             $stderr->close;
             # $! = $oserr;
             # $? = $cherr;
             $current_sig_pipe->() if $current_sig_pipe && ref $current_sig_pipe eq 'CODE';
         };
    }
    
    my $child_pid = IPC::Open3::open3( $stdin, $stdout, $stderr, @cmd ); 
    if (exists $arg_hr->{'_pre_run_sleep'}) {
        if(my $sec = int($arg_hr->{'_pre_run_sleep'})) {
            sleep $sec; # undocumented, only for testing 
        }
    }

    $sel->add($stdout); # unless exists $arg_hr->{'ignore_handle'} && $arg_hr->{'ignore_handle'} eq 'stdout';
    $sel->add($stderr); # unless exists $arg_hr->{'ignore_handle'} && $arg_hr->{'ignore_handle'} eq 'stderr';
    
    if (exists $arg_hr->{'pre_read_print_to_stdin'}) {
        $stdin->printflush($arg_hr->{'pre_read_print_to_stdin'});
    }
    
    if($arg_hr->{'close_stdin'}) {
       $stdin->close();
       undef $stdin;
    }

    local *_;

    # to avoid "Modification of readonly value attempted" errors with @_
    # You ask, "Do you mean the _open3()'s or while()'s @_? " and the answer is: "exactly!" ;p

    my $is_open3_err = 0;
    my $return_bool  = 1;
    my $short_circuit_loop = 0;

    my $get_next = sub { readline(shift) };

    if (my $byte_size = int($arg_hr->{'read_length_bytes'} || 0)) {
        my $buffer;
        if ($arg_hr->{'child_error'}) {
            $byte_size = 128 if $byte_size < 128;
        }
        $get_next = sub { shift->sysread($buffer, $byte_size);return $buffer; };
    }
    
    my $caught_child;
    my $caught_oserr;
    READ_LOOP:
    while(my @ready = $sel->can_read) {
        HANDLE:
        for my $fh (@ready) {
            if ($fh->eof) {
                $fh->close;
                next HANDLE;
            }
            
            my $is_stderr = $fh eq $stderr ? 1 : 0;
            
            CMD_OUTPUT:
            while ( my $cur_line = $get_next->($fh) ) {
                next CMD_OUTPUT if exists $arg_hr->{'ignore_handle'} && $arg_hr->{'ignore_handle'} eq ($is_stderr ? 'stderr' : 'stdout');
                
                $is_open3_err = 1 if $is_stderr && $cur_line =~ m{^open3:};             
                if ($is_open3_err) {
                    if (ref $arg_hr->{'open3_error'} eq 'SCALAR') {
                        ${$arg_hr->{'open3_error'}} = $cur_line;
                    }
                    else {
                        $arg_hr->{'open3_error'} = $cur_line;
                    }

                    if ( $arg_hr->{'carp_open3_errors'}) {
                        require Carp;
                        Carp::carp($cur_line);
                    }
                }
                
                if ($arg_hr->{'child_error'}) {
                    if($cur_line =~ m{^IPC\:\:Open3\:\:Utils \-(\-?\d+)\-(\d+(?:\.\d+)?)\-(\d+)\-(.*)-$}) {
                        my($exit, $uniq, $errno, $wrapper_zero) = ($1,$2,$3,$4);
                        if ($uniq ne $arg_hr->{'child_error_uniq'})  {
                            if (ref $arg_hr->{'child_error_uniq_mismatch'} eq 'CODE') {
                                last READ_LOOP if $arg_hr->{'child_error_uniq_mismatch'}->($uniq, $arg_hr->{'child_error_uniq'}, $exit, $errno, $cur_line, $wrapper_zero);
                            }
                            next READ_LOOP;
                        }
                        else {
                            $caught_child = $exit;
                            $caught_oserr = $errno;
                            ${$arg_hr->{'child_error_wrapper_used'}} =  $wrapper_zero if ref $arg_hr->{'child_error_wrapper_used'} eq 'SCALAR';
                            ${$arg_hr->{'child_error'}} = $exit if ref $arg_hr->{'child_error'} eq 'SCALAR';
                            ${$arg_hr->{'child_error_errno'}} = $errno if ref $arg_hr->{'child_error_errno'} eq 'SCALAR'; 
                            last READ_LOOP;
                        }
                    }                 
                }

                $return_bool = $arg_hr->{'handler'}->($cur_line, $stdin, $is_stderr, $is_open3_err, \$short_circuit_loop);

                last READ_LOOP if !$return_bool;                
                last READ_LOOP if $is_open3_err && $arg_hr->{'stop_read_on_open3_err'}; # this is probably the last one anyway
                last READ_LOOP if $short_circuit_loop;
            }
        }
    }

    # my $oserr = $!;
    # my $cherr = $?;
    $stdout->close;
    $stderr->close;
    $stdin->close if defined $stdin && ref $stdin eq 'IO::Handle'; #  && !$arg_hr->{'close_stdin'};
    # $! = $oserr;
    # $? = $cherr;
    
    waitpid $child_pid, 0;
     
    if (defined $caught_child || defined $caught_oserr) {
        $? = $caught_child;
        $! = $caught_oserr;
        return if !child_error_ok($?);
    }
    
    return if $is_open3_err || !$return_bool;
    return 1;
}

sub put_cmd_in {
    my (@cmd) = @_;
    
    my $arg_hr = ref $cmd[-1] eq 'HASH' ? pop(@cmd) : {};

    # not being this strict allows us to do "no" output ref quietness
    # return if @cmd < 2;
    # return if defined $cmd[-1] && !ref $cmd[-1];
    # my $err = pop(@cmd);
    
    my $err = !defined $cmd[-1] || ref $cmd[-1] ? pop(@cmd) : undef;
    my $out = !defined $cmd[-1] || ref $cmd[-1] ? pop(@cmd) : $err;

    $arg_hr->{'handler'} = sub {
        my ($cur_line, $stdin, $is_stderr, $is_open3_err, $short_circuit_loop_sr) = @_;

        my $mod = $is_stderr ? $err : $out;
        return 1 if !defined $mod;
        
        if (ref $mod eq 'SCALAR') {
            ${ $mod } .= $cur_line;
        } 
        else {
            push @{ $mod }, $cur_line;
        }
        
        return 1;
    };
    
    return run_cmd(@cmd, $arg_hr);
}

#####################
#### child_error_* ##
#####################

sub child_error_ok {
    my $sysrc = @_ ? shift() : $?;
    return 1 if $sysrc eq '0';
    return; 
}

sub child_error_failed_to_execute {
    my $sysrc = @_ ? shift() : $?;
    return $sysrc == -1;
}

sub child_error_seg_faulted {
    my $sysrc = @_ ? shift() : $?;
    return child_error_exit_signal($sysrc) == 11; 
}

sub child_error_core_dumped {
    my $sysrc = @_ ? shift() : $?;
    return if child_error_failed_to_execute($sysrc);
    return $sysrc & 128; 
}

sub child_error_exit_signal {
    my $sysrc = @_ ? shift() : $?;
    return if child_error_failed_to_execute($sysrc);
    return $sysrc & 127;
}
 
sub child_error_exit_value {
    my $sysrc = @_ ? shift() : $?;
    return $sysrc >> 8;
}

sub create_ipc_open3_utils_wrap_script {
    my ($file, $mode) = @_;
    $file ||= '/usr/bin/ipc_open3_utils_wrap';
    $mode ||= '0755'; # 0755 fails 'Integer with leading zero' critic test

    my $contents = q(#!/usr/bin/perl
    my $id = $ARGV[0] =~ m{\d+(?:\.\d+)?} ? shift(@ARGV) : 0;
    {
        local $| = 1;
        local $! = 0;
        system @ARGV;
        print "IPC::Open3::Utils -$?-$id-" . int($!) . "-$0-\n";
    }
);
    
    if (open my $fh, '>', $file) {
        print {$fh} $contents; # or return; ?
        close $fh or return; # system quota
        
        $mode = oct($mode) if substr($mode,0,1) eq '0';
        chmod($mode,$file) or return; # $! already set    
    }
    else {
        return; # $! already set
    }
    
    return 1;
}

1; 

__END__

=head1 NAME

IPC::Open3::Utils - Functions for facilitating some of the most common open3() uses

=head1 VERSION

This document describes IPC::Open3::Utils version 0.5

=head1 DESCRIPTION

The goals of this module are:

=over 4

=item 1 Encapsulate logic done every time you want to use open3().

=item 2 boolean check of command execution

=item 3 Out of the box printing to STDOUT/STDERR or assignments to variables (see #6)

=item 4 Provide access to $? and $! like you have with system() (See L</TODO> for a note about this)

=item 5 open3() error reporting

=item 6 comprehensive but simple output processing handlers for flexibility (see #3)

=item 7 Lightweight utilities for examining the meaning of $? without POSIX

=back

=head1 SYNOPSIS

    use IPC::Open3::Utils qw(run_cmd put_cmd_in ...);

    
    run_cmd(@cmd); # like 'system(@cmd)'
    
    # like 'if (system(@cmd) != 0)'
    if (!run_cmd(@cmd)) {
        print "Oops you may need to re-run that command, it failed.\n1";   
    }

So far not too useful but its when you need more complex things than system()-like behavior 
(and why you are using open3() to begin with one could assume) that this module comes into play.

If you care about exactly what went wrong you can get very detailed:
 
    my $open3_error;
    if (!run_cmd(@cmd, {'open3_error' => \$open3_error, 'child_error' => 1, })) {
        print "open3() said: $open3_error\n" if $open3_error;
        
        if ($!) {
            print int($!) . ": $!\n";
        }
        
        if ($? ne '') {
            # we already know its not but we could use: child_error_ok($?);
        
            print "Command failed to execute.\n" if child_error_failed_to_execute($?);
            print "Command seg faulted.\n" if child_error_seg_faulted($?);
            print "Command core dumped.\n" if child_error_core_dumped($?);
            print "Command exited with signal: " . child_error_exit_signal($?) . ".\n";
            print "Command exited with value: " . child_error_exit_value($?) . ".\n";
        }
    }

You can slurp the output into variables:

    # both STDOUT/STDERR in one
    my @output;
    if (put_cmd_in(@cmd, \@output)) {
        print _my_stringify(\@output);
    }

    # seperate STDOUT/STDERR
    my @stdout;
    my $stderr;
    if (put_cmd_in(@cmd, \@stdout, \$stderr)) {
        print "The command ran ok\n";
        print "The output was: " . _my_stringify(\@stdout);
        if ($stderr) {
            print "However there were errors reported:" . _my_stringify($stderr);
        }
    }

You can look for a certain piece of data then stop processing once you have it:

   my $widget_value;
   run_cmd(@cmd, {
      'handler' => sub {
          my ($cur_line, $stdin, $is_stderr, $is_open3_err, $short_circuit_loop_boolean_scalar_ref) = @_;
          
          if ($cur_line =~ m{^\s*widget_value:\s*(\d+)}) {
              $widget_value = $1;
              ${ short_circuit_loop_boolean_scalar_ref } = 1;
          }
          
          return 1;
       },
   });
   
   if (defined $widget_value) {
       print "You Widget is set to $widget_value.";
   }
   else {
       print "You do not have a widget value set.";
   } 
   
You can do any or all of it!

=head1 EXPORT

All functions can be exported.

run_cmd() and put_cmd_in() are exported by default and via ':cmd'

:all will export, well, all functions

:err will export all child_error* functions.

=head1 INTERFACE 

Both of these functions:

=over 4

=item * take an array containing the command to run through open3() as its first arguments

=item * take an optional configuration hashref as the last argument (described below in L</%args>)

=item * return true if the command was executed successfully and false otherwise.

=back

=head2 run_cmd()

    run_cmd(@cmd)
    run_cmd(@cmd, \%args)

By default the 'handler' (see L</%args> below) prints the command's STDOUT and STDERR to perl's STDOUT and STDERR.

=head2 put_cmd_in()

Same %args as run_cmd() but it overrides 'handler' with one that populates the given "output" refs.

You can have one "output" ref to combine the command's STDERR/STDOUT into one variable. Or two, one for STDOUT and one for STDERR.

The ref can be an ARRAY reference or a SCALAR reference and are specified after the command and before the args hashref (if any)

    put_cmd_in(@cmd, \@all_output, \%args)
    put_cmd_in(@cmd, \$all_output, \%args)
    put_cmd_in(@cmd, \@stdout, \@stderr, \%args)
    put_cmd_in(@cmd, \$stdout, \$stderr, \%args)

To not waste memory on one that you are not interested in simply pass it undef for the one you don't care about.

    put_cmd_in(@cmd, undef, \@stderr, \%args);
    put_cmd_in(@cmd, \@stdout, undef, \%args)

Or quiet it up completely.

    put_cmd_in(@cmd, undef, undef, \%args)

or progressivley getting simpler:

    put_cmd_in(@cmd, undef, \%args);
    put_cmd_in(@cmd, \%args);
    put_cmd_in(@cmd);

Note that using one "output" ref does not gaurantee the output will be in the same order as it is when you execute the command via the shell due to the handling of the filehandles via L<IO::Select>. Due to that occasionally a test regarding single "output" ref testing will fail. Just run it again and it should be fine :)

=head2 %args

This is an optional 'last arg' hashref that configures behavior and functionality of run_cmd() and put_cmd_in()

Below are the keys and a description of their values.

=over 4

=item handler

A code reference that should return a boolean status. If it returns false run_cmd() and put_cmd_in() will also return false. 

If it returns true and assuming open3() threw no errors that'd make them return false then run_cmd() and put_cmd_in() will return true.

It gets the following arguments sent to it:

=over 4

=item 1 The current line of the command's output

=item 2 The command's STDIN IO::Handle object

=item 3 A boolean of whether or not the line is from the command's STDERR

=item 4 A boolean of whether or not the line is an error from open3()

=item 5 A scalar ref that when set to true will stop the while loop the command is running in.

This is useful for efficiency so you can stop processing the command once you get what you're interested in and still return true overall.

=back 

    'handler' => sub {
        my ($cur_line, $stdin, $is_stderr, $is_open3_err, $short_circuit_loop_boolean_scalar_ref) = @_;  
        ...
        return 1;
    },

=over 4

=item close_stdin

Boolean to have the command's STDIN closed immediately after the open3() call.

If this is set to true then the stdin variable in your handler's arguments will be undefined.

=item ignore_handle 

The value of this can be 'stderr' or 'stdout' and will cause the named handle to not even be included 
in the while() loop and hence never get to the 'handler'.

This might be useful to, say, make run_cmd() only print the command's STDERR.

   run_cmd(@cmd); # default handler prints the command's STDERR and STDOUT to perl's STDERR and STDOUT
   run_cmd(@cmd, { 'ignore_handle' => 'stdout' }); # only print the command's STDERR to perl's STDERR
   run_cmd(@cmd, { 'ignore_handle' => 'stderr' }); # only print the command's STDOUT to perl's STDOUT

=item autoflush

This is a hashref that tells which, if any, handles you want autoflush turned on for (IE $handle->autoflush(1) See L<IO::Handle>).

It can have 3 keys whose value is a boolean that, when true, will turn on the handle's autoflush before the open3() call.

Those keys are 'stdout', 'stderr', 'sdtin'

      run_cmd(@cmd, {
          'autoflush' => {
              'stdout' => 1,
              'stderr' => 1,
              'stdin' => 1, # open3() will probably already have done this but just in case you want to be explicit
          },
      });

=item read_length_bytes

Number of bytes to read from the command via sysread. The default is to use readline()

If 'child_error' is set and 'read_length_bytes' is less than 128 then 'read_length_bytes' gets reset to 128.

=item open3_error

This is the key that any open3() errors get put in for post examination. If it is a SCALAR ref then the error will be in the variable it references.
   
   my %args;
   if (!run_cmd(@cmd,\%args)) {
      # $args{'open3_error'} will have the error if it was from open3() 
   }

=item carp_open3_errors

Boolean to carp() errors from open3() itself. Default is false.

=item stop_read_on_open3_err

Boolean to quit the loop if an open3() error is thrown. This will more than likley happen anyway, this is just explicit. Default is false.

=item child_error

Setting this to a true allows for L</Getting the Child Error Code (IE $?) from an open3() call>.

This means, in short that $? and $! will be set like it is after a system() call.

If the value is a scalar reference then the value of the SCALAR refernced will be the Child Error Code of the command (IE $?)

Other related values are:

=over 4

=item child_error_errno

A SCALAR reference whose value will be the error number (IE: $! or ERRNO) of the command.

=item child_error_uniq

A unique identifier string to be used internally. Defaults to rand()

=item child_error_wrapper

The path to the "ipc_open3_utils_wrap" script. Defaults to './ipc_open3_utils_wrap' if it is executable or else 'ipc_open3_utils_wrap' and assumes its in the PATH.

=item child_error_uniq_mismatch

A code ref that will be called if the output looks like a "child error" line from ipc_open3_utils_wrap but whose uniq identifier does not match 'child_error_uniq'.

It gets passed the uniq id it found, the uniq id it expected, the child error it had ($?), the errno it had ($!), the current line, the wrapper script's $0.

If your code ref returns true it will stop the while loop over the command. Otherwise/by default it will simply not invoke the handler for that line and go to the next line.

=item child_error_wrapper_used

A SCALAR reference used to store the name of the script that ended up being used as the child_error_wrapper.

=back

=back

=back

=head2 Getting the Child Error Code (IE $?) from an open3() call

See L</TODO> for a note about this

This functionality is acheived by wrapping the command by a script that calls system() then outputs a specially formatted line indicating the values we are interested in.

If anyone has a better way to do this I'd be very ineterested!

The script can be in ., PATH, or specified via the L</%args> key 'child_error_wrapper'.

It can  be created with this convienience function:

=head3 create_ipc_open3_utils_wrap_script();

The first, optional argument, is the file to create/update. Defaults to /usr/bin/ipc_open3_utils_wrap.

The second, optional argument, is the mode. Defaults to 0755.

B<It is not recommended to call it something else besides 'ipc_open3_utils_wrap' as it will require the 'child_error_wrapper' key all the time.>

Returns true on success, false other wise. Be sure to check $! for the reason why it failed.

=head2 Child Error Code Exit code utilities

Each of these child_error* functions opertates on the value of $? or the argument you pass it.

=over 4

=item child_error_ok()
 
Returns true if the value indicates success.

    if ( child_error_ok(system(@cmd)) ) {
        print "The command was run successfully\n";
    }

=item child_error_failed_to_execute()

Returns true if the value indicates failure to execute.

=item child_error_seg_faulted()

Returns true if the value indicated that the execution had a segmentaton fault

=item child_error_core_dumped()

Returns true if the value indicated that the execution had a core dump

=item child_error_exit_signal()

Returns the exit signal that the value represents

=item child_error_exit_value()

Returns the exit value that the value represents

=back

=head1 DIAGNOSTICS

Throws no warnings or errors of its own. Capturing errors associated with a given command are documented above.

=head1 CONFIGURATION AND ENVIRONMENT

IPC::Open3::Utils requires no configuration files or environment variables.

=head1 DEPENDENCIES

L<IPC::Open3>, L<IO::Handle>, L<IO::Select>

=head1 INCOMPATIBILITIES

None reported.

=head1 BUGS AND LIMITATIONS

No bugs have been reported.

Please report any bugs or feature requests to
C<bug-ipc-open3-utils@rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org>.

=head1 TODO

 - clarify when wrapper is needed (e.g. SIGCHLD = ignore), improve/simplify/document non-wrapped erro value logic
 
 - abort loop, blocks ? (close before waitpid ?  autoflush() by default ? if not closed && !autoflushed() finish read ?)
 
 - 'blocking' $io->blocking($v)

 - add filehandle support to put_cmd_in()

 - find out why $! seems to always be 'Bad File Descriptor' on some systems

=head1 AUTHOR

Daniel Muey  C<< <http://drmuey.com/cpan_contact.pl> >>

=head1 LICENCE AND COPYRIGHT

Copyright (c) 2008, Daniel Muey C<< <http://drmuey.com/cpan_contact.pl> >>. All rights reserved.

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself. See L<perlartistic>.

=head1 DISCLAIMER OF WARRANTY

BECAUSE THIS SOFTWARE IS LICENSED FREE OF CHARGE, THERE IS NO WARRANTY
FOR THE SOFTWARE, TO THE EXTENT PERMITTED BY APPLICABLE LAW. EXCEPT WHEN
OTHERWISE STATED IN WRITING THE COPYRIGHT HOLDERS AND/OR OTHER PARTIES
PROVIDE THE SOFTWARE "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER
EXPRESSED OR IMPLIED, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE. THE
ENTIRE RISK AS TO THE QUALITY AND PERFORMANCE OF THE SOFTWARE IS WITH
YOU. SHOULD THE SOFTWARE PROVE DEFECTIVE, YOU ASSUME THE COST OF ALL
NECESSARY SERVICING, REPAIR, OR CORRECTION.

IN NO EVENT UNLESS REQUIRED BY APPLICABLE LAW OR AGREED TO IN WRITING
WILL ANY COPYRIGHT HOLDER, OR ANY OTHER PARTY WHO MAY MODIFY AND/OR
REDISTRIBUTE THE SOFTWARE AS PERMITTED BY THE ABOVE LICENCE, BE
LIABLE TO YOU FOR DAMAGES, INCLUDING ANY GENERAL, SPECIAL, INCIDENTAL,
OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OR INABILITY TO USE
THE SOFTWARE (INCLUDING BUT NOT LIMITED TO LOSS OF DATA OR DATA BEING
RENDERED INACCURATE OR LOSSES SUSTAINED BY YOU OR THIRD PARTIES OR A
FAILURE OF THE SOFTWARE TO OPERATE WITH ANY OTHER SOFTWARE), EVEN IF
SUCH HOLDER OR OTHER PARTY HAS BEEN ADVISED OF THE POSSIBILITY OF
SUCH DAMAGES.1
