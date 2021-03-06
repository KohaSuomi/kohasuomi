# Copyright KohaSuomi
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with Koha; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

package C4::OPLIB::OKM;

use Modern::Perl;
#use open qw( :std :encoding(UTF-8) );
#binmode( STDOUT, ":encoding(UTF-8)" );
use Carp;

use Data::Dumper;
use URI::Escape;
use File::Temp;
use File::Basename qw( dirname );
use YAML::XS;

use DateTime;

use C4::Branch;
use C4::Items;
use C4::ItemType;
use C4::OPLIB::OKMLibraryGroup;
use C4::OPLIB::OKMLogs;
use C4::Context;
use C4::Templates qw(gettemplate);

use Koha::BiblioDataElements;

use Koha::Exception::BadSystemPreference;
use Koha::Exception::FeatureUnavailable;

=head new

    my $okm = C4::OPLIB::OKM->new($log, $timeperiod, $limit, $individualBranches, $verbose);
    $okm->createStatistics();

@PARAM1 ARRAYRef of Strings, OPTIONAL, all notifications are collected here in addition to being printed to STDOUT.
                OKM creates an internal Array to store log entries, but you can reuse on big log for multiple OKMs by giving it to them explicitly.
@PARAM4 String, a .csv-row with each element as a branchcode
                'JOE_JOE,JOE_RAN,[...]'
                or
                '_A' which means ALL BRANCHES. Then the function fetches all the branchcodes from DB.

=cut

sub new {
    my ($class, $log, $timeperiod, $limit, $individualBranches, $verbose) = @_;

    my $self = {};
    bless($self, $class);

    $self->{verbose} = $verbose if $verbose;
    $self->{logs} = $log || [];
    $self->loadConfiguration();

    if ($self->isExecutionBlocked()) {
        Koha::Exception::FeatureUnavailable->throw(error => __PACKAGE__.":> Execution prevented by the System preference 'OKM's 'blockStatisticsGeneration'-flag.");
    }

    my $libraryGroups;
    if ($individualBranches) {
        $libraryGroups = $self->setLibraryGroups(  $self->createLibraryGroupsFromIndividualBranches($individualBranches)  );
        $self->{individualBranches} = $individualBranches;
    }
    else {
        $libraryGroups = $self->setLibraryGroups(  $self->getOKMBranchCategoriesAndBranches()  );
    }

    my ($startDate, $endDate) = StandardizeTimeperiodParameter($timeperiod);
    $self->{startDate} = $startDate;
    $self->{startDateISO} = $startDate->iso8601();
    $self->{endDate} = $endDate;
    $self->{endDateISO} = $endDate->iso8601();
    $self->{limit} = $limit; #Set the SQL LIMIT. Used in testing to generate statistics faster.

    return $self;
}

sub createStatistics {
    my ($self) = @_;

    my $libraryGroups = $self->getLibraryGroups();

    foreach my $groupcode (sort keys %$libraryGroups) {
        my $libraryGroup = $libraryGroups->{$groupcode};
        print '    #'.DateTime->now()->iso8601()."# Starting $groupcode #\n" if $self->{verbose};

        $self->statisticsBranchCounts( $libraryGroup, 1); #We have one main library here.

        #Calculate collections and acquisitions
        my $itemBomb = $self->fetchItemsDataMountain($libraryGroup);
        foreach my $itemnumber (sort {$a <=> $b} keys %$itemBomb) {
            $self->_processItemsDataRow( $libraryGroup, $itemBomb->{$itemnumber} );
        }
        #calculate issues
        my $issuesBomb = $self->fetchIssuesDataMountain($libraryGroup);
        foreach my $itemnumber (sort {$a <=> $b} keys %$issuesBomb) {
            $self->_processIssuesDataRow( $libraryGroup, $issuesBomb->{$itemnumber} );
        }

        $self->statisticsSubscriptions( $libraryGroup );
        $self->statisticsDiscards( $libraryGroup );
        $self->statisticsActiveBorrowers( $libraryGroup );

        $self->tidyStatistics( $libraryGroup );
    }
}

=head _processItemsDataRow

    _processItemsDataRow( $row );

@DUPLICATES _processIssuesDataRow(), almost completely.
            But it was decided to duplicate the statistical category if-else-forest instead of adding another
            layer of complexity to the 'collections, acquisitions, issues'-counter, because this module is complex enough as it is.

=cut

sub _processItemsDataRow {
    my ($self, $libraryGroup, $row) = @_;
    my $statCat = $self->getItypeToOKMCategory($row->{itype});
    return undef if $statCat eq 'Electronic';
    unless ($statCat) {
        $self->log("Couldn't get the statistical category for this item:<br/> - biblionumber => ".$row->{biblionumber}."<br/> - itemnumber => ".$row->{itemnumber}."<br/> - itype => ".$row->{itype}."<br/>Using category 'Other'.");
        $statCat = 'Other';
    }

    my $stats = $libraryGroup->getStatistics();

    my $deleted = $row->{deleted}; #These inlcude also Issues for Items outside of this libraryGroup.
    my $primaryLanguage = $row->{primary_language};
    my $isChildrensMaterial = $self->isItemChildrens($row);
    my $isFiction = $row->{fiction};
    my $isMusicalRecording = $row->{musical};
    my $isAcquired = (not($deleted)) ? $self->isItemAcquired($row) : undef; #If an Item is deleted, omit the acquisitions calculations because they wouldn't be accurate. Default to not acquired.
    my $itemtype = $row->{itype};
    my $issues = $row->{issuesQuery}->{issues} || 0;
    my $serial = ($statCat eq "Serials") ? 1 : 0; #Is the item type considered to be a serial or a magazine?

    #Increase the collection for every Item found
    $stats->{collection}++ if not($deleted) && not($serial);
    $stats->{acquisitions}++ if $isAcquired && not($serial);
    $stats->{expenditureAcquisitions} += $row->{price} if $isAcquired && not($serial) && $row->{price};

    if ($statCat eq "Books") {

        $stats->{'collection'.$statCat.'Total'}++ if not($deleted);
        $stats->{'acquisitions'.$statCat.'Total'}++ if $isAcquired;
        $stats->{'expenditureAcquisitions'.$statCat} += $row->{price} if $isAcquired && $row->{price};

        if (not(defined($primaryLanguage)) || $primaryLanguage eq 'fin') {
            $stats->{'collection'.$statCat.'Finnish'}++ if not($deleted);
            $stats->{'acquisitions'.$statCat.'Finnish'}++ if $isAcquired;
        }
        elsif ($primaryLanguage eq 'swe') {
            $stats->{'collection'.$statCat.'Swedish'}++ if not($deleted);
            $stats->{'acquisitions'.$statCat.'Swedish'}++ if $isAcquired;
        }
        else {
            $stats->{'collection'.$statCat.'OtherLanguage'}++ if not($deleted);
            $stats->{'acquisitions'.$statCat.'OtherLanguage'}++ if $isAcquired;
        }

        if ($isFiction) {
            if ($isChildrensMaterial) {
                $stats->{'collection'.$statCat.'FictionJuvenile'}++ if not($deleted);
                $stats->{'acquisitions'.$statCat.'FictionJuvenile'}++ if $isAcquired;
            }
            else { #Adults fiction
                $stats->{'collection'.$statCat.'FictionAdult'}++ if not($deleted);
                $stats->{'acquisitions'.$statCat.'FictionAdult'}++ if $isAcquired;
            }
        }
        else { #Non-Fiction
            if ($isChildrensMaterial) {
                $stats->{'collection'.$statCat.'NonFictionJuvenile'}++ if not($deleted);
                $stats->{'acquisitions'.$statCat.'NonFictionJuvenile'}++ if $isAcquired;
            }
            else { #Adults Non-fiction
                $stats->{'collection'.$statCat.'NonFictionAdult'}++ if not($deleted);
                $stats->{'acquisitions'.$statCat.'NonFictionAdult'}++ if $isAcquired;
            }
        }
    }
    elsif ($statCat eq 'Recordings') {
        if ($isMusicalRecording) {
            $stats->{'collectionMusicalRecordings'}++ if not($deleted);
            $stats->{'acquisitionsMusicalRecordings'}++ if $isAcquired;
        }
        else {
            $stats->{'collectionOtherRecordings'}++ if not($deleted);
            $stats->{'acquisitionsOtherRecordings'}++ if $isAcquired;
        }
    }
    elsif ($serial || $statCat eq 'Other') {
        $stats->{'collectionOther'}++ if not($deleted) && not($serial);
        $stats->{'acquisitionsOther'}++ if $isAcquired && not($serial);
        #Serials and magazines are collected from the subscriptions-table using statisticsSubscriptions()
        #Don't count them for the collection or acquisitions. Serials must be included in the cumulative Issues.
    }
    else {
        $stats->{'collection'.$statCat}++ if not($deleted);
        $stats->{'acquisitions'.$statCat}++ if $isAcquired;
    }
}

=head _processIssuesDataRow

    _processIssuesDataRow( $row );

@DUPLICATES _processItemsDataRow(), almost completely.
            But it was decided to duplicate the statistical category if-else-forest instead of adding another
            layer of complexity to the 'collections, acquisitions, issues'-counter, because this module is complex enough as it is.

=cut

sub _processIssuesDataRow {
    my ($self, $libraryGroup, $row) = @_;
    my $statCat = $self->getItypeToOKMCategory($row->{itype});
    return undef if $statCat eq 'Electronic';
    unless ($statCat) {
        #Already logged in _processItemsDataRow()# $self->log("Couldn't get the statistical category for this item:<br/> - biblionumber => ".$row->{biblionumber}."<br/> - itemnumber => ".$row->{itemnumber}."<br/> - itype => ".$row->{itype}."<br/>Using category 'Other'.");
        $statCat = 'Other';
    }

    my $stats = $libraryGroup->getStatistics();

    my $deleted = $row->{deleted}; #These inlcude also Issues for Items outside of this libraryGroup.
    my $primaryLanguage = $row->{primary_language};
    my $isChildrensMaterial = $self->isItemChildrens($row);
    my $isFiction = $row->{fiction};
    my $isMusicalRecording = $row->{musical};
    my $itemtype = $row->{itype};
    my $issues = $row->{issues} || 0;
    my $serial = ($statCat eq "Serials") ? 1 : 0; #Is the item type considered to be a serial or a magazine?

    #Increase the issues for every Issue found
    $stats->{issues} += $issues; #Serials are included in the cumulative issues.
    if ($statCat eq "Books") {
        $stats->{'issues'.$statCat.'Total'} += $issues;

        if (not(defined($primaryLanguage)) || $primaryLanguage eq 'fin') {
            $stats->{'issues'.$statCat.'Finnish'} += $issues;
        }
        elsif ($primaryLanguage eq 'swe') {
            $stats->{'issues'.$statCat.'Swedish'} += $issues;
        }
        else {
            $stats->{'issues'.$statCat.'OtherLanguage'} += $issues;
        }

        if ($isFiction) {
            if ($isChildrensMaterial) {
                $stats->{'issues'.$statCat.'FictionJuvenile'} += $issues;
            }
            else { #Adults fiction
                $stats->{'issues'.$statCat.'FictionAdult'} += $issues;
            }
        }
        else { #Non-Fiction
            if ($isChildrensMaterial) {
                $stats->{'issues'.$statCat.'NonFictionJuvenile'} += $issues;
            }
            else { #Adults Non-fiction
                $stats->{'issues'.$statCat.'NonFictionAdult'} += $issues;
            }
        }
    }
    elsif ($statCat eq 'Recordings') {
        if ($isMusicalRecording) {
            $stats->{'issuesMusicalRecordings'} += $issues;
        }
        else {
            $stats->{'issuesOtherRecordings'} += $issues;
        }
    }
    elsif ($serial || $statCat eq 'Other') {
        $stats->{'issuesOther'} += $issues;
        #Serials and magazines are collected from the subscriptions-table using statisticsSubscriptions()
        #Don't count them for the collection or acquisitions. Serials must be included in the cumulative Issues.
    }
    else {
        $stats->{'issues'.$statCat} += $issues;
    }
}

sub _processItemsDataRow_old {
    my ($self, $libraryGroup, $row) = @_;

    my $stats = $libraryGroup->getStatistics();

    my $deleted = $row->{deleted}; #These inlcude also Issues for Items outside of this libraryGroup.
    my $primaryLanguage = $row->{primary_language};
    my $isChildrensMaterial = $self->isItemChildrens($row);
    my $isFiction = $row->{fiction};
    my $isMusicalRecording = $row->{musical};
    my $isAcquired = (not($deleted)) ? $self->isItemAcquired($row) : undef; #If an Item is deleted, omit the acquisitions calculations because they wouldn't be accurate. Default to not acquired.
    my $itemtype = $row->{itype};
    my $issues = $row->{issuesQuery}->{issues} || 0;
    my $serial = ($itemtype eq 'AL' || $itemtype eq 'SL') ? 1 : 0;

    #Increase the collection for every Item found
    $stats->{collection}++ if not($deleted) && not($serial);
    $stats->{acquisitions}++ if $isAcquired && not($serial);
    $stats->{issues} += $issues; #Serials are included in the cumulative issues.
    $stats->{expenditureAcquisitions} += $row->{price} if $isAcquired && not($serial) && $row->{price};

    if ($itemtype eq 'KI') {

        $stats->{collectionBooksTotal}++ if not($deleted);
        $stats->{acquisitionsBooksTotal}++ if $isAcquired;
        $stats->{expenditureAcquisitionsBooks} += $row->{price} if $isAcquired && $row->{price};
        $stats->{issuesBooksTotal} += $issues;

        if (not(defined($primaryLanguage)) || $primaryLanguage eq 'fin') {
            $stats->{collectionBooksFinnish}++ if not($deleted);
            $stats->{acquisitionsBooksFinnish}++ if $isAcquired;
            $stats->{issuesBooksFinnish} += $issues;
        }
        elsif ($primaryLanguage eq 'swe') {
            $stats->{collectionBooksSwedish}++ if not($deleted);
            $stats->{acquisitionsBooksSwedish}++ if $isAcquired;
            $stats->{issuesBooksSwedish} += $issues;
        }
        else {
            $stats->{collectionBooksOtherLanguage}++ if not($deleted);
            $stats->{acquisitionsBooksOtherLanguage}++ if $isAcquired;
            $stats->{issuesBooksOtherLanguage} += $issues;
        }

        if ($isFiction) {
            if ($isChildrensMaterial) {
                $stats->{collectionBooksFictionJuvenile}++ if not($deleted);
                $stats->{acquisitionsBooksFictionJuvenile}++ if $isAcquired;
                $stats->{issuesBooksFictionJuvenile} += $issues;
            }
            else { #Adults fiction
                $stats->{collectionBooksFictionAdult}++ if not($deleted);
                $stats->{acquisitionsBooksFictionAdult}++ if $isAcquired;
                $stats->{issuesBooksFictionAdult} += $issues;
            }
        }
        else { #Non-Fiction
            if ($isChildrensMaterial) {
                $stats->{collectionBooksNonFictionJuvenile}++ if not($deleted);
                $stats->{acquisitionsBooksNonFictionJuvenile}++ if $isAcquired;
                $stats->{issuesBooksNonFictionJuvenile} += $issues;
            }
            else { #Adults Non-fiction
                $stats->{collectionBooksNonFictionAdult}++ if not($deleted);
                $stats->{acquisitionsBooksNonFictionAdult}++ if $isAcquired;
                $stats->{issuesBooksNonFictionAdult} += $issues;
            }
        }
    }
    elsif ($itemtype eq 'NU' || $itemtype eq 'PA') {
        $stats->{collectionSheetMusicAndScores}++ if not($deleted);
        $stats->{acquisitionsSheetMusicAndScores}++ if $isAcquired;
        $stats->{issuesSheetMusicAndScores} += $issues;
    }
    elsif ($itemtype eq 'KA' || $itemtype eq 'CD' || $itemtype eq 'MP' || $itemtype eq 'LE' || $itemtype eq 'ÄT' || $itemtype eq 'NÄ') {
        if ($isMusicalRecording) {
            $stats->{collectionMusicalRecordings}++ if not($deleted);
            $stats->{acquisitionsMusicalRecordings}++ if $isAcquired;
            $stats->{issuesMusicalRecordings} += $issues;
        }
        else {
            $stats->{collectionOtherRecordings}++ if not($deleted);
            $stats->{acquisitionsOtherRecordings}++ if $isAcquired;
            $stats->{issuesOtherRecordings} += $issues;
        }
    }
    elsif ($itemtype eq 'VI') {
        $stats->{collectionVideos}++ if not($deleted);
        $stats->{acquisitionsVideos}++ if $isAcquired;
        $stats->{issuesVideos} += $issues;
    }
    elsif ($itemtype eq 'CR' || $itemtype eq 'DR' || $itemtype eq 'KP') {
        $stats->{collectionCDROMs}++ if not($deleted);
        $stats->{acquisitionsCDROMs}++ if $isAcquired;
        $stats->{issuesCDROMs} += $issues;
    }
    elsif ($itemtype eq 'BR' || $itemtype eq 'DV') {
        $stats->{collectionDVDsAndBluRays}++ if not($deleted);
        $stats->{acquisitionsDVDsAndBluRays}++ if $isAcquired;
        $stats->{issuesDVDsAndBluRays} += $issues;
    }
    elsif ($serial || $itemtype eq 'DI' || $itemtype eq 'ES' || $itemtype eq 'KO' || $itemtype eq 'KR' || $itemtype eq 'MM' || $itemtype eq 'MO' || $itemtype eq 'SK' || $itemtype eq 'TY' || $itemtype eq 'MF' || $itemtype eq 'KU' || $itemtype eq 'MK' || $itemtype eq 'KÄ') {
        $stats->{collectionOther}++ if not($deleted) && not($serial);
        $stats->{acquisitionsOther}++ if $isAcquired && not($serial);
        $stats->{issuesOther} += $issues;
        #Serials and magazines are collected from the subscriptions-table using statisticsSubscriptions()
        #Don't count them for the collection or acquisitions. Serials must be included in the cumulative Issues.
    }
    else {
        $self->log("\nUnmapped itemtype \n'$itemtype'\n with this statistical row:\n".Data::Dumper::Dumper($row));
    }
}

=head fetchItemsDataMountain

    my $itemBomb = $okm->fetchItemsDataMountain();

Queries the DB for the required data elements and returns a Hash $itemBomb.
Collects the related acquisitions and collections data for the given timeperiod.

=cut

sub fetchItemsDataMountain {
    my ($self, $libraryGroup) = @_;

    my @cc = caller(0);
    print '    #'.DateTime->now()->iso8601()."# Starting ".$cc[3]." #\n" if $self->{verbose};
    my $in_libraryGroupBranches = $libraryGroup->getBranchcodesINClause();
    my $limit = $self->getLimit();

    my $dbh = C4::Context->dbh();
    #Get all the Items' informations for Items residing in the libraryGroup.
    my $sth = $dbh->prepare("
        (
        SELECT  i.itemnumber, i.biblionumber, i.itype, i.location, i.price,
                ao.ordernumber, ao.datereceived, i.dateaccessioned,
                bde.primary_language, bde.fiction, bde.musical,
                0 as deleted
            FROM items i
            LEFT JOIN aqorders_items ai ON i.itemnumber = ai.itemnumber
            LEFT JOIN aqorders ao ON ai.ordernumber = ao.ordernumber LEFT JOIN statistics s ON s.itemnumber = i.itemnumber
            LEFT JOIN biblioitems bi ON i.biblionumber = bi.biblioitemnumber
            LEFT JOIN biblio_data_elements bde ON bi.biblioitemnumber = bde.biblioitemnumber
            WHERE i.homebranch $in_libraryGroupBranches
            GROUP BY i.itemnumber $limit
        )
        UNION
        (
        SELECT  di.itemnumber, di.biblionumber, di.itype, di.location, di.price,
                ao.ordernumber, ao.datereceived, di.dateaccessioned,
                bde.primary_language, bde.fiction, bde.musical,
                1 as deleted
            FROM deleteditems di
            LEFT JOIN aqorders_items ai ON di.itemnumber = ai.itemnumber
            LEFT JOIN aqorders ao ON ai.ordernumber = ao.ordernumber LEFT JOIN statistics s ON s.itemnumber = di.itemnumber
            LEFT JOIN biblioitems bi ON di.biblionumber = bi.biblioitemnumber
            LEFT JOIN biblio_data_elements bde ON bi.biblioitemnumber = bde.biblioitemnumber
            WHERE di.homebranch $in_libraryGroupBranches
            GROUP BY di.itemnumber $limit
        )
    ");
    $sth->execute(  ); #This will take some time.....
    if ($sth->err) {
        my @cc = caller(0);
        Koha::Exception::DB->throw(error => $cc[3]."():> ".$sth->errstr);
    }
    my $itemBomb = $sth->fetchall_hashref('itemnumber');

    print '    #'.DateTime->now()->iso8601()."# Leaving ".$cc[3]." #\n" if $self->{verbose};
    return $itemBomb;
}

=head fetchItemsDataMountain

    my $itemBomb = $okm->fetchItemsDataMountain();

Queries the DB for the required data elements and returns a Hash $itemBomb.
Collects the related issuing data for the given timeperiod.

=cut

sub fetchIssuesDataMountain {
    my ($self, $libraryGroup) = @_;

    my @cc = caller(0);
    print '    #'.DateTime->now()->iso8601()."# Starting ".$cc[3]." #\n" if $self->{verbose};
    my $in_libraryGroupBranches = $libraryGroup->getBranchcodesINClause();
    my $limit = $self->getLimit();

    my $dbh = C4::Context->dbh();
    #Get all the Issues informations. We can have issues for other branches Items' which are not included in the $sthItems and $sthDeleteditems -queries.
    #This means that Patrons can check-out Items whose homebranch is not in this libraryGroup, but whom are checked out/renewed from this libraryGroup.
    my $sth = $dbh->prepare("
        (
        SELECT s.itemnumber, i.biblionumber, i.itype, i.location, 0 as deleted, COUNT(s.itemnumber) as issues,
               bde.primary_language, bde.fiction, bde.musical
            FROM statistics s
            LEFT JOIN items i ON s.itemnumber = i.itemnumber
            LEFT JOIN biblioitems bi ON i.biblionumber = bi.biblioitemnumber
            LEFT JOIN biblio_data_elements bde ON bi.biblioitemnumber = bde.biblioitemnumber
            WHERE s.branch $in_libraryGroupBranches
            AND s.type IN ('issue','renew')
            AND s.datetime BETWEEN ? AND ?
            AND (s.usercode != 'KIRJASTO' AND s.usercode != 'TILASTO' AND s.usercode != 'KAUKOLAINA')
            AND i.itemnumber IS NOT NULL
            GROUP BY s.itemnumber $limit
        )
        UNION
        (
        SELECT s.itemnumber, di.biblionumber, di.itype, di.location, 1 as deleted, COUNT(s.itemnumber) as issues,
               bde.primary_language, bde.fiction, bde.musical
            FROM statistics s
            LEFT JOIN deleteditems di ON s.itemnumber = di.itemnumber
            LEFT JOIN biblioitems bi ON di.biblionumber = bi.biblioitemnumber
            LEFT JOIN biblio_data_elements bde ON bi.biblioitemnumber = bde.biblioitemnumber
            WHERE s.branch $in_libraryGroupBranches
            AND s.type IN ('issue','renew')
            AND s.datetime BETWEEN ? AND ?
            AND (s.usercode != 'KIRJASTO' AND s.usercode != 'TILASTO' AND s.usercode != 'KAUKOLAINA')
            AND di.itemnumber IS NOT NULL
            GROUP BY s.itemnumber $limit
        )");
    $sth->execute(  $self->{startDateISO}, $self->{endDateISO}, $self->{startDateISO}, $self->{endDateISO}  ); #This will take some time.....
    if ($sth->err) {
        Koha::Exception::DB->throw(error => $cc[3]."():> ".$sth->errstr);
    }
    my $issuesBomb = $sth->fetchall_hashref('itemnumber');

    print '    #'.DateTime->now()->iso8601()."# Leaving ".$cc[3]." #\n" if $self->{verbose};
    return $issuesBomb;
}

sub fetchItemsDataMountain_old {
    my ($self, $libraryGroup) = @_;

    my $in_libraryGroupBranches = $libraryGroup->getBranchcodesINClause();
    my $limit = $self->getLimit();

    my $dbh = C4::Context->dbh();
    #Get all the Items' informations for Items residing in the libraryGroup.
    my $sthItems = $dbh->prepare(
                "SELECT i.itemnumber, i.biblionumber, i.itype, i.location, i.price, ao.ordernumber, ao.datereceived, av.imageurl, i.dateaccessioned,
                        bde.primary_language, bde.fiction, bde.musical
                 FROM items i LEFT JOIN aqorders_items ai ON i.itemnumber = ai.itemnumber
                              LEFT JOIN aqorders ao ON ai.ordernumber = ao.ordernumber LEFT JOIN statistics s ON s.itemnumber = i.itemnumber
                              LEFT JOIN authorised_values av ON av.authorised_value = i.permanent_location
                              LEFT JOIN biblioitems bi ON i.biblionumber = bi.biblioitemnumber
                              LEFT JOIN biblio_data_elements bde ON bi.biblioitemnumber = bde.biblioitemnumber
                 WHERE i.homebranch $in_libraryGroupBranches
                 GROUP BY i.itemnumber ORDER BY i.itemnumber $limit;");
#    $sth->execute(  $self->{startDateISO}, $self->{endDateISO}  ); #This will take some time.....
    $sthItems->execute(  ); #This will take some time.....
    my $itemBomb = $sthItems->fetchall_hashref('itemnumber');

    #Get all the Deleted Items' informations. We need them for the statistical entries that have a deleted item.
    my $sthDeleteditems = $dbh->prepare(
                "SELECT i.itemnumber, i.biblionumber, i.itype, i.location, i.price, av.imageurl, i.dateaccessioned, 1 as deleted,
                        bde.primary_language, bde.fiction, bde.musical
                 FROM deleteditems i
                              LEFT JOIN authorised_values av ON av.authorised_value = i.permanent_location
                              LEFT JOIN biblioitems bi ON i.biblionumber = bi.biblioitemnumber
                              LEFT JOIN biblio_data_elements bde ON bi.biblioitemnumber = bde.biblioitemnumber
                 WHERE i.homebranch $in_libraryGroupBranches
                 GROUP BY i.itemnumber ORDER BY i.itemnumber $limit;");
#    $sth->execute(  $self->{startDateISO}, $self->{endDateISO}  ); #This will take some time.....
    $sthDeleteditems->execute(  ); #This will take some time.....
    my $deleteditemBomb = $sthDeleteditems->fetchall_hashref('itemnumber');

    #Get all the Issues informations. We can have issues for other branches Items' which are not included in the $sthItems and $sthDeleteditems -queries.
    #This means that Patrons can check-out Items whose homebranch is not in this libraryGroup, but whom are checked out/renewed from this libraryGroup.
    my $sthIssues = $dbh->prepare(
                "SELECT s.itemnumber, i.biblionumber, i.itype, i.location, COUNT(s.itemnumber) as issues
                 FROM statistics s LEFT JOIN items i ON i.itemnumber = s.itemnumber
                 WHERE s.branch $in_libraryGroupBranches
                   AND s.type IN ('issue','renew')
                   AND s.datetime BETWEEN ? AND ?".
#                  "AND (s.usercode = 'HENKILO' OR s.usercode = 'VIRKAILIJA' OR s.usercode = 'LAPSI' OR s.usercode = 'MUUKUINLAP' OR s.usercode = 'TAKAAJA' OR s.usercode = 'YHTEISO')
                   "AND (s.usercode != 'KIRJASTO' AND s.usercode != 'TILASTO' AND s.usercode != 'KAUKOLAINA')
                 GROUP BY s.itemnumber ORDER BY s.itemnumber $limit;");
    $sthIssues->execute(  $self->{startDateISO}, $self->{endDateISO}  ); #This will take some time.....
    my $issuesBomb = $sthIssues->fetchall_hashref('itemnumber');
    #Get the same stuff for possibly deleted Items.
    my $sthDeleteditemsIssues = $dbh->prepare(
                "SELECT s.itemnumber, i.biblionumber, i.itype, i.location, COUNT(s.itemnumber) as issues
                 FROM statistics s LEFT JOIN deleteditems i ON i.itemnumber = s.itemnumber
                 WHERE s.branch $in_libraryGroupBranches
                   AND s.type IN ('issue','renew')
                   AND s.datetime BETWEEN ? AND ?".
#                  "AND (s.usercode = 'HENKILO' OR s.usercode = 'VIRKAILIJA' OR s.usercode = 'LAPSI' OR s.usercode = 'MUUKUINLAP' OR s.usercode = 'TAKAAJA' OR s.usercode = 'YHTEISO')
                   "AND (s.usercode != 'KIRJASTO' AND s.usercode != 'TILASTO' AND s.usercode != 'KAUKOLAINA')
                 GROUP BY s.itemnumber ORDER BY s.itemnumber $limit;");
    $sthDeleteditemsIssues->execute(  $self->{startDateISO}, $self->{endDateISO}  ); #This will take some time.....
    my $deleteditemsIssuesBomb = $sthDeleteditemsIssues->fetchall_hashref('itemnumber');

    #Merge Issues to Items' informations.
    foreach my $itemnumber (sort {$a <=> $b} (keys(%$issuesBomb))) {
        my $it = $itemBomb->{$itemnumber};
        my $id = $deleteditemBomb->{$itemnumber};
        my $is = $issuesBomb->{$itemnumber};
        my $di = $deleteditemsIssuesBomb->{$itemnumber};

        unless ($it) {
            unless ($id) {
                if (($is && $is->{itype}) || ($di && $di->{itype})) { #We have an Issue with no item anywhere
                    print "OKM->fetchDataMountain(): Issue with no Item or deleted Item. Using itemnumber '$itemnumber'.\n" if $self->{verbose};
                }
                else {
                    print "OKM->fetchDataMountain(): No Item or deleted Item found for Issues? Using itemnumber '$itemnumber'. Not inlcuding '".$is->{issues}."' issues to the statistics.\n";
                    next();
                }
                #Store the Issue with partial Item statistical information. These are counted only as issues towards different itemtypes.
                #Because these Items-data are not from the libraryGroup whose collection/acquisitions are being calculated.
                $itemBomb->{$itemnumber} = $is;
                $it = $is; #Consider this like any other deleted Item from now on, so don't include it to collection/acquisitions statistics, but make sure the itemtype is accessible properly.
                $it->{deleted} = 1;
                #Discard are calculated in statisticsDiscards() and this has nothing to do with that.
            }
            else {
                $itemBomb->{$itemnumber} = $id; #Take the deleted Item from the dead and reuse it.
                #print "OKM->fetchDataMountain(): Issues for deleted Item? Using deleted itemnumber '$itemnumber'.\n" if $self->{verbose};
            }
        }
        unless ($is) {
            print "OKM->fetchDataMountain(): No Issues in issuesBomb? Using itemnumber '$itemnumber'. This should never happen, since we get these itemnumbers from this same issues Hash.\n";
            next();
        }

        $it->{issuesQuery} = $is;
    }

    return $itemBomb;
}
=head getBranchCounts

    getBranchCounts( $branchcode, $mainLibrariesCount );

Fills OKM columns "Pääkirjastoja, Sivukirjastoja, Laitoskirjastoja, Kirjastoautoja"
1. SELECTs all branches we have.
2. Finds bookmobiles by the regexp /AU$/ in the branchcode
3. Finds bookboats by the regexp /VE$/ in the branchcode
4. Institutional libraries by /JOE_(LA)KO/, where LA stand for LaitosKirjasto.
5. Main libraries cannot be differentiated from branch libraries so this is fed as a parameter to the script.
6. Branch libraries are what is left after picking all previously mentioned branch types.
=cut

sub statisticsBranchCounts {
    my ($self, $libraryGroup, $mainLibrariesCount) = (@_);

    my $stats = $libraryGroup->getStatistics();

    foreach my $branchcode (sort keys %{$libraryGroup->{branches}}) {
        #Get them bookmobiles!
        if ($branchcode =~ /^\w\w\w_\w\w\wAU$/) {  #JOE_JOEAU, JOE_LIPAU
            $stats->{bookmobiles}++;
        }
        #Get them bookboats!
        elsif ($branchcode =~ /^\w\w\w_\w\w\wVE$/) {  #JOE_JOEVE, JOE_LIPVE
            $stats->{bookboats}++;
        }
        #Get them institutional libraries!
        elsif ($branchcode =~ /^\w\w\w_LA\w\w$/) {  #JOE_LAKO, JOE_LASI
            $stats->{institutionalLibraries}++;
        }
        #Get them branch libraries!
        else {
            $stats->{branchLibraries}++;
        }
    }
    #After all is counted, we remove the given main branches from branch libraries and set the main libraries count.
    $stats->{branchLibraries} = $stats->{branchLibraries} - $mainLibrariesCount;
    $stats->{mainLibraries} = $mainLibrariesCount;
}

sub statisticsSubscriptions {
    my ($self, $libraryGroup) = (@_);
    my @cc = caller(0);
    print '    #'.DateTime->now()->iso8601()."# Starting ".$cc[3]." #\n" if $self->{verbose};

    my $dbh = C4::Context->dbh();
    my $in_libraryGroupBranches = $libraryGroup->getBranchcodesINClause();
    my $limit = $self->getLimit();
    my $sth = $dbh->prepare(
               "SELECT COUNT(subscriptionid) AS count,
                       SUM(IF(  marcxml REGEXP '  <controlfield tag=\"008\">.....................n..................</controlfield>'  ,1,0)) AS newspapers,
                       SUM(IF(  marcxml REGEXP '  <controlfield tag=\"008\">.....................p..................</controlfield>'  ,1,0)) AS magazines
                FROM subscription s LEFT JOIN biblioitems bi ON bi.biblionumber = s.biblionumber
                WHERE branchcode $in_libraryGroupBranches AND
                       NOT (? < startdate AND enddate < ?) $limit");
    #The SQL WHERE-clause up there needs a bit of explaining:
    # Here we find if a subscription intersects with the given timeperiod of our report.
    # Using this algorithm we can define whether two lines are on top of each other in a 1-dimensional space.
    # Think of two lines:
    #   sssssssssssssssssssssss   (subscription duration (s))
    #           tttttttttttttttttttttttttttt   (timeperiod of the report (t))
    # They cannot intersect if t.end < s.start AND s.end < t.start
    $sth->execute( $self->{endDateISO}, $self->{startDateISO} );
    if ($sth->err) {
        Koha::Exception::DB->throw(error => $cc[3]."():> ".$sth->errstr);
    }
    my $retval = $sth->fetchrow_hashref();

    my $stats = $libraryGroup->getStatistics();
    $stats->{newspapers} = $retval->{newspapers} ? $retval->{newspapers} : 0;
    $stats->{magazines} = $retval->{magazines} ? $retval->{magazines} : 0;
    $stats->{count} = $retval->{count} ? $retval->{count} : 0;

    if ($stats->{newspapers} + $stats->{magazines} != $stats->{count}) {
        carp "Calculating subscriptions, total count ".$stats->{count}." is not the same as newspapers ".$stats->{newspapers}." and magazines ".$stats->{magazines}." combined!";
    }
    print '    #'.DateTime->now()->iso8601()."# Leaving ".$cc[3]." #\n" if $self->{verbose};
}
sub statisticsDiscards {
    my ($self, $libraryGroup) = (@_);
    my @cc = caller(0);
    print '    #'.DateTime->now()->iso8601()."# Starting ".$cc[3]." #\n" if $self->{verbose};

    #Do not statistize these itemtypes as item discard:
    my $excludedItemTypes = $self->getItemtypesByStatisticalCategories('Serials', 'Electronic');
    my $dbh = C4::Context->dbh();
    my $in_libraryGroupBranches = $libraryGroup->getBranchcodesINClause();
    my $limit = $self->getLimit();
    my $sql =  "SELECT count(*) FROM deleteditems ".
               "WHERE homebranch $in_libraryGroupBranches ".
               "  AND timestamp BETWEEN ? AND ? ".
               "  AND itype NOT IN (".join(',', map {"'$_'"} @$excludedItemTypes).") ".
#                 AND itype != 'SL' AND itype != 'AL'
               "  $limit; ";

    my $sth = $dbh->prepare($sql);

    $sth->execute( $self->{startDateISO}, $self->{endDateISO} );
    if ($sth->err) {
        Koha::Exception::DB->throw(error => $cc[3]."():> ".$sth->errstr);
    }
    my $discards = $sth->fetchrow;

    my $stats = $libraryGroup->getStatistics();
    $stats->{discards} = $discards;
    print '    #'.DateTime->now()->iso8601()."# Leaving ".$cc[3]." #\n" if $self->{verbose};
}
sub statisticsActiveBorrowers {
    my ($self, $libraryGroup) = (@_);
    #_statisticsOurBorrowersWhoHaveCirculatedInAnyBranch($self, $libraryGroup);
    _statisticsBorrowersWhoCirculatedInOurBranches($self, $libraryGroup);
}
sub _statisticsOurActiveBorrowersWhoHaveCirculatedInAnyBranch {
    my ($self, $libraryGroup) = (@_);
    my @cc = caller(0);
    print '    #'.DateTime->now()->iso8601()."# Starting ".$cc[3]." #\n" if $self->{verbose};

    my $dbh = C4::Context->dbh();
    my $in_libraryGroupBranches = $libraryGroup->getBranchcodesINClause();
    my $limit = $self->getLimit();
    my $sth = $dbh->prepare(
                "SELECT COUNT(stat.borrowernumber) FROM borrowers b
                 LEFT JOIN (
                    SELECT borrowernumber
                    FROM statistics s WHERE s.type IN ('issue','renew') AND datetime BETWEEN ? AND ?
                    GROUP BY s.borrowernumber
                 )
                 AS stat ON stat.borrowernumber = b.borrowernumber
                 WHERE b.branchcode $in_libraryGroupBranches $limit");
    $sth->execute( $self->{startDateISO}, $self->{endDateISO} );
    if ($sth->err) {
        Koha::Exception::DB->throw(error => $cc[3]."():> ".$sth->errstr);
    }
    my $activeBorrowers = $sth->fetchrow;

    my $stats = $libraryGroup->getStatistics();
    $stats->{activeBorrowers} = $activeBorrowers;
    print '    #'.DateTime->now()->iso8601()."# Leaving ".$cc[3]." #\n" if $self->{verbose};
}
sub _statisticsBorrowersWhoCirculatedInOurBranches {
    my ($self, $libraryGroup) = (@_);
    my @cc = caller(0);
    print '    #'.DateTime->now()->iso8601()."# Starting ".$cc[3]." #\n" if $self->{verbose};

    my $dbh = C4::Context->dbh();
    my $in_libraryGroupBranches = $libraryGroup->getBranchcodesINClause();
    my $limit = $self->getLimit();
    my $sth = $dbh->prepare("
        SELECT COUNT(DISTINCT(borrowernumber))
        FROM statistics s
        WHERE s.type IN ('issue','renew') AND
              s.datetime BETWEEN ? AND ? AND
              s.branch $in_libraryGroupBranches $limit
    ");
    $sth->execute( $self->{startDateISO}, $self->{endDateISO} );
    if ($sth->err) {
        Koha::Exception::DB->throw(error => $cc[3]."():> ".$sth->errstr);
    }
    my $activeBorrowers = $sth->fetchrow;

    my $stats = $libraryGroup->getStatistics();
    $stats->{activeBorrowers} = $activeBorrowers;
    print '    #'.DateTime->now()->iso8601()."# Leaving ".$cc[3]." #\n" if $self->{verbose};
}
sub tidyStatistics {
    my ($self, $libraryGroup) = (@_);
    my $stats = $libraryGroup->getStatistics();
    $stats->{expenditureAcquisitionsBooks} = sprintf("%.2f", $stats->{expenditureAcquisitionsBooks});
    $stats->{expenditureAcquisitions}      = sprintf("%.2f", $stats->{expenditureAcquisitions});
}

sub getLibraryGroups {
    my $self = shift;

    return $self->{lib_groups};
}

=head setLibraryGroups

    setLibraryGroups( $libraryGroups );

=cut

sub setLibraryGroups {
    my ($self, $libraryGroups) = @_;

    croak '$libraryGroups parameter is not a HASH of groups of branchcodes!' unless (ref $libraryGroups eq 'HASH');
    $self->{lib_groups} = $libraryGroups;

    foreach my $groupname (sort keys %$libraryGroups) {
        $libraryGroups->{$groupname} = C4::OPLIB::OKMLibraryGroup->new(  $groupname, $libraryGroups->{$groupname}->{branches}  );
    }
    return $self->{lib_groups};
}

=head createLibraryGroupsFromIndividualBranches

    $okm->createLibraryGroupsFromIndividualBranches($individualBranches);

@PARAM1 String, a .csv-row with each element as a branchcode
                'JOE_JOE,JOE_RAN,[...]'
                or
                '_A' which means ALL BRANCHES. Then the function fetches all the branchcodes from DB.
@RETURNS a HASH of library monstrosity
=cut

sub createLibraryGroupsFromIndividualBranches {
    my ($self, $individualBranches) = @_;
    my @iBranchcodes;

    if ($individualBranches eq '_A') {
        @iBranchcodes = keys %{C4::Branch::GetBranches()};
    }
    else {
        @iBranchcodes = split(',',$individualBranches);
        for(my $i=0 ; $i<@iBranchcodes ; $i++) {
            my $bc = $iBranchcodes[$i];
            $bc =~ s/\s//g; #Trim all whitespace
            $iBranchcodes[$i] = $bc;
        }
    }

    my $libraryGroups = {};
    foreach my $branchcode (@iBranchcodes) {
        $libraryGroups->{$branchcode}->{branches} = {$branchcode => 1};
    }
    return $libraryGroups;
}

=head asHtml

    my $html = $okm->asHtml();

Returns an HTML table header and rows for each library group with statistical categories as columns.
=cut

sub asHtml {
    my $self = shift;
    my $libraryGroups = $self->getLibraryGroups();

    my @sb;

    push @sb, '<table>';
    my $firstrun = 1;
    foreach my $groupcode (sort keys %$libraryGroups) {
        my $libraryGroup = $libraryGroups->{$groupcode};
        my $stat = $libraryGroup->getStatistics();

        push @sb, $stat->asHtmlHeader() if $firstrun-- > 0;

        push @sb, $stat->asHtml();
    }
    push @sb, '</table>';

    return join("\n", @sb);
}

=head asCsv

    my $csv = $okm->asCsv();

Returns a csv header and rows for each library group with statistical categories as columns.

@PARAM1 Char, The separator to use to separate columns. Defaults to ','
=cut

sub asCsv {
    my ($self, $separator) = @_;
    my @sb;
    my $a;
    $separator = ',' unless $separator;

    my $libraryGroups = $self->getLibraryGroups();

    my $firstrun = 1;
    foreach my $groupcode (sort keys %$libraryGroups) {
        my $libraryGroup = $libraryGroups->{$groupcode};
        my $stat = $libraryGroup->getStatistics();

        push @sb, $stat->asCsvHeader($separator) if $firstrun-- > 0;

        push @sb, $stat->asCsv($separator);
    }

    return join("\n", @sb);
}

=head asOds

=cut

sub asOds {
    my $self = shift;

    my $ods_fh = File::Temp->new( UNLINK => 0 );
    my $ods_filepath = $ods_fh->filename;

    use OpenOffice::OODoc;
    my $tmpdir = dirname $ods_filepath;
    odfWorkingDirectory( $tmpdir );
    my $container = odfContainer( $ods_filepath, create => 'spreadsheet' );
    my $doc = odfDocument (
        container => $container,
        part      => 'content'
    );
    my $table = $doc->getTable(0);
    my $libraryGroups = $self->getLibraryGroups();

    my $firstrun = 1;
    my $row_i = 1;
    foreach my $groupcode (sort keys %$libraryGroups) {
        my $libraryGroup = $libraryGroups->{$groupcode};
        my $stat = $libraryGroup->getStatistics();

        my $headers = $stat->getPrintOrder() if $firstrun > 0;
        my $columns = $stat->getPrintOrderElements();

        if ($firstrun-- > 0) { #Set the table size and print the header!
            $doc->expandTable( $table, scalar(keys(%$libraryGroups))+1, scalar(@$headers) );
            my $row = $doc->getRow( $table, 0 );
            for (my $j=0 ; $j<@$headers ; $j++) {
                $doc->cellValue( $row, $j, $headers->[$j] );
            }
        }

        my $row = $doc->getRow( $table, $row_i++ );
        for (my $j=0 ; $j<@$columns ; $j++) {
            my $value = Encode::encode( 'UTF8', $columns->[$j] );
            $doc->cellValue( $row, $j, $value );
        }
    }

    $doc->save();
    binmode(STDOUT);
    open $ods_fh, '<', $ods_filepath;
    my @content = <$ods_fh>;
    unlink $ods_filepath;
    return join('', @content);
}

=head getOKMBranchCategories

    C4::OPLIB::OKM::getOKMBranchCategories();
    $okm->getOKMBranchCategories();

Searches Koha for branchcategories ending to letters "_OKM".
These branchcategories map to a OKM annual statistics row.

@RETURNS a hash of branchcategories.categorycode = 1
=cut

sub getOKMBranchCategories {
    my $self = shift;
    my $libraryGroups = {};

    my $branchcategories = C4::Branch::GetBranchCategories();
    for( my $i=0 ; $i<@$branchcategories ; $i++) {
        my $branchCategory = $branchcategories->[$i];
        my $code = $branchCategory->{categorycode};
        if ($code =~ /^\w\w\w_OKM$/) { #Catch branchcategories which are OKM statistical groups.
            #HASHify the categorycodes for easy access
            $libraryGroups->{$code} = $branchCategory;
        }
    }
    return $libraryGroups;
}

=head getOKMBranchCategoriesAndBranches

    C4::OPLIB::OKM::getOKMBranchCategoriesAndBranches();
    $okm->getOKMBranchCategoriesAndBranches();

Calls getOKMBranchCategories() to find the branchCategories and then finds which branchcodes are mapped to those categories.

@RETURNS a hash of branchcategories.categorycode -> branches.branchcode = 1
=cut

sub getOKMBranchCategoriesAndBranches {
    my $self = shift;
    my $libraryGroups = $self->getOKMBranchCategories();

    foreach my $categoryCode (keys %$libraryGroups) {
        my $branchcodes = C4::Branch::GetBranchesInCategory( $categoryCode );

        if (not($branchcodes) || scalar(@$branchcodes) <= 0) {
            $self->log("Statistical library group $categoryCode has no libraries, removing it from OKM statistics");
            delete $libraryGroups->{$categoryCode};
            next();
        }

        #HASHify the branchcodes for easy access
        $libraryGroups->{$categoryCode} = {}; #CategoryCode used to be 1, which makes for a poor HASH reference.
        $libraryGroups->{$categoryCode}->{branches} = {};
        my $branches = $libraryGroups->{$categoryCode}->{branches};
        grep { $branches->{$_} = 1 } @$branchcodes;
    }
    return $libraryGroups;
}

=head FindMarcField

Static method

    my $subfieldContent = FindMarcField('041', 'a', $marcxml);

Finds a single subfield effectively.
=cut

sub FindMarcField {
    my ($tagid, $subfieldid, $marcxml) = @_;
    if ($marcxml =~ /<(data|control)field tag="$tagid".*?>(.*?)<\/(data|control)field>/s) {
        my $fieldStr = $2;
        if ($fieldStr =~ /<subfield code="$subfieldid">(.*?)<\/subfield>/s) {
            return $1;
        }
    }
}

=head isItemChildrens

    $row->{location} = 'LAP';
    my $isChildrens = $okm->isItemChildrens($row);
    assert($isChildrens == 1);

@PARAM1 hash, containing the koha.items.location as location-key
=cut

sub isItemChildrens {
    my ($self, $row) = @_;
    my $juvenileShelvingLocations = $self->{conf}->{juvenileShelvingLocations};

    return 1 if $row->{location} && $juvenileShelvingLocations->{$row->{location}};
    return 0;
}

sub IsItemFiction {
    my ($marcxml) = @_;

    my $sf = FindMarcField('084','a', $marcxml);
    if ($sf =~/^8[1-5].*/) { #ykl numbers 81.* to 85.* are fiction.
        return 1;
    }
    return 0;
}

sub IsItemMusicalRecording {
    my ($marcxml) = @_;

    my $sf = FindMarcField('084','a', $marcxml);
    if ($sf =~/^78.*/) { #ykl number 78 is a musical recording.
        return 1;
    }
    return 0;
}

sub isItemAcquired {
    my ($self, $row) = @_;

    my $startEpoch = $self->{startDate}->epoch();
    my $endEpoch = $self->{endDate}->epoch();
    my $receivedEpoch    = 0;
    my $accessionedEpoch = 0;
    if ($row->{datereceived} && $row->{datereceived} =~ /(\d\d\d\d)-(\d\d)-(\d\d)/) { #Parse ISO date
        eval { $receivedEpoch = DateTime->new(year => $1, month => $2, day => $3, time_zone => C4::Context->tz())->epoch(); };
        if ($@) { #Sometimes the DB has datetimes 0000-00-00 which is not nice for DateTime.
            $receivedEpoch = 0;
        }

    }
    if ($row->{dateaccessioned} && $row->{dateaccessioned} =~ /(\d\d\d\d)-(\d\d)-(\d\d)/) { #Parse ISO date
        eval { $accessionedEpoch = DateTime->new(year => $1, month => $2, day => $3, time_zone => C4::Context->tz())->epoch(); };
        if ($@) { #Sometimes the DB has datetimes 0000-00-00 which is not nice for DateTime.
            $accessionedEpoch = 0;
        }
    }

    #This item has been received from the vendor.
    if ($receivedEpoch) {
        return 1 if $startEpoch <= $receivedEpoch && $endEpoch >= $receivedEpoch;
        return 0; #But this item is not received during the requested timeperiod :(
    }
    #This item has been added to Koha via acquisitions, but the order hasn't been received during the requested timeperiod
    elsif ($row->{ordernumber}) {
        return 0;
    }
    #This item has been added to Koha outside of the acquisitions module
    elsif ($startEpoch <= $accessionedEpoch && $endEpoch >= $accessionedEpoch) {
        return 1; #And this item is added during the requested timeperiod
    }
    else {
        return 0;
    }
}

=head getLimit

    my $limit = $self->getLimit();

Gets the SQL LIMIT clause used in testing this feature faster (but not more accurately). It can be passed to the OKM->new() constructor.
=cut

sub getLimit {
    my $self = shift;
    my $limit = '';
    $limit = 'LIMIT '.$self->{limit} if $self->{limit};
    return $limit;
}

=head save

    $okm->save();

Serializes this object and saves it to the koha.okm_statistics-table

@RETURNS the DBI->error() -text.

=cut

sub save {
    my $self = shift;

    my @cc = caller(0);
    print '    #'.DateTime->now()->iso8601()."# Starting ".$cc[3]." #\n" if $self->{verbose};

    C4::OPLIB::OKMLogs::insertLogs($self->flushLogs());
    #Clean some cumbersome Entities which make serialization quite messy.
    $self->{endDate} = undef; #Like DateTime-objects which serialize quite badly.
    $self->{startDate} = undef;

    $Data::Dumper::Indent = 0;
    $Data::Dumper::Purity = 1;
    my $serialized_self = Data::Dumper::Dumper( $self );

    #See if this yearly OKM is already serialized
    my $dbh = C4::Context->dbh();
    my $sth = $dbh->prepare('SELECT id FROM okm_statistics WHERE startdate = ? AND enddate = ? AND individualbranches = ?');
    $sth->execute( $self->{startDateISO}, $self->{endDateISO}, $self->{individualBranches} );
    if ($sth->err) {
        Koha::Exception::DB->throw(error => $cc[3]."():> ".$sth->errstr);
    }
    if (my $id = $sth->fetchrow()) { #Exists in DB
        $sth = $dbh->prepare('UPDATE okm_statistics SET okm_serialized = ? WHERE id = ?');
        $sth->execute( $serialized_self, $id );
    }
    else {
        $sth = $dbh->prepare('INSERT INTO okm_statistics (startdate, enddate, individualbranches, okm_serialized) VALUES (?,?,?,?)');
        $sth->execute( $self->{startDateISO}, $self->{endDateISO}, $self->{individualBranches}, $serialized_self );
    }
    if ($sth->err) {
        Koha::Exception::DB->throw(error => $cc[3]."():> ".$sth->errstr);
    }
    return undef;
}

=head Retrieve

    my $okm = C4::OPLIB::OKM::Retrieve( $okm_statisticsId, $startDateISO, $endDateISO, $individualBranches );

Gets an OKM-object from the koha.okm_statistics-table.
Either finds the OKM-object by the id-column, or by checking the startdate, enddate and individualbranches.
The latter is used when calculating new statistics, and firstly precalculated values are looked for. If a report
matching the given values is found, then we don't need to rerun it.

Generally you should just pass the parameters given to the OKM-object during initialization here to see if a OKM-report already exists.

@PARAM1 long, okm_statistics.id
@PARAM2 ISO8601 datetime, the start of the statistical reporting period.
@PARAM3 ISO8601 datetime, the end of the statistical reporting period.
@PARAM4 Comma-separated String, list of branchcodes to run statistics of if using the librarygroups is not desired.
=cut
sub Retrieve {
    my ($okm_statisticsId, $timeperiod, $individualBranches) = @_;

    my $okm_serialized;
    if ($okm_statisticsId) {
        $okm_serialized = _RetrieveById($okm_statisticsId);
    }
    else {
        my ($startDate, $endDate) = StandardizeTimeperiodParameter($timeperiod);
        $okm_serialized = _RetrieveByParams($startDate->iso8601(), $endDate->iso8601(), $individualBranches);
    }
    return _deserialize($okm_serialized) if $okm_serialized;
    return undef;
}
sub _RetrieveById {
    my ($id) = @_;

    my $dbh = C4::Context->dbh();
    my $sth = $dbh->prepare('SELECT okm_serialized FROM okm_statistics WHERE id = ?');
    $sth->execute( $id );
    return $sth->fetchrow();
}
sub _RetrieveByParams {
    my ($startDateISO, $endDateISO, $individualBranches) = @_;

    my $dbh = C4::Context->dbh();
    my $sth = $dbh->prepare('SELECT okm_serialized FROM okm_statistics WHERE startdate = ? AND enddate = ? AND individualbranches = ?');
    $sth->execute( $startDateISO, $endDateISO, $individualBranches );
    return $sth->fetchrow();
}
sub RetrieveAll {
    my $dbh = C4::Context->dbh();
    my $sth = $dbh->prepare('SELECT * FROM okm_statistics ORDER BY enddate DESC');
    $sth->execute(  );
    return $sth->fetchall_arrayref({});
}
sub _deserialize {
    my $serialized = shift;
    my $VAR1;
    eval $serialized if $serialized;

    #Rebuild some cumbersome objects
    if ($VAR1) {
        my ($startDate, $endDate) = C4::OPLIB::OKM::StandardizeTimeperiodParameter($VAR1->{startDateISO}.' - '.$VAR1->{endDateISO});
        $VAR1->{startDate} = $startDate;
        $VAR1->{endDate} = $endDate;
        return $VAR1;
    }

    return undef;
}
=head Delete

    C4::OPLIB::OKM::Delete($id);

@PARAM1 Long, The koha.okm_statistics.id of the statistical row to delete.
@RETURNS DBI::Error if database errors, otherwise undef.
=cut
sub Delete {
    my $id = shift;

    my $dbh = C4::Context->dbh();
    my $sth = $dbh->prepare('DELETE FROM okm_statistics WHERE id = ?');
    $sth->execute( $id );
    if ( $sth->err ) {
        return $sth->err;
    }
    return undef;
}

=head _loadConfiguration

    $self->_loadConfiguration();

Loads the configuration YAML from sysprefs and parses it to a Hash.
=cut

sub loadConfiguration {
    my ($self) = @_;

    my $yaml = C4::Context->preference('OKM');
    utf8::encode( $yaml );
    $self->{conf} = YAML::XS::Load($yaml);

    ##Make 'juvenileShelvingLocations' more searchable
    my $juvShelLocs = $self->{conf}->{juvenileShelvingLocations};
    $self->{conf}->{juvenileShelvingLocations} = {};
    foreach my $loc (@{$juvShelLocs}) {
        $self->{conf}->{juvenileShelvingLocations}->{$loc} = 1;
    }

    $self->_validateConfigurationAndPreconditions();
    $self->_makeStatisticalCategoryToItemTypesMap();
}

sub getItemtypesByStatisticalCategories {
    my ($self, @statCats) = @_;
    my @itypes;
    foreach my $sc (@statCats) {
        push(@itypes, @{$self->{conf}->{statisticalCategoryToItemTypes}->{$sc}});
    }
    return \@itypes;
}

=head _validateConfigurationAndPreconditions
Since this is a bit complex feature. Check for correct configurations here.
Also make sure system-wide preconditions and precalculations are in place.
=cut

sub _validateConfigurationAndPreconditions {
    my ($self) = @_;

    ##Make sanity checks for the config and throw an error to tell the user that the config needs fixing.
    my @statCatKeys = ();
    my @juvenileShelLocKeys = ();
    if (ref $self->{conf}->{itemTypeToStatisticalCategory} eq 'HASH') {
        @statCatKeys = keys(%{$self->{conf}->{itemTypeToStatisticalCategory}});
    }
    if (ref $self->{conf}->{juvenileShelvingLocations} eq 'HASH') {
        @juvenileShelLocKeys = keys($self->{conf}->{juvenileShelvingLocations});
    }
    unless (scalar(@statCatKeys)) {
        my @cc = caller(0);
        Koha::Exception::BadSystemPreference->throw(
            error => $cc[3]."():> System preference 'OKM' is missing YAML-parameter 'itemTypeToStatisticalCategory'.\n".
                     "It should look something like this: \n".
                     "itemTypeToStatisticalCategory: \n".
                     "  BK: Books \n".
                     "  MU: Recordings \n");
    }
    unless (scalar(@juvenileShelLocKeys)) {
        my @cc = caller(0);
        Koha::Exception::BadSystemPreference->throw(
            error => $cc[3]."():> System preference 'OKM' is missing YAML-parameter 'juvenileShelvingLocations'.\n".
                     "It should look something like this: \n".
                     "juvenileShelvingLocations: \n".
                     "  - CHILD \n".
                     "  - AV \n");
    }

    my @itypes = C4::ItemType->all();

    ##Check that we haven't accidentally mapped any itemtypes that don't actually exist in our database
    my %mappedItypes = map {$_ => 1} @statCatKeys; #Copy the itemtypes-as-keys

    ##Check that all itemtypes and statistical categories are mapped
    my %statCategories = ( "Books" => 0, "SheetMusicAndScores" => 0,
                        "Recordings" => 0, "Videos" => 0, "CDROMs" => 0,
                        "DVDsAndBluRays" => 0, "Other" => 0, "Serials" => 0,
                        "Electronic" => 0, "Celia" => 0);
    foreach my $itype (@itypes) {
        my $it = $itype->{itemtype};
        my $mapping = $self->getItypeToOKMCategory($it);
        unless ($mapping) { #Is itemtype mapped?
            my @cc = caller(0);
            Koha::Exception::BadSystemPreference->throw(error => $cc[3]."():> System preference 'OKM' has an unmapped itemtype '".$itype->{itemtype}."'. Put it under 'itemTypeToStatisticalCategory'.");
        }
        else {
            delete $mappedItypes{$it};
        }
        if(exists($statCategories{$mapping})) {
            $statCategories{$mapping} = 1; #Mark this mapping as used.
        }
        else { #Do we have extra statistical mappings we dont care of?
            my @cc = caller(0);
            my @statCatKeys = keys(%statCategories);
            Koha::Exception::BadSystemPreference->throw(error => $cc[3]."():> System preference 'OKM' has an unknown mapping '$mapping'. Allowed statistical categories under 'itemTypeToStatisticalCategory' are @statCatKeys");
        }
    }
    #Do we have extra mapped item types?
    if (scalar(keys(%mappedItypes))) {
        my @cc = caller(0);
        my @itypes = keys(%mappedItypes);
        Koha::Exception::BadSystemPreference->throw(error => $cc[3]."():> System preference 'OKM' has an mapped itemtypes '@itypes' that don't exist in your database itemtypes-listing?");
    }

    #Check that all statistical categories are mapped
    while (my ($k, $v) = each(%statCategories)) {
        unless ($v) {
            my @cc = caller(0);
            Koha::Exception::BadSystemPreference->throw(error => $cc[3]."():> System preference 'OKM' has an unmapped statistical category '$k'. Map it to the 'itemTypeToStatisticalCategory'");
        }
    }

    ##Check that koha.biblio_data_elements -table is being updated regularly.
    Koha::BiblioDataElements::verifyFeatureIsInUse($self->{verbose});
}

sub _makeStatisticalCategoryToItemTypesMap {
    my ($self) = @_;
    my %statisticalCategoryToItemTypes;
    while (my ($itype, $statCat) = each(%{$self->{conf}->{itemTypeToStatisticalCategory}})) {
        $statisticalCategoryToItemTypes{$statCat} = [] unless $statisticalCategoryToItemTypes{$statCat};
        push(@{$statisticalCategoryToItemTypes{$statCat}}, $itype);
    }
    $self->{conf}->{statisticalCategoryToItemTypes} = \%statisticalCategoryToItemTypes;
}

=head getItypeToOKMCategory

    my $category = $okm->getItypeToOKMCategory('BK'); #Returns 'Books'

Takes an Itemtype and converts it based on the mapping rules to an OKM statistical
category type, like 'Books'.

@PARAM1 String, itemtype
@RETURNS String, OKM category type or undef
=cut

sub getItypeToOKMCategory {
    my ($self, $itemtype) = @_;
    return $self->{conf}->{itemTypeToStatisticalCategory}->{$itemtype};
}

sub isExecutionBlocked {
    return shift->{conf}->{blockStatisticsGeneration};
}

=head StandardizeTimeperiodParameter

    my ($startDate, $endDate) = C4::OPLIB::OKM::StandardizeTimeperiodParameter($timeperiod);

@PARAM1 String, The timeperiod definition. Supported values are:
                1. "YYYY-MM-DD - YYYY-MM-DD" (start to end, inclusive)
                   "YYYY-MM-DDThh:mm:ss - YYYY-MM-DDThh:mm:ss" is also accepted, but only the YYYY-MM-DD-portion is used.
                2. "YYYY" (desired year)
                3. "MM" (desired month, of the current year)
                4. "lastyear" (Calculates the whole last year)
                5. "lastmonth" (Calculates the whole previous month)
                Kills the process if no timeperiod is defined or if it is unparseable!
@RETURNS Array of DateTime, or die
=cut
sub StandardizeTimeperiodParameter {
    my ($timeperiod) = @_;

    my ($startDate, $endDate);

    if ($timeperiod =~ /^(\d\d\d\d)-(\d\d)-(\d\d)([Tt ]\d\d:\d\d:\d\d)? - (\d\d\d\d)-(\d\d)-(\d\d)([Tt ]\d\d:\d\d:\d\d)?$/) {
        #Make sure the values are correct by casting them into a DateTime
        $startDate = DateTime->new(year => $1, month => $2, day => $3, time_zone => C4::Context->tz());
        $endDate = DateTime->new(year => $5, month => $6, day => $7, time_zone => C4::Context->tz());
    }
    elsif ($timeperiod =~ /^(\d\d\d\d)$/) {
        $startDate = DateTime->from_day_of_year(year => $1, day_of_year => 1, time_zone => C4::Context->tz());
        $endDate = ($startDate->is_leap_year()) ?
                            DateTime->from_day_of_year(year => $1, day_of_year => 366, time_zone => C4::Context->tz()) :
                            DateTime->from_day_of_year(year => $1, day_of_year => 365, time_zone => C4::Context->tz());
    }
    elsif ($timeperiod =~ /^(\d\d)$/) {
        $startDate = DateTime->new( year => DateTime->now()->year(),
                                    month => $1,
                                    day => 1,
                                    time_zone => C4::Context->tz(),
                                   );
        $endDate = DateTime->last_day_of_month( year => $startDate->year(),
                                                month => $1,
                                                time_zone => C4::Context->tz(),
                                              ) if $startDate;
    }
    elsif ($timeperiod =~ 'lastyear') {
        $startDate = DateTime->now(time_zone => C4::Context->tz())->subtract(years => 1)->set_month(1)->set_day(1);
        $endDate = ($startDate->is_leap_year()) ?
                DateTime->from_day_of_year(year => $startDate->year(), day_of_year => 366, time_zone => C4::Context->tz()) :
                DateTime->from_day_of_year(year => $startDate->year(), day_of_year => 365, time_zone => C4::Context->tz()) if $startDate;
    }
    elsif ($timeperiod =~ 'lastmonth') {
        $startDate = DateTime->now(time_zone => C4::Context->tz())->subtract(months => 1)->set_day(1);
        $endDate = DateTime->last_day_of_month( year => $startDate->year(),
                                                month => $startDate->month(),
                                                time_zone => $startDate->time_zone(),
                                              ) if $startDate;
    }

    if ($startDate && $endDate) {
        #Check if startdate is smaller than enddate, if not fix it.
        if (DateTime->compare($startDate, $endDate) == 1) {
            my $temp = $startDate;
            $startDate = $endDate;
            $endDate = $temp;
        }

        #Make sure the HMS portion also starts from 0 and ends at the end of day. The DB usually does timeformat casting in such a way that missing
        #complete DATETIME elements causes issues when they are automaticlly set to 0.
        $startDate->truncate(to => 'day');
        $endDate->set_hour(23)->set_minute(59)->set_second(59);
        return ($startDate, $endDate);
    }
    die "OKM->_standardizeTimeperiodParameter($timeperiod): Timeperiod '$timeperiod' could not be parsed.";
}

=head log

    $okm->log("Something is wrong, why don't you fix it?");
    my $logArray = $okm->getLog();

=cut

sub log {
    my ($self, $message) = @_;
    push @{$self->{logs}}, $message;
    print $message."\n" if $self->{verbose};
}
sub flushLogs {
    my ($self) = @_;
    my $logs = $self->{logs};
    delete $self->{logs};
    return $logs;
}
1; #Happy happy joy joy!
