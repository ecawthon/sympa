# SDM.pm - Sympa Database Manager : This module contains all functions relative to
# the access and maintenance of the Sympa database.
#<!-- RCS Identication ; $Revision: 7016 $ --> 
#
# Sympa - SYsteme de Multi-Postage Automatique
# Copyright (c) 1997, 1998, 1999, 2000, 2001 Comite Reseau des Universites
# Copyright (c) 1997,1998, 1999 Institut Pasteur & Christophe Wolfhugel
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.

package SDM;

use strict;

use Carp;
use Exporter;

use Conf;
use Log;
use List;
use Sympa::Constants;
use SQLSource;
use Data::Dumper;

our @ISA;
our $AUTOLOAD;

use Sympa::DatabaseDescription;

# db structure description has moved in Sympa/Constant.pm 
my %db_struct = &Sympa::DatabaseDescription::db_struct();

my %not_null = %Sympa::DatabaseDescription::not_null;

my %primary =  %Sympa::DatabaseDescription::primary ;
	       
my %autoincrement = %Sympa::DatabaseDescription::autoincrement ;

## List the required INDEXES
##   1st key is the concerned table
##   2nd key is the index name
##   the table lists the field on which the index applies
my %indexes = %Sympa::DatabaseDescription::indexes ;

# table indexes that can be removed during upgrade process
my @former_indexes =  %Sympa::DatabaseDescription::primary ;

our $db_source;
our $use_db;

sub do_query {
    my $query = shift;
    my @params = @_;
    my $sth;
    unless (&check_db_connect) {
	&Log::do_log('err', 'Unable to get a connection to the Sympa database');
	return undef;
    }

    unless ($sth = $db_source->do_query($query,@params)) {
	do_log('err','SQL query failed to execute in the Sympa database');
	return undef;
    }

    return $sth;
}

sub do_prepared_query {
    my $query = shift;
    my @params = @_;
    my $sth;
    unless (&check_db_connect) {
	&Log::do_log('err', 'Unable to get a connection to the Sympa database');
	return undef;
    }

    unless ($sth = $db_source->do_prepared_query($query,@params)) {
	do_log('err','SQL query failed to execute in the Sympa database');
	return undef;
    }

    return $sth;
}

## Get database handler
sub db_get_handler {
    &Log::do_log('debug3', 'Returning handle to sympa database');

    if(&check_db_connect()) {
	return $db_source->{'dbh'};
    }else {
	&Log::do_log('err', 'Unable to get a handle to Sympa database');
	return undef;
    }
}

## Just check if DB connection is ok
sub check_db_connect {
    
    &Log::do_log('debug2', 'Checking connection to the Sympa database');
    ## Is the Database defined
    unless (&Conf::get_robot_conf('*','db_name')) {
	&Log::do_log('err', 'No db_name defined in configuration file');
	return undef;
    }
    
    unless ($db_source->{'dbh'} && $db_source->{'dbh'}->ping()) {
	unless (&connect_sympa_database('just_try')) {
	    &Log::do_log('err', 'Failed to connect to database');	   
	    return undef;
	}
    }

    return 1;
}

## Connect to Database
sub connect_sympa_database {
    my $option = shift;

    &Log::do_log('debug', 'Connecting to Sympa database');

    ## We keep trying to connect if this is the first attempt
    ## Unless in a web context, because we can't afford long response time on the web interface
    my $db_conf = &Conf::get_parameters_group('*','Database');
    $db_conf->{'reconnect_options'} = {'keep_trying'=>($option ne 'just_try' && ( !$db_source->{'connected'} && !$ENV{'HTTP_HOST'})),
						 'warn'=>1 };
    unless ($db_source = new SQLSource($db_conf)) {
	&Log::do_log('err', 'Unable to create SQLSource object');
    	return undef;
    }
    ## Used to check that connecting to the Sympa database works and the
    ## SQLSource object is created.
    $use_db = 1;

    # Just in case, we connect to the database here. Probably not necessary.
    unless ( $db_source->{'dbh'} = $db_source->connect()) {
	&Log::do_log('err', 'Unable to connect to the Sympa database');
	return undef;
    }
    &Log::do_log('debug2','Connected to Database %s',&Conf::get_robot_conf('*','db_name'));

    return 1;
}

## Disconnect from Database
sub db_disconnect {
    &Log::do_log('debug', 'Disconnecting from Sympa database');

    unless ($db_source->{'dbh'}->disconnect()) {
	&Log::do_log('err','Can\'t disconnect from Database %s : %s',&Conf::get_robot_conf('*','db_name'), $db_source->{'dbh'}->errstr);
	return undef;
    }

    return 1;
}

sub probe_db {
    &do_log('debug3', 'Checking database structure');    
    my (%checked, $table);
    
    ## Database structure
    ## Report changes to listmaster
    my @report;

    unless (&check_db_connect) {
	&Log::do_log('err', 'Unable to get a connection to the Sympa database');
	return undef;
    }

    my $dbh = &db_get_handler();

    ## Get tables
    my @tables;
    my $list_of_tables;
    if ($list_of_tables = $db_source->get_tables()) {
	@tables = @{$list_of_tables};
    }else{
	@tables = ();
    }

    my ( $fields, %real_struct);
	## Check required tables
    foreach my $t1 (keys %{$db_struct{'mysql'}}) {
	my $found;
	foreach my $t2 (@tables) {
	    $found = 1 if ($t1 eq $t2) ;
	}
	unless ($found) {
	    if (my $rep = $db_source->add_table({'table'=>$t1})) {
		push @report, $rep;
		&do_log('notice', 'Table %s created in database %s', $t1, &Conf::get_robot_conf('*','db_name'));
		push @tables, $t1;
		$real_struct{$t1} = {};
	    }
	}
    }
    ## Get fields
    foreach my $t (@tables) {
	$real_struct{$t} = $db_source->get_fields({'table'=>$t});
    }
   
    foreach $table ( @tables ) {
	$checked{$table} = 1;
    }
    
    my $found_tables = 0;
    foreach $table('user_table', 'subscriber_table', 'admin_table') {
	if ($checked{$table} || $checked{'public.' . $table}) {
	    $found_tables++;
	}else {
	    &do_log('err', 'Table %s not found in database %s', $table, &Conf::get_robot_conf('*','db_name'));
	}
    }
    
    ## Check tables structure if we could get it
    ## Only performed with mysql and SQLite
    if (%real_struct) {

	foreach my $t (keys %{$db_struct{&Conf::get_robot_conf('*','db_type')}}) {
	    unless ($real_struct{$t}) {
		&do_log('err', 'Table \'%s\' not found in database \'%s\' ; you should create it with create_db.%s script', $t, &Conf::get_robot_conf('*','db_name'), &Conf::get_robot_conf('*','db_type'));
		return undef;
	    }
	    
	    my %added_fields;
	    
	    foreach my $f (sort keys %{$db_struct{&Conf::get_robot_conf('*','db_type')}{$t}}) {
		unless ($real_struct{$t}{$f}) {
		    push @report, sprintf('Field \'%s\' (table \'%s\' ; database \'%s\') was NOT found. Attempting to add it...', $f, $t, &Conf::get_robot_conf('*','db_name'));
		    &do_log('info', 'Field \'%s\' (table \'%s\' ; database \'%s\') was NOT found. Attempting to add it...', $f, $t, &Conf::get_robot_conf('*','db_name'));
		    
		    my $options;
		    ## To prevent "Cannot add a NOT NULL column with default value NULL" errors
		    if ($not_null{$f}) {
			$options .= 'NOT NULL';
		    }
		    if ( $autoincrement{$t} eq $f) {
					$options .= ' AUTO_INCREMENT PRIMARY KEY ';
			}
		    my $sqlquery = "ALTER TABLE $t ADD $f $db_struct{&Conf::get_robot_conf('*','db_type')}{$t}{$f} $options";
		    
		    unless ($dbh->do($sqlquery)) {
			    &do_log('err', 'Could not add field \'%s\' to table\'%s\'. (%s)', $f, $t, $sqlquery);
			    &do_log('err', 'Sympa\'s database structure may have change since last update ; please check RELEASE_NOTES');
			    return undef;
		    }
		    
		    push @report, sprintf('Field %s added to table %s (options : %s)', $f, $t, $options);
		    &do_log('info', 'Field %s added to table %s  (options : %s)', $f, $t, $options);
		    $added_fields{$f} = 1;
		    
		    ## Remove temporary DB field
		    if ($real_struct{$t}{'temporary'}) {
			unless ($dbh->do("ALTER TABLE $t DROP temporary")) {
			    &do_log('err', 'Could not drop temporary table field : %s', $dbh->errstr);
			}
			delete $real_struct{$t}{'temporary'};
		    }
		    
		    next;
		}
		
		## Change DB types if different and if update_db_types enabled
		if (&Conf::get_robot_conf('*','update_db_field_types') eq 'auto' && &Conf::get_robot_conf('*','db_type') ne 'SQLite') {
		    unless (&check_db_field_type(effective_format => $real_struct{$t}{$f},
						 required_format => $db_struct{&Conf::get_robot_conf('*','db_type')}{$t}{$f})) {
			push @report, sprintf('Field \'%s\'  (table \'%s\' ; database \'%s\') does NOT have awaited type (%s). Attempting to change it...', 
					      $f, $t, &Conf::get_robot_conf('*','db_name'), $db_struct{&Conf::get_robot_conf('*','db_type')}{$t}{$f});
			&do_log('notice', 'Field \'%s\'  (table \'%s\' ; database \'%s\') does NOT have awaited type (%s) where type in database seems to be (%s). Attempting to change it...', 
				$f, $t, &Conf::get_robot_conf('*','db_name'), $db_struct{&Conf::get_robot_conf('*','db_type')}{$t}{$f},$real_struct{$t}{$f});
			
			my $options;
			if ($not_null{$f}) {
			    $options .= 'NOT NULL';
			}
			
			push @report, sprintf("ALTER TABLE $t CHANGE $f $f $db_struct{&Conf::get_robot_conf('*','db_type')}{$t}{$f} $options");
			&do_log('notice', "ALTER TABLE $t CHANGE $f $f $db_struct{&Conf::get_robot_conf('*','db_type')}{$t}{$f} $options");
			unless ($dbh->do("ALTER TABLE $t CHANGE $f $f $db_struct{&Conf::get_robot_conf('*','db_type')}{$t}{$f} $options")) {
			    &do_log('err', 'Could not change field \'%s\' in table\'%s\'.', $f, $t);
			    &do_log('err', 'Sympa\'s database structure may have change since last update ; please check RELEASE_NOTES');
			    return undef;
			}
			
			push @report, sprintf('Field %s in table %s, structure updated', $f, $t);
			&do_log('info', 'Field %s in table %s, structure updated', $f, $t);
		    }
		}else {
		    unless ($real_struct{$t}{$f} eq $db_struct{&Conf::get_robot_conf('*','db_type')}{$t}{$f}) {
			&do_log('err', 'Field \'%s\'  (table \'%s\' ; database \'%s\') does NOT have awaited type (%s).', $f, $t, &Conf::get_robot_conf('*','db_name'), $db_struct{&Conf::get_robot_conf('*','db_type')}{$t}{$f});
			&do_log('err', 'Sympa\'s database structure may have change since last update ; please check RELEASE_NOTES');
			return undef;
		    }
		}
	    }
	    if ((&Conf::get_robot_conf('*','db_type') eq 'mysql')||(&Conf::get_robot_conf('*','db_type') eq 'Pg')) {
		## Check that primary key has the right structure.
		my $should_update;
		my %primaryKeyFound;	      

		my $sql_query ;
		my $test_request_result ;

		if (&Conf::get_robot_conf('*','db_type') eq 'mysql') { # get_primary_keys('mysql');

		    $sql_query = "SHOW COLUMNS FROM $t";
		    $test_request_result = $dbh->selectall_hashref($sql_query,'key');

		    foreach my $scannedResult ( keys %$test_request_result ) {
			if ( $scannedResult eq "PRI" ) {
			    $primaryKeyFound{$scannedResult} = 1;
			}
		    }
		}elsif ( &Conf::get_robot_conf('*','db_type') eq 'Pg'){# get_primary_keys('Pg');

#		    $sql_query = "SELECT column_name FROM information_schema.columns WHERE table_name = $t";
#		    my $sql_query = 'SELECT pg_attribute.attname AS field FROM pg_index, pg_class, pg_attribute WHERE pg_class.oid =\''.$t.'\'::regclass AND indrelid = pg_class.oid AND pg_attribute.attrelid = pg_class.oid AND pg_attribute.attnum = any(pg_index.indkey) AND indisprimary';
#		    $test_request_result = $dbh->selectall_hashref($sql_query,'key');

		    my $sql_query = 'SELECT pg_attribute.attname AS field FROM pg_index, pg_class, pg_attribute WHERE pg_class.oid =\''.$t.'\'::regclass AND indrelid = pg_class.oid AND pg_attribute.attrelid = pg_class.oid AND pg_attribute.attnum = any(pg_index.indkey) AND indisprimary';

		    my $sth;
		    unless ($sth = $dbh->prepare($sql_query)) {
			do_log('err','Unable to prepare SQL query %s : %s', $sql_query, $dbh->errstr);
			return undef;
		    }	    
		    unless ($sth->execute) {
			do_log('err','Unable to execute SQL query %s : %s', $sql_query, $dbh->errstr);
			return undef;
		    }
		    while (my $ref = $sth->fetchrow_hashref('NAME_lc')) {
			$primaryKeyFound{$ref->{'field'}} = 1;
		    }	    
		    $sth->finish();
		   

		}
		
		foreach my $field (@{$primary{$t}}) {		
		    unless ($primaryKeyFound{$field}) {
			$should_update = 1;
			last;
		    }
		}
		
		## Create required PRIMARY KEY. Removes useless INDEX.
		foreach my $field (@{$primary{$t}}) {		
		    if ($added_fields{$field}) {
			$should_update = 1;
			last;
		    }
		}
		
		if ($should_update) {
		    my $fields = join ',',@{$primary{$t}};
		    my %definedPrimaryKey;
		    foreach my $definedKeyPart (@{$primary{$t}}) {
			$definedPrimaryKey{$definedKeyPart} = 1;
		    }
		    my $searchedKeys = ['field','key'];
		    my $test_request_result = $dbh->selectall_hashref('SHOW COLUMNS FROM '.$t,$searchedKeys);
		    my $expectedKeyMissing = 0;
		    my $unExpectedKey = 0;
		    my $primaryKeyFound = 0;
		    my $primaryKeyDropped = 0;
		    foreach my $scannedResult ( keys %$test_request_result ) {
			if ( $$test_request_result{$scannedResult}{"PRI"} ) {
			    $primaryKeyFound = 1;
			    if ( !$definedPrimaryKey{$scannedResult}) {
				&do_log('info','Unexpected primary key : %s',$scannedResult);
				$unExpectedKey = 1;
				next;
			    }
			}
			else {
			    if ( $definedPrimaryKey{$scannedResult}) {
				&do_log('info','Missing expected primary key : %s',$scannedResult);
				$expectedKeyMissing = 1;
				next;
			    }
			}
			
		    }
		    if( $primaryKeyFound && ( $unExpectedKey || $expectedKeyMissing ) ) {
			## drop previous primary key
			unless ($dbh->do("ALTER TABLE $t DROP PRIMARY KEY")) {
			    &do_log('err', 'Could not drop PRIMARY KEY, table\'%s\'.', $t);
			}
			push @report, sprintf('Table %s, PRIMARY KEY dropped', $t);
			&do_log('info', 'Table %s, PRIMARY KEY dropped', $t);
			$primaryKeyDropped = 1;
		    }
		    
		    ## Add primary key
		    if ( $primaryKeyDropped || !$primaryKeyFound ) {
			&do_log('debug', "ALTER TABLE $t ADD PRIMARY KEY ($fields)");
			unless ($dbh->do("ALTER TABLE $t ADD PRIMARY KEY ($fields)")) {
			    &do_log('err', 'Could not set field \'%s\' as PRIMARY KEY, table\'%s\'.', $fields, $t);
			    return undef;
			}
			push @report, sprintf('Table %s, PRIMARY KEY set on %s', $t, $fields);
			&do_log('info', 'Table %s, PRIMARY KEY set on %s', $t, $fields);
		    }
		}
		
		## drop previous index if this index is not a primary key and was defined by a previous Sympa version
		#xxxxx $test_request_result = $dbh->selectall_hashref('SHOW INDEX FROM '.$t,'key_name');
		my %index_columns;
		if ( &Conf::get_robot_conf('*','db_type') eq 'mysql' ){# get_index('Pg');
		    $test_request_result = $dbh->selectall_hashref('SHOW INDEX FROM '.$t,'key_name');		
		    foreach my $indexName ( keys %$test_request_result ) {
			unless ( $indexName eq "PRIMARY" ) {
			    $index_columns{$indexName} = 1;
			}
		    }
		}elsif ( &Conf::get_robot_conf('*','db_type') eq 'Pg'){# get_index('Pg');
		    my $sql_query = 'SELECT pg_attribute.attname AS field FROM pg_index, pg_class, pg_attribute WHERE pg_class.oid =\''.$t.'\'::regclass AND indrelid = pg_class.oid AND pg_attribute.attrelid = pg_class.oid AND pg_attribute.attnum = any(pg_index.indkey)';

		    my $sth;
		    unless ($sth = $dbh->prepare($sql_query)) {
			do_log('err','Unable to prepare SQL query %s : %s', $sql_query, $dbh->errstr);
			return undef;
		    }	    
		    unless ($sth->execute) {
			do_log('err','Unable to execute SQL query %s : %s', $sql_query, $dbh->errstr);
			return undef;
		    }
		    while (my $ref = $sth->fetchrow_hashref('NAME_lc')) {
			$index_columns{$ref->{'field'}} = 1;
		    }	    
		    $sth->finish();
		}

		
		foreach my $idx ( keys %index_columns ) {
		    
		    ## Check whether the index found should be removed
		    my $index_name_is_known = 0;
		    foreach my $known_index ( @former_indexes ) {
			if ( $idx eq $known_index ) {
			    $index_name_is_known = 1;
			    last;
			}
		    }
		    ## Drop indexes
		    if( $index_name_is_known ) {
			if ($dbh->do("ALTER TABLE $t DROP INDEX $idx")) {
			    push @report, sprintf('Deprecated INDEX \'%s\' dropped in table \'%s\'', $idx, $t);
			    &do_log('info', 'Deprecated INDEX \'%s\' dropped in table \'%s\'', $idx, $t);
			}else {
			    &do_log('err', 'Could not drop deprecated INDEX \'%s\' in table \'%s\'.', $idx, $t);
			}
			
		    }
		    
		}
		
		## Create required indexes
		foreach my $idx (keys %{$indexes{$t}}){ 
		    
		    unless ($index_columns{$idx}) {
			my $columns = join ',', @{$indexes{$t}{$idx}};
			if ($dbh->do("ALTER TABLE $t ADD INDEX $idx ($columns)")) {
			    &do_log('info', 'Added INDEX \'%s\' in table \'%s\'', $idx, $t);
			}else {
			    &do_log('err', 'Could not add INDEX \'%s\' in table \'%s\'.', $idx, $t);
			}
		    }
		}	 
	    }   
	    elsif (&Conf::get_robot_conf('*','db_type') eq 'SQLite') {
		## Create required INDEX and PRIMARY KEY
		my $should_update;
		foreach my $field (@{$primary{$t}}) {
		    if ($added_fields{$field}) {
			$should_update = 1;
			last;
		    }
		}
		
		if ($should_update) {
		    my $fields = join ',',@{$primary{$t}};
		    ## drop previous index
		    my $success;
		    foreach my $field (@{$primary{$t}}) {
			unless ($dbh->do("DROP INDEX $field")) {
			    next;
			}
			$success = 1; last;
		    }
		    
		    if ($success) {
			push @report, sprintf('Table %s, INDEX dropped', $t);
			&do_log('info', 'Table %s, INDEX dropped', $t);
		    }else {
			&do_log('err', 'Could not drop INDEX, table \'%s\'.', $t);
		    }
		    
		    ## Add INDEX
		    unless ($dbh->do("CREATE INDEX IF NOT EXIST $t\_index ON $t ($fields)")) {
			&do_log('err', 'Could not set INDEX on field \'%s\', table\'%s\'.', $fields, $t);
			return undef;
		    }
		    push @report, sprintf('Table %s, INDEX set on %s', $t, $fields);
		    &do_log('info', 'Table %s, INDEX set on %s', $t, $fields);
		    
		}
	    }
	}
	# add autoincrement if needed
	foreach my $table (keys %autoincrement) {
	    unless ($db_source->is_autoinc({'table'=>$table,'field'=>$autoincrement{$table}})){
		if ($db_source->set_autoinc({'table'=>$table,'field'=>$autoincrement{$table}})){
		    &Log::do_log('notice',"Setting table $table field $autoincrement{$table} as autoincrement");
		}else{
		    &Log::do_log('err',"Could not set table $table field $autoincrement{$table} as autoincrement");
		}
	    }
	}	
     ## Try to run the create_db.XX script
    }elsif ($found_tables == 0) {
        my $db_script =
            Sympa::Constants::SCRIPTDIR . "/create_db.&Conf::get_robot_conf('*','db_type')";
	unless (open SCRIPT, $db_script) {
	    &do_log('err', "Failed to open '%s' file : %s", $db_script, $!);
	    return undef;
	}
	my $script;
	while (<SCRIPT>) {
	    $script .= $_;
	}
	close SCRIPT;
	my @scripts = split /;\n/,$script;

	$db_script =
        Sympa::Constants::SCRIPTDIR . "/create_db.&Conf::get_robot_conf('*','db_type')";
	push @report, sprintf("Running the '%s' script...", $db_script);
	&do_log('notice', "Running the '%s' script...", $db_script);
	foreach my $sc (@scripts) {
	    next if ($sc =~ /^\#/);
	    unless ($dbh->do($sc)) {
		&do_log('err', "Failed to run script '%s' : %s", $db_script, $dbh->errstr);
		return undef;
	    }
	}

	## SQLite :  the only access permissions that can be applied are 
	##           the normal file access permissions of the underlying operating system
	if ((&Conf::get_robot_conf('*','db_type') eq 'SQLite') &&  (-f &Conf::get_robot_conf('*','db_name'))) {
	    unless (&tools::set_file_rights(file => &Conf::get_robot_conf('*','db_name'),
					    user  => Sympa::Constants::USER,
					    group => Sympa::Constants::GROUP,
					    mode  => 0664,
					    ))
	    {
		&do_log('err','Unable to set rights on %s',&Conf::get_robot_conf('*','db_name'));
		return undef;
	    }
	}
	
    }elsif ($found_tables < 3) {
	&do_log('err', 'Missing required tables in the database ; you should create them with create_db.%s script', &Conf::get_robot_conf('*','db_type'));
	return undef;
    }
    
    ## Used by List subroutines to check that the DB is available
    $List::use_db = 1;

    ## Notify listmaster
    &List::send_notify_to_listmaster('db_struct_updated',  &Conf::get_robot_conf('*','domain'), {'report' => \@report}) if ($#report >= 0);

    return 1;
}

## Check if data structures are uptodate
## If not, no operation should be performed before the upgrade process is run
sub data_structure_uptodate {
     my $version_file = "&Conf::get_robot_conf('*','etc')/data_structure.version";
     my $data_structure_version;

     if (-f $version_file) {
	 unless (open VFILE, $version_file) {
	     do_log('err', "Unable to open %s : %s", $version_file, $!);
	     return undef;
	 }
	 while (<VFILE>) {
	     next if /^\s*$/;
	     next if /^\s*\#/;
	     chomp;
	     $data_structure_version = $_;
	     last;
	 }
	 close VFILE;
     }

     if (defined $data_structure_version &&
	 $data_structure_version ne Sympa::Constants::VERSION) {
	 &do_log('err', "Data structure (%s) is not uptodate for current release (%s)", $data_structure_version, Sympa::Constants::VERSION);
	 return 0;
     }

     return 1;
 }

## Compare required DB field type
## Input : required_format, effective_format
## Output : return 1 if field type is appropriate AND size >= required size
sub check_db_field_type {
    my %param = @_;

    my ($required_type, $required_size, $effective_type, $effective_size);

    if ($param{'required_format'} =~ /^(\w+)(\((\d+)\))?$/) {
	($required_type, $required_size) = ($1, $3);
    }

    if ($param{'effective_format'} =~ /^(\w+)(\((\d+)\))?$/) {
	($effective_type, $effective_size) = ($1, $3);
    }

    if (($effective_type eq $required_type) && ($effective_size >= $required_size)) {
	return 1;
    }

    return 0;
}

sub quote {
    my $param = shift;
    if(&check_db_connect()) {
	return $db_source->quote($param);
    }else{
	&Log::do_log('err', 'Unable to get a handle to Sympa database');
	return undef;
    }
}

sub get_substring_clause {
    my $param = shift;
    if(&check_db_connect()) {
	return $db_source->get_substring_clause($param);
    }else{
	&Log::do_log('err', 'Unable to get a handle to Sympa database');
	return undef;
    }
}

sub get_limit_clause {
    my $param = shift;
    if(&check_db_connect()) {
	return ' '.$db_source->get_limit_clause($param).' ';
    }else{
	&Log::do_log('err', 'Unable to get a handle to Sympa database');
	return undef;
    }
}

## Returns a character string corresponding to the expression to use in
## a read query (e.g. SELECT) for the field given as argument.
## This sub takes a single argument: the name of the field to be used in
## the query.
##
sub get_canonical_write_date {
    my $param = shift;
    return $db_source->get_canonical_write_date($param);
}

## Returns a character string corresponding to the expression to use in 
## a write query (e.g. UPDATE or INSERT) for the value given as argument.
## This sub takes a single argument: the value of the date to be used in
## the query.
##
sub get_canonical_read_date {
    my $param = shift;
    return $db_source->get_canonical_read_date($param);
}

return 1;