#!/etc/bin/perl


use strict;
use warnings;
use File::Path 'rmtree';
use Test::More;
use FindBin qw($Bin);
use File::Copy 'cp';

#making sure commands in HO Oncology part 1 and part 2 run ok

my $path = "$Bin/../../../bin/";
our $dir = 'Oncology_test';
my $model_dir = "HO_Oncology_files";
my @needed = <$model_dir/*>;
mkdir($dir);
foreach my $file (@needed){
	cp($file,$dir.'/.');
}
chdir($dir);
my @command_list=(
	[$path."execute run1sim.mod -model_dir_name","task 1:1"],
	[$path."execute run2.mod -model_dir_name","task 1:5 a"],
	[$path."sumo run2.lst","task 1:5 b"],
	[$path."execute run3.mod -model_dir_name","task 1:5 c"],
	[$path."sumo run3.lst","task 1:5 b"],
	[$path."execute run5.mod -model_dir_name","task 1:6 a"],
	[$path."sumo run5.lst","task 1:6 b"],
	[$path."vpc run2.mod -tte=RTTE -flip_comments -samples=20 -clean=2 -dir=vpc1 -stratify_on=ECOG,META,TSR6,BASET","task 7"],
	[$path."sse -samples=3  run2sim.mod -no-estimate_simulation -alternative_models=1_alt1.mod,2_alt1.mod,3_alt1.mod,4_alt1.mod","task 8c with only 3 samples due to runtime"] #this takes too long with original samples=100, just run 3 here instead of 100
	);
foreach my $ref (@command_list){
	my $command=$ref->[0];
	my $comment=$ref->[1];
	print "Running $comment:\n$command\n";
	my $rc = system($command);
	$rc = $rc >> 8;
	ok ($rc == 0, "$comment ");
}

chdir('..');
rmtree([ "./$dir" ]); #with all sub run dirs



done_testing();
