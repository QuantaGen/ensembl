# Stolen from external db directory this script performs
# the similar function of uploading all valid attribute types
# into the attrib_type table of all databases that are going to
# be released.


use strict;

use Getopt::Long;
use DBI;
use IO::File;
use FindBin;


my ( $host, $user, $pass, $port,@dbnames, $file, $release_num);

GetOptions( "host=s", \$host,
	    "user=s", \$user,
	    "pass=s", \$pass,
	    "port=i", \$port,
	    "file=s", \$file,
            "dbnames=s@", \@dbnames,
	    "release_num=i", \$release_num
	  );

$file ||= $FindBin::Bin."/attrib_type.txt";
usage() if(!$host);
usage() if(($release_num && @dbnames) || (!$release_num && !@dbnames));


#release num XOR dbname are required
$port ||= 3306;

my $dsn = "DBI:mysql:host=$host;port=$port";

my $db = DBI->connect( $dsn, $user, $pass, {RaiseError => 1} );

if($release_num) {
  @dbnames = map {$_->[0] } @{ $db->selectall_arrayref( "show databases" ) };
  
  #
  # filter out all non-core databases
  #
  @dbnames = grep {/^[a-zA-Z]+\_[a-zA-Z]+\_(core|est|estgene|vega)\_${release_num}\_\d+[A-Za-z]?$/} @dbnames;
}


#
# make sure the user wishes to continue
#
print STDERR "The following databases will be external_db updated:\n  ";
print join("\n  ", @dbnames);
print "\ncontinue with update (yes/no)>  ";


my $input = lc(<STDIN>);
chomp($input);
if($input ne 'yes') {
  print "Attrib_type loading aborted\n";
  exit();
}


my $attribs = read_attrib_file( $file );

# if any attrib_types are loaded that are different from 
# the file, a consistency problem is reported and the 
# upload is not done.
for my $database ( @dbnames ) {
  if( check_consistency( $attribs, $database, $db )) {
    # consistent
    $db->do( "use $database" );
    $db->do( "delete from attrib_type" );
    
    load_attribs( $db, $attribs );
  } else {
    print STDERR "Repairing $database, not consistent!\n";
    repair( $attribs, $database, $db );
  }
}


# move attrib types wih the same code to the common attrib_type table
# ones that are not in the table move to an attrib_type_id that is not used
sub repair {
  my ( $attribs, $database, $db ) = @_;
  
  $db->do( $database );

  my @tables = qw( seq_region_attrib misc_attrib translation_attrib transcript_attrib );
  my $ref = $db->selectall_arrayref( "show create table attrib_type" );
  my $create_table = $ref->[0]->[0];
  $db->do( "alter table attrib_type rename old_attrib_type" );
  $db->do( $create_table );

  load_attribs( $db, $attribs );

  $db->do( "delete old_attrib_type " .
	   "from old_attrib_type oat, attrib_type at " .
	   "where oat.attrib_type_id = at.attrib_type_id " .
	   "and oat.code = at.code" );

  # only the conflicts remain in old attrib type
  # move non conflicting entries out of the way to upper part of
  # attrib_type table

  $db->do( "create table tmp_attrib_types ".
	   "select oat.attrib_type_id, oat.code, oat.name, oat.description " .
	   "from old_attrib_type oat " .
	   "left join attrib_type at " .
	   "on oat.code = at.code " .
	   "where at.code is null" );
  $db->do( "insert into attrib_type( code, name, description) ".
	   "select code, name, description ". 
	   "from tmp_attrib_types" );

  $ref = $db->selectall_arrayref( "select code from tmp_attrib_type" );
  $db->do( "drop table tmp_attrib_types" );

  if( ! @$ref ) {
    # no problem, thats strange
    print STDERR "Strange condition, $database didnt have conflicts but ".
	"executed conflict code\n";
    return;
  }

  print STDERR "Database $database has following codes different from attrib_type.txt.\n";
  print STDERR join( ",", map { $_->[0] } @$ref ),"\n";
    
  # now do multi table updates on all tables
  for my $up_table ( @tables ) {
    $db->do( "update $up_table tb, attrib_type at, old_attrib_type oat ".
	     "set tb.attrib_type_id = at.attrib_type_id ".
	     "where tb.attrib_type_id = oat.attrib_type_id ".
	     "and oat.code = at.code " );
  }
}


sub load_attribs {
  my ( $db, $attribs ) = @_;
    my $sth;
    $sth = $db->prepare( "insert into attrib_type( attrib_type_id, code, name, description) ".
			 "values(?,?,?,?)" ); 
    for my $attrib ( @$attribs ) {
      $sth->execute( $attrib->{'attrib_type_id'}, $attrib->{'code'},
		     $attrib->{'name'}, $attrib->{'description'} );
    }
}
  


# alternatively consistency can be enforceed to a certain degree 
sub check_consistency {
  my $attribs = shift;
  my $database = shift;
  my $db = shift;

  my ( %db_codes, %file_codes );
  map { $file_codes{$_->{'attrib_type_id'}} = $_->{'code'}} @$attribs;
  
  $db->do( "use $database" );
  my $sth = $db->prepare( "SELECT attrib_type_id, code, name, description ".
			  "FROM attrib_type" );
  $sth->execute();
  while( my $arr = $sth->fetchrow_arrayref() ) {
    $db_codes{ $arr->[0] } = $arr->[1];
  }

  # check if any ids in the database colide with the file
  my $consistent = 1;
  for my $dbid ( keys %db_codes ) {
    if(! exists $file_codes{ $dbid } || 
       $file_codes{$dbid} ne $db_codes{ $dbid } ) {
      $consistent = 0;
    }
  }

  return $consistent;
}



sub read_attrib_file {
  my $file = shift;
  #
  # read all attrib_type entries from the file
  #
  my $fh = IO::File->new();
  $fh->open($file) or die("could not open input file $file");
  
  my @rows;
  my $row;
  while($row = <$fh>) {
    chomp($row);
    next if( /^\S*$/ );
    next if ( /^\#/ );

    my @a = split(/\t/, $row);
    
    push @rows, {'attrib_type_id' => $a[0],
		 'code' => $a[1],
		 'name' => $a[2],
		 'description'  => $a[3]};
  }
  $fh->close();
  return \@rows;
}

sub usage {
  GetOptions( "host=s", \$host,
	    "user=s", \$user,
	    "pass=s", \$pass,
	    "port=i", \$port,
	    "file=s", \$file,
            "dbnames=s@", \@dbnames,
	    "release_num=i", \$release_num
	  );
  print STDERR <<EOC

Usage perl upload_attributes.pl -host .. -user .. -port .. -pass ..
      and either -dbnames homo_sap_1 -dbname homo_sap_2 -dbnames .....
              or -relase_num ..   
             put -file .. if its not the default 
                          attrib_type.txt right next to this script
                     

EOC
;
  exit;
}
