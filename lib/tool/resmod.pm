package tool::resmod;

use strict;
use Moose;
use MooseX::Params::Validate;
use List::Util qw(max);
use include_modules;
use log;
use array;
use model;
use model::problem;
use tool::modelfit;
use output;
use nmtablefile;

extends 'tool';

has 'model' => ( is => 'rw', isa => 'model' );
has 'groups' => ( is => 'rw', isa => 'Int', default => 4 );       # The number of groups to use for quantiles in the time_varying model 
has 'idv' => ( is => 'rw', isa => 'Str', default => 'TIME' );
has 'dvid' => ( is => 'rw', isa => 'Str', default => 'DVID' );
has 'occ' => ( is => 'rw', isa => 'Str', default => 'OCC' );
has 'run_models' => ( is => 'rw', isa => 'ArrayRef', default => sub { [] } );      # Array of arrays for the run models [DVID]->[model]
has 'l2_model' => ( is => 'rw', isa => 'model' );
has 'residual_models' => ( is => 'rw', isa => 'ArrayRef', default => sub { [] } );  # Array of arrays of hashes for the actual run_models [DVID]->[model]
has 'cutoffs' => ( is => 'rw', isa => 'ArrayRef' );
has 'unique_dvid' => ( is => 'rw', isa => 'ArrayRef' );
has 'numdvid' => ( is => 'rw', isa => 'Int' );
has 'iterative' => ( is => 'rw', isa => 'Bool', default => 0 );
has 'best_models' => ( is => 'rw', isa => 'ArrayRef', default => sub { [] } );

has 'top_level' => ( is => 'rw', isa => 'Bool', default => 1 );     # Is this the top level resmod object
has 'current_dvid' => ( is => 'rw', isa => 'Int' );             # Index of the current DVID. undef if don't have dvid
has 'model_templates' => ( is => 'rw', isa => 'ArrayRef' );		# List of model_templates to use
# Array of iterations over Hash of dvids over Hash of modelnames over type of result = dOFV or parameters
has 'resmod_results' => ( is => 'rw', isa => 'ArrayRef', default => sub { [] } );
has 'iteration' => ( is => 'rw', isa => 'Int', default => 0 );      # Number of the iteration
has 'iteration_summary' => ( is => 'rw', isa => 'ArrayRef[ArrayRef]', default => sub { [ [] ] } );  # [iteration]->[modelnumber if multiple in one iter]->{dvid}->{'model_name', 'dOFV'

sub BUILD
{
    my $self = shift;

	my $model = $self->models()->[0]; 
    $self->model($model);

    if ($self->top_level) {
        my @columns = ( 'ID', $self->idv, 'CWRES' );
        my $cwres_table = $self->model->problems->[0]->find_table(columns => \@columns, get_object => 1);
        if (not defined $cwres_table) {
            die "Error original model has no table containing ID, IDV and CWRES\n";
        }
        my $cwres_table_name = $self->model->problems->[0]->find_table(columns => \@columns);
        my $table = nmtablefile->new(filename => "$cwres_table_name"); 
        my @columns_in_table = @{$cwres_table->columns()};
        my $have_tad = grep { $_ eq 'TAD' } @columns_in_table; 
        my $have_dvid = grep { $_ eq $self->dvid } @columns_in_table;

        my $idv_column = $self->idv;
        if ($have_tad) {
            $idv_column = 'TAD';
        }

        $self->_create_model_templates(table => $table, idv_column => $idv_column); 

        if ($have_dvid) {
            my $dvid_column = $table->tables->[0]->header->{$self->dvid};
            my $unique_dvid = array::unique($table->tables->[0]->columns->[$dvid_column]);
            $self->unique_dvid($unique_dvid);
            my $number_of_dvid = scalar(@$unique_dvid);
            $self->numdvid($number_of_dvid);
        } else {
            $self->unique_dvid(['NA']);
            $self->numdvid(1);
        }
    }
}

sub modelfit_setup
{
	my $self = shift;

    # Find a table with ID, TIME, CWRES and extra_input (IPRED)
    my @columns = ( 'ID', $self->idv, 'CWRES' );
    my $cwres_table = $self->model->problems->[0]->find_table(columns => \@columns, get_object => 1);
    my $cwres_table_name = $self->model->problems->[0]->find_table(columns => \@columns);

    # Do we have IPRED, DVID or TAD?
    my $have_ipred = 0;
    my $have_dvid = 0;
	my $have_occ = 0;
	my $have_tad = 0;
    my $have_l2 = 0;
    for my $option (@{$cwres_table->options}) {
        if ($option->name eq 'IPRED') {
            $have_ipred = 1;
            push @columns, 'IPRED';
        } elsif ($option->name eq $self->dvid) {
            $have_dvid = 1;
            push @columns, $self->dvid;
		} elsif ($option->name eq $self->occ) {
			$have_occ = 1;
			push @columns, $self->occ;
        } elsif ($option->name eq 'TAD') {
			$have_tad = 1;
			push @columns, 'TAD',
		} elsif ($option->name eq 'L2') {
            $have_l2 = 1;
        }
    }

    if (not $self->top_level) {
        $cwres_table_name = "m1/$cwres_table_name";
    }

	my @models_to_run;
    for my $model_properties (@{$self->model_templates}) {
		my $tad;
		if ($have_tad and $model_properties->{'name'} eq 'time_varying') {
			$tad = 1;
		}
    	my $input_columns = _create_input(
			table => $cwres_table,
			columns => \@columns,
			ipred => 1,     # Always add ipred to be able to pass it through to next iteration if needed
			occ => $model_properties->{'need_occ'},
			occ_name => $self->occ,
			tad => $tad
		);
        next if ($model_properties->{'need_ipred'} and not $have_ipred);
		next if ($model_properties->{'need_occ'} and not $have_occ);

        my $accept = "";
        for (my $i = 0; $i < $self->numdvid; $i++) {
            if ($have_dvid) {
                $accept = "IGNORE=(" . $self->dvid . ".NEN." . $self->unique_dvid->[$i] . ")";
            }

            my @prob_arr = @{$model_properties->{'prob_arr'}};
            for my $row (@prob_arr) {
                $row =~ s/<inputcolumns>/$input_columns/g;
                $row =~ s/<cwrestablename>/$cwres_table_name/g;
                $row =~ s/<dvidaccept>/$accept/g;
                my $idv = $self->idv;
				if ($have_tad and $model_properties->{'name'} eq 'time_varying') {
					$idv = 'TAD';
				} 
                $row =~ s/<idv>/$idv/g;
            }

            my $dvid_suffix = "";
            $dvid_suffix = "_DVID" . int($self->unique_dvid->[$i]) if ($have_dvid);

            if ($self->iterative) {
                my $ipred = "";
                if ($have_ipred) {
                    $ipred = ' IPRED';
                } 
                push @prob_arr, "\$TABLE ID TIME CWRES$ipred NOPRINT NOAPPEND ONEHEADER FILE=" . $model_properties->{'name'} . "$dvid_suffix.tab";
            }

            my $cwres_model = $self->_create_new_model(
                prob_arr => \@prob_arr,
                filename => $model_properties->{'name'} . "$dvid_suffix.mod"
            );

            push @models_to_run, $cwres_model;
            push @{$self->run_models->[$i]}, $cwres_model;
            push @{$self->residual_models->[$i]}, $model_properties; 
        }
    }

    if ($have_l2 and $self->numdvid > 1) {
        push @columns, 'L2';
    	my $input_columns = _create_input(
			table => $cwres_table,
			columns => \@columns,
            l2 => 1,
		);

        my $l2_model = $self->_prepare_L2_model(
		    input_columns => $input_columns,
            table_name => $cwres_table_name,
            num_dvid => $self->numdvid,
        );

        $self->l2_model($l2_model);
        push @models_to_run, $l2_model;
    }

    _create_extra_fortran_files();

	my $modelfit = tool::modelfit->new(
		%{common_options::restore_options(@common_options::tool_options)},
		models => \@models_to_run, 
		base_dir => $self->directory . 'm1/',
		directory => undef,
		top_tool => 0,
        copy_data => 0,
	);

	$self->tools([]) unless defined $self->tools;
	push(@{$self->tools}, $modelfit);
}

sub modelfit_analyze
{
    my $self = shift;

    _delete_extra_fortran_files();

    my %base_models;        # Hash from basemodelno to base model OFV
	my $current_dvid;
    my @dofvs;
    my @model_names;
    my $base_sum = 0;
	for (my $dvid_index = 0; $dvid_index < $self->numdvid; $dvid_index++) {
		for (my $i = 0; $i < scalar(@{$self->residual_models->[$dvid_index]}); $i++) {
			my $model = $self->run_models->[$dvid_index]->[$i];
			my $model_name = $self->residual_models->[$dvid_index]->[$i]->{'name'};
			my $ofv;
			if ($model->is_run()) {
				my $output = $model->outputs->[0];
				$ofv = $output->get_single_value(attribute => 'ofv');
			}
			if (not defined $ofv) {
				$ofv = 'NA';
			}
			if (exists $self->residual_models->[$dvid_index]->[$i]->{'base'}) {        # This is a base model
				$base_models{$self->residual_models->[$dvid_index]->[$i]->{'base'}} = $ofv;
                if ($self->residual_models->[$dvid_index]->[$i]->{'name'} eq 'base') {
                    $base_sum += $ofv;
                }
				next;
			}

			my $base_ofv;
			$base_ofv = $base_models{$self->residual_models->[$dvid_index]->[$i]->{'use_base'}};
			if ($base_ofv eq 'NA' or $ofv eq 'NA') {        # Really skip parameters if no base ofv?
                $self->resmod_results->[$self->iteration]->{$self->unique_dvid->[$dvid_index]}->{$model_name}->{'dOFV'} = 'NA';
                $self->resmod_results->[$self->iteration]->{$self->unique_dvid->[$dvid_index]}->{$model_name}->{'parameters'} = 'NA';
				next;
			}
			my $delta_ofv = $ofv - $base_ofv;
			$delta_ofv = sprintf("%.2f", $delta_ofv);
            push @dofvs, $delta_ofv;
            push @model_names, $model_name;
            $self->resmod_results->[$self->iteration]->{$self->unique_dvid->[$dvid_index]}->{$model_name}->{'dOFV'} = $delta_ofv;

			if (exists $self->residual_models->[$dvid_index]->[$i]->{'parameters'}) {
                my @parameter_strings;
				for my $parameter (@{$self->residual_models->[$dvid_index]->[$i]->{'parameters'}}) {
					if ($parameter->{'name'} eq "CUTOFFS") {
                        if ($parameter->{'cutoff'} eq 'all') {
                            for (my $i = 0; $i < scalar(@{$self->cutoffs}); $i++) {
                                push @parameter_strings, sprintf("t" . ($i + 1) . "=%.2f ", $self->cutoffs->[$i]);
                            }
                        } else {
                            push @parameter_strings, sprintf('t0=%.2f', $self->cutoffs->[$parameter->{'cutoff'}]); 
                        }
                        next;
                    }
                    my $param_string = $parameter->{'name'} . "=";
					my $coordval;
					my $param = $parameter->{'parameter'};
					my $paramhash;
					if ($param =~ /OMEGA/) {
						$paramhash = $model->outputs->[0]->omegacoordval()->[0]->[0];
					} elsif ($param =~ /SIGMA/) {
						$paramhash = $model->outputs->[0]->sigmacoordval()->[0]->[0];
					} elsif ($param =~ /THETA/) {
						$paramhash = $model->outputs->[0]->thetacoordval()->[0]->[0];
					}
                    my $param_value = $paramhash->{$param};
                    if (exists $parameter->{'recalc'}) {
                        $param_value = $parameter->{'recalc'}->($param_value);
                    }
                    $param_string .= sprintf("%.3f", $param_value);
                    push @parameter_strings, $param_string;
				}
                my $parameter_string = join(',', @parameter_strings);
                $self->resmod_results->[$self->iteration]->{$self->unique_dvid->[$dvid_index]}->{$model_name}->{'parameters'} = $parameter_string;
			}
		}
	}

    if (defined $self->l2_model) {
        my $ofv;
        my $dofv;
        if ($self->l2_model->is_run()) {
            my $output = $self->l2_model->outputs->[0];
            $ofv = $output->get_single_value(attribute => 'ofv');
        }
        if (not defined $ofv or not defined $base_sum) {
            $dofv = 'NA';
        } else {
            $dofv = $ofv - $base_sum;
            $dofv = sprintf("%.2f", $dofv);
        }
        $self->resmod_results->[$self->iteration]->{'L2'} = $dofv;
    }

    if ($self->iterative) {
        my @best_models = @{$self->best_models};
        my $model_name;

        my $minvalue;
        my $model_no = 0;
        while (scalar(@dofvs)) {
            ($minvalue, my $minind) = array::min(@dofvs);
            $model_name = $model_names[$minind];

            # Was the model selected previously?
            if (grep { $_ eq $model_name } @best_models) {
                splice @dofvs, $minind, 1;
                splice @model_names, $minind, 1;
                next;
            }

            # Check if the CWRES column is all zeros
            my $table = nmtablefile->new(filename => "m1/$model_name.tab"); 
            my $cwres_column = $table->tables->[0]->header->{'CWRES'};
            my $unique_cwres = array::unique($table->tables->[0]->columns->[$cwres_column]);
            if (scalar(@$unique_cwres) == 1 && $unique_cwres->[0] == 0) {
                splice @dofvs, $minind, 1;
                splice @model_names, $minind, 1;
                push @best_models, $model_name;
                $self->iteration_summary->[$self->iteration]->[$model_no]->{'NA'}->{'dOFV'} = $minvalue;
                $self->iteration_summary->[$self->iteration]->[$model_no]->{'NA'}->{'model_name'} = $model_name;
                $model_no++;
                next;
            }

            last;
        }

        if (scalar(@dofvs) == 0) {      # Exit recursion
            return;
        }

        $self->iteration_summary->[$self->iteration]->[$model_no]->{'NA'}->{'dOFV'} = $minvalue;
        $self->iteration_summary->[$self->iteration]->[$model_no]->{'NA'}->{'model_name'} = $model_name;

        push @best_models, $model_name;

        my $model = model->new(
            #eval($eval_string),
            filename => "m1/$model_name.mod",
            ignore_missing_output_files => 1,
            ignore_missing_data => 1,
        );
        my $resmod = tool::resmod->new(
            #eval( $common_options::parameters ),
            models => [ $model ],
            idv => $self->idv,
            iterative => $self->iterative,
            best_models => \@best_models,
            cutoffs => $self->cutoffs,
            top_level => 0,
            model_templates => $self->model_templates,
            numdvid => $self->numdvid,
            unique_dvid => $self->unique_dvid,
            iteration => $self->iteration + 1,
            resmod_results => $self->resmod_results,
            iteration_summary => $self->iteration_summary,
        );
        $resmod->run();
    }


    # End of all iterations
    if ($self->top_level) {
        $self->_print_results();
    }
}

sub _print_results
{
    my $self = shift;

    open my $fh, '>', 'results.csv';
    print $fh "Iteration,DVID,Model,dOFV,Parameters\n";

    for (my $iter = 0; $iter < scalar(@{$self->resmod_results}); $iter++) {
        my $print_iter;
        if (scalar(@{$self->resmod_results}) == 1) {
            $print_iter = 'NA';
        } else {
            $print_iter = $iter;
        }
        my $l2_dofv = $self->resmod_results->[$iter]->{'L2'};
        if (defined $l2_dofv) {
            delete $self->resmod_results->[$iter]->{'L2'};
        }
        my @sorted_dvids = sort keys %{$self->resmod_results->[$iter]};
        my %dvid_sum;
        for my $dvid (@sorted_dvids) {
            my @sorted_modelnames = sort { $a cmp $b } keys %{$self->resmod_results->[$iter]->{$dvid}};
            for my $model_name (@sorted_modelnames) {
                my $dofv = $self->resmod_results->[$iter]->{$dvid}->{$model_name}->{'dOFV'};
                if (not defined $dvid_sum{$model_name}) {
                    $dvid_sum{$model_name} = 0;
                }
                if ($dvid_sum{$model_name} ne 'NA') {
                    if ($dofv ne 'NA') {
                        $dvid_sum{$model_name} += $dofv;
                    } else {
                        $dvid_sum{$model_name} = 'NA';
                    }
                }
                my $parameter_string = $self->resmod_results->[$iter]->{$dvid}->{$model_name}->{'parameters'};
                print $fh "$print_iter,$dvid,$model_name,$dofv,$parameter_string\n";
            }
        }
        # Create summary for DVID
        if (scalar(@sorted_dvids) > 1) {
            my @sorted_modelnames = sort { $a cmp $b } keys %{$self->resmod_results->[$iter]->{$sorted_dvids[0]}};
            for my $model_name (@sorted_modelnames) {
                print $fh "$print_iter,sum,$model_name,$dvid_sum{$model_name}\n";
            }
            if (defined $l2_dofv) {
                print $fh "$print_iter,sum,L2,$l2_dofv\n";
            }
        } 
    }

    close $fh;

    open my $iter_fh, '>', "iteration_summary.csv";
    print $iter_fh "Iteration,Model no,DVID,Model,dOFV\n";

    for (my $iter = 0; $iter < scalar(@{$self->iteration_summary}); $iter++) {
        for (my $model_no = 0; $model_no < scalar(@{$self->iteration_summary->[$iter]}); $model_no++) {
            my @sorted_dvids = sort keys %{$self->iteration_summary->[$iter]->[$model_no]};
            for my $dvid (@sorted_dvids) {
                my $model_name = $self->iteration_summary->[$iter]->[$model_no]->{$dvid}->{'model_name'};
                my $dofv = $self->iteration_summary->[$iter]->[$model_no]->{$dvid}->{'dOFV'};
                print $iter_fh "$iter,$model_no,$dvid,$model_name,$dofv\n"
            }
        }
    }
    close $iter_fh;
}

sub _calculate_quantiles
{
    my $self = shift;
	my %parm = validated_hash(\@_,
		table => { isa => 'nmtable' },
		column => { isa => 'Str' },
	);
	my $table = $parm{'table'};
	my $column = $parm{'column'};

	my $column_no = $table->header->{$column};
    my $cwres_col = $table->header->{'CWRES'};
    my @data;
    for my $i (0 .. scalar(@{$table->columns->[$column_no]}) - 1) {    # Filter out all 0 CWRES as non-observations
        my $cwres = $table->columns->[$cwres_col]->[$i];
        if ($cwres ne 'CWRES' and $cwres != 0) {
            push @data, $table->columns->[$column_no]->[$i] + 0;
        }
    }
    @data = sort { $a <=> $b } @data;
	my $quantiles = array::quantile(numbers => \@data, groups => $self->groups);
	
    return $quantiles;
}

sub _create_input
{
	# Create $INPUT string from table
	my %parm = validated_hash(\@_,
		table => { isa => 'model::problem::table' },
		columns => { isa => 'ArrayRef' },
		ipred => { isa => 'Bool', default => 1 },		# Should ipred be included if in columns?
		occ => { isa => 'Bool', default => 1 },			# Should occ be included if in columns?
		occ_name => { isa => 'Str', default => 'OCC' },	# Name of the occ column
		tad => { isa => 'Bool', default => 0 },			# Should TAD be used instead of $self->idv?
        l2 => { isa => 'Bool', default => 0 },          # Should L2 be included if in columns?
	);
	my $table = $parm{'table'};
	my @columns = @{$parm{'columns'}};
	my $ipred = $parm{'ipred'};
	my $occ = $parm{'occ'};
	my $occ_name = $parm{'occ_name'};
	my $tad = $parm{'tad'};
	my $l2 = $parm{'l2'};

	my $input_columns;
	my @found_columns;
	for my $option (@{$table->options}) {
		my $found = 0; 
		for (my $i = 0; $i < scalar(@columns); $i++) {
            if ($option->name eq $columns[$i] and not $found_columns[$i]) {
                $found_columns[$i] = 1;
                my $name = $option->name;
                $name = 'DV' if ($name eq 'CWRES');
				$name = 'DROP' if ($name eq 'IPRED' and not $ipred);
				$name = 'DROP' if ($name eq $occ_name and not $occ);
				$name = 'DROP' if ($name eq 'TAD' and not $tad);
				$name = 'DROP' if ($name eq 'TIME' and $tad);
                $name = 'DROP' if ($name eq 'L2' and not $l2);
                $input_columns .= $name;
                $found = 1;
                last;
            }
        }
        if (not $found) {
            $input_columns .= 'DROP';
        }
        last if ((grep { $_ } @found_columns) == scalar(@columns));
        $input_columns .= ' ';
    }
	
	return $input_columns;
}

sub _create_new_model
{
    my $self = shift;
	my %parm = validated_hash(\@_,
		prob_arr => { isa => 'ArrayRef' },
        filename => { isa => 'Str' },
    );
    my $prob_arr = $parm{'prob_arr'};
    my $filename = $parm{'filename'};

    my $sh_mod = model::shrinkage_module->new(
        nomegas => 1,
        directory => 'm1/',
        problem_number => 1
    );

    my $cwres_problem = model::problem->new(
        prob_arr => $prob_arr,
        shrinkage_module => $sh_mod,
    );

    my $cwres_model = model->new(
        directory => 'm1/',
        filename => $filename,
        problems => [ $cwres_problem ],
        extra_files => [ $self->directory . '/contr.txt', $self->directory . '/ccontra.txt' ],
    );

    $cwres_model->_write();
    
    return $cwres_model;
}

sub _prepare_L2_model
{
    my $self = shift;
    my %parm = validated_hash(\@_,
		input_columns => { isa => 'Str' },
        table_name => { isa => 'Str' },
        num_dvid => { isa => 'Int' },
    );
    my $input_columns = $parm{'input_columns'};
    my $table_name = $parm{'table_name'};
    my $num_dvid = $parm{'num_dvid'};

    my @prob_arr = (
        '$PROBLEM    CWRES base model',
        '$INPUT ' . $input_columns,
        '$DATA ../' . $table_name . ' IGNORE=@ IGNORE(DV.EQN.0)',
        '$PRED',
    );

    for (my $i = 1; $i <= $num_dvid; $i++) {
        push @prob_arr, "IF(DVID.EQ.$i) Y = THETA($i) + ETA($i) + ERR($i)";
    }

    for (my $i = 0; $i < $num_dvid; $i++) {
        push @prob_arr, '$THETA 0.1';
    }    

    for (my $i = 0; $i < $num_dvid; $i++) {
        push @prob_arr, '$OMEGA 0.01';
    }

    push @prob_arr, "\$SIGMA BLOCK($num_dvid)";
    for (my $i = 0; $i < $num_dvid; $i++) {
        my $row = " ";
        for (my $j = 0; $j < $i; $j++) {
            $row .= '0.01 ';
        }
        $row .= '1';
        push @prob_arr, $row;
    }

    push @prob_arr, '$ESTIMATION METHOD=1 INTER MAXEVALS=9990 PRINT=2 POSTHOC';

    my $l2_model = $self->_create_new_model(
        prob_arr => \@prob_arr,
        filename => 'l2.mod',
    );

    return $l2_model;
}

sub _build_time_varying_template
{
    # Create the templates for the different time_varying models
    my $self = shift;
    my %parm = validated_hash(\@_,
		cutoffs => { isa => 'ArrayRef' },
    );
    my $cutoffs = $parm{'cutoffs'};

    my @models;

    # Create one model for each interval.
    for (my $i = 0; $i < scalar(@$cutoffs); $i++) {
        my %hash;
        $hash{'use_base'} = 1;
        $hash{'name'} = "time_varying_RUV_cutoff$i";
        my @prob_arr = (
            "\$PROBLEM CWRES time varying cutoff $i",
            '$INPUT <inputcolumns>',
            '$DATA ../<cwrestablename> IGNORE=@ IGNORE=(DV.EQN.0) <dvidaccept>',
            '$PRED',
            'Y = THETA(1) + ETA(1) + ERR(2)',
            'IF (<idv>.LT.' . $cutoffs->[$i] . ") THEN",
            '    Y = THETA(1) + ETA(1) + ERR(1)',
            'END IF',
            '$THETA -0.0345794',
            '$OMEGA 0.5',
            '$SIGMA 0.5',
            '$SIGMA 0.5',
            '$ESTIMATION METHOD=1 INTER MAXEVALS=9990 PRINT=2 POSTHOC',
        );

        $hash{'prob_arr'} = \@prob_arr;

        $hash{'parameters'} = [
            { name => "sdeps_0-t0", parameter => "SIGMA(1,1)", recalc => sub { sqrt($_[0]) } },
            { name => "sdeps_t0-inf", parameter => "SIGMA(2,2)", recalc => sub { sqrt($_[0]) } },
            { name => "CUTOFFS", cutoff => $i },
        ];

        push @models, \%hash;
    } 

    for my $param ('theta', 'eps') {
        my %hash;
        if ($param eq 'eps') {
            $hash{'name'} = 'time_varying_RUV';
        } else {
            $hash{'name'} = 'time_varying_theta';
        }
        $hash{'use_base'} = 1;
        my @prob_arr = (
            '$PROBLEM CWRES time varying',
            '$INPUT <inputcolumns>',
            '$DATA ../<cwrestablename> IGNORE=@ IGNORE=(DV.EQN.0) <dvidaccept>',
            '$PRED',
        );

        if ($param eq 'eps') {
            push @prob_arr, 'Y = THETA(1) + ETA(1) + ERR(' . (scalar(@$cutoffs) + 1)  . ')';
        } else {
            push @prob_arr, 'Y = THETA(' . (scalar(@$cutoffs) + 1) . ') + ETA(1) + ERR(1)';
        }
        for (my $i = 0; $i < scalar(@$cutoffs); $i++) {
            if ($i == 0) {
                push @prob_arr, "IF (<idv>.LT." . $cutoffs->[0] . ") THEN";
            } else {
                push @prob_arr, "IF (<idv>.GE." .$cutoffs->[$i - 1] . " .AND. <idv>.LT." . $cutoffs->[$i] . ") THEN";
            }
            if ($param eq 'eps') {
                push @prob_arr, "    Y = THETA(1) + ETA(1) + EPS(" . ($i + 1) . ")";
            } else {
                push @prob_arr, "    Y = THETA(" . ($i + 1) . ") + ETA(1) + EPS(1)";
            }
            push @prob_arr, "END IF";
        }

        if ($param eq 'eps') {
            push @prob_arr, '$THETA -0.0345794';
        } else {
            for (my $i = 0 ; $i <= scalar(@$cutoffs); $i++) {
                push @prob_arr, '$THETA 0.03';
            }
        }
        push @prob_arr, '$OMEGA 0.5';

        if ($param eq 'eps') {
            for (my $i = 0; $i <= scalar(@$cutoffs); $i++) {
                push @prob_arr, '$SIGMA 0.5';
            }
        } else {
            push @prob_arr, '$SIGMA 0.5';
        }

        push @prob_arr, '$ESTIMATION METHOD=1 INTER MAXEVALS=9990 PRINT=2 POSTHOC';
        $hash{'prob_arr'} = \@prob_arr;

        my @parameters;
        for (my $i = 0; $i <= scalar(@$cutoffs); $i++) {
            my %parameter_hash;
            my $start;
            my $end;
            if ($i == 0) {
                $start = '0';
            } else {
                $start = "t$i";
            }
            if ($i == scalar(@$cutoffs)) {
                $end = 'inf';
            } else {
                $end = "t" . ($i + 1);
            }
            if ($param eq 'eps') {
                $parameter_hash{'name'} = "sdeps_$start-$end";
                $parameter_hash{'parameter'} = "SIGMA(" . ($i + 1) . "," . ($i + 1) . ")";
                $parameter_hash{'recalc'} = sub { sqrt($_[0]) };
            } else {
                $parameter_hash{'name'} = "th_$start-$end";
                $parameter_hash{'parameter'} = "THETA" . ($i + 1);
            }
            push @parameters, \%parameter_hash;
        }
        push @parameters, { name => "CUTOFFS", cutoff => 'all' };
        $hash{'parameters'} = \@parameters;
        push @models, \%hash;
    }

    return \@models;
}

sub _create_extra_fortran_files
{
	# Create the contr.txt and ccontra.txt needed for dtbs
	open my $fh_contr, '>', "contr.txt";
	print $fh_contr <<'END';
      subroutine contr (icall,cnt,ier1,ier2)
      double precision cnt
      call ncontr (cnt,ier1,ier2,l2r)
      return
      end
END
	close $fh_contr;

	open my $fh_ccontra, '>', "ccontra.txt";
	print $fh_ccontra <<'END';
      subroutine ccontr (icall,c1,c2,c3,ier1,ier2)
      USE ROCM_REAL,   ONLY: theta=>THETAC,y=>DV_ITM2
      USE NM_INTERFACE,ONLY: CELS
!      parameter (lth=40,lvr=30,no=50)
!      common /rocm0/ theta (lth)
!      common /rocm4/ y
!      double precision c1,c2,c3,theta,y,w,one,two
      double precision c1,c2,c3,w,one,two
      dimension c2(:),c3(:,:)
      data one,two/1.,2./
      if (icall.le.1) return
      w=y(1)

         if(theta(3).eq.0) y(1)=log(y(1))
         if(theta(3).ne.0) y(1)=(y(1)**theta(3)-one)/theta(3)


      call cels (c1,c2,c3,ier1,ier2)
      y(1)=w
      c1=c1-two*(theta(3)-one)*log(y(1))

      return
      end
END
	close $fh_ccontra;
}

sub _delete_extra_fortran_files
{
	unlink('contr.txt', 'ccontra.txt');
}

# This array of hashes represent the different models to be tested.
our @residual_models =
(
	{
		name => 'base',
	    prob_arr => [
			'$PROBLEM CWRES base model',
			'$INPUT <inputcolumns>',
			'$DATA ../<cwrestablename> IGNORE=@ IGNORE=(DV.EQN.0) <dvidaccept>',
			'$PRED',
            'Y = THETA(1) + ETA(1) + ERR(1)',
			'$THETA .1',
			'$OMEGA 0.01',
			'$SIGMA 1',
			'$ESTIMATION METHOD=1 INTER MAXEVALS=9990 PRINT=2 POSTHOC',
        ],
        base => 1,
	}, {
		name => 'IIV_on_RUV',
	    prob_arr => [
			'$PROBLEM CWRES omega-on-epsilon',
			'$INPUT <inputcolumns>',
			'$DATA ../<cwrestablename> IGNORE=@ IGNORE=(DV.EQN.0) <dvidaccept>',
			'$PRED',
            'Y = THETA(1) + ETA(1) + ERR(1) * EXP(ETA(2))',
			'$THETA .1',
			'$OMEGA 0.01',
            '$OMEGA 0.01',
			'$SIGMA 1',
			'$ESTIMATION METHOD=1 INTER MAXEVALS=9990 PRINT=2 POSTHOC',
        ],
        parameters => [
            { name => "%CV", parameter => "OMEGA(2,2)", recalc => sub { sqrt($_[0])*100 } },
        ],
        use_base => 1,
    }, {
		name => 'power',
        need_ipred => 1,
	    prob_arr => [
			'$PROBLEM CWRES power IPRED',
			'$INPUT <inputcolumns>',
			'$DATA ../<cwrestablename> IGNORE=@ IGNORE=(DV.EQN.0) <dvidaccept>',
			'$PRED',
            'Y = THETA(1) + ETA(1) + ERR(1)*(IPRED)**THETA(2)',
			'$THETA .1',
			'$THETA .1',
			'$OMEGA 0.01',
			'$SIGMA 1',
			'$ESTIMATION METHOD=1 INTER MAXEVALS=9990 PRINT=2 POSTHOC',
        ],
        parameters => [
            { name => "delta_power", parameter => "THETA2" },
        ],
        use_base => 1,
	}, {
        name => 'autocorrelation',
        prob_arr => [
			'$PROBLEM CWRES AR1',
			'$INPUT <inputcolumns>',
			'$DATA ../<cwrestablename> IGNORE=@ IGNORE=(DV.EQN.0) <dvidaccept>',
			'$PRED',
            '"FIRST',
            '" USE SIZES, ONLY: NO',
            '" USE NMPRD_REAL, ONLY: C=>CORRL2',
            '" REAL (KIND=DPSIZE) :: T(NO)',
            '" INTEGER (KIND=ISIZE) :: I,J,L',
            '"MAIN',
            '"C If new ind, initialize loop',
            '" IF (NEWIND.NE.2) THEN',
            '"  I=0',
            '"  L=1',
            '"  OID=ID',
            '" END IF',
            '"C Only if first in L2 set and if observation',
            '"C  IF (MDV.EQ.0) THEN',
            '"  I=I+1',
            '"  T(I)=TIME',
            '"  IF (OID.EQ.ID) L=I',
            '"',
            '"  DO J=1,I',
            '"      C(J,1)=EXP((-0.6931/THETA(2))*(TIME-T(J)))',
            '"  ENDDO',
            'Y = THETA(1) + ETA(1) + EPS(1)',
            '$THETA  -0.0345794',
            '$THETA  (0.001,1)',
            '$OMEGA  2.41E-006',
            '$SIGMA  0.864271',
            '$ESTIMATION METHOD=1 INTER MAXEVALS=9990 PRINT=2 POSTHOC',
        ],
        parameters => [
            { name => "half-life", parameter => "THETA2" },
        ],
        use_base => 1,
    }, {
		name => 'autocorrelation_iov',
		need_occ => 1,
		prob_arr => [
			'$PROBLEM CWRES AR1 IOV',
			'$INPUT <inputcolumns>',
			'$DATA ../<cwrestablename> IGNORE=@ IGNORE=(DV.EQN.0) <dvidaccept>',
			'$ABBREVIATED DECLARE T1(NO)',
			'$ABBREVIATED DECLARE INTEGER I,DOWHILE J',
			'$PRED', 
			'IF(NEWIND.NE.2) THEN',
			'  I=0',
			'  L=1',
			'  OOCC=OCC',
			'  OID=ID',
			'END IF',
			'IF(NEWL2==1) THEN',
			'  I=I+1',
			'  T1(I)=TIME',
			'  IF(OID.EQ.ID.AND.OOCC.NE.OCC)THEN',
			'    L=I',
			'    OOCC=OCC',
			'  END IF',
			'  J=L',
			'  DO WHILE (J<=I)',
			'    CORRL2(J,1) = EXP((-0.6931/THETA(2))*(TIME-T1(J)))',
			'    J=J+1',
			'  ENDDO',
			'ENDIF',
			'Y = THETA(1) + ETA(1) + EPS(1)',
			'$THETA -0.0345794',
			'$THETA (0.001,1)',
			'$OMEGA 2.41E-006',
			'$SIGMA 0.864271',
			'$ESTIMATION METHOD=1 INTER MAXEVALS=9990 PRINT=2 POSTHOC',
		],
        parameters => [
            { name => "half-life", parameter => "THETA2" },
        ],
		use_base => 1, 
    }, {
		name => 'tdist_base',
	    prob_arr => [
			'$PROBLEM CWRES t-distribution base mode',
			'$INPUT <inputcolumns>',
			'$DATA ../<cwrestablename> IGNORE=@ IGNORE=(DV.EQN.0) <dvidaccept>',
			'$PRED',
			'IPRED_ = THETA(1) + ETA(1)',
			'W     = THETA(2)',
			'IWRES=(DV-IPRED_)/W',
			'LIM = 10E-14',
			'IF(IWRES.EQ.0) IWRES = LIM',
			'LL=-0.5*LOG(2*3.14159265)-LOG(W)-0.5*(IWRES**2)',
			'L=EXP(LL)',
			'Y=-2*LOG(L)',
			'$THETA  .1 ; Mean',
			'$THETA  (0,1) ; W : SD',
			'$OMEGA  0.0001',
			'$ESTIMATION MAXEVAL=99999 -2LL METH=1 LAPLACE PRINT=2 POSTHOC',
		],
		base => 2,
    }, {
        name => 'tdist_2ll_dfest',
        prob_arr => [
			'$PROBLEM CWRES laplace 2LL DF=est',
			'$INPUT <inputcolumns>',
			'$DATA ../<cwrestablename> IGNORE=@ IGNORE=(DV.EQN.0) <dvidaccept>',
			'$PRED',
            'IPRED_ = THETA(1) + ETA(1)',
            'W = THETA(2)',
            'DF = THETA(3) ; degrees of freedom of Student distribution',
            'SIG1 = W ; scaling factor for standard deviation of RUV',
            'IWRES = (DV - IPRED_) / SIG1',
            'PHI = (DF + 1) / 2 ; Nemesapproximation of gamma funtion(2007) for first factor of t-distrib(gamma((DF+1)/2))',
            'INN = PHI + 1 / (12 * PHI - 1 / (10 * PHI))',
            'GAMMA = SQRT(2 * 3.14159265 / PHI) * (INN / EXP(1)) ** PHI',
            'PHI2 = DF / 2 ; Nemesapproximation of gamma funtion(2007) for second factor of t-distrib(gamma(DF/2))',
            'INN2 = PHI2 + 1 / (12 * PHI2 - 1 / (10 * PHI2))',
            'GAMMA2 = SQRT(2*3.14159265/PHI2)*(INN2/EXP(1))**PHI2',
            'COEFF=GAMMA/(GAMMA2*SQRT(DF*3.14159265))/SIG1 ; coefficient of PDF of t-distribution',
            'BASE=1+IWRES*IWRES/DF ; base of PDF of t-distribution',
            'POW=-(DF+1)/2 ; power of PDF of t-distribution',
            'L=COEFF*BASE**POW ; PDF oft-distribution',
            'Y=-2*LOG(L)',
			'$THETA .1',
			'$THETA (0,1)',
			'$THETA (3,10,300)',
			'$OMEGA 0.01',
			'$ESTIMATION METHOD=1 LAPLACE MAXEVALS=9990 PRINT=2 -2LL',
        ],
        parameters => [
            { name => "df", parameter => "THETA3" },
        ],
		use_base => 2,
    }, {
        name => 'dtbs_base',
        need_ipred => 1,
        prob_arr => [
			'$PROBLEM    CWRES dtbs base model',
			'$INPUT <inputcolumns>',
			'$DATA ../<cwrestablename> IGNORE=@ IGNORE=(DV.EQN.0) <dvidaccept>',
			'$SUBROUTINE CONTR=contr.txt CCONTR=ccontra.txt',
			'$PRED',
			'IPRT   = THETA(1)*EXP(ETA(1))',
			'WA     = THETA(2)',
			'LAMBDA = THETA(3)',
			'ZETA   = THETA(4)',
			'IF(IPRT.LT.0) IPRT=10E-14',
			'W = WA*IPRED**ZETA',
			'IPRTR = IPRT',
			'IF (LAMBDA .NE. 0 .AND. IPRT .NE.0) THEN',
			'	IPRTR = (IPRT**LAMBDA-1)/LAMBDA',
			'ENDIF',
			'IF (LAMBDA .EQ. 0 .AND. IPRT .NE.0) THEN',
			'	IPRTR = LOG(IPRT)',
			'ENDIF',
			'IF (LAMBDA .NE. 0 .AND. IPRT .EQ.0) THEN',
			'	IPRTR = -1/LAMBDA',
			'ENDIF',
			'IF (LAMBDA .EQ. 0 .AND. IPRT .EQ.0) THEN',
			'	IPRTR = -1000000000',
			'ENDIF',
			'IPRT = IPRTR',
			'Y = IPRT + ERR(1)*W',
			'IF(ICALL.EQ.4) Y=EXP(DV)',
			'$THETA  0.973255 ; IPRED 1',
			'$THETA  (0,1.37932) ; WA',
			'$THETA  0 FIX ; lambda',
			'$THETA  0 FIX ; zeta',
			'$OMEGA  0.0001',
			'$SIGMA  1  FIX',
			'$SIMULATION (1234)',
			'$ESTIMATION METHOD=1 INTER MAXEVALS=99999 PRINT=2 POSTHOC',
        ],
		base => 3,
    }, {
		name => 'dtbs',
        need_ipred => 1,
		prob_arr => [
			'$PROBLEM    CWRES dtbs model',
			'$INPUT <inputcolumns>',
			'$DATA ../<cwrestablename> IGNORE=@ IGNORE=(DV.EQN.0) <dvidaccept>',
			'$SUBROUTINE CONTR=contr.txt CCONTR=ccontra.txt',
			'$PRED',
			'IPRT   = THETA(1)*EXP(ETA(1))',
			'WA     = THETA(2)',
			'LAMBDA = THETA(3)',
			'ZETA   = THETA(4)',
			'IF(IPRT.LT.0) IPRT=10E-14',
			'W = WA*IPRED**ZETA',
			'IPRTR = IPRT',
			'IF (LAMBDA .NE. 0 .AND. IPRT .NE.0) THEN',
			'	IPRTR = (IPRT**LAMBDA-1)/LAMBDA',
			'ENDIF',
			'IF (LAMBDA .EQ. 0 .AND. IPRT .NE.0) THEN',
			'	IPRTR = LOG(IPRT)',
			'ENDIF',
			'IF (LAMBDA .NE. 0 .AND. IPRT .EQ.0) THEN',
			'	IPRTR = -1/LAMBDA',
			'ENDIF',
			'IF (LAMBDA .EQ. 0 .AND. IPRT .EQ.0) THEN',
			'	IPRTR = -1000000000',
			'ENDIF',
			'IPRT = IPRTR',
			'Y = IPRT + ERR(1)*W',
			'IF(ICALL.EQ.4) Y=EXP(DV)',
			'$THETA   0.973255 ; IPRED 1',
			'$THETA  (0,1.37932) ; WA',
			'$THETA     0.001    ; lambda',
			'$THETA     0.001    ; zeta',
			'$OMEGA  0.0001',
			'$SIGMA  1  FIX',
			'$SIMULATION (1234)',
			'$ESTIMATION METHOD=1 INTER MAXEVALS=99999 PRINT=2 POSTHOC',
		],
        parameters => [
            { name => "lambda", parameter => "THETA3" },
            { name => "zeta", parameter => "THETA4" },
        ],
		use_base => 3,
	},
);

sub _create_model_templates
{
    # Top level call to resmod will generate all model templates via this method
    my $self = shift;
    my %parm = validated_hash(\@_,
		table => { isa => 'nmtablefile' },
        idv_column => { isa => 'Str' },
    );
    my $table = $parm{'table'};
    my $idv_column = $parm{'idv_column'};

    my @templates = @residual_models;      # A shallow copy
    $self->model_templates(\@templates);

    my $cutoffs = $self->_calculate_quantiles(table => $table->tables->[0], column => $idv_column);  
    my $time_var_modeltemplates = $self->_build_time_varying_template(cutoffs => $cutoffs);
    push @{$self->model_templates}, @$time_var_modeltemplates;
    $self->cutoffs($cutoffs);
}


no Moose;
__PACKAGE__->meta->make_immutable;
1;
