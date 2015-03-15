#!/usr/bin/perl

# Made by Anonymous; modified by Dariush to work with Danbooru 2
# v.2.1.0 - added blacklist, fixed downloading of tags with over 200 images, generally cleaned up;
# v.2.2.0 - added Gelbooru support, made everything extensible for support for more sites later;
# v.2.3.0 - added Pixiv support, added blacklist addition from the command line, revamped the code, added automatic subdirectory creation, remade the way Sigint works, unified tag and pool downloads (note that pools aren't explicitly supported right now, but you can still grab them by searching for "pool:XXXX" as tag);
# v.2.4.0 - changed argument handling so that quotes are no longer required, added folder and file naming schemes; blacklist now supports multi-tag combinations;
# v.2.4.1 - added Pixiv tag downloads. Unfortunately, if they contain Japanese characters, they have to be entered in the parameter section of the script itself, since commandline doesn't pass Unicode to Perl properly;
# v.2.4.2 - added DeviantArt support. No other changes;
# You may contact me via PM on Danbooru or at archsinus@gmail.com
 
# Parameters that you (yes, YOU) can modify.

my @blacklist = ("amputee","scat","comic monochrome","doll_joints","puru-see","yaoi","duplicate"); #input tags as strings separated by commas 
my $tag_override = ""; #intended to be used only when trying to pass Unicode as input (for example, when using Pixiv tags that contain non-latin symbols (aka all of them)); I failed to get Unicode to read from ARGV properly. :(

# Below this line begins the script.

use strict;
use warnings;
use WWW::Mechanize;
use HTTP::Response;
use threads;
use threads::shared;
use File::Basename;
use Digest::SHA1 qw(sha1_hex);
use URI::Escape;
use Data::Dumper;
use Digest::MD5;
	
my $stop = 0;
$SIG{'INT'} = 'SIGINT_handler'; 
$| = 1; #flush stdout immediately
my $user;
my $pass;
my $directory :shared;
$directory = 'images';
my $tags;
my $site = 'dant';
my $limit = 180; #Danbooru hardcaps requests at 200 images, so don't set this above 200. I want some overhead, so I set it to a bit lower value
my $threads = 8;
my $subdir = "<orig>";#id booru_name
my $name = "<orig>";#hash title
	#open(my $debug, '>','debug.txt');
	my $exit = 0; #0 is full work, 1 is exit before download
my $mech = WWW::Mechanize->new();
$mech -> cookie_jar(HTTP::Cookies->new());
 
if (grep { /-help$|^help$|-h/i } @ARGV )
{
	show_help();
	exit;
}

#data input	
my $args = join(' ',@ARGV);
my @strs = split(/(-\S)\b/,$args);
shift @strs;
$/ = ' ';
foreach(@strs)	{	s/^\s+//; chomp;	}
my %input = @strs;

$user = $input{"-u"};
$pass = $input{"-p"};
$tags = $input{"-t"};
											if ($tag_override ne '')
	{$tags = $tag_override;
	print "WARNING: tag override is in effect.\n";}
											if (exists $input{"-b"})
	{push @blacklist, split(' ',$input{"-b"}); 
	s/%/ /g foreach (@blacklist);}
$directory = $input{"-d"} 					if (exists $input{"-d"});
$exit = $input{"-e"} 						if (exists $input{"-e"});
$site = $input{"-s"} 						if (exists $input{"-s"});
$subdir = $input{"-r"} 						if (exists $input{"-r"});
$name = $input{"-n"} 						if (exists $input{"-n"});
$limit = $input{"-l"} 						if (exists $input{"-l"});
$threads = $input{"-x"} 					if (exists $input{"-x"});

#data handling
$directory =~ s/\/|\\$//;
my %url_base = (
		dant => "http://danbooru.donmai.us/post/index.xml",
		gel  => "http://gelbooru.com/index.php?page=dapi&s=post&q=index",
		pixi => "http://www.pixiv.net/member_illust.php",
		pixt => "http://www.pixiv.net/search.php",
		danp => "http://danbooru.donmai.us/pool/show.xml",
		dea  => "deviantart.com/gallery/",
		);

my @auth = ('pix');
 
print "Downloading '$tags' to $directory from $site.\n\n";
 
if ($tags eq '' or !exists $url_base{$site} or (($user eq '' or $pass eq '') and grep {$site =~ $_} @auth))
{
	show_help();
	exit;
}
my $url = $url_base{$site};
$url = authorize($url);
 
my @files :shared;

die "Non-unique subdirectory name" if (
	(($site =~ 'dan' or $site eq 'gel')
		and $subdir !~ /(<orig>)/
		and $subdir !~ /(<booru_name>)/)
	or  ($site eq 'pixi'
		and $subdir !~ /(<orig>)/
		and ($subdir !~ /(<booru_name>)/ or $subdir !~ /(<booru_fallback=[^>]+>)/)
		and $subdir !~ /(<id>)/)
	or  ($site eq 'pixt'
		and $subdir !~ /(<orig>)/
		and $subdir !~ /(<id>)/)
	or  ($site eq 'dea'
		and $subdir !~ /(<orig>)/
		and $subdir !~ /(<id>)/)
		and ($subdir !~ /(<booru_name>)/ or $subdir !~ /(<booru_fallback=[^>]+>)/)
	);
	 
for(my $page = 1; ; $page++)
{
	exit if ($stop);	
		
	fetch_page($page);
	last if (handle_page($mech->content));
}

	#print Dumper(@files);
	exit if ($exit == 1);
#yay, we have an array of links to files to be downloaded!

if (!-d $directory)
{	mkdir $directory;} 
chdir $directory;
$subdir = proper($subdir);
if (!-d $subdir)
{	mkdir $subdir;} 
die "Failed to chdir into subdirectory. Please try some other naming scheme." if !chdir $subdir;

my @thr;
my $file;
if ($#files+1 < $threads) { $threads = $#files+1; };
 
print "\nDownloading ".($#files+1)." files in $threads threads.\n";
 
for (1..$threads)
{
	if ($file = shift @files)
	{
		$thr[$_] = threads->create(\&save_file, $file);
	}
}
 
while (sleep 1)
{
	for (1..$threads)
	{
		if ($thr[$_]->is_joinable)
		{
			$thr[$_]->join;
			if ($file = shift @files and !$stop)
			{
				$thr[$_] = threads->create(\&save_file, $file);
			}
		}
	}
	last if (($#files == -1 or $stop) and threads->list == 0);
}

sub handle_page 
#return value of 0 means that there are more pages to be fetched (non-empty page from a multi-page site); return of 1 means that this is the last page (the only page from a single-page site or an empty page from a multi-page one)
{
	my $content = shift;
	if ($site =~ 'dan' or $site eq 'gel')
	{	
		$subdir =~ s/<orig>/$tags/g;
		$subdir =~ s/<booru_name>/$tags/g;
																	
		return 1 if ($content !~ /<post (.+)\/>/);
		while ($content =~ /<post (.+)\/>/g)
		{
			my $hash = hashXML($1);
			foreach (@blacklist)
			{
				my @sep_black = split(' ',$_); #separate components of multi-tag blacklisted combinations
				my $black_counter = 0;
				foreach (@sep_black)
				{
					if ($hash->{tags} =~ /$_/)
					{
						$black_counter += 1;
					}
				}
				if ($black_counter >= 0+@sep_black) #only blacklist the whole post if it matches every tag in the space-separated combination
				{
					$hash->{blacklisted} = 1;
					last;
				}
			}
			push @files, ($site =~ 'dan' ? "http://danbooru.donmai.us".$hash->{file_url}:$hash->{file_url}) unless $hash->{blacklisted};
		}
	}
	if ($site =~ 'pix')
	{	
		my @links = grep {$_ =~ /illust_id=(\d+)/} map {$_->url} ($mech->links);
		return 1 if (!@links);
		foreach (@links)
		{
			/illust_id=(\d+)/;
			$mech -> get("http://spapi.pixiv.net/iphone/illust.php?illust_id=$1");
			my $content = $mech->content;
			$content =~ s/"//g;
			my @fields = split /,/, $content; 
			my $url;
			my $manga_pages = '';
			if ($fields[1] != 0 and 0+@fields == 31) #API is working correctly, we can do this the fast way
			{
				$url = $fields[9];
				$manga_pages = $fields[19];					
				$url =~ s/(mobile\/)|(_480mw)|(jpg.*$)//g; #we chop the extension because it might be different from the actual one
				$url .= $fields[2];
					$subdir =~ s/<orig>/$fields[24]/g;
			}
			else
			{ #API is fucked up :(
				$mech->get("http://pixiv.net/".$_);
				$url = $mech->find_image(url_regex => qr/\d+_m.\S+/)->url;
				$url =~ s/_m//;
				if ($mech->content =~ /<li>Manga (\d+)P<\/li>/) #manga
				{
					$manga_pages = $1;	
				}
					if ($subdir =~ /<orig>/)
					{
						my $name = $mech->find_link(url_regex => qr/\S+stacc\/([^?\/]+)$/)->url;
						$name =~ s/^\S+\///;
						$subdir =~ s/<orig>/$name/g;
					}
			}
			#ID and Danbooru name lookup are independent of API, so they are done outside of API-specific blocks
					$subdir =~ s/<id>/$tags/g;			
				if ($subdir =~ /<booru_name>/)
				{
					$mech->get("http://danbooru.donmai.us/artists.xml?name=http://www.pixiv.net/member.php?id=$tags");
					if ($mech->content =~ /<name>(\S+)<\/name>/)
					{
						my $temp = $1;
						$subdir =~ s/<booru_name>/$temp/g;
						$subdir =~ s/<booru_fallback=[^>]+>//g;
					} else {
						$subdir =~ s/<booru_name>//g;
						$subdir =~ s/<booru_fallback=([^>]+)>/$1/g;
					}	
				}
			if ($manga_pages ne '')
			{
				$url =~ /(\S+)(\.\w+)$/;
				for (my $i = 0; $i < $manga_pages; $i++)
				{
					push @files, $1."_p$i".$2;
				}
			}
			else
			{
				push @files, $url;
			}
		}
	}
	if ($site eq 'dea')
	{	
		$subdir =~ s/<orig>/$tags/g;	
		if ($subdir =~ /<booru_name>/)
		{
			$mech->get("http://danbooru.donmai.us/artists.xml?name=http://$tags.deviantart.com/");
			if ($mech->content =~ /<name>(\S+)<\/name>/)
			{
				my $temp = $1;
				$subdir =~ s/<booru_name>/$temp/g;
				$subdir =~ s/<booru_fallback=[^>]+>//g;
			} else {
				$subdir =~ s/<booru_name>//g;
				$subdir =~ s/<booru_fallback=([^>]+)>/$1/g;
			}	
		}
		my @links = grep {$_ =~ /\/art\/(\S)+#comments/} map {$_->url} ($mech->links);
		return 1 if (!@links);
		foreach (@links)
		{
			s/#comments//;
			$mech -> get("http://backend.deviantart.com/oembed?url=$_");
			my $hash = hashJSON($mech->content);
			push @files, $hash->{url};
		}
	}
	print "Unused argument $1 supplied in subdirectory naming scheme.\n" while $subdir =~ /(<[^>]+>)/g;
	$subdir =~ s/<[^>]+>//g;
	return 0;
}

sub authorize
{
	my $lurl = shift;
	if ($site =~ 'dan')
	{
		$lurl.="?login=".uri_escape($user)."&password_hash=".sha1_hex("choujin-steiner--$pass--");
		#no failure detection because apparently Danbooru doesn't actually care whether the username/password combination is correct
	}
	if ($site =~ 'pix')
	{
		$mech -> get('http://www.pixiv.net/login.php');
		$mech -> submit_form( 
					with_fields => {
						pixiv_id	=> $user,
						pass		=> $pass,
						skip		=> 1,
					},
				);			
		die("Authorization failed.\n") if ($mech->content =~ /loggedIn = false/);
	}
	print "Authorization successful.\n";
	
	return $lurl;
}

sub hashJSON
{
	my $string = shift @_;	
	my $hash;
	while ($string =~ /"([^"]+)":"*([^,"]*)"*,/g) #JSON #{"approver_id":13793,"created_
	{
		$hash -> {$1} = $2;
	}
	return $hash;
}

sub hashXML
{
	my $string = shift @_;	
	my $hash;
	while ($string =~ /(\S+)="([^"]*)"/g)
	{
		$hash -> {$1} = $2;
	}
	return $hash;
}
 
sub fetch_page
{
	my $page = shift;
	my %local = (
		dant => "<url>&tags=$tags&page=$page&limit=$limit",
		gel  => "<url>&tags=$tags&pid=".($page-1)."&limit=$limit",
		pixi => "<url>?id=$tags&p=$page",
		pixt => "<url>?s_mode=s_tag_full&word=$tags&p=$page",
		danp => "<url>?id=$tags&page=$page&limit=$limit",
		dea  => "http://$tags.<url>?offset=".($page-1)*24,
		);
	my $lurl = $local{$site};
	$lurl =~ s/<url>/$url/;
	print "Getting [$lurl] (page $page)... ";
	my $response = $mech->get($lurl);  
	if ($response->is_success)
	{
		print "OK.\n";
		return $response->content;
	}
	else
	{
		print 'Error: ' . $response->code . ' ' . $response->message . "\n";
		return undef;
	}
}
 
sub save_file
{
	my $file_url = shift;
	my $local_name = $name;
	$file_url =~ /(([^\/\\]+)\.([^\/\\]+))$/;
	my $filename = $1;
	my $file_id = $2;
	my $ext = $3;	
	$local_name =~ s/<orig>/$file_id/g;
	my $temp_name = $local_name;
	$temp_name =~ s/(<[^>]+>)//g; #this includes hashes and other options that can only be added after downloading
	#we do everything that's possible to do with the file without downloading before this line
	print ''.($#files+1)." files left, saving $filename...\n";
	if (-e "$temp_name.$ext") #duplicate detection only works if chosen file naming scheme doesn't use hashes
		{ print "File already existed, skipping...\n" ; 
		threads->exit; }
	else
		{$mech->get($file_url, ':content_file' => $filename); }
	if ($local_name =~ /<hash>/)
	{	
		open (my $fh, '<', $filename) or die "Can't open $filename: $!";
		binmode ($fh);
		my $hash = Digest::MD5->new->addfile($fh)->hexdigest;
		$local_name =~ s/<hash>/$hash/g;
	}
	print "Unused argument $1 supplied in file naming scheme.\n" while $local_name =~ /(<[^>]+>)/g;
	$local_name =~ s/(<[^>]+>)//g;
	if ($name eq "<orig>")
	{
		print "Saved $filename succesfully.\n"; 
	} else {
		rename ($filename, $local_name.'.'.$ext); #this also serves as a backup duplicate detection scheme - pictures may get downloaded a second time, but they quietly overwrite the old version so the only symptom is a redundant download
		print "Saved $filename (as $local_name.$ext) succesfully.\n"; 
	}
	threads->exit;
}
 
sub show_help
{
		print "Multibooru download script.
Usage: ".basename($0)." -u <username> -p <pass> -t <input> <other options>}
Options:
		-t			any input you want to throw at the script - artist ID for Pixiv, tags for 'boorus;
		-d			directory to save images to (a unique subdirectory based on input will be automatically created) (default `$directory');
		-s			site to download from (default Danbooru), syntax: 
			'dant' for Danbooru; 
			'gel' for Gelbooru;
			'pixi' for Pixiv download by ID;
			'pixt' for Pixiv download by tag; (if using this option, use ".'$tag_override'." option in the parameter section to ensure correct Unicode handling)
		-b			blacklisted tags that work like simple tags prefixed with '-', but don't take up the two-tag limit and are processed client-side and not server-side like normal exclusions. Thus, this option is best used when you want to exclude a small percentage of posts and not for something like 'long_hair -b touhou'; if you want to exclude a combination of tags, all of which must be present for image not to be downloaded, use % as separator, as in 'comic%monochrome'; only applies to 'boorus;
		-r			subdirectory naming scheme: takes a string that consists of any of the following arguments (angular brackets must be included):
			<orig> 					'booru tag for 'boorus, artist name for Pixiv and DA;
			<id> 					numeric ID, only works on Pixiv;
			<booru_name> 			'booru tag, works everywhere;
			<booru_fallback=X> 		if artist isn't in the database, X will be substituted (X may contain other bracketed values, so <booru_fallback=<orig> (Pixiv <id>)> is a valid string). Otherwise, this block is ignored);
				default is <orig>;
		-n			file naming scheme: takes a string that consists of any of the following arguments (angular brackets must be included): 
			<orig> 					unchanged file name - hash for 'boorus, image id for Pixiv, title with artist suffix for DA;
			<hash> 					MD5 hash - produces collisions when the same picture has been downloaded from another site (this is a good thing);
			<title> 				work title, supposed to work on Pixiv and DA, but doesn't;
				default is <orig>;
		===			Things you probably want to mess with end here			===
		-l			files per page (defaut $limit); only applies to 'boorus;
		-x			number of threads (default $threads);
		-e			debug code (0 is normal run, 1 exits after completing the link array, but before downloading anything or creating any directories, more options will probably be added later).
		";
}

sub proper
{
	$_[0] =~ s/_|:/ /g;
    return join('',map{ucfirst("$_")} split(/\b/,$_[0]));
}
 
sub SIGINT_handler
{
		#@files = ();
		print "Interrupted by SIGINT, stopping...\n";
		$stop = 1;
}