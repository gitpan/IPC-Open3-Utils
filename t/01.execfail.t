use Test::More tests => 27;

use lib '../lib', 'lib';

chdir 't';

use IPC::Open3::Utils qw(:all);

BAIL_OUT("System does not have wrapper") if !-x '/usr/bin/ipc_open3_utils_wrap';

my %test_cmd = (
    'nvlskdjfvjkf' => 'possible PATH or shell cmd',
    './nvlskdjfvjkf' => 'non existant file',
    './non-executable' => 'non executable file',
);

for my $ne_cmd (sort keys %test_cmd){
    ok(!run_cmd($ne_cmd,{'handler' => sub { return 1; }}), $test_cmd{$ne_cmd} . ' nonexistant command gets failure RC ');
    my $oe;
    ok(!run_cmd($ne_cmd,{'handler' => sub { return 1; },'open3_error' => \$oe}), $test_cmd{$ne_cmd} . ' nonexistant command gets failure RC w/ open3_error');
    ok($oe,$test_cmd{$ne_cmd} . ' nonexistant command gets open3_error set');

    {
        local $? = 0;
        local $! = 42;
        my $mych;
        my $myen;
        ok($? == 0 && $! != 0 , $test_cmd{$ne_cmd} . ' pre test variable sanity check');
        my $rc = run_cmd($ne_cmd, {'handler' => sub { return 1; }, 
        'child_error_errno' => \$myen, 'child_error' => \$mych });
        ok(!$rc,$test_cmd{$ne_cmd} . ' rc is failed on non existant command w/ child_error');
        ok($mych == $?, $test_cmd{$ne_cmd} . ' child_error SCALAR matches $?');
        ok($myen == $!, $test_cmd{$ne_cmd} . ' child_error_errno SCALAR matches $!');
        ok($? == -1, $test_cmd{$ne_cmd} . ' child_error ARG as string gets $? set');
        ok($! != 42, $test_cmd{$ne_cmd} . ' child_error ARG as string gets $! set: ' .int($!));   
    }
}