#!/etc/bin/perl

# sse with uncertainty from rawres

use strict;
use warnings;
use Test::More;
use Test::Exception;
use File::Path 'rmtree';
use FindBin qw($Bin);
use lib "$Bin/../.."; #location of includes.pm
use includes; #file with paths to PsN packages and $path variable definition
use tool::cdd;
use output;
use model;
use File::Copy 'cp';
use File::Spec;


my $model_dir = $includes::testfiledir . "/";

my $orig_outobj = output->new(filename => 'run87.lst', 
							  directory => $model_dir.'/cdd/some_cov_fail');

my @cdd_models=();
for (my $i=1; $i<=10; $i++){
	push(@cdd_models,model->new(filename => $model_dir.'/cdd/some_cov_fail/cdd_'.$i.'.mod', 
								ignore_missing_data => 1));
}

my @ansofv=qw(-109.289575499971
-94.7399241251553
-102.268683266721
-89.5704698714267
-105.296516324303
-95.6584533210587
-93.7890522701952
-101.385700615357
-142.702843546687
-110.979184951016);

my @ansest=([28.2274,2.32394,0.214096,0.207504,0.327413,0.0556697,-0.263183,4.14975,0.00284936],
[28.8971,2.91297,0.217259,0.204975,0.34686,0.0459164,-0.261705,5.47917,0.00125305],
[27.5380,4.0316,0.220698,0.207074,0.332572,0.055555,-0.287371,5.24045,0.00003000],
[27.6420,4.52683,0.210685,0.208464,0.352573,0.0549477,-0.26287,4.2961,0.00165580],
[27.9135,3.30394,0.21078,0.209459,0.34064,0.0554607,-0.308989,5.81181,0.00128914],
[27.6374,2.38579,0.211667,0.202301,0.347491,0.0547836,-0.376041,5.7604,0.00199438],
[27.8704,5.07882,0.219304,0.206634,0.345311,0.0566534,-0.283089,3.9826,0.00214259],
[26.3749,3.86817,0.204632,0.21028,0.342087,0.0250208,-0.153761,4.56506,0.00003000],
[28.1101,1.26532,0.207786,0.232393,0.274204,0.0618226,-0.407205,7.55443,0.00962333],
[29.4169,2.41668,0.216791,0.20741,0.326752,0.0318506,-0.306876,6.51196,0.00400798]);

my @ansse=(
[2.41282,2.08258,0.0125755,0.00965854,0.0617790,0.0308678,0.13608,1.75420,0.00787879],
[2.30100,3.02348,0.0135446,0.00928655,0.0570912,0.0312844,0.1269880,2.44864,0.00744874],
[],
[2.39318,3.39450,0.0152301,0.0101768,0.0567051,0.0316574,0.1418220,1.75122,0.012029],
[2.45216,3.67235,0.0124386,0.00995314,0.0562108,0.0311090,0.1508180,2.96544,0.00838095],
[2.41414,2.94618,0.0131728,0.00757095,0.0562084,0.0312356,0.2167140,3.64628,0.00866654],
[2.41291,3.44968,0.0141049,0.00968238,0.0576850,0.0308702,0.1374210,1.31682,0.00753589],
[],
[],
[1.97964,3.03860,0.0137849,0.0100637,0.0611217,0.0228584,0.2039630,3.89333,0.007506880000000],
);
my ($ofvs,$estimates,$ses,$root_deter,$successful) = tool::cdd::get_ofv_estimates_se(cdd_models => \@cdd_models,
	problem_index => 0);


is_deeply($ofvs,\@ansofv,'get_ofv_estimates_se ofv');
is_deeply($estimates,\@ansest,'get_ofv_estimates_se estim');
is_deeply($ses,\@ansse,'get_ofv_estimates_se se');
cmp_float_array($root_deter,[undef,undef,undef,undef,8.5579888149120E-14,undef,undef,undef,undef,undef],'get_ofv_estimates_se too deter');
is($successful,10,'get_ofv_estimates_se count');

my $meanvec=[];
my $invchol=[];
my $sevec=[];
my $fullcov=[];

my ($error,$invdet)= linear_algebra::jackknife_inv_cholesky_mean_det($estimates,$invchol,$meanvec,$sevec,$fullcov);
is($error,0,'ok jackknife inv cholesky 0');

my $vector=[18.96898264410,  -15.09833381572,   1186.50670609803,   8895.49373461873,   762.64955074774,
	-2928.15555067374 , -873.30343537179, -45.31133211407,  -20757.84850901961];
for (my $i=0;$i<9;$i++){
	cmp_relative(abs($invchol->[8]->[$i]),abs($vector->[$i]),6,'chol 8'); #jackknife}
}
#foreach my $line (@{$invchol}){
#	print join(' ',@{$line})."\n";
#}

my $jackknife_ind_scores_facit =[[0.128102410284791,0.279205903606929,0.028336807112141,0.021415466175730,0.118376245812668,0.157819059674186,0.063963472442775,0.270569692150080,0.109246911107255],
[0.416279045043690,0.102221859224865,0.243275226526294,0.128450473998695,0.183811054307961,0.128011853703263,0.071507803483428,0.139902355570657,0.092656366116935],
[0.168551273458356,0.233889479021250,0.476968942734094,0.039614380119531,0.038210447421023,0.154457653200030,0.059502210379493,0.066195109379164,0.247349253594334],
[0.123799339734412,0.382689723999145,0.203454197826738,0.019214667280200,0.272585469158024,0.136660075591002,0.065561155538665,0.225382629984677,0.041716044436283],
[0.006970974291615,0.015251702108269,0.196998570307187,0.061326107685044,0.087158356886749,0.151694090597475,0.169849536791425,0.242608364171270,0.088091657961865],
[0.125778752187587,0.260622023082965,0.136723395466734,0.241622324895731,0.193616175219984,0.131850949153259,0.512111028630302,0.226734999867044,0.001107975711788],
[0.025517208363749,0.548544472752954,0.382241103131397,0.058236524620165,0.159741114065926,0.186647442835721,0.037645088920714,0.322178967455492,0.019853761127777],
[0.669041409172970,0.184784166264071,0.614779601783067,0.096073336401000,0.109643317203227,0.740379814656975,0.622499190392928,0.142338473920401,0.247349253594334],
[0.077627392728842,0.597286220507157,0.400452768133925,1.031963066724929,0.945191901292618,0.338136390928235,0.671185137257439,0.780660146000271,0.966027074620826],
	[0.639952652252405,0.251340599164044,0.211472766745762,0.025393833409956,0.128647537291032,0.540225203173139,0.159063899789463,0.458786851189423,0.255790611928206]];



my @jackknife_scores_matlab =qw( 
 315.013517097342
   158.566332922048
   76.680811384881
   277.384528652429
   285.459876225910
   269.561941218077
   387.719070345428
   197.951840874672
   1032.618986365173
   567.889443731215);

#my $ans_cook=[0,3.170302989709680,
#			  0.65269,1.34665,2.21297,1.66382,3.5193,1.98862,7.93781,59.76814,7.57732];

my @cook_matlab=qw(3.170302989709680
   1.688748627536337
   2.124978570238009
   1.411264227801416
   1.101918373487039
   4.163924682508454
   1.208984035596749
   8.601880029180297
  60.973505155513635
   8.373315686778515);

#rawres ratio  $ans_ratio = [1,1.06352,undef,undef,1.43112,2.32917,undef,3.17268,undef,undef,undef];

my @matlab_ratio=(undef,undef,undef,undef,0.089474167447793,undef,undef,undef,undef,undef);

my @origval = qw(-114.32816869952981 2.79297E+01  3.25318E+00  2.13679E-01  2.08010E-01  3.35031E-01 5.02845E-02 -2.75714E-01  5.02606E+00  1.98562E-03  2.22826E+00  2.98861E+00  1.27533E-02  9.91432E-03  5.46461E-02  2.83978E-02  1.31650E-01  2.16481E+00  7.67732E-03 );
my @cdd2val = qw(-94.739924125155298 2.88971E+01  2.91297E+00  2.17259E-01  2.04975E-01  3.46860E-01 4.59164E-02 -2.61705E-01  5.47917E+00  1.25305E-03 2.30100E+00  3.02348E+00  1.35446E-02  9.28655E-03  5.70912E-02 3.12844E-02  1.26988E-01  2.44864E+00 7.44874E-03    );
my @answer_changes = ();
my @par_cook_answers=();
for (my $i=0; $i< scalar(@origval); $i++){
	push(@answer_changes,100*($cdd2val[$i]- $origval[$i])/$origval[$i]);
	if ($i>0 and $i <10){
		push(@par_cook_answers,(abs($cdd2val[$i]- $origval[$i])/$origval[$i+9]));
	}
}
my @localc_bias=(9*0.03307,	-0.041774*9,	-0.0003092*9,	0.0016394*9,	-0.0014407*9,	-0.00051645*9,-0.015395*9,0.309113*9, 0.000501943*9);
my @rel_bias = ();
for (my $i=0; $i < scalar(@localc_bias); $i++){
	push(@rel_bias,100*$localc_bias[$i]/$origval[$i+1]);
}

my ($cook_scores,$cov_ratios,$parameter_cook_scores, $rel_changes,$bias, $rel_bias,
	$jackknife_cook,$jackknife_parameter_cook,$full_jackknife_cov,$sample_ofvs) = 
	tool::cdd::cook_scores_and_cov_ratios(original => $orig_outobj,
	cdd_models => \@cdd_models,
	bins => 10);
cmp_float_array($cook_scores,\@cook_matlab,'cook scores all');
cmp_float_array($cov_ratios,\@matlab_ratio,'cov ratios');
cmp_float_array($parameter_cook_scores->[1],\@par_cook_answers,'paramtere cook');
cmp_float_array($rel_changes->[1],\@answer_changes,'relative changes');
cmp_float_array($jackknife_cook,\@jackknife_scores_matlab,'jackknife cook scores');
for (my $i=0;$i<10; $i++){
	cmp_float_array($jackknife_parameter_cook->[$i],$jackknife_ind_scores_facit->[$i],'individual parameter jackknife cook scores '.$i);
}


cmp_float_array($bias,\@localc_bias,'bias');
cmp_float_array($rel_bias,\@rel_bias,'rel bias');


my $cddpheno=[[0.00557242,1.33455,0.250655,0.143693,0.0165084],
[0.00559714,1.33714,0.247025,0.144703,0.0164128],
[0.00551749,1.33043,0.245772,0.141863,0.0164914],
[0.00563405,1.34424,0.251609,0.141327,0.0169133],
[0.00552949,1.32783,0.246116,0.140417,0.0165176],
[0.00559138,1.33364,0.25473,0.143786,0.0156389],
[0.00557264,1.34174,0.255692,0.143605,0.0167847],
[0.00553893,1.34623,0.256507,0.142396,0.0168711],
[0.00556373,1.33948,0.255452,0.144513,0.0169883],
[0.00553945,1.335,0.251582,0.143633,0.0166557],
[0.00553414,1.32943,0.24503,0.140373,0.0162586],
[0.00554123,1.33557,0.257027,0.143658,0.016387],
[0.00562218,1.34461,0.251991,0.141781,0.0167472],
[0.00547781,1.35054,0.265512,0.144086,0.0157282],
[0.00554495,1.33537,0.251391,0.143661,0.0165122],
[0.00560483,1.33782,0.247472,0.144705,0.0167211],
[0.00561182,1.34124,0.24855,0.144409,0.0166909],
[0.00536408,1.35555,0.268453,0.147339,0.0148903],
[0.00556078,1.34158,0.255574,0.143995,0.0165503],
[0.00554183,1.34247,0.253957,0.144021,0.0168487],
[0.00551308,1.3321,0.25161,0.142227,0.0165415],
[0.00554908,1.33562,0.247406,0.14405,0.0166001],
[0.00550992,1.32089,0.233299,0.135654,0.0163553],
[0.0055158,1.3168,0.230523,0.132563,0.0162858],
[0.00570526,1.33468,0.250302,0.144522,0.0141208],
[0.00553174,1.31974,0.240067,0.133656,0.0161962],
[0.0055286,1.33586,0.248602,0.144012,0.0164874],
[0.00555354,1.32253,0.244196,0.134436,0.016093],
[0.00556765,1.34404,0.249358,0.143737,0.0165918],
[0.00552083,1.32751,0.248427,0.140134,0.016213],
[0.00555524,1.33942,0.247282,0.144695,0.0164984],
[0.00556449,1.31157,0.238146,0.127051,0.0162179],
[0.0055587,1.33258,0.247905,0.142911,0.0165227],
[0.00554775,1.3325,0.248804,0.142888,0.0164718],
[0.00555273,1.32758,0.248298,0.139605,0.0163683],
[0.00547903,1.33792,0.252624,0.144247,0.0163379],
[0.00556922,1.33768,0.253742,0.144181,0.0165332],
[0.00552169,1.33451,0.253981,0.143455,0.0163734],
[0.00549836,1.32962,0.245616,0.141167,0.0164873],
[0.00556082,1.33563,0.245238,0.144235,0.0166702],
[0.00554725,1.32793,0.245132,0.14037,0.0165629],
[0.00554874,1.31369,0.235687,0.129467,0.015947],
[0.00554651,1.351,0.253144,0.139504,0.0166786],
[0.00551709,1.33469,0.254512,0.143218,0.0165866],
[0.00562158,1.34391,0.250819,0.142047,0.0169803],
[0.00555423,1.34158,0.248115,0.144548,0.016539],
[0.00554396,1.32591,0.244183,0.137992,0.0161759],
[0.00588402,1.39956,0.0648003,0.166824,0.0171117],
[0.00555652,1.3339,0.252174,0.143414,0.0164705],
[0.0055874,1.3466,0.256545,0.140266,0.017015],
[0.00561649,1.33945,0.248087,0.145368,0.0157626],
[0.00540082,1.36475,0.261979,0.130308,0.0162831],
[0.00556904,1.33345,0.24606,0.143216,0.0163979],
[0.00555518,1.33483,0.249847,0.143657,0.0169657],
[0.00553329,1.33288,0.2464,0.142241,0.0163433],
[0.00559046,1.3558,0.257954,0.128665,0.016677],
[0.0055337,1.32633,0.245155,0.139596,0.0162674],
[0.00552992,1.33933,0.251914,0.144364,0.0166919],
	[0.00562201,1.34253,0.250845,0.143049,0.016901]];


$meanvec=[];
$invchol=[];
$sevec=[];
$fullcov=[];

($error,$invdet)= linear_algebra::jackknife_inv_cholesky_mean_det($cddpheno,$invchol,$meanvec,$sevec,$fullcov);
is($error,0,'ok jackknife inv cholesky');

cmp_float_array($meanvec,[0.005556306949153,1.336972203389830,0.246591106779661,0.141788203389830,0.016431188135593],
	'meanvec jackknife');
cmp_float_array($sevec,[0.000503201324008, 0.097001318878544, 0.188526823663372, 0.041766795157592 ,  0.003624328667558],'sevec jackknife');
#cmp_float($invdet,3.707935032766232e+13,'sqrt determinant inverse');
my $matlabfullcov=[  [ 0.000000253211572,0.000018175066088 , -0.000063553522824,0.000009940651661,0.000000370759664],
	[   0.000018175066088,0.009409255864177 , -0.008281985621341,0.002425451061804,0.000077149013143],
 [ -0.000063553522824 , -0.008281985621341,0.035542363240600 , -0.003828499600677,  -0.000130556085484],
  [ 0.000009940651661,0.002425451061804,  -0.003828499600677,0.001744465177736,0.000020409830316],
[  0.000000370759664,0.000077149013143 , -0.000130556085484,0.000020409830316,0.000013135758290]];

for (my $i=0; $i<5; $i++){
	cmp_float_array($fullcov->[$i],$matlabfullcov->[$i],'fullcov pheno '.$i);
}

my $data=[ [0.032557464164973,   1.528973417062025],
   [0.552527021112224 ,  0.863994820399939],
   [1.100610217880866 ,  1.628452512386418],
   [1.544211895503951 ,  0.459324344835354],
   [0.085931133175425 ,  0.008454705761949],
  [-1.491590310637609 , -0.005920811002033],
  [-0.742301837259857 ,  1.345130990560160],
  [-1.061581733319986 ,  0.874470667021703],
   [2.350457224002042 ,  0.861604296404869],
	[-0.615601881466894 ,  2.003542261902062]
];	

$meanvec=[];
$invchol=[];
$sevec=[];
$fullcov=[];
($error,$invdet)= linear_algebra::jackknife_inv_cholesky_mean_det($data,$invchol,$meanvec,$sevec,$fullcov);
is($error,0,'ok jackknife inv cholesky');

cmp_float_array($meanvec,[ 0.175521919315513, 0.956802720533245],'meanvec jackknife');
cmp_float_array($sevec,[3.473788637706692 ,1.926339961708588 ],'sevec jackknife');
#cmp_float($invdet,1.211004182548487,'sqrt determinant inverse'); #regular cov
cmp_float($invdet,0.149506689203517,'sqrt determinant inverse'); #jackknife

#cmp_float_array($invchol->[0],[ 0.819292763888603  ,      0],' chol 1'); #regular cov
#cmp_float_array($invchol->[1],[-0.024679534277344 ,1.478109213122678],'chol 2'); #regular cov

cmp_float_array($invchol->[0],[ 0.287870133820282 ,      0],' chol 1'); #jackknifr
cmp_float_array($invchol->[1],[-0.008671504434290  , 0.519354638216323],'chol 2'); #jackknife
cmp_float_array($fullcov->[0],[12.067207499460114,   0.201482446946927],'fullcov 1');
cmp_float_array($fullcov->[1],[ 0.201482446946927,   3.710785648075446],'fullcov 2');

my $data2=[ [0.032557464164973,   1.528973417062025],
			[],
   [0.552527021112224 ,  0.863994820399939],
			[1.100610217880866 ,  1.628452512386418],
			[],
			[],
   [1.544211895503951 ,  0.459324344835354],
   [0.085931133175425 ,  0.008454705761949],
  [-1.491590310637609 , -0.005920811002033],
  [-0.742301837259857 ,  1.345130990560160],
			[-1.061581733319986 ,  0.874470667021703],
			[],
			[],
   [2.350457224002042 ,  0.861604296404869],
	[-0.615601881466894 ,  2.003542261902062]
];	


$sevec=[];
$meanvec=[];
$invchol=[];
$fullcov=[];
($error,$invdet)= linear_algebra::jackknife_inv_cholesky_mean_det($data2,$invchol,$meanvec,$sevec,$fullcov);
is($error,0,'ok jackknife inv cholesky 2');

cmp_float_array($meanvec,[ 0.175521919315513, 0.956802720533245],'meanvec jackknife 2');
cmp_float_array($sevec,[3.473788637706692 ,1.926339961708588 ],'sevec jackknife 2');
cmp_float($invdet,0.149506689203517,'sqrt determinant inverse 2'); #jackknife

cmp_float_array($invchol->[0],[ 0.287870133820282 ,      0],' chol 1 2'); #jackknifr
cmp_float_array($invchol->[1],[-0.008671504434290  , 0.519354638216323],'chol 2 2'); #jackknife
cmp_float_array($fullcov->[0],[12.067207499460114,   0.201482446946927],'fullcov 1 b');
cmp_float_array($fullcov->[1],[ 0.201482446946927,   3.710785648075446],'fullcov 2 b');


done_testing();
