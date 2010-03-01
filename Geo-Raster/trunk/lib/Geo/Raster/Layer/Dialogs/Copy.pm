package Geo::Raster::Layer::Dialogs::Copy;
# @brief 

use strict;
use warnings;
use UNIVERSAL qw(isa);
use Carp;
use Glib qw/TRUE FALSE/;
use Gtk2::Ex::Geo::Dialogs qw/:all/;

## @ignore
# copy dialog
sub open {
    my($self, $gui) = @_;

    # bootstrap:
    my $dialog = $self->{copy_dialog};
    unless ($dialog) {
	$self->{copy_dialog} = $dialog = $gui->get_dialog('copy_dialog');
	croak "copy_dialog for Geo::Raster does not exist" unless $dialog;

	my $combo = $dialog->get_widget('copy_driver_combobox');
	my $renderer = Gtk2::CellRendererText->new;
	$combo->pack_start ($renderer, TRUE);
	$combo->add_attribute ($renderer, text => 0);
	$combo->signal_connect(changed=>\&copy_driver_selected, [$self, $gui]);

	$dialog->get_widget('copy_folder_button')
	    ->signal_connect(clicked => \&copy_select_folder, $self);
	
	$combo = $dialog->get_widget('copy_region_combobox');
	$renderer = Gtk2::CellRendererText->new;
	$combo->pack_start ($renderer, TRUE);
	$combo->add_attribute ($renderer, text => 0);
	$combo->signal_connect(changed=>\&copy_region_selected, [$self, $gui]);

	$dialog->get_widget('copy_dialog')
	    ->signal_connect(delete_event => \&cancel_copy, [$self, $gui]);
	$dialog->get_widget('copy_cancel_button')
	    ->signal_connect(clicked => \&cancel_copy, [$self, $gui]);
	$dialog->get_widget('copy_ok_button')
	    ->signal_connect(clicked => \&do_copy, [$self, $gui, 1]);

	for ('minx','miny','maxx','maxy','cellsize') {
	    $dialog->get_widget('copy_'.$_.'_entry')->signal_connect(
		changed => 
		sub {
		    my(undef, $self) = @_;
		    return if $self->{_ignore_copy_entry_change};
		    $self->{copy_dialog}->get_widget('copy_region_combobox')->set_active(0);
		    copy_info($self);
		}, $self);
	}

	$dialog->get_widget('from_EPSG_entry')
	    ->signal_connect(changed => \&Geo::Raster::Layer::update_srs_labels, [$self, $gui]);
	$dialog->get_widget('to_EPSG_entry')
	    ->signal_connect(changed => \&Geo::Raster::Layer::update_srs_labels, [$self, $gui]);

    } elsif (!$dialog->get_widget('copy_dialog')->get('visible')) {
	$dialog->get_widget('copy_dialog')->move(@{$self->{copy_dialog_position}});
    }
    $dialog->get_widget('copy_dialog')->set_title("Copy ".$self->name);
    $dialog->get_widget('copy_progressbar')->set_fraction(0);
	
    my $model = Gtk2::ListStore->new('Glib::String');
    $model->set($model->append, 0, 'libral');
    my @drivers;
    for my $driver (Geo::GDAL::Drivers) {
	next unless $driver->TestCapability('Create');
	my $name = $driver->{ShortName};
	push @drivers, $name;
    }
    for my $driver (sort @drivers) {
	$model->set($model->append, 0, $driver);
    }
    my $combo = $dialog->get_widget('copy_driver_combobox');
    $combo->set_model($model);
    $combo->set_active(0);

    $model = Gtk2::ListStore->new('Glib::String');
    $model->set($model->append, 0, '');
    $model->set($model->append, 0, '<Current view>');
    $model->set($model->append, 0, '<self>');
    my %names;
    for my $layer (@{$gui->{overlay}->{layers}}) {
	my $n = $layer->name();
	$names{$n} = 1;
	next unless isa($layer, 'Geo::Raster');
	next if $n eq $self->name();
	$model->set($model->append, 0, $n);
    }
    $combo = $dialog->get_widget('copy_region_combobox');
    $combo->set_model($model);
    $combo->set_active(2);

    copy_region_selected($combo, [$self, $gui]);

    my $i = ord('a'); 
    while ($names{chr($i)}) {$i++}
    my $name = chr($i);
	
    $dialog->get_widget('copy_name_entry')->set_text($name);

    $dialog->get_widget('copy_dialog')->show_all;
    $dialog->get_widget('copy_dialog')->present;
    return $dialog->get_widget('copy_dialog');
}

##@ignore
sub do_copy {
    my($self, $gui, $close) = @{$_[1]};

    my $dialog = $self->{copy_dialog};

    my $minx = get_number_from_entry($dialog->get_widget('copy_minx_entry'));
    my $miny = get_number_from_entry($dialog->get_widget('copy_miny_entry'));
    my $maxx = get_number_from_entry($dialog->get_widget('copy_maxx_entry'));
    my $maxy = get_number_from_entry($dialog->get_widget('copy_maxy_entry'));
    my $cellsize = get_number_from_entry($dialog->get_widget('copy_cellsize_entry'));
    if ($minx eq '' or $miny eq '' or $maxx eq '' or $maxy eq '' or $cellsize eq '') {
	return;
    }

    my($src, $dst);
    my $project = $dialog->get_widget('copy_projection_checkbutton')->get_active;
    my @bounds;
    if ($project) {
	my $from = $dialog->get_widget('from_EPSG_entry')->get_text;
	my $to = $dialog->get_widget('to_EPSG_entry')->get_text;
	return unless $Geo::Raster::Layer::EPSG{$from} and $Geo::Raster::Layer::EPSG{$to};

	$src = Geo::OSR::SpatialReference->create( EPSG => $from );
	$dst = Geo::OSR::SpatialReference->create( EPSG => $to );
	return unless $src and $dst;

	# compute corner points in new srs
	my $ct;
	eval {
	    $ct = Geo::OSR::CoordinateTransformation->new($src, $dst);
	};
	if ($@ or !$ct) {
	    $@ = '' unless $@;
	    $@ = ": $@" if $@;
	    $gui->message("Can't create coordinate transformation$@.");
	    return;
	}
	my $points = [[$minx,$miny],[$minx,$maxy],[$maxx,$miny],[$maxx,$maxy]];
	$ct->TransformPoints($points);
	for (@$points) {
	    $bounds[0] = $_->[0] if (!defined($bounds[0]) or ($_->[0] < $bounds[0]));
	    $bounds[1] = $_->[1] if (!defined($bounds[1]) or ($_->[1] < $bounds[1]));
	    $bounds[2] = $_->[0] if (!defined($bounds[2]) or ($_->[0] > $bounds[2]));
	    $bounds[3] = $_->[1] if (!defined($bounds[3]) or ($_->[1] > $bounds[3]));
	}

	$src = $src->ExportToPrettyWkt;
	$dst = $dst->ExportToPrettyWkt;
    }

    my $name = $dialog->get_widget('copy_name_entry')->get_text();
    my $folder = $dialog->get_widget('copy_folder_entry')->get_text();
    $folder .= '/' if $folder;

    my $combo = $dialog->get_widget('copy_driver_combobox');
    my $iter = $combo->get_active_iter;
    my $driver = $combo->get_model->get($iter);
    $combo = $dialog->get_widget('copy_region_combobox');
    $iter = $combo->get_active_iter;
    my $region = $combo->get_model->get($iter);

    my($new_layer, $src_dataset, $dst_dataset);
    
    # src_dataset
    if ($driver eq 'libral' and !$project) {
	if ($self->{GDAL}) {
	    $new_layer = $self->cache($minx, $miny, $maxx, $maxy, $cellsize);
	} else {
	    $new_layer = $self * 1;
	}
    } else {
	$src_dataset = $self->dataset;

	if ($project) {
	    #my($w, $h) = $src_dataset->Size;
	    #my @transform = $src_dataset->GeoTransform;
	    #my $w = int(($maxx-$minx)/$transform[1]);
	    #my $h = int(($miny-$maxy)/$transform[5]);
	    my $w = int(($bounds[2]-$bounds[0])/$cellsize+1);
	    my $h = int(($bounds[3]-$bounds[1])/$cellsize+1);
	    my $bands = $src_dataset->Bands;
	    my $type = $src_dataset->Band(1)->DataType;
	    my $d = $driver eq 'libral' ? 'MEM' : $driver;
	    $dst_dataset = Geo::GDAL::Driver($d)->Create($folder.$name, $w, $h, $bands, $type);
	    my @transform = ($bounds[0], $cellsize, 0, 
			     $bounds[1], 0, $cellsize);
	    $dst_dataset->GeoTransform(@transform);
	    my $alg = 'NearestNeighbour';
	    my $bar = $dialog->get_widget('copy_progressbar');

	    eval {
		Geo::GDAL::ReprojectImage($src_dataset, $dst_dataset, $src, $dst, $alg, 0, 0.0, 
					  \&progress, $bar);
	    };
	    if ($@) {
		$gui->message("Error in reprojection: $@.");
		return;
	    }
	} else {
	    $dst_dataset = Geo::GDAL::Driver($driver)->Copy($folder.$name, $src_dataset);
	}

	$new_layer = {};
	$new_layer->{GDAL}->{dataset} = $dst_dataset;
	$new_layer->{GDAL}->{band} = 1;
	if ($driver eq 'libral') {
	    Geo::Raster::cache($new_layer);
	    delete $new_layer->{GDAL};
	}
	bless $new_layer => 'Geo::Raster';
    }
    
    $gui->add_layer($new_layer, $name, 1);
    $gui->set_layer($new_layer);
    $gui->select_layer($name);
    $gui->{overlay}->zoom_to($new_layer);

    $self->{copy_dialog_position} = [$dialog->get_widget('copy_dialog')->get_position];
    $dialog->get_widget('copy_dialog')->hide() if $close;
    $gui->{overlay}->render;
}

sub progress {
    my($progress, $msg, $bar) = @_;
    $progress = 1 if $progress > 1;
    $bar->set_fraction($progress);
    Gtk2->main_iteration while Gtk2->events_pending;
    return 1;
}

##@ignore
sub cancel_copy {
    my($self, $gui);
    for (@_) {
	next unless ref CORE::eq 'ARRAY';
	($self, $gui) = @{$_};
    }
    
    my $dialog = $self->{copy_dialog}->get_widget('copy_dialog');
    $self->{copy_dialog_position} = [$dialog->get_position];
    $dialog->hide();
    $gui->set_layer($self);
    $gui->{overlay}->render;
    1;
}

sub copy_select_folder {
    my(undef, $self) = @_;
    my $entry = $self->{copy_dialog}->get_widget('copy_folder_entry');
    file_chooser('Select a folder', 'select_folder', $entry);
}

sub copy_driver_selected {
    my $combo = $_[0];
    my($self, $gui) = @{$_[1]};
    my $dialog = $self->{copy_dialog};
    my $model = $combo->get_model;
    my $iter = $combo->get_active_iter;
    my $driver = $model->get($iter);
    my $a = ($driver eq 'libral' or $driver eq 'MEM');
    for ('copy_folder_button','copy_folder_entry') {
	$dialog->get_widget($_)->set_sensitive(not $a);
    }
}

sub copy_region_selected {
    my $combo = $_[0];
    my($self, $gui) = @{$_[1]};
    my $dialog = $self->{copy_dialog};
    my $model = $combo->get_model;
    my $iter = $combo->get_active_iter;
    my $region = $model->get($iter);
    my @region;
    if ($region eq '') {
    } elsif ($region eq '<Current view>') {
	@region = $gui->{overlay}->get_viewport();
	push @region, $self->cell_size( of_GDAL => 1 );
    } else {
	$region = $self->name if $region eq '<self>';
	my $layer = $gui->{overlay}->get_layer_by_name($region);
	@region = $layer->world( of_GDAL => 1 );
	push @region, $layer->cell_size( of_GDAL => 1 );
    }
    copy_define_region($self, @region);
}

sub copy_define_region {
    my $self = shift;

    my $dialog = $self->{copy_dialog};
    $dialog->get_widget('copy_size_label')->set_text('?');
    $dialog->get_widget('copy_memory_size_label')->set_text('?');

    my($minx, $miny, $maxx, $maxy, $cellsize);

    if (@_) {

	($minx, $miny, $maxx, $maxy, $cellsize) = @_;
	
    } else {

	$minx = get_number_from_entry($dialog->get_widget('copy_minx_entry'));
	$miny = get_number_from_entry($dialog->get_widget('copy_miny_entry'));
	$maxx = get_number_from_entry($dialog->get_widget('copy_maxx_entry'));
	$maxy = get_number_from_entry($dialog->get_widget('copy_maxy_entry'));
	$cellsize = get_number_from_entry($dialog->get_widget('copy_cellsize_entry'));

	$cellsize = $self->cell_size( of_GDAL => 1 ) if $cellsize eq '';
	my @world = $self->world( of_GDAL => 1 ); # $min_x, $min_y, $max_x, $max_y

	$minx = $world[0] if $minx eq '';
	$miny = $world[1] if $miny eq '';
	$maxx = $world[2] if $maxx eq '';
	$maxy = $world[3] if $maxy eq '';

    }

    $self->{_ignore_copy_entry_change} = 1; 
    $dialog->get_widget('copy_minx_entry')->set_text($minx);
    $dialog->get_widget('copy_miny_entry')->set_text($miny);
    $dialog->get_widget('copy_maxx_entry')->set_text($maxx);
    $dialog->get_widget('copy_maxy_entry')->set_text($maxy);
    $dialog->get_widget('copy_cellsize_entry')->set_text($cellsize);
    $self->{_ignore_copy_entry_change} = 0;
    
    copy_info($self);

    return ($minx, $miny, $maxx, $maxy, $cellsize);

}

sub copy_info {
    my($self) = @_;
    my $dialog = $self->{copy_dialog};
    my $minx = get_number_from_entry($dialog->get_widget('copy_minx_entry'));
    my $miny = get_number_from_entry($dialog->get_widget('copy_miny_entry'));
    my $maxx = get_number_from_entry($dialog->get_widget('copy_maxx_entry'));
    my $maxy = get_number_from_entry($dialog->get_widget('copy_maxy_entry'));
    my $cellsize = get_number_from_entry($dialog->get_widget('copy_cellsize_entry'));
    if ($minx eq '' or $miny eq '' or $maxx eq '' or $maxy eq '' or $cellsize eq '') { 
	$dialog->get_widget('copy_size_label')->set_text('?');
	$dialog->get_widget('copy_memory_size_label')->set_text('?');
    } else {
	my $M = int(($maxy - $miny)/$cellsize)+1;
	my $N = int(($maxx - $minx)/$cellsize)+1;
	my $datatype = $self->datatype || '';
	my $bytes =  $datatype eq 'Integer' ? 2 : 4; # should look this up from libral/GDAL
	my $size = $M*$N*$bytes;
	if ($size > 1024) {
	    $size = int($size/1024);
	    if ($size > 1024) {
		$size = int($size/1024);
		if ($size > 1024) {
		    $size = int($size/1024);
		    $size = "$size GiB";
		} else {
		    $size = "$size MiB";
		}
	    } else {
		$size = "$size KiB";
	    }
	} else {
	    $size = "$size B";
	}
	$dialog->get_widget('copy_size_label')->set_text("~${M} x ~${N}");
	$dialog->get_widget('copy_memory_size_label')->set_text($size);
    }
}

1;