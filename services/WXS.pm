package WXS;

use Carp;
require Exporter;
our @ISA = qw(Exporter);
our %EXPORT_TAGS = (all  => [ qw/Operation config error serve_document serve_vsi xml_elements xml_element/ ]);
our @EXPORT_OK = @{$EXPORT_TAGS{all}};

use Encode;
use JSON;

sub Operation {
    my($config, $name, $parameters) = @_;
    my @parameters;
    for my $p (@$parameters) {
	for my $n (keys %$p) {
	    my @values;
	    for my $v (@{$p->{$n}}) {
		push @values, ['ows:Value', $v];
	    }
	    push @parameters, ['ows:Parameter', {name=>$n}, \@values];
	}
    }
    xml_element('ows:Operation', 
		{name => $name}, 
		[['ows:DCP', 
		  ['ows:HTTP', [['ows:Get', {'xlink:type'=>'simple', 'xlink:href'=>$config->{resource}}],
				['ows:Post', {'xlink:type'=>'simple', 'xlink:href'=>$config->{resource}}]]
		  ]],@parameters]);
}

sub config {
    my $conf = shift;
    unless ($conf) {
	if (open(my $fh, '<', '/var/www/etc/dispatch')) {
	    while (<$fh>) {
		chomp;
		@l = split /\t/;
		$conf = $l[1] if $l[0] and $l[0] eq $0;
	    }
	}
    }
    croak "no configuration file.#" unless $conf;
    open(my $fh, '<', $conf) or croak "can't open configuration file.#";
    binmode $fh, ":utf8";
    my @json = <$fh>;
    close $fh;
    $config = JSON->new->utf8->decode(encode('UTF-8', "@json"));
    $config->{CORS} = $ENV{'REMOTE_ADDR'} unless $config->{CORS};
    return $config;
}

sub error {
    my($cgi, $msg, %header_arg) = @_;
    select(STDOUT);
    print $cgi->header(%header_arg, -charset=>'utf-8'), '<?xml version="1.0" encoding="UTF-8"?>',"\n";
    my($error) = ($msg =~ /(.*?)\.\#/);
    if ($error) {
	$error =~ s/ $//;
	$error = { code => $error } if $error eq 'LayerNotDefined';
    } else {
	$error = 'Unspecified error: '.$msg;
    }
    xml_element('ServiceExceptionReport',['ServiceException', $error]);
    select(STDERR);
    print "$error\n";
}

sub serve_document {
    my($cgi, $doc, $type) = @_;
    my $length = (stat($doc))[10];
    croak "Can't stat file to serve" unless $length;    
    open(DOC, '<', $doc) or croak "Couldn't open $doc: $!";
    print $cgi->header(-type => $type, -Content_length => $length, -charset=>'utf-8');
    my $data;
    while( sysread(DOC, $data, 10240) ) {
	print $data;
    }
    close DOC;
}

sub serve_vsi {
    my($cgi, $doc, $type) = @_;
    my $fp = Geo::GDAL::VSIFOpenL($vsi, 'r');
    my $data;
    while (my $chunk = Geo::GDAL::VSIFReadL(1024,$fp)) {
	$data .= $chunk;
    }
    Geo::GDAL::VSIFCloseL($fp);
    $data = decode('utf8', $data);
    $length = length(Encode::encode_utf8($data));
    print $cgi->header(-type => $type, -Content_length => $length, -charset=>'utf-8');
    print $data;
    STDOUT->flush;
    Geo::GDAL::Unlink($arg{vsi});
}

sub xml_elements {
    for my $e (@_) {
	if (ref($e) eq 'ARRAY') {
	    xml_element(@$e);
	} else {
	    xml_element($e->{element}, $e->{attributes}, $e->{content});
	}
    }
}

sub xml_element {
    my $element = shift;
    my $attributes;
    my $content;
    for my $x (@_) {
	$attributes = $x, next if ref($x) eq 'HASH';
	$content = $x;
    }
    #print(encode utf8=>"<$element");
    print("<$element");
    if ($attributes) {
	for my $a (keys %$attributes) {
	    #print(encode utf8=>" $a=\"$attributes->{$a}\"");
	    print(" $a=\"$attributes->{$a}\"");
	}
    }
    unless (defined $content) {
	print("/>");
    } else {
	if (ref $content) {
	    print(">");
	    if (ref $content->[0]) {
		for my $e (@$content) {
		    xml_element(@$e);
		}
	    } else {
		xml_element(@$content);
	    }
	    #print(encode utf8=>"</$element>");
	    print("</$element>");
	} elsif ($content eq '>' or $content eq '<' or $content eq '<>') {
	    print(">");
	} else {
	    #print(encode utf8=>">$content</$element>");
	    print(">$content</$element>");
	}
    }
}

1;
