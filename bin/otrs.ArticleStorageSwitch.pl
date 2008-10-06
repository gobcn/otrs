#!/usr/bin/perl -w
# --
# otrs.ArticleStorageSwitch.pl - to move stored attachments from one backend to other
# Copyright (C) 2001-2008 OTRS AG, http://otrs.org/
# --
# $Id: otrs.ArticleStorageSwitch.pl,v 1.2 2008-10-06 16:44:37 mh Exp $
# --
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
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
# --

use strict;
use warnings;

# use ../ as lib location
use File::Basename;
use FindBin qw($RealBin);
use lib dirname($RealBin);
use lib dirname($RealBin) . "/Kernel/cpan-lib";

use vars qw($VERSION);
$VERSION = qw($Revision: 1.2 $) [1];

use Getopt::Std;
use Kernel::Config;
use Kernel::System::Log;
use Kernel::System::Time;
use Kernel::System::Encode;
use Kernel::System::DB;
use Kernel::System::Main;
use Kernel::System::Ticket;

# get options
my %Opts = ();
getopt( 'hsdv', \%Opts );
if ( $Opts{h} ) {
    print "otrs.ArticleStorageSwitch.pl <Revision $VERSION> - to move storage content\n";
    print "Copyright (c) 2001-2008 OTRS AG, http://otrs.org/\n";
    print "usage: otrs.ArticleStorageSwitch.pl -s ArticleStorageDB -d ArticleStorageFS\n";
    exit 1;
}

# create common objects
my %CommonObject = ();
$CommonObject{ConfigObject} = Kernel::Config->new();
$CommonObject{LogObject}    = Kernel::System::Log->new(
    LogPrefix => 'OTRS-ArticleStorageSwitch',
    %CommonObject,
);
$CommonObject{MainObject}   = Kernel::System::Main->new(%CommonObject);
$CommonObject{EncodeObject} = Kernel::System::Encode->new(%CommonObject);
$CommonObject{TimeObject}   = Kernel::System::Time->new( %CommonObject, );

# create needed objects
$CommonObject{DBObject}     = Kernel::System::DB->new(%CommonObject);
$CommonObject{TicketObject} = Kernel::System::Ticket->new(%CommonObject);

# get all tickets
my @TicketIDs = $CommonObject{TicketObject}->TicketSearch(

    # result (required)
    Result => 'ARRAY',

    # result limit
    Limit      => 1_000_000_000,
    UserID     => 1,
    Permission => 'ro',
);

my $Count = 0;
for my $TicketID (@TicketIDs) {

    $Count++;

    # get articles
    my @ArticleIndex = $CommonObject{TicketObject}->ArticleIndex(
        TicketID => $TicketID,
        UserID   => 1,
    );
    for my $ArticleID (@ArticleIndex) {

        # create source object
        $CommonObject{ConfigObject}->Set(
            Key   => 'Ticket::StorageModule',
            Value => 'Kernel::System::Ticket::' . $Opts{s},
        );
        my $TicketObjectSource = Kernel::System::Ticket->new(%CommonObject);

        # read source attachments
        my %Index = $TicketObjectSource->ArticleAttachmentIndex(
            ArticleID     => $ArticleID,
            OnlyMyBackend => 1,
        );

        # read source plain
        my $Plain = $TicketObjectSource->ArticlePlain(
            ArticleID     => $ArticleID,
            OnlyMyBackend => 1,
        );
        my $PlainMD5Sum = '';
        if ($Plain) {
            $PlainMD5Sum = $CommonObject{MainObject}->MD5sum(
                String => $Plain,
            );
        }

        # write destination attachments
        my @Attachments;
        my %MD5Sums;
        for my $FileID ( keys %Index ) {
            my %Attachment = $TicketObjectSource->ArticleAttachment(
                ArticleID => $ArticleID,
                FileID    => $FileID,
                UserID    => 1,
            );
            push @Attachments, \%Attachment;
            my $MD5Sum = $CommonObject{MainObject}->MD5sum(
                String => $Attachment{Content},
            );
            $MD5Sums{$MD5Sum} = 1;
            print
                "Read: ArticleID: $ArticleID $Index{$FileID}->{Filename} $Index{$FileID}->{Filesize} ($MD5Sum)\n"
                if $Opts{v};
        }

        $CommonObject{ConfigObject}->Set(
            Key   => 'Ticket::StorageModule',
            Value => 'Kernel::System::Ticket::' . $Opts{d},
        );
        my $TicketObjectDestination = Kernel::System::Ticket->new(%CommonObject);
        for my $Attachment (@Attachments) {
            print "Wrtie: ArticleID: $ArticleID $Attachment->{Filename} $Attachment->{Filesize} \n"
                if $Opts{v};
            $TicketObjectDestination->ArticleWriteAttachment(
                %{$Attachment},
                ArticleID => $ArticleID,
                UserID    => 1,
            );

        }

        # write destination plain
        if ($Plain) {
            $TicketObjectDestination->ArticleWritePlain(
                Email     => $Plain,
                ArticleID => $ArticleID,
                UserID    => 1,
            );
        }

        # verify destination attachments
        %Index = $TicketObjectDestination->ArticleAttachmentIndex(
            ArticleID     => $ArticleID,
            OnlyMyBackend => 1,
        );
        for my $FileID ( keys %Index ) {
            my %Attachment = $TicketObjectDestination->ArticleAttachment(
                ArticleID => $ArticleID,
                FileID    => $FileID,
                UserID    => 1,
            );
            my $MD5Sum = $CommonObject{MainObject}->MD5sum(
                String => $Attachment{Content},
            );
            if ( !$MD5Sums{$MD5Sum} ) {
                print "ERROR: Corrupt file: $Attachment{Filename}\n";
            }
            else {
                print "NOTICE: Ok file: $Attachment{Filename} ($MD5Sum)\n" if $Opts{v};
            }
        }

        # verify destination plain
        my $PlainVerify = $TicketObjectDestination->ArticlePlain(
            ArticleID     => $ArticleID,
            OnlyMyBackend => 1,
        );
        my $PlainMD5SumVerify = '';
        if ($PlainVerify) {
            $PlainMD5SumVerify = $CommonObject{MainObject}->MD5sum(
                String => $PlainVerify,
            );
        }
        if ( $PlainMD5Sum ne $PlainMD5SumVerify ) {
            print
                "ERROR: Corrupt plain file: ArticleID: $ArticleID ($PlainMD5Sum/$PlainMD5SumVerify)\n";
        }

        # remove source attachments
        $CommonObject{ConfigObject}->Set(
            Key   => 'Ticket::StorageModule',
            Value => 'Kernel::System::Ticket::' . $Opts{s},
        );
        $TicketObjectSource = Kernel::System::Ticket->new(%CommonObject);
        $TicketObjectSource->ArticleDeleteAttachment(
            ArticleID     => $ArticleID,
            UserID        => 1,
            OnlyMyBackend => 1,
        );
        print "NOTICE: Remove attachments of ArticleID: $ArticleID\n" if $Opts{v};

        # remove source plain
        $TicketObjectSource->ArticleDeletePlain(
            ArticleID     => $ArticleID,
            UserID        => 1,
            OnlyMyBackend => 1,
        );
        print "NOTICE: Remove plain of ArticleID: $ArticleID\n" if $Opts{v};

    }

}
print "NOTICE: done.\n";

exit(0);
