package tool::frem;

use include_modules;
use tool::modelfit;
use Math::Random;
use Data::Dumper;
use Config;
use linear_algebra;
use ui;
use File::Copy qw/cp mv/;


use Moose;
use MooseX::Params::Validate;

extends 'tool';

my $joindata = 'data_plus_conditional_tv.tab';
my $fremtype = 'FREMTYPE'; 
my $name_check_model = 'check_data.mod';
my $name_model0 = 'model_0.mod';
my $name_model1 = 'model_1.mod';
my $name_model2_all = 'model_2.mod';
my $name_model2_timevar = 'model_2_timevar.mod';
my $name_model2_invar = 'model_2_invariant.mod';
my $name_model3 = 'model_3.mod';
my $name_modelvpc_1 = 'vpc_model_1.mod';
my $name_modelvpc_2 = 'vpc_model_2.mod';
my $data2name = 'frem_data2.dta';
my $undefined = 'undefined';

has 'bsv_parameters' => ( is => 'rw', isa => 'Int' );
has 'start_eta' => ( is => 'rw', isa => 'Int', default => 1 );
has 'bov_parameters' => ( is => 'rw', isa => 'Int' );
has 'done_file' => ( is => 'rw', isa => 'Str', default => 'template_models_done.pl');
#has 'original_data' => ( is => 'rw', isa => 'Str');
has 'filtered_datafile' => ( is => 'rw', isa => 'Str' );
has 'estimate' => ( is => 'rw', isa => 'Int', default => -1 );
has 'typeorder' => ( is => 'rw', isa => 'ArrayRef', default => sub { [] } );
has 'occasionlist' => ( is => 'rw', isa => 'ArrayRef[Int]', default => sub { [] } );
has 'extra_input_items' => ( is => 'rw', isa => 'ArrayRef[Str]', default => sub { [] } );
has 'invariant_median' => ( is => 'rw', isa => 'ArrayRef', default => sub { [] } );
has 'timevar_median' => ( is => 'rw', isa => 'ArrayRef', default => sub { [] } );
has 'invariant_covmatrix' => ( is => 'rw', isa => 'ArrayRef', default => sub { [] } );
has 'timevar_covmatrix' => ( is => 'rw', isa => 'ArrayRef', default => sub { [] } );
has 'check' => ( is => 'rw', isa => 'Bool', default => 1 );
has 'vpc' => ( is => 'rw', isa => 'Bool', default => 0 );
has 'dv' => ( is => 'rw', isa => 'Str', default => 'DV' );
has 'occasion' => ( is => 'rw', isa => 'Str', default => 'OCC' );
has 'parameters' => ( is => 'rw', isa => 'ArrayRef[Str]' );
has 'time_varying' => ( is => 'rw', isa => 'ArrayRef[Str]' );
has 'invariant' => ( is => 'rw', isa => 'ArrayRef[Str]' );
has 'final_model_directory' => ( is => 'rw', isa => 'Str' );
has 'logfile' => ( is => 'rw', isa => 'ArrayRef', default => sub { ['frem.log'] } );
has 'results_file' => ( is => 'rw', isa => 'Str', default => 'frem_results.csv' );



sub BUILD
{
	my $this  = shift;

	for my $accessor ('logfile','raw_results_file','raw_nonp_file'){
		my @new_files=();
		my @old_files = @{$this->$accessor};
		for (my $i=0; $i < scalar(@old_files); $i++){
			my $name;
			my $ldir;
			( $ldir, $name ) =
			OSspecific::absolute_path( $this ->directory(), $old_files[$i] );
			push(@new_files,$ldir.$name) ;
		}
		$this->$accessor(\@new_files);
	}	

	foreach my $model ( @{$this -> models} ) {
		foreach my $problem (@{$model->problems()}){
			if (defined $problem->nwpri_ntheta()){
				ui -> print( category => 'all',
					message => "Warning: frem does not support \$PRIOR NWPRI.",
					newline => 1);
				last;
			}
		}
	}

	if ( scalar (@{$this -> models->[0]-> problems}) > 1 ){
		croak('Cannot have more than one $PROB in the input model.');
	}

	#checks left for frem->new:
#checks left for frem->new: occ and dv exist in $INPUT if needed. type exists in $INPUT if given. 
	#if bov_parameters is > 0 then must have occasion in $input
	#must have dv in $input

	my $occ_ok=1;
	my $dv_ok=0;

	if (scalar(@{$this->parameters()})>0){
		$occ_ok=0;
	}

	my $prob = $this -> models->[0]-> problems -> [0];
	if (defined $prob->priors()){
		croak("frem does not support \$PRIOR");
	}

	if( defined $prob -> inputs and defined $prob -> inputs -> [0] -> options ) {
		foreach my $option ( @{$prob -> inputs -> [0] -> options} ) {
			unless (($option -> value eq 'DROP' or $option -> value eq 'SKIP'
						or $option -> name eq 'DROP' or $option -> name eq 'SKIP')){
				$dv_ok = 1 if ($option -> name() eq $this->dv()); 
#				$type_ok = 1 if ($option -> name() eq $this->type()); 
				$occ_ok = 1 if ($option -> name() eq $this->occasion()); 
			}
		}
#		croak("type column ".$this->type()." not found in \$INPUT" ) unless $type_ok;
		croak("dependent column ".$this->dv()." not found in \$INPUT" ) unless $dv_ok;
		croak("occasion column ".$this->occasion()." not found in \$INPUT" ) unless $occ_ok;
	} else {
		croak("Trying to check parameters in input model".
			" but no headers were found in \$INPUT" );
	}
}

sub create_template_models
{
	my $self = shift;
	my %parm = validated_hash(\@_,
		 model => { isa => 'Ref', optional => 0 }
	);
	my $model = $parm{'model'};


	#variables to store 
	my $n_invariant	= scalar(@{$self->invariant()});
	my $n_time_varying = scalar(@{$self->time_varying()});
	my $n_occasions;
	my $total_orig_etas;
	my $start_omega_record;
	my %theta_parameter;
	my $use_pred;
	my %oldstring_to_CTVpar;
	my @etanum_to_thetanum;
	my $start_eta = $self->start_eta();
	my $bsv_parameters;
	my $bov_parameters = scalar(@{$self->parameters()});
	my $phi_file_0;

	#local objects
	my $frem_model0;
	my $output_0;
	my $frem_model1;
	my $frem_model2;
	my $frem_model2_timevar;
	my $frem_model2_invar;
	my $frem_model3;
	my $frem_vpc_model1;
	my $frem_vpc_model2;
	my @leading_omega_records=();
	my $filter_data_model;
	my $data_check_model;
	my $data2_data_record;
	my $mod0_ofv;

	if ($model -> is_run()){
		$output_0 =  $model ->outputs()->[0];
		$phi_file_0 = $model -> directory().$model->filename();
		if ( defined $output_0){
			$mod0_ofv = $output_0->get_single_value(attribute=> 'ofv');
		}else{
			$mod0_ofv = $undefined;
		}
	}else{
		$mod0_ofv = $undefined;
	}

	#copy original data to m1. Then only use that file, use relative data path in modelfits
	#only set data record string in all models, do not mess with data object and chdir and such
	#since we are not running any models here

	my $original_data_name = '../'.$model->datas->[0]->filename();
	cp($model->datas->[0]->full_name(),$self->directory().'/'.$model->datas->[0]->filename());
	$start_omega_record = $model-> problems -> [0]->check_start_eta(start_eta => $start_eta);
	for (my $i=0; $i< ($start_omega_record-1);$i++){
		#if start_omega_record is 1 we will push nothing
		push(@leading_omega_records,$model-> problems -> [0]->omegas->[$i]);
	}
	
	##########################################################################################
	#Create Model 0
	##########################################################################################
	$frem_model0 = $model ->  copy( filename    => $self -> directory().'m1/'.$name_model0,
									output_same_directory => 1,
									copy_data   => 0,
									copy_output => 0);
	#Update inits from output, if any
	if (defined $output_0){
		$frem_model0 -> update_inits ( from_output => $output_0,
									   problem_number => 1);
	}
	#set the data file name without changing data object. Always first option in data record
#	$frem_model0->problems->[0]->datas->[0]->options->[0]->name($original_data_name);
	$frem_model0 ->_write();
	#read number of etas already in model and set bsv_parameters
	$total_orig_etas = $frem_model0->problems->[0]->nomegas( with_correlations => 0,
															 with_same => 1);
	$bsv_parameters = ($total_orig_etas-$start_eta+1);
	
	##########################################################################################
	#Create data set 2
	##########################################################################################
	$self->create_data2(model=>$frem_model0,
						filename => $self -> directory().'m1/filter_data_model.mod',
						bov_parameters => $bov_parameters);
	
	$n_occasions = scalar(@{$self->occasionlist()}); #attribute set inside createdata2
	
	##########################################################################################
	#Create Data check model
	##########################################################################################
	
	$data_check_model = $frem_model0 ->  copy( filename    => $self -> directory().'m1/'.$name_check_model,
											   output_same_directory => 1,
											   copy_data   => 0,
											   copy_output => 0);
	
	#need to set data object , setting record not enough
	#chdir so can use local data file name
	chdir($self -> directory().'m1');
	$data_check_model->datafiles(problem_numbers => [1],
								 absolute_path =>1,
								 new_names => [$data2name]);
	chdir($self -> directory());

	# have filtered data so can skip old accept/ignores. Need ignore=@ since have a header
	#change data file name to local name so that not too long.
	$data_check_model-> set_records(type => 'data',
									record_strings => [$data2name.' IGNORE=@ IGNORE=('.$fremtype.'.GT.0)']);
	
	foreach my $item (@{$self->extra_input_items()}){
		$data_check_model -> add_option(problem_numbers => [1],
										record_name => 'input',
										option_name => $item);
	}
	$data_check_model ->_write();

	my @run1_models=();
	my $run1_message = "\nExecuting ";
	my $run1_name = '';

	if ((not defined $output_0) and (($self->estimate() >= 0) or ($self->check()))){
		#estimate model 0 if no lst-file found and estimation is requested or check of dataset is requested
		push(@run1_models,$frem_model0);
		$run1_message = 'FREM Model 0 ';
		$run1_message .= 'and ' if ($self->check());
		$run1_name='model0';
		$run1_name .= '_' if ($self->check());
	}

	if ($self->check()){
		$run1_message .= 'Data2 check model';
		push(@run1_models,$data_check_model);
		$run1_name .= 'data2check';
	}
	if (scalar (@run1_models)>0){
	  ##########################################################################################
	  #Estimate model 0 and/or data check model
	  ##########################################################################################
		my $run1_fit = tool::modelfit ->
			new( %{common_options::restore_options(@common_options::tool_options)},
				 base_directory	 => $self -> directory(),
				 directory		 => $self -> directory().'/'.$run1_name.'_modelfit_dir1',
				 models		 => \@run1_models,
#		   raw_results           => undef,
				 top_tool              => 0);
#		   %subargs );
		
		ui -> print( category => 'all', message =>  $run1_message);
		$run1_fit -> run;
		if ($frem_model0 -> is_run()){
			$output_0 = $frem_model0 -> outputs -> [0] ;
			$phi_file_0 = $frem_model0 -> directory().$frem_model0->filename();
		}
	}
	if ($self->check()){
		#compare ofv. print this to log file
		my $mod0_ofv;
		my $check_ofv;
		if ( defined $output_0){
			$mod0_ofv = $output_0->get_single_value(attribute=> 'ofv');
		}else{
			$mod0_ofv = 'undefined';
		}
		if ($data_check_model->is_run()){
			$check_ofv = $data_check_model->outputs -> [0]->get_single_value(attribute=> 'ofv');
		}else{
			$check_ofv = 'undefined';
		}
		print "\nModel 0 ofv is    $mod0_ofv\n";
		print   "Data check ofv is $check_ofv\n";
	}
	#to be able to do model-> new later
	$frem_model0->problems->[0]->datas->[0]->options->[0]->name($original_data_name);
	$frem_model0 ->_write();
	$phi_file_0 =~ s/mod$/phi/;

	##########################################################################################
	#Create Model 1
	##########################################################################################
	
	$frem_model1 = $frem_model0 ->  copy( filename    => $self -> directory().'m1/'.$name_model1,
										  output_same_directory => 1,
										  copy_data   => 0,
										  copy_output => 0);
	
	#Update inits from output, if any
	if (defined $output_0){
		$frem_model1 -> update_inits ( from_output => $output_0,
									   problem_number => 1);
	}

	#	  print "using empirical omega fill\n";
	my $BSV_par_block = $frem_model1-> problems -> [0]->get_filled_omega_matrix(start_eta => $start_eta);

	#reset $start_omega_record and on, not not kill all
	$frem_model1 -> problems -> [0]-> omegas(\@leading_omega_records);
	
	#TODO get labels from input model for bsv par block
	$frem_model1-> problems -> [0]->add_omega_block(new_omega => $BSV_par_block);

	$frem_model1->problems->[0]->datas->[0]->options->[0]->name($original_data_name);
	$frem_model1 ->_write();

	##########################################################################################
	#Create Model 2
	##########################################################################################

	$frem_model2 = $frem_model1 ->  copy( filename    => $self -> directory().'m1/'.$name_model2_all,
										  output_same_directory => 1,
										  copy_data   => 0,
										  copy_output => 0);

	#SETUP
	my $ntheta = $frem_model2 ->nthetas(problem_number => 1);
	my $epsnum = 1 + $frem_model2->problems()->[0]->nsigmas(with_correlations => 0,
															with_same => 1);
	
	#DATA changes
	#skip set data object , since not running anything here 
	#change data file name to local name so that not too long set ignore also.
	$frem_model2-> set_records(type => 'data',
							   record_strings => [$data2name.' IGNORE=@']);
	
	
	#set theta omega sigma code input
	#TODO adjust this function to start_eta

	$self->set_frem_records(model => $frem_model2,
							n_time_varying => $n_time_varying,
							n_invariant => $n_invariant,
							epsnum => $epsnum,
							ntheta => $ntheta,
							bsv_parameters => $bsv_parameters,
							bov_parameters => $bov_parameters,
							model_type =>'2');

	$frem_model2->_write();


	##########################################################################################
	#Create Model 2 only invariant
	##########################################################################################

	if (0){
		#need to double check definitions here. Based on 0 or 1??
		$frem_model2_invar = $frem_model1 ->  copy( filename    => $self -> directory().'m1/'.$name_model2_invar,
													output_same_directory => 1,
													copy_data   => 0,
													copy_output => 0);

		#DATA changes
		#skip set data object , since not running anything here 
		#change data file name to local name so that not too long set ignore also.
		$frem_model2_invar-> set_records(type => 'data',
										 record_strings => [$data2name.' IGNORE=@ IGNORE=('.$fremtype.'.GT.'.$n_invariant.')']);
		
		
		#set theta omega sigma code input
		$self->set_frem_records(model => $frem_model2_invar,
								n_time_varying => 0,
								n_invariant => $n_invariant,
								bsv_parameters => $bsv_parameters,
								bov_parameters => $bov_parameters,
								epsnum => $epsnum,
								ntheta => $ntheta,
								model_type =>'2');
		
		$frem_model2_invar->_write();
	}
	##########################################################################################
	#Create Model 2 only time-varying
	##########################################################################################
	
	#base on model 0
	$frem_model2_timevar = $frem_model0 ->  copy( filename    => $self -> directory().'m1/'.$name_model2_timevar,
													 output_same_directory => 1,
													 copy_data   => 0,
													 copy_output => 0);

	#DATA changes
	#skip set data object , since not running anything here 

	#change data file name to local name so that not too long set ignore also.
	$frem_model2_timevar-> set_records(type => 'data',
									   record_strings => [$data2name.' IGNORE=@ ACCEPT=('.$fremtype.'.LT.1) '.
														  'ACCEPT=('.$fremtype.'.GT.'.$n_invariant.')']);
	
	
	#set theta omega sigma code input
	$self->set_frem_records(model => $frem_model2_timevar,
							n_time_varying => $n_time_varying,
							n_invariant => 0,
							epsnum => $epsnum,
							bsv_parameters => $bsv_parameters,
							bov_parameters => $bov_parameters,
							ntheta => $ntheta,
							model_type =>'2');
	
	$frem_model2_timevar->_write();
		
	##########################################################################################
	#Create Model 3
	##########################################################################################

	$frem_model3 = $frem_model1 ->  copy( filename    => $self -> directory().'m1/'.$name_model3,
										  output_same_directory => 1,
										  copy_data   => 0,
										  copy_output => 0);

	#DATA changes
	#skip set data object , since not running anything here 

	#change data file name to local name so that not too long set ignore also.
	$frem_model3-> set_records(type => 'data',
							   record_strings => [$data2name.' IGNORE=@']);
	
	
	#set theta omega sigma code input
	$self->set_frem_records(model => $frem_model3,
							n_time_varying => $n_time_varying,
							n_invariant => $n_invariant,
							epsnum => $epsnum,
							ntheta => $ntheta,
							bsv_parameters => $bsv_parameters,
							bov_parameters => $bov_parameters,
							model_type =>'3');
#	

	$frem_model3->_write();

	##########################################################################################
	#Create Model 1 vpc
	##########################################################################################
	
	$frem_vpc_model1 = $frem_model3 ->  copy( filename    => $self -> directory().'m1/'.$name_modelvpc_1,
											  output_same_directory => 1,
											  copy_data   => 1,
											  copy_output => 0,
											  skip_data_parsing => 1);      
	#fix omega
	foreach my $rec (@{$frem_vpc_model1->problems()->[0]->omegas()}){
		$rec->fix(1) unless $rec->same();
	}
	#fix theta 
	foreach my $rec (@{$frem_vpc_model1->problems()->[0]->thetas()}){
		foreach my $opt (@{$rec->options()}){
			$opt->fix(1);
		}
	}
	#unfix all sigma
	$frem_vpc_model1 -> fixed( parameter_type => 'sigma',
							   new_values => [[(0) x $frem_vpc_model1 -> nsigmas -> [0] ]] );
	
	#the data object is correct but need to set IGNORE
	#assume no old ignores for FREMTYPE
	$frem_vpc_model1-> add_option(problem_numbers => [1],
								  record_name => 'data',
								  option_name => 'IGNORE',
								  option_value=>'('.$fremtype.'.GT.0)');
		
	$frem_vpc_model1 -> remove_records(type => 'covariance');
	
	
	my @code;
	@code = @{$frem_vpc_model1 -> pk( problem_number => 1 )};
	$use_pred = 0;
	unless ( $#code > 0 ) {
		@code = @{$frem_vpc_model1 -> pred( problem_number => 1 )};
		$use_pred = 1;
	}
	if ( $#code <= 0 ) {
		croak("Neither PK or PRED defined in vpc model 1");
	}
	#find all thetas on right hand side where left hand is not Y or Ynumber
	#store mapping theta number and parameter name
	for (my $i=0; $i<scalar(@code); $i++) {
		if ( $code[$i] =~ /^\s*(\w+)\s*=.*\bTHETA\((\d+)\)/  ){
			$theta_parameter{$2} = $1 unless ($1 =~ /^Y\d*$/);
		}
	}
	if (0){
		print "\n";
		foreach my $num (sort keys %theta_parameter){
			print "THETA($num) to ".$theta_parameter{$num}."\n";
		}
		print "done theta map\n";
	}
	#find mapping eta number to theta number
	#store mapping replacestring to CTVpar
	#my %oldstring_to_CTVpar;
	@etanum_to_thetanum= (0) x $bsv_parameters;
	for (my $i=0; $i<scalar(@code); $i++) {
		next if ( $code[$i] =~ /^\s*\;/); #comment line
		if ( $code[$i] =~ /^\s*(\w+)\s*=.*\bETA\((\d+)\)/  ){
			#TODO handle placeholder (0) for ETA here??? if no bsv but need BOV
			my $etanum = $2;
			my $new_param = $1;
			if ($etanum_to_thetanum[$etanum] != 0){
				croak("Found multiple lines with ETA($etanum) in vpc_model1, ambigous");
			}
			if ($etanum > $bsv_parameters){
				next;
			}
			if ( $code[$i] =~ /^.+=.*\bTHETA\((\d+)\)/  ){
				#coupling on same line as in CL=THETA(2)*EXP(ETA(1))
				$etanum_to_thetanum[$etanum]=$1;
				$oldstring_to_CTVpar{'THETA('.$1.')'} = 'CTV'.$new_param;
			}else{
				#loop to find indirect coupling as in TVCL=THETA(2), CL=TVCL*EXP(ETA(1))
				my $found = 0;
				foreach my $thetanum (keys %theta_parameter){
					my $par = $theta_parameter{$thetanum};
					if ( $code[$i] =~ /=.*\b$par\b/  ){
						$etanum_to_thetanum[$etanum]=$thetanum;
						$found=1;
						#replace indirect coupling parameter and instead set left hand param from ETA line to theta mapping
						$theta_parameter{$thetanum} = $new_param;
						$oldstring_to_CTVpar{$par} = 'CTV'.$new_param;
						last;
					}
				}
				croak("Could not find THETA coupled to ETA($etanum) in vpc_model1") unless ($found);
			}
		}
	}
	if (0){
		print "\n";
		for (my $etanum=1; $etanum< scalar(@etanum_to_thetanum); $etanum++){
			if ($etanum_to_thetanum[$etanum] == 0){
				croak("Could not find ETA($etanum) in code vpc_model1");
			}
			print "ETA($etanum) to THETA(".$etanum_to_thetanum[$etanum].")\n";
		}
		print "\n";
	}
	if (0){
		print "\n";
		foreach my $key (keys %oldstring_to_CTVpar){
			print "oldstring $key to be replaced with ".$oldstring_to_CTVpar{$key}."\n";
		}
		print "\n";
	}

	#To create combined data simply print table with both filtered input data and new conditional data
	#The conditional headers will have wrong headers in table file to be used as data, but that is fine
	#as long as $INPUT in vpc2 is correct
	my @vpc1_table_params =();
	my @vpc2_input_params =();
	if( defined $frem_vpc_model1->problems()->[0] -> inputs and 
		defined $frem_vpc_model1->problems()->[0] -> inputs -> [0] -> options ) {
		foreach my $option ( @{$frem_vpc_model1->problems()->[0] -> inputs -> [0] -> options} ) {
			unless ( $option -> name eq 'DROP' or $option -> name eq 'SKIP' or
					 $option -> value eq 'DROP' or $option -> value eq 'SKIP'){
				push(@vpc1_table_params,$option -> name);
				push( @vpc2_input_params, $option -> name );
			}
		}
	} else {
		croak("Trying to construct table for filtering data".
			  " but no headers were found in \$INPUT" );
	}

	for (my $etanum=1; $etanum< scalar(@etanum_to_thetanum); $etanum++){
		my $par = $theta_parameter{$etanum_to_thetanum[$etanum]}; # parameter that has ETA on it
		push(@vpc1_table_params,$par);
		push( @vpc2_input_params, 'CTV'.$par);
	}

	$frem_vpc_model1 -> add_records( type           => 'table',
									 record_strings => [ join( ' ', @vpc1_table_params ).
														 ' NOAPPEND NOPRINT ONEHEADER FORMAT=sG15.7 FILE='.$joindata]);

	$frem_vpc_model1->problems->[0]->datas->[0]->options->[0]->name($data2name);
	$frem_vpc_model1->_write();

	##########################################################################################
	#Create Model 2 vpc
	##########################################################################################
	
	$frem_vpc_model2 = $frem_model3 ->  copy( filename    => $self -> directory().'m1/'.$name_modelvpc_2,
											  output_same_directory => 1,
											  copy_data   => 0,
											  copy_output => 0);

	$frem_vpc_model2->ignore_missing_files(1);

	#move most of this to subroutine, too complex to have here, similar to prev. modifications?
	
	#DATA changes
	#skip set data object , since not running anything here 
	#change data file name to local name so that not too long set ignore also.
	$frem_vpc_model2-> set_records(type => 'data',
								   record_strings => [$joindata.' IGNORE=@ IGNORE=('.$fremtype.'.GT.0)']);

	#fix theta ???
	if (1){
		foreach my $rec (@{$frem_vpc_model2->problems()->[0]->thetas()}){
			foreach my $opt (@{$rec->options()}){
				$opt->fix(1);
			}
		}
	}
	#fix all sigma
	$frem_vpc_model2 -> fixed( parameter_type => 'sigma',
							   new_values => [[(1) x $frem_vpc_model1 -> nsigmas -> [0] ]] );
	
	
	$frem_vpc_model2 -> remove_records(type => 'covariance');
	
	my $new_input_string = join(' ',@vpc2_input_params);
	$frem_vpc_model2->problems()->[0]->set_records(type => 'input',
												   record_strings => [$new_input_string]);
	
	#replace TVpar with CTVpar, or if no TV then THETAx with CTVpar
	my @code;
	@code = @{$frem_vpc_model1 -> pk( problem_number => 1 )};
	my $use_pred = 0;
	unless ( $#code > 0 ) {
		@code = @{$frem_vpc_model1 -> pred( problem_number => 1 )};
		$use_pred = 1;
	}
	if ( $#code <= 0 ) {
		croak("Neither PK or PRED defined in vpc model 1");
	}
	
	foreach my $oldstring (keys %oldstring_to_CTVpar){
		my $found = 0;
		for (my $i=0; $i<scalar(@code); $i++) {
			next if ( $code[$i] =~ /^\s*\;/); #comment line
			if ( $code[$i] =~ /^(\s*)$oldstring\s*=/ ){
				$code[$i] = $1.$oldstring.'='.$oldstring_to_CTVpar{$oldstring};
				$found = 1;
				last; #done substitution for this par, cont outer loop
			}
		}
		croak("could not find where to set\n".$oldstring.'='.$oldstring_to_CTVpar{$oldstring}) unless $found;
	}
	if ( $use_pred ) {
		$frem_vpc_model2 -> pred( problem_number => 1,
								  new_pred       => \@code );
	} else {
		$frem_vpc_model2 -> pk( problem_number => 1,
								new_pk         => \@code );
	}
	
	$frem_vpc_model2->_write();


	my @dumper_names=qw(n_invariant n_time_varying n_occasions total_orig_etas start_omega_record *theta_parameter use_pred *oldstring_to_CTVpar *etanum_to_thetanum start_eta bsv_parameters bov_parameters phi_file_0);
	open(FH, '>'.$self->done_file()) or die "Could not open file ".$self->done_file()." for writing.\n";
	print FH Data::Dumper->Dump(
		[$n_invariant,$n_time_varying,$n_occasions,$total_orig_etas,$start_omega_record,\%theta_parameter,$use_pred,\%oldstring_to_CTVpar,\@etanum_to_thetanum,$start_eta,$bsv_parameters,$bov_parameters,$phi_file_0],
		\@dumper_names
		);
	close FH;
	
}


sub modelfit_setup
{
	my $self = shift;
	my %parm = validated_hash(\@_,
		 model_number => { isa => 'Int', optional => 1 }
	);
	my $model_number = $parm{'model_number'};

	my $model = $self -> models -> [$model_number-1];

	#TODO make sure phi is copied back, make sure $self->nm_output includes phi

	#declare variables
	#these should be same set as "variables to store" in create_template_models
	my $n_invariant;
	my $n_time_varying;
	my $n_occasions;
	my $total_orig_etas;
	my $start_omega_record;
	my %theta_parameter;
	my $use_pred;
	my %oldstring_to_CTVpar;
	my @etanum_to_thetanum;
	my $start_eta;
	my $bsv_parameters;
	my $bov_parameters;
	my $phi_file_0;

	#read from done_file, do eval on string to slurp variable values

	unless (-e $self->done_file()){
		$self->create_template_models( model => $self -> models -> [$model_number-1]);
	}
	unless (-e $self->done_file()){
		croak("Could not find ".$self->done_file());
	}
	open(FH, $self->done_file()) or croak("Could not open file ".$self->done_file()." for reading.\n");
	my $string = join(' ',<FH>);
	close(FH);
	eval $string;
	
    my $frem_model0 = model -> new ( %{common_options::restore_options(@common_options::model_options)},
									 filename                    => 'm1/'.$name_model0,
									 ignore_missing_output_files => 1 );
    my $frem_model1 = model -> new ( %{common_options::restore_options(@common_options::model_options)},
									 filename                    => 'm1/'.$name_model1,
									 ignore_missing_output_files => 1 );
    my $frem_model2 = model -> new ( %{common_options::restore_options(@common_options::model_options)},
									 filename                    => 'm1/'.$name_model2_all,
									 ignore_missing_output_files => 1 );
    my $frem_model2_timevar = model -> new ( %{common_options::restore_options(@common_options::model_options)},
											 filename                    => 'm1/'.$name_model2_timevar,
											 ignore_missing_output_files => 1 );
	
    my $frem_model2_invar;
	#need to double check definitions here. Based on 0 or 1??
	if (0){
		$frem_model2_invar = model -> new ( %{common_options::restore_options(@common_options::model_options)},
											filename                    => 'm1/'.$name_model2_invar,
											ignore_missing_output_files => 1 );
	}

    my $frem_model3 = model -> new ( %{common_options::restore_options(@common_options::model_options)},
									 filename                    => 'm1/'.$name_model3,
									 ignore_missing_output_files => 1 );

    my $frem_vpc_model1 = model -> new ( %{common_options::restore_options(@common_options::model_options)},
										 filename                    => 'm1/'.$name_modelvpc_1,
										 ignore_missing_output_files => 1 );
    my $frem_vpc_model2 = model -> new ( %{common_options::restore_options(@common_options::model_options)},
										 filename                    => 'm1/'.$name_modelvpc_2,
										 ignore_missing_data =>1,
										 ignore_missing_output_files => 1 );


#	my $data2_data_record;
	my $output_0;
	my $output_1;
	my $output_2;
	my $output_3;
	my $output_vpc_1;
	my $eta_covariance_3;
	my @leading_omega_records=();
	my $eta_covariance_0;
	my $eta_covariance_1;
	my $eta_covariance_2;


	for (my $i=0; $i< ($start_omega_record-1);$i++){
		#if start_omega_record is 1 we will push nothing
		push(@leading_omega_records,$frem_model0-> problems -> [0]->omegas->[$i]);
	}


	##########################################################################################
	#Run Model 0
	##########################################################################################

	if ($frem_model0->is_run()){
		$output_0 = $frem_model0 -> outputs -> [0];
	}elsif (not -e $phi_file_0 and ($self->estimate() >= 0)){
		my $zero_fit = tool::modelfit ->
			new( %{common_options::restore_options(@common_options::tool_options)},
				 base_directory	 => $frem_model0 -> directory(),
				 directory		 => $self -> directory().'/model_0_modelfit_dir1',
				 models		 => [$frem_model0],
				 top_tool              => 0);
		
		ui -> print( category => 'all', message => "\nExecuting FREM Model 0" );
		$zero_fit -> run;
		$output_0 = $frem_model0 -> outputs -> [0] if ($frem_model0 -> is_run());
	}

	##########################################################################################
	#Compute ETA covariance matrix from model 0 
	##########################################################################################

	if (-e $phi_file_0 and (not $frem_model1->is_run())){
		my $phi = data -> new(filename=>$phi_file_0) if (-e $phi_file_0);
		my $eta_matrix = $phi -> get_eta_matrix( start_eta => $start_eta,
												 n_eta => $bsv_parameters) if (defined $phi);
		if (defined $eta_matrix and defined $eta_matrix->[0] and scalar(@{$eta_matrix->[0]})==$bsv_parameters ){
			$eta_covariance_0 = [];
			my $err = linear_algebra::row_cov($eta_matrix,$eta_covariance_0);
			if ($err != 0){
				print "failed to compute eta covariance model 0\n";
				$eta_covariance_0 = undef;
			}else{
				if (0){
					#print to file??
					print "printing eta cov\n";
					for (my $row=0; $row<$bsv_parameters; $row++){
						for (my $col=0; $col<$bsv_parameters; $col++){
							printf("  %.4f",$eta_covariance_0->[$row][$col]); #matlab format
						}
						print "\n";
					}
					print "\n";
				}
				#verify that not all zero
				my $nonzero=0;
				for (my $row=0; $row<$bsv_parameters; $row++){
					$nonzero = 1 if ($eta_covariance_0->[$row][$row] > 0);
				}
				$eta_covariance_0 = undef unless $nonzero;
			}
		}
	}
	
	##########################################################################################
	#Update and run Model 1
	##########################################################################################

	if ($frem_model1->is_run()){
		$output_1 = $frem_model1 -> outputs -> [0];
	}else{
		if (0 and defined $eta_covariance_0 and (scalar(@{$eta_covariance_0}) >0)){
			#get filled omega only fills in nonzero values, but we have done empirical fill above
			#redo update inits but set zeros from output to reset
			#assume output_0 defined when phi file existed above
			croak("mod 0 phi file existed but not lst-file") unless (defined $output_0);
			$frem_model1 -> update_inits ( from_output => $output_0,
										   ignore_missing_parameters => 1,
										   update_fix => 1,
										   skip_output_zeros => 0,
										   problem_number => 1);

			my $BSV_par_block;
			#	  print "using ETA cov omega fill\n";
			$BSV_par_block = $frem_model1-> problems -> [0]->get_filled_omega_matrix(covmatrix => $eta_covariance_0,
																					 start_eta => $start_eta);

			#reset $start_omega_record and on, not not kill all
			$frem_model1 -> problems -> [0]-> omegas(\@leading_omega_records);
	
			#TODO get labels from input model for bsv par block
			$frem_model1-> problems -> [0]->add_omega_block(new_omega => $BSV_par_block);

			$frem_model1 ->_write();
		}elsif (defined $output_0){
			$frem_model1 -> update_inits ( from_output => $output_0,
										   ignore_missing_parameters => 1,
										   update_fix => 1,
										   skip_output_zeros => 1,
										   problem_number => 1);
		}
		if ($self->estimate() >= 1){
			#estimate model 1 if estimation is requested
			my $one_fit = tool::modelfit ->
				new( %{common_options::restore_options(@common_options::tool_options)},
					 base_directory	 => $frem_model1 -> directory(),
					 directory		 => $self -> directory().'/model1_modelfit_dir1',
					 models		 => [$frem_model1],
					 top_tool              => 0);
			
			ui -> print( category => 'all', message => "\nExecuting FREM Model 1" );
			$one_fit -> run;
			$output_1 = $frem_model1 -> outputs -> [0] if ($frem_model1 -> is_run());
		}
	}

	##########################################################################################
	#Update and run Model 2
	##########################################################################################

	if ($frem_model2->is_run()){
		$output_2 = $frem_model2 -> outputs -> [0];
	}else{
		if (defined $output_1){
			$frem_model2 -> update_inits ( from_output => $output_1,
										   ignore_missing_parameters => 1,
										   update_fix => 1,
										   skip_output_zeros => 1,
										   problem_number => 1);
			$frem_model2 ->_write();
		}

		if ($self->estimate() >= 2){
			#estimate model 2 if estimation is requested
			my $two_fit = tool::modelfit ->
				new( %{common_options::restore_options(@common_options::tool_options)},
					 base_directory	 => $frem_model2 -> directory(),
					 directory		 => $self -> directory().'/model2_modelfit_dir1',
					 models		 => [$frem_model2],
					 top_tool              => 0);
			
			ui -> print( category => 'all', message => "\nExecuting FREM Model 2" );
			$two_fit -> run;
			$output_2 = $frem_model2 -> outputs -> [0] if ($frem_model2 -> is_run());
		}
	}

	##########################################################################################
	#Update Model 2 only invariant
	##########################################################################################

	#need to check definition of model here
	if (0){
		#Update inits from output, if any TODO handle model differences
		if (defined $output_1){
			$frem_model2_invar -> update_inits ( from_output => $output_1,
												 problem_number => 1);
			$frem_model2_invar->_write();
		}
	}

	##########################################################################################
	#Update Model 2 only time-varying
	##########################################################################################

	#Update inits from output, if any
	#based on mod 0, there should be no fill in of block as in mod 1
	if (defined $output_0){
		$frem_model2_timevar -> update_inits ( from_output => $output_0,
											   ignore_missing_parameters => 1,
											   update_fix => 1,
											   skip_output_zeros => 1,
											   problem_number => 1);
		$frem_model2_timevar->_write();
	}
	
	
	
	##########################################################################################
	#Update and run Model 3
	##########################################################################################

	if ($frem_model3->is_run()){
		$output_3 = $frem_model3 -> outputs -> [0];
	}else{
		#Update inits from output, if any
		if (0 and defined $output_2){
			#handle reordered etas
 
		}elsif (defined $output_1){ 
			$frem_model3 -> update_inits ( from_output => $output_1,
										   ignore_missing_parameters => 1,
										   update_fix => 1,
										   skip_output_zeros => 1,
										   problem_number => 1);
			$frem_model3->_write();
		}


		if ($self->estimate() >= 3){
			#estimate model 3 if estimation is requested
			my $three_fit = tool::modelfit ->
				new( %{common_options::restore_options(@common_options::tool_options)},
					 base_directory	 => $frem_model3 -> directory(),
					 directory		 => $self -> directory().'/model3_modelfit_dir1',
					 models		 => [$frem_model3],
					 top_tool              => 0);
			
			ui -> print( category => 'all', message => "\nExecuting FREM Model 3" );
			$three_fit -> run;
			$output_3 = $frem_model3 -> outputs -> [0] if ($frem_model3 -> is_run());
		}
	}

	if ($self->vpc()){
		##########################################################################################
		#Update and run  Model 1 vpc
		##########################################################################################

		if ($frem_vpc_model1->is_run()){
			$output_vpc_1 = $frem_vpc_model1 -> outputs -> [0];
		}else{

			#Update inits from output3, if any
			if (defined $output_3){
				$frem_vpc_model1 -> update_inits ( from_output => $output_3,
												   ignore_missing_parameters => 1,
												   update_fix => 1,
												   skip_output_zeros => 1,
												   problem_number => 1);
				$frem_vpc_model1->_write();
			}

			
			my $vpc1_fit = tool::modelfit ->
				new( %{common_options::restore_options(@common_options::tool_options)},
					 base_directory	 => $frem_vpc_model1 -> directory(),
					 directory	 => $self -> directory().'/vpc1_modelfit_dir1',
					 models		 => [$frem_vpc_model1],
					 top_tool              => 0);
			
			ui -> print( category => 'all', message => "\nExecuting FREM vpc model 1" );
			$vpc1_fit -> run;
			$output_vpc_1 = $frem_vpc_model1 -> outputs -> [0] if ($frem_vpc_model1 -> is_run());
			
		}
		unless (-e $frem_vpc_model1->directory().$joindata){
			die ($frem_vpc_model1->directory().$joindata." does not exist\n");
		}

		##########################################################################################
		#Update Model 2 vpc
		##########################################################################################


		#Update inits from output3, if any
		if (defined $output_3){
			$frem_vpc_model2 -> update_inits ( from_output => $output_3,
											   ignore_missing_parameters => 1,
											   update_fix => 1,
											   skip_output_zeros => 1,
											   problem_number => 1);
			$frem_vpc_model2->_write();
		}


	}#end if vpc
}

sub _modelfit_raw_results_callback
{
	my $self = shift;
	my %parm = validated_hash(\@_,
		 model_number => { isa => 'Int', optional => 1 }
	);
	my $model_number = $parm{'model_number'};
	my $subroutine;


    #this is just a placeholder
my ($dir,$file) = 
    OSspecific::absolute_path( $self -> directory,
			       $self -> raw_results_file->[$model_number-1] );
my ($npdir,$npfile) = 
    OSspecific::absolute_path( $self -> directory,
			       $self -> raw_nonp_file->[$model_number -1]);


#my $orig_mod = $self -> models[$model_number-1];
$subroutine = sub {

  my $modelfit = shift;
  my $mh_ref   = shift;
  my %max_hash = %{$mh_ref};
  
};
return $subroutine;


	return \&subroutine;
}

sub modelfit_analyze
{
	my $self = shift;
	my %parm = validated_hash(\@_,
		 model_number => { isa => 'Int', optional => 1 }
	);
	my $model_number = $parm{'model_number'};


}

sub prepare_results
{
	my $self = shift;
	my %parm = validated_hash(\@_,
		arg1  => { isa => 'Int', optional => 1 }
	);
}

sub create_data2
{
	my $self = shift;
	my %parm = validated_hash(\@_,
							  model => { isa => 'Ref', optional => 0 },
							  filename => { isa => 'Str', optional => 0 },
							  bov_parameters => { isa => 'Int', optional => 0 }
		);
	#filename created is module global $data2name

	my $model = $parm{'model'};
	my $filename = $parm{'filename'};
	my $bov_parameters = $parm{'bov_parameters'};

	#in ref of model, 
	#filename of new filter model
	#out name of data file $outdatafile with full path

	my $filtered_data_model = $model -> copy ( filename => $filename,
		output_same_directory => 1,
		copy_data          => 0,
		copy_output        => 0,
		skip_data_parsing => 1);

	die "no problems" unless defined $filtered_data_model->problems();
	die "more than one problem" unless (scalar(@{$filtered_data_model->problems()})==1);

	$self->filtered_datafile('filtered_plus_type0.dta');

	my @filter_table_header;

	#need to handle DROP SKIP without value
	my $dummycounter=0;
	if( defined $filtered_data_model->problems()->[0] -> inputs and 
		defined $filtered_data_model->problems()->[0] -> inputs -> [0] -> options ) {
		foreach my $option ( @{$filtered_data_model->problems()->[0] -> inputs -> [0] -> options} ) {
			if ($option->name eq 'DROP' or $option->name eq 'SKIP'){
				if (defined $option->value and $option->value ne '' and not ($option->value eq 'DROP' or $option->value eq 'SKIP') ){
					push( @filter_table_header, $option -> value );
				}else{
					#simple drop used in $INPUT without name. Set dummy name as placeholder here.
					$dummycounter++;
					$option->value('DUMMY'.$dummycounter);
					push( @filter_table_header, $option -> value );
				}
			}else{
				push( @filter_table_header, $option -> name );
			}
		}
	} else {
		croak("Trying to construct table for filtering data".
			" but no headers were found in \$INPUT" );
	}
	my $new_input_string = join(' ',@filter_table_header);
	#do not want to drop anything, keep everything for table. Unset DROP in $INPUT of the model
	$filtered_data_model->problems()->[0]->set_records(type => 'input',
		record_strings => [$new_input_string]);

	$self->typeorder([$self->dv()]); #index 0 is original obs column name
	if (scalar(@{$self->invariant()})>0){
		push(@{$self->typeorder()},@{$self->invariant()}); #add list of invariant covariate names to typeorder
	}
	my $first_timevar_type = scalar(@{$self->typeorder()});
	if (scalar(@{$self->time_varying()})>0){
		push(@{$self->typeorder()},@{$self->time_varying()}); #add list of time_varying covariate names to typeorder
	}
	my @cov_indices = (-1) x scalar(@{$self->typeorder()}); #initiate with invalid indices

	my $evid_index;
	my $mdv_index;
	my $type_index;
	my $occ_index;
	for (my $i=0; $i< scalar(@filter_table_header); $i++){
		if ($filter_table_header[$i] eq 'EVID'){
			$evid_index = $i;
		}elsif($filter_table_header[$i] eq 'MDV'){
			$mdv_index = $i;
		}elsif($filter_table_header[$i] eq $fremtype){
			$type_index = $i;
		}elsif($filter_table_header[$i] eq $self->occasion()){
			$occ_index = $i;
		}else{
			#0 is dv
			for (my $j=0; $j< scalar(@cov_indices); $j++){
				if($filter_table_header[$i] eq $self->typeorder()->[$j]){
					$cov_indices[$j] = $i;
					last;
				}
			}
		}
	}
	unless (defined $evid_index or defined $mdv_index){
		push(@filter_table_header,'MDV');
		$mdv_index = $#filter_table_header;
		push(@{$self->extra_input_items()},'MDV');
	}
	if (defined $type_index){
		croak($fremtype." already defined in input model, not allowed.");
	}else{
		push(@filter_table_header,$fremtype);
		$type_index = $#filter_table_header;
		push(@{$self->extra_input_items()},$fremtype);
	}
	unless (defined $occ_index or ($bov_parameters<1)){
		croak("occasion column ".$self->occasion()." not found in input model.");
	}
	if ($cov_indices[0] < 0){
		croak("dependent value ".$self->dv()." not found in input model.");
	}
	for (my $j=1; $j< scalar(@cov_indices); $j++){
		if ($cov_indices[$j] < 0){
			croak("covariate column ".$self->typeorder()->[$j]." not found in input model.");
		}
	}

	foreach my $remove_rec ('abbreviated','msfi','contr','subroutine','prior','model','tol','infn','omega','pk','aesinitial','aes','des','error','pred','mix','theta','sigma','simulation','estimation','covariance','nonparametric','table','scatter'){
		$filtered_data_model -> remove_records(type => $remove_rec);
	}

	$filtered_data_model -> add_records(type => 'pred',
		record_strings => [$fremtype.'=0','Y=THETA(1)+ETA(1)+EPS(1)']);

	$filtered_data_model -> add_records(type => 'theta',
		record_strings => ['1']);
	$filtered_data_model -> add_records(type => 'omega',
		record_strings => ['1']);
	$filtered_data_model -> add_records(type => 'sigma',
		record_strings => ['1']);
	$filtered_data_model -> add_records(type => 'estimation',
		record_strings => ['MAXEVALS=0 METHOD=ZERO']);

	# set $TABLE record

	$filtered_data_model -> add_records( type           => 'table',
		record_strings => [ join( ' ', @filter_table_header ).
			' NOAPPEND NOPRINT ONEHEADER FORMAT=sG15.7 FILE='.$self->filtered_datafile]);

	$filtered_data_model->_write();
	# run model in data_filtering_dir clean=3
	my $filter_fit = tool::modelfit -> new
	( %{common_options::restore_options(@common_options::tool_options)},
		base_directory => $self->directory(),
		directory      => $self->directory().'/create_data2_dir/',
		models         => [$filtered_data_model],
		top_tool       => 0,
		clean => 2  );
	ui -> print( category => 'all',
		message  => "Running dummy model to filter data and add ".$fremtype." for Data set 2",
		newline => 1 );
	$filter_fit -> run;

	my $filtered_data = data -> new(filename=>$filtered_data_model->directory().$self->filtered_datafile);

	foreach my $covariate (@{$self->invariant()}){
		my %strata = %{$filtered_data-> factors( column_head => $covariate,
		return_occurences =>1,
		unique_in_individual => 1,
		ignore_missing => 1)};

		if ( $strata{'Non-unique values found'} eq '1' ) {
			ui -> print( category => 'all',
				message => "\nWarning: Individuals were found to have multiple values ".
				"in the $covariate column, which will not be handled correctly by the frem script. ".
				"Consider terminating this run and setting ".
				"covariate $covariate as time-varying instead.\n" );
		}
	}

	if (defined $occ_index){
		my $factors = $filtered_data -> factors( column => ($occ_index+1),
			ignore_missing =>1,
			unique_in_individual => 0,
			return_occurences => 1 );

		#key is the factor, e.g. occasion 1. Value is the number of occurences
		my @temp=();
		#sort occasions ascending.
		foreach my $key (sort {$a <=> $b} keys (%{$factors})){
			push(@temp,sprintf("%.12G",$key));
		}
		$self->occasionlist(\@temp); 

	}

	$filtered_data -> filename($data2name); #change name so that when writing to disk get new file

	my $invariant_matrix; #array of arrays
	my $timevar_matrix; #array of arrays of arrays

	#this writes new data to disk
	($invariant_matrix,$timevar_matrix) = 
	$filtered_data->add_frem_lines( occ_index => $occ_index,
		evid_index => $evid_index,
		mdv_index => $mdv_index,
		type_index => $type_index,
		cov_indices => \@cov_indices,
		first_timevar_type => $first_timevar_type);



	my $inv_covariance = [];
	my $inv_median = [];
	my $timev_covariance = [];
	my $timev_median = [];
	my $err = linear_algebra::row_cov_median($invariant_matrix,$inv_covariance,$inv_median,$self->missing_data_token());
	if ($err != 0){
		print "failed to compute invariant covariates covariance\n";
	}else{
		$self->invariant_median($inv_median);
		$self->invariant_covmatrix($inv_covariance);
	}
	$err = linear_algebra::row_cov_median($timevar_matrix,$timev_covariance,$timev_median,$self->missing_data_token());
	if ($err != 0){
		print "failed to compute time-varying covariates covariance\n";
	}else{
		$self->timevar_median($timev_median);
		$self->timevar_covmatrix($timev_covariance);
	}

}

sub set_frem_records
{
	my $self = shift;
	my %parm = validated_hash(\@_,
							  model => { isa => 'Ref', optional => 0 },
							  n_invariant => { isa => 'Int', optional => 0 },
							  n_time_varying => { isa => 'Int', optional => 0 },
							  model_type => { isa => 'Str', optional => 0 },
							  epsnum => { isa => 'Int', optional => 0 },
							  ntheta => { isa => 'Int', optional => 0 },
							  bsv_parameters => { isa => 'Int', optional => 0 },
							  bov_parameters => { isa => 'Int', optional => 0 },
							  output_2 => { isa => 'Ref', optional => 1 }
		);
	my $model = $parm{'model'};
	my $n_invariant = $parm{'n_invariant'};
	my $n_time_varying = $parm{'n_time_varying'};
	my $model_type = $parm{'model_type'};
	my $epsnum = $parm{'epsnum'};
	my $ntheta = $parm{'ntheta'};
	my $bsv_parameters = $parm{'bsv_parameters'};
	my $bov_parameters = $parm{'bov_parameters'};
	my $output_2 = $parm{'output_2'};

    #in is ref of model
    #model_type 2 or 3 or vpc1 or vpc2
    #local number n_time_varying. If 0 then locally ignore bov_parameters
    #local number n_invariant
    #epsnum
    #ntheta
    #this sets theta omega sigma code input

	#TODO adjust code to start_eta

    unless ($model_type eq '2' or $model_type eq '3'){
#    unless ($model_type eq '2' or $model_type eq '3' or $model_type eq 'vpc1' or $model_type eq 'vpc2'){
		croak("invalid model_type $model_type input to set_theta_omega_code");
    }
    if ($model_type eq 'vpc1' or $model_type eq 'vpc2'){
		croak("vpc not implemented yet");
    }

    my $n_occasions = scalar(@{$self->occasionlist()});

    #INPUT changes
    foreach my $item (@{$self->extra_input_items()}){
		$model -> add_option(problem_numbers => [1],
							 record_name => 'input',
							 option_name => $item);
    }
    
    #SIGMA changes
    $model->add_records(type => 'sigma',
						problem_numbers => [1],
						record_strings => ['0.0000001 FIX ; EPSCOV']);


    #THETA changes
    my @theta_strings =();
    for (my $i=0; $i< $n_invariant; $i++){
		push(@theta_strings,' '.sprintf("%.12G",$self->invariant_median()->[$i]).'; TV'.$self->invariant()->[$i]);
    }
    for (my $i=0; $i< $n_time_varying; $i++){
		push(@theta_strings,' '.sprintf("%.12G",$self->timevar_median()->[$i]).'; TV'.$self->time_varying()->[$i]);
    }
    $model->add_records(type => 'theta',
						problem_numbers => [1],
						record_strings => \@theta_strings);


    #OMEGA changes
    if ($n_invariant > 0){
#	if (($model_type eq '3') and (defined $output_2)){
	    #TODO take block estimates from output_2

#	}else{
	    $model-> problems -> [0]->add_omega_block(new_omega => $self->invariant_covmatrix(),
												  labels => $self->invariant());
#	}
    }
    if ($n_time_varying > 0){

		if ($model_type eq '2'){
			my $BOV_par_block;
			my @bovlabels=();
			for (my $i=0 ; $i< $bov_parameters; $i++){
				push(@{$BOV_par_block},[(0.0002) x $bov_parameters]);
				$BOV_par_block->[$i][$i] = 0.01;
				push(@bovlabels,'BOV par '.$self->parameters()->[$i]);
			}
			$model-> problems -> [0]->add_omega_block(new_omega => $BOV_par_block,
													  labels => \@bovlabels);
			for (my $i=1; $i< $n_occasions; $i++){
				$model -> add_records (type => 'omega',
									   record_strings => ['BLOCK SAME ; '.$self->occasion().'='.$self->occasionlist()->[$i]]);
				
			}
			$model-> problems -> [0]->add_omega_block(new_omega => $self->timevar_covmatrix,
													  labels => $self->time_varying());
			for (my $i=1; $i< $n_occasions; $i++){
				$model -> add_records (type => 'omega',
									   record_strings => ['BLOCK SAME ; '.$self->occasion().'='.$self->occasionlist()->[$i]]);
				
			}
		}elsif ($model_type eq '3'){
			my $BOV_all_block;
			my @bovlabels=();

#	    if (defined $output_2){
			#TODO: if have model 2 output use other initials here
			#get bov par block as it is. then look further down for bov cov block, get as it is
			#finally take phi-file and compute extra off-diagonals
#	    }else{	
			for (my $i=0 ; $i< ($bov_parameters+$n_time_varying); $i++){
				push(@{$BOV_all_block},[(0.0001) x ($bov_parameters+$n_time_varying)]);
				$BOV_all_block->[$i][$i] = 0.01;
				if ($i < $bov_parameters){
					push(@bovlabels,'BOV par '.$self->parameters()->[$i]);
				}else {
					push(@bovlabels,'BOV cov '.$self->time_varying()->[$i-($bov_parameters)]);
				}
			}
			#replace part with ->timevar_covmatrix 
			for (my $i=0 ; $i<$n_time_varying; $i++){
				for (my $j=0 ; $j<= $i ; $j++){
					$BOV_all_block->[$bov_parameters+$i][$bov_parameters+$j] = 
						$self->timevar_covmatrix()->[$i][$j];
				}
			}
#	    }
			$model-> problems -> [0]->add_omega_block(new_omega => $BOV_all_block,
													  labels => \@bovlabels);
			for (my $i=1; $i< $n_occasions; $i++){
				$model -> add_records (type => 'omega',
									   record_strings => ['BLOCK SAME ; '.$self->occasion().'='.$self->occasionlist()->[$i]]);
				
			}
		}else{
			croak("bug in loop set_theta_omega_code");
			
		}

    }

	
    my @code;
    @code = @{$model -> pk( problem_number => 1 )};
    my $use_pred = 0;
    unless ( $#code > 0 ) {
		@code = @{$model -> pred( problem_number => 1 )};
		$use_pred = 1;
    }
    if ( $#code <= 0 ) {
		croak("Neither PK or PRED defined in input model");
    }



    #PK/PRED changes at beginning A
    my @begin_code =(';;;FREM CODE BEGIN A');
    for (my $i=0; $i< $n_invariant; $i++){
		push(@begin_code,'BSV'.$self->invariant()->[$i].' = ETA('.($bsv_parameters+$i+1).')' );
    }
    if ($n_time_varying > 0){
		for (my $i=0 ; $i< $bov_parameters; $i++){
			push(@begin_code,'BOV'.$self->parameters()->[$i].' = 0' );
		}
		for (my $i=0 ; $i< $n_time_varying; $i++){
			push(@begin_code,'BOV'.$self->time_varying()->[$i].' = 0' );
		}
		if ($model_type eq '2'){
			for (my $i=0; $i< $n_occasions; $i++){
				push(@begin_code,'IF ('.$self->occasion().'.EQ.'.$self->occasionlist()->[$i].') THEN' );
				my $offset = $bsv_parameters+$n_invariant+$i*$bov_parameters;
				for (my $j=0 ; $j< $bov_parameters; $j++){
					push(@begin_code,'   BOV'.$self->parameters()->[$j].' = ETA('.($offset+$j+1).')');
				}
				push(@begin_code,'END IF' );
			}
			for (my $i=0; $i< $n_occasions; $i++){
				push(@begin_code,'IF ('.$self->occasion().'.EQ.'.$self->occasionlist()->[$i].') THEN' );
				my $offset = $bsv_parameters+$n_invariant;
				$offset = $offset+$bov_parameters*$n_occasions+$i*$n_time_varying;
				for (my $j=0 ; $j< $n_time_varying; $j++){
					push(@begin_code,'   BOV'.$self->time_varying()->[$j].' = ETA('.($offset+$j+1).')');
				}
				push(@begin_code,'END IF' );
			}
		}elsif ($model_type eq '3'){
			for (my $i=0; $i< $n_occasions; $i++){
				push(@begin_code,'IF ('.$self->occasion().'.EQ.'.$self->occasionlist()->[$i].') THEN' );
				my $offset = $bsv_parameters+$n_invariant+$i*($bov_parameters+$n_time_varying);
				for (my $j=0 ; $j< $bov_parameters; $j++){
					push(@begin_code,'   BOV'.$self->parameters()->[$j].' = ETA('.($offset+$j+1).')');
				}
				$offset = $offset+$bov_parameters;
				for (my $j=0 ; $j< $n_time_varying; $j++){
					push(@begin_code,'   BOV'.$self->time_varying()->[$j].' = ETA('.($offset+$j+1).')');
				}
				push(@begin_code,'END IF' );
			}
		}else{
			croak("bug in loop set_theta_omega_code");
		}
    }
    push(@begin_code,';;;FREM CODE END A' );

    
    #ERROR/PRED changes at end
    my @end_code = (';;;FREM CODE BEGIN C');
    for (my $i=0; $i< $n_invariant; $i++){
		push(@end_code,'Y'.($i+1).' = THETA('.($ntheta+$i+1).') + BSV'.$self->invariant()->[$i]);
    }
    for (my $i=0; $i< $n_time_varying; $i++){
		push(@end_code,'Y'.($n_invariant+$i+1).' = THETA('.($ntheta+$n_invariant+$i+1).') + BOV'.$self->time_varying()->[$i]);
    }
    for (my $i=1; $i<=($n_invariant+$n_time_varying); $i++){
		push(@end_code,'IF ('.$fremtype.'.EQ.'.$i.') THEN' );
		push(@end_code,'   Y = Y'.$i.'+EPS('.$epsnum.')' );
		push(@end_code,'   IPRED = Y'.$i );
		push(@end_code,'END IF' );
    }

    push(@end_code,';;;FREM CODE END C' );



    #PK/PRED changes at beginning B
    if ( $n_time_varying > 0){
		foreach my $parameter (@{$self->parameters()}){
			my $success = 0;
			my $etanum = 0;
			my $bov= 'BOV'.$parameter;
			
#	for (reverse  @code ) {
			for (my $i=$#code; $i>=0 ; $i--) {
				next if ( $code[$i] =~ /^\s*;/); #comment line
				$_ = $code[$i];
				if ( /^\s*(\w+)\s*=\s*/ and $1 eq $parameter ){
					s/^(\s*\w+\s*=\s*)//;
					my $left = $1;
					my ($right,$comment) = split( ';', $_, 2 );

					#TODO use \b boundary matching here, subst with $1 etc
					if ($right =~ /[^A-Z0-9_]ETA\(([0-9]+)\)/){
						#add BOV
						$etanum = $1;
						$right =~ s/ETA\($etanum\)/(ETA($etanum)+$bov)/;
					}elsif ($right =~ /\(0\)/){
						#replace 0 with BOV
						$right =~ s/\(0\)/($bov)/;
					}else{
						croak("Could not find an appropriate place to add $bov on the line ".
							  $parameter."= ...");
					}
					$success=1;
					$code[$i] = $left.$right;
					$code[$i] = $code[$i].';'.$comment if (length($comment)>0);
					last;
				}
				
			}
			unless ( $success ) {
				my $mes = "Could not find $parameter=... line to add $bov\n";
				croak($mes );
			}
		}
    }

    my $found_anchor = -1;
    my $i = 0;
    for ( @code ) {
		if ( /^;;;FREM-ANCHOR/) {
			$found_anchor = $i;
			last;
		}
		$i++
    }
    if ($found_anchor >= 0){
		my @block1 =  (@code[0..$found_anchor]);
		my @block2 =  (@code[($found_anchor+1)..$#code]);
		@code = (@block1,@begin_code,@block2);
    }else{
		unshift(@code,@begin_code);
    }
    
    if ( $use_pred ) {
		push(@code,@end_code);
		$model -> pred( problem_number => 1,
						new_pred       => \@code );
    } else {
		$model -> pk( problem_number => 1,
					  new_pk         => \@code );
		my @error = @{$model -> error( problem_number => 1 )};
		push(@error,@end_code);
		$model -> error( problem_number => 1,
						 new_error         => \@error );
    }
}

sub cleanup
{
	my $self = shift;
	my %parm = validated_hash(\@_,
		  arg1 => { isa => 'Int', optional => 1 }
	);

  #remove tablefiles in simulation NM_runs, they are 
  #copied to m1 by modelfit and read from there anyway.
  for (my $samp=1;$samp<=$self->samples(); $samp++){
    unlink $self -> directory."/simulation_dir1/NM_run".$samp."/mc-sim-".$samp.".dat";
    unlink $self -> directory."/simulation_dir1/NM_run".$samp."/mc-sim-".$samp."-1.dat"; #retry
  }

}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
